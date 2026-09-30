### AnyKernel3 Ramdisk Mod Script
## 由本工程生成：只替换 kernel Image，保留原机 DTB 与 ramdisk
##
## 为什么只换 Image：
##   vendor/unicorn_GKI.config 里只有 MI_CHARGER_M81 / MI_THERMAL_MULTI_CHARGE
##   两个电源相关配置，与设备树无关；本次改动只涉及内核配置
##   （cgroup / namespace / ReSukiSU），不动 DTS。
##   所以保留原机 DTB 是安全的，也避免自编 DTB 与机器不匹配。
##
## LineageOS 的 boot 镜像规格（来自 sm8450-common/BoardConfigCommon.mk）：
##   BOARD_BOOT_HEADER_VERSION := 4
##   BOARD_RAMDISK_USE_LZ4 := true
##   BOARD_KERNEL_IMAGE_NAME := Image
##   BOARD_INCLUDE_DTB_IN_BOOTIMG := true
##   -> 交给 AnyKernel3 的 magiskboot 处理即可，不要手工按 header v3 拼包。

properties() { '
kernel.string=Unicorn 5.10 GKI + ReSukiSU + Docker cgroups
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=unicorn
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

# shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto

## AnyKernel 内部方法（请勿修改）
. tools/ak3-core.sh;

## 安装
dump_boot;

# ---------------------------------------------------------------------------
# 说明：AnyKernel3 会自动把压缩包根目录的 kernel 镜像（Image / Image.gz 等）
#       替换进 boot 镜像的 kernel 段；这里没有放 dtb 文件，所以原机 DTB 保留。
#       如果想连 DTB 一起替换，把 dtb 文件放到压缩包根目录即可（本项目不推荐）。
# ---------------------------------------------------------------------------

write_boot;
## end install
