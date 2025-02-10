#!/bin/bash

# Check if the script is being run as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run this script as root"
        exit 1
    fi
}

# Install a package using pacman
install_package() {
    local package=$1
    echo "Installing $package..."
    pacman -Sy $package --noconfirm || { echo "Failed to install $package"; exit 1; }
    echo "$package installation complete."
}

# Optimize mirrorlist using reflector
optimize_mirrorlist() {
    local mirrorlist_file=$1
    local number=$2
    echo "Optimizing $mirrorlist_file using reflector..."

    # Ensure that the number of mirrors is set to a default if not provided
    number=${number:-5}

    # Use reflector to generate an optimized mirrorlist
    reflector --country China --protocol https --sort rate --number $number --save $mirrorlist_file || { echo "Failed to optimize $mirrorlist_file"; exit 1; }

    echo "$mirrorlist_file optimization complete."
}

# Update package database
update_package_cache() {
    echo "Updating package database..."
    pacman -Sy || { echo "Failed to update package database"; exit 1; }
    echo "Package database update complete."
}

# Disk partitioning
handle_disk() {
    available_disks=($(lsblk -d -o NAME | grep -Ev '^(sr|loop)'))
    if [ ${#available_disks[@]} -eq 0 ]; then
        echo "No suitable disk found"
        exit 1
    fi

    echo "Available disks:"
    for i in "${!available_disks[@]}"; do
        echo "$((i + 1)). /dev/${available_disks[$i]}"
    done

    read -p "Select disk number (1-${#available_disks[@]}): " disk_choice
    if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [ "$disk_choice" -lt 1 ] || [ "$disk_choice" -gt ${#available_disks[@]} ]; then
        echo "Invalid choice"
        exit 1
    fi

    disk_device=${available_disks[$((disk_choice - 1))]}
    echo "Selected disk: /dev/$disk_device"

    # Confirm the operation
    read -p "Warning: This will erase all data on /dev/$disk_device. Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Operation canceled"
        exit 1
    fi

    # Partitioning
    echo "Partitioning the disk..."
    parted /dev/$disk_device -- mklabel gpt || { echo "Failed to create GPT partition table"; exit 1; }
    parted /dev/$disk_device -- mkpart primary fat32 1MiB 501MiB || { echo "Failed to create EFI partition"; exit 1; }
    parted /dev/$disk_device -- set 1 boot on || { echo "Failed to set EFI partition as bootable"; exit 1; }
    parted /dev/$disk_device -- mkpart primary linux-swap 501MiB 8501MiB || { echo "Failed to create swap partition"; exit 1; }
    parted /dev/$disk_device -- mkpart primary ext4 8501MiB 100% || { echo "Failed to create root partition"; exit 1; }
    echo "Partitioning complete."

    # Format partitions
    echo "Formatting partitions..."
    mkfs.fat -F32 /dev/${disk_device}1 || { echo "Failed to format EFI partition"; exit 1; }
    mkfs.ext4 /dev/${disk_device}3 || { echo "Failed to format root partition"; exit 1; }
    mkswap /dev/${disk_device}2 || { echo "Failed to create swap space"; exit 1; }
    swapon /dev/${disk_device}2 || { echo "Failed to enable swap space"; exit 1; }
    echo "Formatting complete."

    # Mount partitions
    echo "Mounting partitions..."
    mount /dev/${disk_device}3 /mnt || { echo "Failed to mount root partition"; exit 1; }
    mkdir -p /mnt/boot || { echo "Failed to create /boot directory"; exit 1; }
    mount /dev/${disk_device}1 /mnt/boot || { echo "Failed to mount EFI partition"; exit 1; }
    echo "Partitions mounted."

    # Create /mnt/etc if it doesn't exist
    if [ ! -d "/mnt/etc" ]; then
        echo "Creating /mnt/etc directory..."
        mkdir -p /mnt/etc || { echo "Failed to create /mnt/etc"; exit 1; }
    fi

    # Generate fstab file
    echo "Generating fstab file..."
    genfstab -U /mnt >> /mnt/etc/fstab || { echo "Failed to generate fstab file"; exit 1; }
    echo "fstab file generated."
}

# Main function
main() {
    check_root
    handle_disk
    optimize_mirrorlist "/etc/pacman.d/mirrorlist" 5
    update_package_cache

    # Select CPU type for microcode
    echo "Select CPU type:"
    echo "1. Intel"
    echo "2. AMD"
    read -p "Enter choice (1/2): " cpu_choice

    # Choose kernel
    echo "Select kernel to install:"
    echo "1. Standard Linux Kernel (linux)"
    echo "2. Linux LTS Kernel (linux-lts)"
    echo "3. Linux Zen Kernel (linux-zen)"
    read -p "Enter choice (1/2/3): " kernel_choice

    case $kernel_choice in
        1)
            kernel_package="linux linux-headers"
            ;;
        2)
            kernel_package="linux-lts linux-lts-headers"
            ;;
        3)
            kernel_package="linux-zen linux-zen-headers"
            ;;
        *)
            echo "Invalid choice, defaulting to Standard Linux Kernel"
            kernel_package="linux linux-headers"
            ;;
    esac

    # Install base system packages and selected kernel
    echo "Installing base system packages..."
    pacstrap /mnt base base-devel $kernel_package linux-firmware || { echo "Failed to install base system packages"; exit 1; }
    echo "Base system packages installed."

    # Enter chroot environment to configure the new system
    echo "Entering chroot environment..."

    arch-chroot /mnt /bin/bash <<EOF
# Set timezone
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc

# Configure locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
export LANG=en_US.UTF-8

# Install microcode for Intel or AMD
if [ "$cpu_choice" == "1" ]; then
    # Intel microcode
    pacman -S --noconfirm intel-ucode || { echo "Failed to install Intel microcode"; exit 1; }
elif [ "$cpu_choice" == "2" ]; then
    # AMD microcode
    pacman -S --noconfirm amd-ucode || { echo "Failed to install AMD microcode"; exit 1; }
fi

# Install bootloader (GRUB example)
pacman -S --noconfirm grub efibootmgr || { echo "Failed to install GRUB and efibootmgr"; exit 1; }
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch || { echo "Failed to install GRUB"; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg || { echo "Failed to generate GRUB configuration"; exit 1; }

# Create user and set passwords
useradd -m -g users -G wheel -s /bin/bash $username || { echo "Failed to create user"; exit 1; }
echo "$username:$userpassword" | chpasswd || { echo "Failed to set user password"; exit 1; }
echo "User $username created."

# Set root password
echo "root:$rootpassword" | chpasswd || { echo "Failed to set root password"; exit 1; }

# Install common packages
pacman -S --noconfirm vim git || { echo "Failed to install common packages"; exit 1; }
EOF

    echo "System setup complete. Please reboot."
}

main
