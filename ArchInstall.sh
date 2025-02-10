#!/bin/bash

# Check if the script is being run as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run this script as root"
        exit 1
    fi
}

# Install a specified package
install_package() {
    local package=$1
    echo "Installing $package tool..."
    pacman -Sy $package --noconfirm || { echo "Failed to install $package"; exit 1; }
    echo "$package tool installation completed."
}

# Optimize the mirrorlist
optimize_mirrorlist() {
    local mirrorlist_file=$1
    local url=$2
    local number=$3
    echo "Optimizing $mirrorlist_file mirror list..."
    reflector --country China --protocol https --sort rate --number $number --save $mirrorlist_file || { echo "Failed to optimize $mirrorlist_file mirror list"; exit 1; }
    echo "$mirrorlist_file mirror list optimization completed."
}

# Update package cache
update_package_cache() {
    echo "Updating package cache..."
    pacman -Sy || { echo "Failed to update package cache"; exit 1; }
    echo "Package cache updated."
}

# Disk management related
handle_disk() {
    # Detect all available disk devices
    available_disks=($(lsblk -d -o NAME | grep -Ev '^(sr|loop)'))
    if [ ${#available_disks[@]} -eq 0 ]; then
        echo "No suitable disk devices found"
        exit 1
    fi

    echo "Available disk devices:"
    for i in "${!available_disks[@]}"; do
        echo "$((i + 1)). /dev/${available_disks[$i]}"
    done

    read -p "Please select the disk number to use (1 - ${#available_disks[@]}): " disk_choice
    if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [ "$disk_choice" -lt 1 ] || [ "$disk_choice" -gt ${#available_disks[@]} ]; then
        echo "Invalid choice"
        exit 1
    fi

    disk_device=${available_disks[$((disk_choice - 1))]}
    echo "You have selected the disk device: /dev/$disk_device"

    # Confirm with the user before proceeding with partitioning and formatting
    read -p "You are about to partition and format /dev/$disk_device. This will erase all data on this disk. Continue? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Operation canceled"
        exit 1
    fi

    # Partition setup
    echo "Partitioning the disk..."
    parted /dev/$disk_device -- mklabel gpt || { echo "Failed to create GPT partition table"; exit 1; }
    parted /dev/$disk_device -- mkpart primary fat32 1MiB 501MiB || { echo "Failed to create EFI partition"; exit 1; }
    parted /dev/$disk_device -- set 1 boot on || { echo "Failed to set EFI partition as bootable"; exit 1; }
    parted /dev/$disk_device -- mkpart primary linux-swap 501MiB 8501MiB || { echo "Failed to create swap partition"; exit 1; }
    parted /dev/$disk_device -- mkpart primary ext4 8501MiB 100% || { echo "Failed to create root partition"; exit 1; }
    echo "Disk partitioning completed."

    # Format partitions
    echo "Formatting the partitions..."
    mkfs.fat -F32 /dev/${disk_device}1 || { echo "Failed to format EFI partition"; exit 1; }
    mkfs.ext4 /dev/${disk_device}3 || { echo "Failed to format root partition"; exit 1; }
    mkswap /dev/${disk_device}2 || { echo "Failed to create swap space"; exit 1; }
    swapon /dev/${disk_device}2 || { echo "Failed to enable swap space"; exit 1; }
    echo "Partition formatting completed."

    # Mount partitions
    echo "Mounting the partitions..."
    mount /dev/${disk_device}3 /mnt || { echo "Failed to mount root partition"; exit 1; }
    mkdir -p /mnt/boot || { echo "Failed to create /boot directory"; exit 1; }
    mount /dev/${disk_device}1 /mnt/boot || { echo "Failed to mount EFI partition"; exit 1; }
    echo "Partition mounting completed."

    # Generate fstab file
    echo "Generating fstab file..."
    genfstab -U /mnt >> /mnt/etc/fstab || { echo "Failed to generate fstab file"; exit 1; }
    echo "fstab file generated."
}

# Main function
main() {
    check_root

    handle_disk

    install_package "reflector"
    optimize_mirrorlist "/etc/pacman.d/mirrorlist" "" 5
    update_package_cache

    echo "Installing base system packages..."
    pacman -S --noconfirm base base-devel linux-firmware || { echo "Failed to install base system packages"; exit 1; }
    echo "Base system packages installation completed."

    # Prompt user for username, user password, and root password
    read -p "Please enter your username: " username
    read -s -p "Please enter password for user $username: " userpassword
    echo ""
    read -s -p "Please enter root password: " rootpassword
    echo ""

    # Choose kernel type
    echo "Please choose the kernel to use:"
    echo "1. Standard Linux kernel (linux)"
    echo "2. Linux LTS kernel (linux-lts)"
    echo "3. Linux Zen kernel (linux-zen)"
    read -p "Please enter your choice (1/2/3): " kernel_choice

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

    # Enter the new system environment
    echo "Entering the new system environment for configuration..."
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

# Add ArchLinuxCN repository
echo "[archlinuxcn]" >> /etc/pacman.conf
echo "SigLevel = Optional TrustAll" >> /etc/pacman.conf
echo "Server = https://mirrors.ustc.edu.cn/archlinuxcn/\$arch" >> /etc/pacman.conf

# Optimize ArchLinuxCN mirror with reflector
reflector --country China --protocol https --sort rate --number 1 --save /etc/pacman.d/mirrorlist-archlinuxcn
# Add optimized ArchLinuxCN mirror to pacman.conf
echo -e "\$(cat /etc/pacman.d/mirrorlist-archlinuxcn)\n\$(cat /etc/pacman.conf)" > /etc/pacman.conf

# Update package cache
pacman -Sy

# Install archlinuxcn-keyring
pacman -S --noconfirm archlinuxcn-keyring

# Install selected kernel and headers
echo "Installing kernel and headers..."
pacman -S --noconfirm $kernel_package || { echo "Failed to install kernel"; exit 1; }
echo "Kernel and headers installation completed."

# Install bootloader (example: GRUB)
echo "Installing bootloader..."
pacman -S --noconfirm grub efibootmgr || { echo "Failed to install GRUB and efibootmgr"; exit 1; }
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || { echo "Failed to install GRUB"; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg || { echo "Failed to generate GRUB config"; exit 1; }
echo "Bootloader installation completed."

# Install sudo and configure wheel group for sudo
pacman -S --noconfirm sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
echo "Sudo installation and configuration completed."

# Create a normal user and set the password
echo "Creating a normal user and setting password..."
useradd -m -g users -G wheel -s /bin/bash $username || { echo "Failed to create user"; exit 1; }
echo "$username:$userpassword" | chpasswd || { echo "Failed to set user password"; exit 1; }
echo "User $username created and password set."

# Set the root password
echo "Setting root password..."
echo "root:$rootpassword" | chpasswd || { echo "Failed to set root password"; exit 1; }
echo "Root password set."

# Enable necessary services
systemctl enable NetworkManager
systemctl enable bluetooth

EOF

    echo "Arch Linux installation completed."
}

# Execute the main function
main
