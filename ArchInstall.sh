#!/bin/bash

# 检查是否以root身份运行
if [ "$EUID" -ne 0 ]; then
    echo "请以root身份运行此脚本"
    exit 1
fi

# 配置镜像源，这里简单选择阿里云源
echo "Server = https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist

# 更新软件包缓存
pacman -Sy

# 安装基本系统包
pacman -S --noconfirm base base-devel linux-firmware

# 检测磁盘设备
disk_device=$(lsblk -d -o NAME | grep -Ev '^(sr|loop)')
if [ -z "$disk_device" ]; then
    echo "未找到合适的磁盘设备"
    exit 1
fi

# 分区设置
parted /dev/$disk_device -- mklabel gpt
parted /dev/$disk_device -- mkpart primary fat32 1MiB 501MiB
parted /dev/$disk_device -- set 1 boot on
parted /dev/$disk_device -- mkpart primary linux-swap 501MiB 8501MiB
parted /dev/$disk_device -- mkpart primary ext4 8501MiB 100%

# 格式化分区
mkfs.fat -F32 /dev/${disk_device}1
mkfs.ext4 /dev/${disk_device}3
mkswap /dev/${disk_device}2
swapon /dev/${disk_device}2

# 挂载分区
mount /dev/${disk_device}3 /mnt
mkdir -p /mnt/boot
mount /dev/${disk_device}1 /mnt/boot

# 生成fstab文件
genfstab -U /mnt >> /mnt/etc/fstab

# 提示用户输入用户名、用户密码和root密码
read -p "请输入用户名: " username
read -s -p "请输入用户密码: " userpassword
echo ""
read -s -p "请输入root密码: " rootpassword
echo ""

# 选择内核
echo "请选择要安装的内核:"
echo "1. 标准Linux内核 (linux)"
echo "2. Linux LTS内核 (linux-lts)"
echo "3. Linux Zen内核 (linux-zen)"
read -p "请输入选项 (1/2/3): " kernel_choice

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
        echo "无效选择，使用标准Linux内核"
        kernel_package="linux linux-headers"
        ;;
esac

# 进入新系统环境
arch-chroot /mnt /bin/bash <<EOF
# 设置时区
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc

# 配置locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
export LANG=en_US.UTF-8

# 设置主机名
echo "myarch" > /etc/hostname

# 配置网络
echo -e "[Match]\nName=eth0\n\n[Network]\nDHCP=yes" > /etc/systemd/network/20-wired.network
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# 安装选择的内核及相关头文件
pacman -S --noconfirm $kernel_package

# 安装引导程序（GRUB示例）
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# 创建普通用户并设置密码
useradd -m -g users -G wheel -s /bin/bash $username
echo "$username:$userpassword" | chpasswd

# 设置root密码
echo "root:$rootpassword" | chpasswd

# 安装sudo并配置允许wheel组使用sudo
pacman -S --noconfirm sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# 安装一些常用软件包示例
pacman -S --noconfirm vim git
EOF

# 退出chroot环境
exit

# 卸载挂载的分区
umount -R /mnt

