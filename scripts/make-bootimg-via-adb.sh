#!/usr/bin/env bash
# =============================================================================
# make-bootimg-via-adb.sh —— 把自编内核 Image 打进一个可直接刷的 boot.img
#
# 为什么需要它：
#   本工程的交付物是【裸内核 Image】（make Image），它本身不能刷进分区。
#   可刷的 boot 镜像 = 头部 + 内核 + ramdisk + cmdline + dtb，其中 ramdisk
#   必须来自你的 ROM —— 所以只能"拿一个现成的 boot 镜像，把里面的内核换掉"。
#
# 做法（全程在手机上用 magiskboot 完成，避免在 Windows 上找交叉工具）：
#   1. 把 AK3 zip 推到 /data/local/tmp（手机自带 unzip，就不用宿主机解压）
#   2. 在里面解出 tools/magiskboot 和 Image
#   3. magiskboot unpack <base_boot.img>     -> kernel / ramdisk.cpio / ...
#   4. 用我们的 Image 覆盖 kernel
#   5. magiskboot repack <base_boot.img>     -> 新的 boot-new.img
#   6. 拉回本地一份，同时推回 /sdcard/ 方便直接用 App 刷
#
# ⚠️ base 镜像的选择很关键：
#   最稳的是 dump【当前】boot 分区（在 ReSukiSU 管理器的 root 终端里执行）：
#       dd if=/dev/block/by-name/boot_b of=/sdcard/boot_b_current.img bs=1M
#   本脚本会优先用 /sdcard/boot_b_current.img，其次 <slot> 变体，最后 /sdcard/boot.img。
#
# 用法:
#   bash scripts/make-bootimg-via-adb.sh [AK3zip] [base_img] [out_name]
#     默认 AK3zip   = ./anykernel3-unicorn-fixed.zip
#     默认 base_img = 按上面的顺序自动挑
#     默认 out_name = boot-unicorn-custom.img
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AK3_ZIP="${1:-$HERE/anykernel3-unicorn-fixed.zip}"
BASE_IMG="${2:-}"
OUT_NAME="${3:-boot-unicorn-custom.img}"

# adb 路径：优先环境变量，其次本机常见位置，最后 PATH
ADB="${ADB:-}"
if [ -z "$ADB" ]; then
  for c in \
    "/e/YanRainOTAToolBox_v1.1.2_x64_portable/resources/platform-tools/windows/adb.exe" \
    "$(command -v adb 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADB="$c"; break; }
  done
fi

err()  { printf '\n[ERROR] %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }

[ -n "$ADB" ] || { err "找不到 adb，可先 export ADB=/path/to/adb"; exit 2; }
[ -f "$AK3_ZIP" ] || { err "找不到 AK3 zip: $AK3_ZIP"; exit 2; }

# Git Bash 下 /sdcard/... 会被当成 Windows 路径改写，必须关掉
export MSYS_NO_PATHCONV=1

step "0. 检查设备"
"$ADB" devices -l 2>&1
SER="$("$ADB" shell getprop ro.serialno 2>/dev/null | tr -d '\r\n')"
[ -n "$SER" ] || { err "没有检测到设备（请插上 USB 并允许调试）"; exit 1; }
SLOT="$("$ADB" shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r\n')"
info "  serial = $SER"
info "  slot   = $SLOT"
info "  uname  = $("$ADB" shell uname -r 2>/dev/null | tr -d '\r\n')"

# ---- base 镜像 -------------------------------------------------------------
if [ -z "$BASE_IMG" ]; then
  for cand in "/sdcard/boot_b_current.img" "/sdcard/boot${SLOT}_current.img" \
              "/sdcard/boot.img" "/sdcard/boot_b.img"; do
    if "$ADB" shell "[ -f $cand ] && echo yes" 2>/dev/null | grep -q yes; then
      BASE_IMG="$cand"; break
    fi
  done
fi
[ -n "$BASE_IMG" ] || {
  err "没找到可用的 base boot 镜像。请先在 ReSukiSU 管理器的 root 终端里执行："
  err "    dd if=/dev/block/by-name/boot${SLOT} of=/sdcard/boot_b_current.img bs=1M"
  err "  然后重新运行本脚本。"
  exit 1
}
info ""
info "  base 镜像 = $BASE_IMG"

# ---- 手机上准备工具 --------------------------------------------------------
WORK=/data/local/tmp/bootimg-build
step "1. 推送 AK3 zip 并在手机上解出 magiskboot 与 Image"
"$ADB" push "$AK3_ZIP" "/data/local/tmp/ak3src.zip" 2>&1 | tail -1
"$ADB" shell "rm -rf $WORK && mkdir -p $WORK && cd $WORK && \
  unzip -o -q /data/local/tmp/ak3src.zip tools/magiskboot Image 2>&1 | head -5; \
  chmod 755 tools/magiskboot 2>/dev/null; \
  ls -l tools/magiskboot Image" 2>&1

step "2. 用 magiskboot 拆开 base 镜像"
"$ADB" shell "cd $WORK && cp '$BASE_IMG' boot.img && ./tools/magiskboot unpack boot.img 2>&1 | tail -20" 2>&1
HAVE_KERNEL="$("$ADB" shell "cd $WORK && [ -f kernel ] && echo yes" 2>/dev/null | tr -d '\r\n')"
if [ "$HAVE_KERNEL" != "yes" ]; then
  err "magiskboot unpack 没有产出 kernel —— base 镜像可能不是有效的 Android boot 镜像"
  err "（也可能是该分区 dump 不是 boot。请用上面那条 dd 命令重新 dump 当前 boot 分区。）"
  exit 1
fi
info "  [+] 已拆出 kernel / ramdisk 等"

step "3. 换成我们的内核 Image"
"$ADB" shell "cd $WORK && cp -f Image kernel && ls -l kernel" 2>&1

step "4. 重新打包"
"$ADB" shell "cd $WORK && ./tools/magiskboot repack boot.img boot-new.img 2>&1 | tail -20; ls -l boot-new.img" 2>&1

step "5. 取回并放到 /sdcard"
"$ADB" shell "[ -f $WORK/boot-new.img ] && echo yes" 2>/dev/null | grep -q yes || {
  err "repack 失败，没有生成 boot-new.img"; exit 1; }
"$ADB" pull "$WORK/boot-new.img" "$HERE/$OUT_NAME" 2>&1 | tail -1
"$ADB" push "$HERE/$OUT_NAME" "/sdcard/$OUT_NAME" 2>&1 | tail -1

info ""
info "============================================================"
info "  已生成:"
info "    PC:     $HERE/$OUT_NAME"
info "    手机:   /sdcard/$OUT_NAME"
info "============================================================"
info ""
info "刷入方式（看你的工具支持哪种）："
info "  1) 刷机 App 的『刷入镜像』功能，选 /sdcard/$OUT_NAME，目标分区 boot"
info "  2) fastboot:  adb reboot bootloader && fastboot flash boot $OUT_NAME && fastboot reboot"
info ""
info "⚠️ 注意事项："
info "  - 这个镜像的内核已经换成自编的 Image，ramdisk/DTB 来自 base 镜像，未改动。"
info "  - 重打包后 AVB 签名失效；你设备已解锁（verifiedbootstate=orange），通常可直接刷。"
info "  - 刷前务必留好回退方案：手机上现成的"
info "      android12-5.10.246-2025-12-r1-ReSukiSU-AnyKernel3.zip"
info "    重刷一次即可回到原来的内核。"
exit 0
