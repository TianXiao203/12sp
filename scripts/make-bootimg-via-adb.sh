#!/usr/bin/env bash
# =============================================================================
# make-bootimg-via-adb.sh —— 把自编内核 Image 打进一个可直接刷的 boot.img
#
# 为什么需要它：
#   本工程的交付物是【裸内核 Image】（make Image），它本身不能刷进分区。
#   可刷的 boot 镜像 = 头部 + 内核 + ramdisk + cmdline + dtb，其中 ramdisk
#   必须来自你的 ROM —— 所以只能"拿一个现成的 boot 镜像，把里面的内核换掉"。
#
# 做法（全程在手机上用 magiskboot，避免在 Windows 上找交叉工具）：
#   1. 备份当前 boot 分区（dd）
#   2. magiskboot unpack 它            -> kernel / ramdisk.cpio / dtb / header ...
#   3. 用我们的 Image 覆盖 kernel
#   4. magiskboot repack               -> new-boot.img
#   5. 拉回本地一份，同时放回 /sdcard
#
# 设计说明：
#   - 手机上执行的部分写成独立脚本 push 过去跑（`su -c "sh 脚本"`），
#     因为把多行脚本塞进 `su -c "..."` 会被引号/转义搞坏（踩过）。
#   - AK3 自带的 magiskboot 是 32 位 ARM 静态二进制；本设备 CONFIG_COMPAT=y，
#     可以直接运行。
#   - adb shell 默认没有 su；需要 ReSukiSU 管理器里给 shell 授权 root。
#
# 用法:
#   bash scripts/make-bootimg-via-adb.sh [AK3zip] [out_name]
#     默认 AK3zip   = ./anykernel3-unicorn-fixed.zip（内含 Image 与 tools/magiskboot）
#     默认 out_name = boot-unicorn-custom.img
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AK3_ZIP="${1:-$HERE/anykernel3-unicorn-fixed.zip}"
OUT_NAME="${2:-boot-unicorn-custom.img}"

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
step() { printf '\n===== %s =====\n' "$*"; }
# 以 root 跑任意命令（用于探测）；以及跑设备端构包脚本
su_run() { "$ADB" shell "su -c '$*'"; }
sh_dev() { "$ADB" shell "su -c 'sh /data/local/tmp/kb-build.sh $*'"; }

[ -n "$ADB" ] || { err "找不到 adb，可先 export ADB=/path/to/adb"; exit 2; }
[ -f "$AK3_ZIP" ] || { err "找不到 AK3 zip: $AK3_ZIP"; exit 2; }

# Git Bash 下 /sdcard/... 会被当成 Windows 路径改写，必须关掉；
# 但关掉之后，传给 adb 的【本地】路径又必须是 Windows 形式（adb 不认 /d/...），
# 所以本地路径统一用 cygpath 转一下。
export MSYS_NO_PATHCONV=1
winpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

step "0. 检查设备与 root"
"$ADB" devices -l 2>&1 | tail -3
UID_="$(su_run id 2>/dev/null | tr -d '\r')"
case "$UID_" in
  *uid=0*) info "  [+] root 可用: $UID_" ;;
  *) err "adb shell 里拿不到 root（返回: ${UID_:-空}）。"
     err "请先在 ReSukiSU 管理器里给 shell 授权 root，或改用管理器自带终端执行。"
     exit 1 ;;
esac
SLOT="$("$ADB" shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r\n')"
info "  slot  = $SLOT"
info "  uname = $("$ADB" shell uname -r 2>/dev/null | tr -d '\r\n')"
[ -n "$SLOT" ] || { err "取不到 slot_suffix"; exit 1; }
[ "$SLOT" = "_a" ] || [ "$SLOT" = "_b" ] || { err "slot 异常: $SLOT"; exit 1; }

# ---- 推送 zip 与设备端脚本 -------------------------------------------------
step "1. 推送 AK3 zip 与构包脚本到 /data/local/tmp"
"$ADB" push "$(winpath "$AK3_ZIP")" "/data/local/tmp/ak3src.zip" 2>&1 | tail -1

TMP_SH="$HERE/.kb-build.sh.tmp"
cat > "$TMP_SH" <<'DEVEOF'
#!/system/bin/sh
# 由 make-bootimg-via-adb.sh 生成；在手机 root 下执行
set -e
W=/data/local/tmp/kb
BASE="/dev/block/by-name/boot$1"
OUTNAME="$2"
cd "$W"

echo "[1/5] 备份当前 boot 分区 ($BASE) -> /sdcard/boot${1}_backup.img"
dd if="$BASE" of="/sdcard/boot${1}_backup.img" bs=1M
ls -l "/sdcard/boot${1}_backup.img"

echo "[2/5] 准备 magiskboot 与 Image"
unzip -o -q /data/local/tmp/ak3src.zip tools/magiskboot Image
chmod 755 tools/magiskboot
ls -l tools/magiskboot Image

echo "[3/5] unpack 备份镜像"
cp -f "/sdcard/boot${1}_backup.img" base.img
./tools/magiskboot unpack -h base.img
echo "--- 拆出的文件 ---"
ls -l

echo "[4/5] 用自编 Image 覆盖 kernel"
ls -l kernel Image
cp -f Image kernel

echo "[5/5] repack"
./tools/magiskboot repack base.img new-boot.img
ls -l new-boot.img
cp -f new-boot.img "/sdcard/$OUTNAME"
echo "DONE"
DEVEOF

"$ADB" push "$(winpath "$TMP_SH")" /data/local/tmp/kb-build.sh 2>&1 | tail -1
rm -f "$TMP_SH"
"$ADB" shell "su -c 'mkdir -p /data/local/tmp/kb && chmod 755 /data/local/tmp/kb-build.sh'" 2>&1

# ---- 在手机上执行 ----------------------------------------------------------
step "2. 在手机上备份 + 拆包 + 换内核 + 重打包"
sh_dev "$SLOT" "$OUT_NAME" 2>&1 | tail -45

step "3. 取回结果"
if ! "$ADB" shell "[ -f /sdcard/$OUT_NAME ] && echo yes" 2>/dev/null | grep -q yes; then
  err "手机上没生成 /sdcard/$OUT_NAME —— 看上面的输出定位是哪一步失败的"
  exit 1
fi
"$ADB" pull "/sdcard/$OUT_NAME" "$(winpath "$HERE/$OUT_NAME")" 2>&1 | tail -1

step "4. 结果"
info "  PC  : $HERE/$OUT_NAME"
info "  手机: /sdcard/$OUT_NAME"
info "  备份: /sdcard/boot${SLOT}_backup.img  （回退用）"
info ""
info "刷入（二选一）："
info "  A) 直接写分区（adb shell 有 root 时）："
info "     adb shell su -c 'dd if=/sdcard/$OUT_NAME of=/dev/block/by-name/boot${SLOT} bs=1M'"
info "  B) fastboot:"
info "     adb reboot bootloader && fastboot flash boot $OUT_NAME && fastboot reboot"
info ""
info "回退："
info "     adb shell su -c 'dd if=/sdcard/boot${SLOT}_backup.img of=/dev/block/by-name/boot${SLOT} bs=1M'"
exit 0
