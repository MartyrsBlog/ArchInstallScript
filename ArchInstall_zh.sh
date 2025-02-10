#!/bin/bash

# 检查是否以root身份运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请以root身份运行此脚本"
        exit 1
    fi
}

# 安装指定软件包
install_package() {
    local package=$1
    echo "正在安装 $package 工具..."
    pacman -Sy $package --noconfirm || { echo "安装 $package 失败"; exit 1; }
    echo "$package 工具安装完成。"
}

# 优化镜像源
optimize_mirrorlist() {
    local mirrorlist_file=$1
    local url=$2
    local number=$3
    echo "正在优化 $mirrorlist_file 镜像源..."
    reflector --country China --protocol https --sort rate --save $mirrorlist_file --url "$url" --number $number || { echo "优化 $mirrorlist_file 镜像源失败"; exit 1; }
    echo "$mirrorlist_file 镜像源优化完成。"
}

# 更新软件包缓存
update_package_cache() {
    echo "正在更新软件包缓存..."
    pacman -Sy || { echo "更新软件包缓存失败"; exit 1; }
    echo "软件包缓存更新完成。"
}

# 磁盘操作相关
handle_disk() {
    # 检测所有可用磁盘设备
    available_disks=($(lsblk -d -o NAME | grep -Ev '^(sr|loop)'))
    if [ ${#available_disks[@]} -eq 0 ]; then
        echo "未找到合适的磁盘设备"
        exit 1
    fi

    echo "可用的磁盘设备如下："
    for i in "${!available_disks[@]}"; do
        echo "$((i + 1)). /dev/${available_disks[$i]}"
    done

    read -p "请选择要使用的磁盘编号 (1 - ${#available_disks[@]}): " disk_choice
    if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [ "$disk_choice" -lt 1 ] || [ "$disk_choice" -gt ${#available_disks[@]} ]; then
        echo "无效的选择"
        exit 1
    fi

    disk_device=${available_disks[$((disk_choice - 1))]}
    echo "你选择的磁盘设备是: /dev/$disk_device"

    # 提示用户确认操作
    read -p "即将对 /dev/$disk_device 进行分区和格式化操作，此操作将清除该磁盘上的所有数据。是否继续？(y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "操作已取消"
        exit 1
    fi

    # 分区设置
    echo "正在对磁盘进行分区设置..."
    parted /dev/$disk_device -- mklabel gpt || { echo "创建GPT分区表失败"; exit 1; }
    parted /dev/$disk_device -- mkpart primary fat32 1MiB 501MiB || { echo "创建EFI分区失败"; exit 1; }
    parted /dev/$disk_device -- set 1 boot on || { echo "设置EFI分区为可引导失败"; exit 1; }
    parted /dev/$disk_device -- mkpart primary linux-swap 501MiB 8501MiB || { echo "创建交换分区失败"; exit 1; }
    parted /dev/$disk_device -- mkpart primary ext4 8501MiB 100% || { echo "创建根分区失败"; exit 1; }
    echo "磁盘分区设置完成。"

    # 格式化分区
    echo "正在格式化分区..."
    mkfs.fat -F32 /dev/${disk_device}1 || { echo "格式化EFI分区失败"; exit 1; }
    mkfs.ext4 /dev/${disk_device}3 || { echo "格式化根分区失败"; exit 1; }
    mkswap /dev/${disk_device}2 || { echo "创建交换空间失败"; exit 1; }
    swapon /dev/${disk_device}2 || { echo "启用交换空间失败"; exit 1; }
    echo "分区格式化完成。"

    # 挂载分区
    echo "正在挂载分区..."
    mount /dev/${disk_device}3 /mnt || { echo "挂载根分区失败"; exit 1; }
    mkdir -p /mnt/boot || { echo "创建/boot目录失败"; exit 1; }
    mount /dev/${disk_device}1 /mnt/boot || { echo "挂载EFI分区失败"; exit 1; }
    echo "分区挂载完成。"

    # 生成fstab文件
    echo "正在生成 fstab 文件..."
    genfstab -U /mnt >> /mnt/etc/fstab || { echo "生成fstab文件失败"; exit 1; }
    echo "fstab 文件生成完成。"
}

# 主函数
main() {
    check_root

    handle_disk

    install_package "reflector"
    optimize_mirrorlist "/etc/pacman.d/mirrorlist" "" 5
    update_package_cache

    echo "正在安装基本系统包..."
    pacman -S --noconfirm base base-devel linux-firmware || { echo "安装基本系统包失败"; exit 1; }
    echo "基本系统包安装完成。"

    # 提示用户输入用户名、用户密码和root密码
    read -p "请输入用户名: " username
    read -s -p "请输入用户 $username 的密码: " userpassword
    echo ""
    read -s -p "请输入 root 密码: " rootpassword
    echo ""

    # 选择内核
    echo "请选择要使用的内核:"
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
    echo "正在进入新系统环境进行配置..."
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

# 添加 ArchLinuxCN 源
echo "[archlinuxcn]" >> /etc/pacman.conf
echo "SigLevel = Optional TrustAll" >> /etc/pacman.conf
echo "Server = https://mirrors.ustc.edu.cn/archlinuxcn/\$arch" >> /etc/pacman.conf

# 使用 reflector 对 ArchLinuxCN 源进行测速并优化
$(optimize_mirrorlist "/etc/pacman.d/mirrorlist-archlinuxcn" "https://mirrors.ustc.edu.cn/archlinuxcn/\$arch" 1)
# 将优化后的 ArchLinuxCN 源添加到 pacman.conf
echo -e "\$(cat /etc/pacman.d/mirrorlist-archlinuxcn)\n\$(cat /etc/pacman.conf)" > /etc/pacman.conf

# 更新软件包缓存
$(update_package_cache)

# 安装 archlinuxcn-keyring
$(install_package "archlinuxcn-keyring")

# 安装选择的内核及相关头文件
echo "正在安装内核及相关头文件..."
pacman -S --noconfirm $kernel_package || { echo "安装内核失败"; exit 1; }
echo "内核及相关头文件安装完成。"

# 安装引导程序（GRUB示例）
echo "正在安装引导程序..."
pacman -S --noconfirm grub efibootmgr || { echo "安装GRUB和efibootmgr失败"; exit 1; }
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || { echo "安装GRUB失败"; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg || { echo "生成GRUB配置文件失败"; exit 1; }
echo "引导程序安装完成。"

# 安装sudo并配置允许wheel组使用sudo
$(install_package "sudo")
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
echo "sudo 安装及权限配置完成。"

# 创建普通用户并设置密码
echo "正在创建普通用户并设置密码..."
useradd -m -g users -G wheel -s /bin/bash $username || { echo "创建用户失败"; exit 1; }
echo "$username:$userpassword" | chpasswd || { echo "设置用户密码失败"; exit 1; }
echo "普通用户创建及密码设置完成。"

# 设置root密码
echo "正在设置 root 密码..."
echo "root:$rootpassword" | chpasswd || { echo "设置root密码失败"; exit 1; }
echo "root 密码设置完成。"

# 安装 yay
$(install_package "yay")

# 安装一些常用软件包示例
echo "正在安装常用软件包..."
pacman -S --noconfirm vim git || { echo "安装常用软件包失败"; exit 1; }
echo "常用软件包安装完成。"
EOF
    echo "新系统环境配置完成。"

    # 退出chroot环境

    # 卸载挂载的分区
    echo "正在卸载挂载的分区..."
    umount -R /mnt || { echo "卸载挂载的分区失败"; exit 1; }
    echo "挂载的分区卸载完成。"

    # 清理 pacman 缓存
    echo "正在清理 pacman 缓存..."
    pacman -Sc --noconfirm
    echo "pacman 缓存清理完成。"

    echo "Arch Linux 安装完成，请重启系统。"
}

main
