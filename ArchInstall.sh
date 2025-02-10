#!/bin/bash

# 检查是否以root身份运行
if [ "$EUID" -ne 0 ]; then
    echo "请以root身份运行此脚本"
    exit 1
fi

# 安装 reflector 工具
pacman -Sy reflector --noconfirm || { echo "安装 reflector 失败"; exit 1; }

# 使用 reflector 优化镜像源，筛选中国的镜像源，按下载速度排序并取前 5 个
reflector --country China --protocol https --sort rate --save /etc/pacman.d/mirrorlist --number 5 || { echo "优化镜像源失败"; exit 1; }

# 更新软件包缓存
pacman -Sy || { echo "更新软件包缓存失败"; exit 1; }

# 安装基本系统包
pacman -S --noconfirm base base-devel linux-firmware || { echo "安装基本系统包失败"; exit 1; }

# 检测磁盘设备
disk_device=$(lsblk -d -o NAME | grep -Ev '^(sr|loop)' | head -n 1)
if [ -z "$disk_device" ]; then
    echo "未找到合适的磁盘设备"
    exit 1
fi
echo "检测到磁盘设备: /dev/$disk_device"

# 分区设置
parted /dev/$disk_device -- mklabel gpt || { echo "创建GPT分区表失败"; exit 1; }
parted /dev/$disk_device -- mkpart primary fat32 1MiB 501MiB || { echo "创建EFI分区失败"; exit 1; }
parted /dev/$disk_device -- set 1 boot on || { echo "设置EFI分区为可引导失败"; exit 1; }
parted /dev/$disk_device -- mkpart primary linux-swap 501MiB 8501MiB || { echo "创建交换分区失败"; exit 1; }
parted /dev/$disk_device -- mkpart primary ext4 8501MiB 100% || { echo "创建根分区失败"; exit 1; }

# 格式化分区
mkfs.fat -F32 /dev/${disk_device}1 || { echo "格式化EFI分区失败"; exit 1; }
mkfs.ext4 /dev/${disk_device}3 || { echo "格式化根分区失败"; exit 1; }
mkswap /dev/${disk_device}2 || { echo "创建交换空间失败"; exit 1; }
swapon /dev/${disk_device}2 || { echo "启用交换空间失败"; exit 1; }

# 挂载分区
mount /dev/${disk_device}3 /mnt || { echo "挂载根分区失败"; exit 1; }
mkdir -p /mnt/boot || { echo "创建/boot目录失败"; exit 1; }
mount /dev/${disk_device}1 /mnt/boot || { echo "挂载EFI分区失败"; exit 1; }

# 生成fstab文件
genfstab -U /mnt >> /mnt/etc/fstab || { echo "生成fstab文件失败"; exit 1; }

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
echo -e "[Match]\nName=*\n\n[Network]\nDHCP=yes" > /etc/systemd/network/20-wired.network
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# 安装选择的内核及相关头文件
pacman -S --noconfirm $kernel_package || { echo "安装内核失败"; exit 1; }

# 安装引导程序（GRUB示例）
pacman -S --noconfirm grub efibootmgr || { echo "安装GRUB和efibootmgr失败"; exit 1; }
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || { echo "安装GRUB失败"; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg || { echo "生成GRUB配置文件失败"; exit 1; }

# 创建普通用户并设置密码
useradd -m -g users -G wheel -s /bin/bash $username || { echo "创建用户失败"; exit 1; }
echo "$username:$userpassword" | chpasswd || { echo "设置用户密码失败"; exit 1; }

# 设置root密码
echo "root:$rootpassword" | chpasswd || { echo "设置root密码失败"; exit 1; }

# 安装sudo并配置允许wheel组使用sudo
pacman -S --noconfirm sudo || { echo "安装sudo失败"; exit 1; }
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# 安装一些常用软件包示例
pacman -S --noconfirm vim git || { echo "安装常用软件包失败"; exit 1; }
EOF

# 退出chroot环境

# 卸载挂载的分区
umount -R /mnt || { echo "卸载挂载的分区失败"; exit 1; }
echo "Arch Linux 安装完成，请重启系统。"

