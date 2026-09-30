#!/usr/bin/env bash
# =============================================================================
# pack-anykernel3.sh —— 用编译产物生成可刷入的 AnyKernel3 包（只换 kernel Image）
#
# 用法:
#   bash scripts/pack-anykernel3.sh <dist_dir> [ak3_work_dir] [output_zip]
#     <dist_dir>      含 Image 的目录
#     [ak3_work_dir]  AnyKernel3 工作目录，默认 ./AnyKernel3（不存在会自动获取）
#     [output_zip]    输出 zip 路径
#
# 产物: <output_zip>，里面【只有】Image，不含 dtb
#       —— 保留原机 DTB / ramdisk，避免 DTS 不匹配。
#
# 设计要点（都来自踩过的坑）：
#  1) anykernel.sh 优先用仓库里的 anykernel3/anykernel.sh；如果它不存在
#     （例如被 .gitignore 的大小写冲突漏掉、或单脚本被单独拷出来用），
#     就写一份内嵌兜底版本，绝不因为"找不到源文件"而静默失败。
#  2) 失败一律用 ::error:: 发注解。Actions 的 job log 接口要仓库 admin 权限
#     （匿名 403），而 check-runs 的 annotations 匿名可读 —— 只有发注解，
#     远程才能看到真实报错。
#  3) 不用 `[ -f x ] && {...}` 作为循环体最后一条命令：在 set -e 下，
#     循环整体会返回该 AND-OR 列表的失败码，导致脚本莫名其妙地退出。
# =============================================================================
set -uo pipefail

DIST_DIR="${1:-}"
AK3_DIR="${2:-./AnyKernel3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

err() { printf '::error::pack-anykernel3: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }

if [ -z "$DIST_DIR" ] || [ ! -d "$DIST_DIR" ]; then
  err "dist_dir 无效: '$DIST_DIR'（用法: bash $0 <dist_dir> [ak3_work_dir] [output_zip]）"
  exit 2
fi

# --- 1) 找 Image -------------------------------------------------------------
IMAGE=""
if [ -f "$DIST_DIR/Image" ]; then
  IMAGE="$DIST_DIR/Image"
elif [ -f "$DIST_DIR/kernel" ]; then
  IMAGE="$DIST_DIR/kernel"
else
  IMAGE="$(find "$DIST_DIR" -maxdepth 2 -type f -name 'Image' -print -quit 2>/dev/null || true)"
fi
if [ -z "$IMAGE" ]; then
  err "在 $DIST_DIR 里找不到 Image。目录内容："
  ls -lh "$DIST_DIR" 2>&1 | head -30 | while IFS= read -r l; do err "$l"; done
  exit 1
fi
log "[+] 内核镜像: $IMAGE ($(du -h "$IMAGE" | cut -f1))"

# --- 2) 准备 AnyKernel3 ------------------------------------------------------
if [ ! -f "$AK3_DIR/tools/ak3-core.sh" ]; then
  log "[+] 获取 AnyKernel3 -> $AK3_DIR"
  rm -rf "$AK3_DIR"
  if git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "$AK3_DIR"; then
    log "[+] git clone 成功"
  else
    log "[WARN] git clone 失败，改用 codeload tarball"
    rm -rf "$AK3_DIR" /tmp/ak3.tar.gz
    mkdir -p "$AK3_DIR"
    if curl -fsSL --retry 3 -o /tmp/ak3.tar.gz \
         https://codeload.github.com/osm0sis/AnyKernel3/tar.gz/refs/heads/master; then
      tar xzf /tmp/ak3.tar.gz -C "$AK3_DIR" --strip-components=1 || true
      log "[+] tarball 解包完成"
    fi
  fi
fi
if [ ! -f "$AK3_DIR/tools/ak3-core.sh" ]; then
  err "AnyKernel3 获取失败（git clone 与 curl 都失败），无法打包"
  ls -la "$AK3_DIR" 2>&1 | head -20 | while IFS= read -r l; do err "$l"; done
  exit 1
fi
log "[+] AnyKernel3 就绪: $AK3_DIR"

# --- 3) 清理：不要 dtb / modules / 旧 Image ---------------------------------
rm -f "$AK3_DIR/dtb" "$AK3_DIR/Image" "$AK3_DIR/Image.gz" "$AK3_DIR/zImage" "$AK3_DIR/kernel"
rm -rf "$AK3_DIR/modules" "$AK3_DIR/ramdisk" "$AK3_DIR/split_img" "$AK3_DIR/rdtmp"

cp -f "$IMAGE" "$AK3_DIR/Image" || { err "复制 Image 到 $AK3_DIR 失败"; exit 1; }

# --- 4) anykernel.sh：优先仓库版本，缺失则内嵌兜底 ---------------------------
# 先删掉任何大小写变体：AK3 backend（META-INF/.../update-binary）里写死的是小写
# `anykernel.sh`（`ash anykernel.sh` 就是入口），而 clone 下来的目录/某些
# 大小写不敏感的文件系统上可能残留 `Anykernel.sh`，两者同时存在会很难查。
rm -f "$AK3_DIR"/anykernel.sh "$AK3_DIR"/Anykernel.sh "$AK3_DIR"/ANYKERNEL.SH

AK3_SH_REPO="$HERE/anykernel3/anykernel.sh"
if [ -f "$AK3_SH_REPO" ]; then
  cp -f "$AK3_SH_REPO" "$AK3_DIR/anykernel.sh" || { err "复制 $AK3_SH_REPO 失败"; exit 1; }
  log "[+] anykernel.sh 来自仓库: $AK3_SH_REPO"
else
  log "[WARN] 仓库里没有 $AK3_SH_REPO，改用内嵌兜底版本"
  cat > "$AK3_DIR/anykernel.sh" <<'AK3EOF'
### AnyKernel3 Ramdisk Mod Script (内嵌兜底版本)
## 只替换 kernel Image，保留原机 DTB 与 ramdisk。
##
## 变量必须【大写】：ak3-core.sh 读的是 $BLOCK / $IS_SLOT_DEVICE 等；
## 现行 AK3 已删掉 `[ "$block" ] && BLOCK="$block"` 那层小写兼容，
## 写小写会让 BLOCK 为空，报 "Unable to determine  partition"（两个空格）。

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

BLOCK=boot
IS_SLOT_DEVICE=auto
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto

. tools/ak3-core.sh;

dump_boot;
write_boot;
## end install
AK3EOF
fi
if [ ! -s "$AK3_DIR/anykernel.sh" ]; then
  err "$AK3_DIR/anykernel.sh 不存在或为空"
  exit 1
fi
# 自检：确认就是小写这一个名字，且变量是大写（否则刷机会在分区判定处失败）
# 注意：不能用 [ -e "$AK3_DIR/Anykernel.sh" ] —— 在 Windows 这类大小写不敏感
#       的文件系统上它会解析到 anykernel.sh，造成误报。这里用 ls 列出真实名字再比对。
AK3_VARIANTS="$(ls -1 "$AK3_DIR" 2>/dev/null | grep -iE '^anykernel\.sh$' | grep -vx 'anykernel.sh' || true)"
if [ -n "$AK3_VARIANTS" ]; then
  err "$AK3_DIR 里存在大小写不一致的脚本名（真实名字：$AK3_VARIANTS），会导致行为不一致"
  exit 1
fi
if ! ls -1 "$AK3_DIR" 2>/dev/null | grep -qx 'anykernel.sh'; then
  err "$AK3_DIR 里没有规范的小写 anykernel.sh（AK3 backend 执行的就是这个名字）"
  exit 1
fi
if ! grep -qE '^BLOCK=' "$AK3_DIR/anykernel.sh"; then
  err "anykernel.sh 里没有大写的 BLOCK= —— 现行 ak3-core.sh 只认大写，写小写会在刷机时报 'Unable to determine  partition'"
  grep -nE '^(block|BLOCK|is_slot_device|IS_SLOT_DEVICE)=' "$AK3_DIR/anykernel.sh" | while IFS= read -r l; do err "$l"; done
  exit 1
fi
log "[+] anykernel.sh 自检通过（小写文件名 + 大写变量）"

# --- 5) 打包 -----------------------------------------------------------------
if ! command -v zip >/dev/null 2>&1; then
  err "系统里没有 zip（ubuntu: apt-get install -y zip）"
  exit 1
fi

OUT_ZIP="${3:-$HERE/anykernel3-unicorn-$(date +%Y%m%d-%H%M).zip}"
OUT_DIR="$(dirname "$OUT_ZIP")"
mkdir -p "$OUT_DIR" || { err "创建 $OUT_DIR 失败"; exit 1; }
OUT_ZIP="$(cd "$OUT_DIR" && pwd)/$(basename "$OUT_ZIP")"
rm -f "$OUT_ZIP"

( cd "$AK3_DIR" && zip -r9 "$OUT_ZIP" . -x '.git/*' '.git*' '*.zip' ) >/dev/null 2>&1
if [ ! -s "$OUT_ZIP" ]; then
  err "zip 打包失败，$OUT_ZIP 不存在或为空"
  exit 1
fi

log ""
log "[+] 已生成: $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"
log "[i] 包含内容:"
( cd "$AK3_DIR" && unzip -l "$OUT_ZIP" 2>/dev/null | sed -n '4,14p' ) || true
log ""
log "刷入方式（三选一）："
log "  1) Recovery:  adb sideload $OUT_ZIP"
log "  2) TWRP:      直接安装该 zip"
log "  3) ReSukiSU / 内核管理器 App 里的 '刷入' 功能选择该 zip"
log ""
log "刷前请务必备份原 boot（当前 slot，实测 _b）："
log "  adb shell su -c 'dd if=/dev/block/by-name/boot_b of=/sdcard/boot_stock.img'"
log "  adb pull /sdcard/boot_stock.img"
exit 0
