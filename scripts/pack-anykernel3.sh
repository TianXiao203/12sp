#!/usr/bin/env bash
# =============================================================================
# pack-anykernel3.sh —— 用编译产物生成可刷入的 AnyKernel3 包（只换 kernel Image）
#
# 用法:
#   bash scripts/pack-anykernel3.sh <dist_dir> [ak3_work_dir] [output_zip]
#     <dist_dir>      编译产物目录，例如 out/msm-kernel-zeus/dist
#     [ak3_work_dir]  AnyKernel3 工作目录，默认 ./AnyKernel3（不存在会自动 clone）
#
# 产物: anykernel3-unicorn-<时间戳>.zip
#   里面【只有】Image，不含 dtb —— 保留原机 DTB / ramdisk，避免 DTS 不匹配。
# =============================================================================
set -euo pipefail

DIST_DIR="${1:-}"
AK3_DIR="${2:-./AnyKernel3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$DIST_DIR" ] || [ ! -d "$DIST_DIR" ]; then
  echo "用法: bash $0 <dist_dir> [ak3_work_dir]" >&2
  exit 1
fi

# --- 1) 找 Image -------------------------------------------------------------
IMAGE=""
for cand in "$DIST_DIR/Image" "$DIST_DIR/kernel" ; do
  [ -f "$cand" ] && { IMAGE="$cand"; break; }
done
if [ -z "$IMAGE" ]; then
  IMAGE="$(find "$DIST_DIR" -maxdepth 2 -type f -name 'Image' -print -quit 2>/dev/null || true)"
fi
if [ -z "$IMAGE" ]; then
  echo "[ERROR] 在 $DIST_DIR 里找不到 Image。目录内容：" >&2
  ls -lh "$DIST_DIR" >&2 || true
  echo "提示：内核镜像也可能在 out/msm-kernel-<target>/arch/arm64/boot/Image" >&2
  exit 1
fi
echo "[+] 内核镜像: $IMAGE ($(du -h "$IMAGE" | cut -f1))"

# --- 2) 准备 AnyKernel3 ------------------------------------------------------
if [ ! -d "$AK3_DIR/tools" ]; then
  echo "[+] 克隆 AnyKernel3 ..."
  git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "$AK3_DIR"
fi
[ -f "$AK3_DIR/tools/ak3-core.sh" ] || { echo "[ERROR] $AK3_DIR 不是合法的 AnyKernel3 目录" >&2; exit 1; }

# --- 3) 清理：不要 dtb / modules / 旧 Image ---------------------------------
rm -f  "$AK3_DIR/dtb" "$AK3_DIR/Image" "$AK3_DIR/Image.gz" "$AK3_DIR/zImage" "$AK3_DIR/kernel"
rm -rf "$AK3_DIR/modules"
rm -rf "$AK3_DIR/ramdisk" "$AK3_DIR/split_img" "$AK3_DIR/rdtmp"

cp -f "$IMAGE" "$AK3_DIR/Image"
cp -f "$HERE/anykernel3/anykernel.sh" "$AK3_DIR/anykernel.sh"

# --- 4) 打包 ----------------------------------------------------------------
OUT_ZIP="${3:-$HERE/anykernel3-unicorn-$(date +%Y%m%d-%H%M).zip}"
OUT_ZIP="$(cd "$(dirname "$OUT_ZIP")" && pwd)/$(basename "$OUT_ZIP")"

( cd "$AK3_DIR" && rm -f "$OUT_ZIP" && zip -r9 "$OUT_ZIP" . -x '.git/*' '.git*' '*.zip' > /dev/null )

echo
echo "[+] 已生成: $OUT_ZIP"
echo "[i] 包含内容:"
( cd "$AK3_DIR" && unzip -l "$OUT_ZIP" 2>/dev/null | sed -n '4,14p' ) || true
echo
echo "刷入方式（三选一）："
echo "  1) Recovery:  adb sideload $OUT_ZIP"
echo "  2) TWRP:      直接安装该 zip"
echo "  3) ReSukiSU / 内核管理器 App 里的 '刷入' 功能选择该 zip"
echo
echo "刷前请务必备份原 boot："
echo "  adb shell su -c 'dd if=/dev/block/by-name/boot_a of=/sdcard/boot_stock.img'"
echo "  adb pull /sdcard/boot_stock.img"
