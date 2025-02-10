#!/bin/bash

# Function to check if the script is run as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run this script as root."
        exit 1
    fi
}

# Function to install a package
install_package() {
    local package=$1
    echo "Installing $package..."
    pacman -S --noconfirm $package || { echo "Failed to install $package"; exit 1; }
}

# Function to optimize the mirror list
optimize_mirrorlist() {
    local mirrorlist_file=$1
    local url=$2
    local number=$3
    echo "Optimizing $mirrorlist_file mirror..."
    reflector --country China --protocol https --sort rate --save $mirrorlist_file --url "$url" --number $number || { echo "Failed to optimize $mirrorlist_file"; exit 1; }
    echo "$mirrorlist_file optimization complete."
}

# Function to update package cache
update_package_cache() {
    echo "Updating package cache..."
    pacman -Sy || { echo "Failed to update package cache"; exit 1; }
    echo "Package cache update complete."
}

# Function to handle disk operations
handle_disk() {
    # List available disks
    available_disks=($(lsblk -d -o NAME | grep -Ev '^(sr|loop)'))
    if [ ${#available_disks[@]} -eq 0 ]; then
        echo "No available disks found."
        exit 1
    fi

    echo "Available disks:"
    for i in "${!available_disks[@]}"; do
        echo "$((i + 1)). /dev/${available_disks[$i]}"
    done

    # Get user input for the disk to be used
    read -p "Choose the disk to use (1 - ${#available_disks[@]}): " disk_choice
    if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [ "$disk_choice" -lt 1 ] || [ "$disk_choice" -gt ${#available_disks[@]} ]; then
        echo "Invalid choice."
        exit 1
    fi

    disk_device=${available_disks[$((disk_choice - 1))]}
    echo "You selected: /dev/$disk_device"

    # Confirm the action
    read -p "This will delete all data on /dev/$disk_device. Do you want to continue? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Operation canceled."
        exit 1
    fi

    # Partition the disk
    echo "Partitioning /dev/$disk_device..."
    parted /dev/$disk_device -- mklabel gpt || { echo "Failed to create GPT partition table"; exit 1; }
    parted /dev/$disk_device -- mkpart primary fat32 1MiB 501MiB || { echo "Failed to create EFI partition"; exit 1; }
    parted /dev/$disk_device -- set 1 boot on || { echo "Failed to mark EFI partition as bootable"; exit 1; }
    parted /dev/$disk_device -- mkpart primary linux-swap 501MiB 8501MiB || { echo "Failed to create swap partition"; exit 1; }
    parted /dev/$disk_device -- mkpart primary ext4 8501MiB 100% || { echo "Failed to create root partition"; exit 1; }
    echo "Partitioning complete."

    # Format partitions
    echo "Formatting partitions..."
    mkfs.fat -F32 /dev/${disk_device}1 || { echo "Failed to format EFI partition"; exit 1; }
    mkfs.ext4 /dev/${disk_device}3 || { echo "Failed to format root partition"; exit 1; }
    mkswap /dev/${disk_device}2 || { echo "Failed to create swap space"; exit 1; }
    swapon /dev/${disk_device}2 || { echo "Failed to enable swap space"; exit 1; }
    echo "Partition formatting complete."

    # Mount the partitions
    echo "Mounting partitions..."
    mount /dev/${disk_device}3 /mnt || { echo "Failed to mount root partition"; exit 1; }
    mkdir -p /mnt/boot || { echo "Failed to create /boot directory"; exit 1; }
    mount /dev/${disk_device}1 /mnt/boot || { echo "Failed to mount EFI partition"; exit 1; }
    echo "Mounting complete."

    # Generate fstab file
    echo "Generating fstab file..."
    genfstab -U /mnt >> /mnt/etc/fstab || { echo "Failed to generate fstab file"; exit 1; }
    echo "fstab file generated."
}

# Main function
main() {
    check_root

    # Disk handling
    handle_disk

    # Install reflector and optimize mirrorlist
    install_package "reflector"
    optimize_mirrorlist "/etc/pacman.d/mirrorlist" "" 5
    update_package_cache

    # Install base system packages
    echo "Installing base system packages..."
    pacman -S --noconfirm base base-devel linux-firmware || { echo "Failed to install base packages"; exit 1; }
    echo "Base system packages installation complete."

    # Get user input for username and passwords
    read -p "Enter username: " username
    read -s -p "Enter password for user $username: " userpassword
    echo ""
    read -s -p "Enter root password: " rootpassword
    echo ""

    # Choose kernel
    echo "Choose a kernel:"
    echo "1. Standard Linux kernel (linux)"
    echo "2. Linux LTS kernel (linux-lts)"
    echo "3. Linux Zen kernel (linux-zen)"
    read -p "Enter option (1/2/3): " kernel_choice

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
            echo "Invalid choice, using standard Linux kernel"
            kernel_package="linux linux-headers"
            ;;
    esac

    # Enter chroot environment for further setup
    echo "Entering new system environment for configuration..."
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

# Set hostname
echo "myarch" > /etc/hostname

# Configure network
echo -e "[Match]\nName=*\n\n[Network]\nDHCP=yes" > /etc/systemd/network/20-wired.network
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Install archlinuxcn repository
echo "[archlinuxcn]" >> /etc/pacman.conf
echo "SigLevel = Optional TrustAll" >> /etc/pacman.conf
echo "Server = https://mirrors.ustc.edu.cn/archlinuxcn/\$arch" >> /etc/pacman.conf

# Update package cache
$(update_package_cache)

# Install keyring and kernel
echo "Installing kernel and keyring..."
pacman -S --noconfirm $kernel_package || { echo "Failed to install kernel"; exit 1; }

# Install GRUB
pacman -S --noconfirm grub efibootmgr || { echo "Failed to install GRUB and efibootmgr"; exit 1; }
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || { echo "Failed to install GRUB"; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg || { echo "Failed to generate GRUB config"; exit 1; }

# Install sudo and configure wheel group
pacman -S --noconfirm sudo || { echo "Failed to install sudo"; exit 1; }
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Create user and set password
useradd -m -g users -G wheel -s /bin/bash $username || { echo "Failed to create user"; exit 1; }
echo "$username:$userpassword" | chpasswd || { echo "Failed to set user password"; exit 1; }

# Set root password
echo "root:$rootpassword" | chpasswd || { echo "Failed to set root password"; exit 1; }

# Exit chroot
exit
EOF

    echo "System installation complete. You can now reboot."
}

# Run the main function
main
