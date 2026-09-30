#!/usr/bin/env bash
# =============================================================================
# lineage-tree-build.sh  —— 构建路径 A（推荐）：在 LineageOS 源码树里直接编 bootimage
#
# 用法:
#   bash scripts/lineage-tree-build.sh <lineage_root> [device] [--no-build] [--hook kprobes]
#     <lineage_root>  LineageOS 源码根（里面有 kernel/、device/、build/ 等）
#     [device]        默认 unicorn
#     --no-build      只打配置 + 集成 ReSukiSU，不真编译
#     --hook          默认 kprobes（5.10 GKI）；备选 tracepoint
#
# 为什么推荐这条路：
#   内核、DTB、vendor 模块由同一棵树同一套配置产出，ABI 天然自洽，
#   工具链由 LineageOS 构建系统自己解析，不需要手动拼 kernel_platform 布局。
# =============================================================================
set -euo pipefail

ROOT="${1:-}"
shift || true

DEVICE="unicorn"
NO_BUILD=0
HOOK="kprobes"
KSU_BRANCH="main"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) NO_BUILD=1 ;;
    --hook)     HOOK="${2:-kprobes}"; shift ;;
    --ksu)      KSU_BRANCH="${2:-main}"; shift ;;
    -*)         echo "[WARN] 忽略未知参数: $1" ;;
    *)          DEVICE="$1" ;;
  esac
  shift
done

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "用法: bash $0 <lineage_root> [device] [--no-build] [--hook kprobes|tracepoint] [--ksu main]" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_SRC="kernel/xiaomi/sm8450"

echo "==================== 环境检查 ===================="
[ -d "$ROOT/$KERNEL_SRC" ] || {
  echo "[ERROR] 找不到 $ROOT/$KERNEL_SRC"
  echo "        先同步内核：cd $ROOT && repo sync kernel/xiaomi/sm8450 kernel/xiaomi/sm8450-modules kernel/xiaomi/sm8450-devicetrees"
  exit 1
}
[ -f "$ROOT/$KERNEL_SRC/arch/arm64/configs/gki_defconfig" ] || {
  echo "[ERROR] 内核树里没有 arch/arm64/configs/gki_defconfig，确认路径：$ROOT/$KERNEL_SRC"
  exit 1
}
[ -f "$ROOT/$KERNEL_SRC/build.config.msm.waipio" ] && echo "[OK] 内核树结构正常"
echo "[OK] 内核树: $ROOT/$KERNEL_SRC"
echo

echo "==================== 1. 写入 Docker/cgroup 配置 ===================="
bash "$HERE/scripts/apply-configs.sh" "$ROOT/$KERNEL_SRC"
echo

echo "==================== 2. 集成 ReSukiSU ===================="
bash "$HERE/scripts/integrate-resukisu.sh" "$ROOT/$KERNEL_SRC" "$KSU_BRANCH" "$HOOK"
echo

echo "==================== 3. 打印本树实际使用的碎片（提醒） ===================="
BC="$ROOT/device/xiaomi/sm8450-common/BoardConfigCommon.mk"
if [ -f "$BC" ]; then
  echo "  TARGET_KERNEL_CONFIG 组合（gki_defconfig 是 base，其余是碎片，只能新增不能改）："
  sed -n '/TARGET_KERNEL_CONFIG/,/^$/p' "$BC" | sed 's/^/    /'
else
  echo "  (未找到 $BC，跳过)"
fi
echo
echo "  期望看到的关键项："
grep -E '^(# )?CONFIG_(CGROUP_DEVICE|CGROUP_PIDS|PID_NS|USER_NS|NF_TABLES|BRIDGE_NETFILTER|KSU)=' \
  "$ROOT/$KERNEL_SRC/arch/arm64/configs/gki_defconfig" | sed 's/^/    /' || true
echo

if [ "$NO_BUILD" -eq 1 ]; then
  echo "[i] 已按 --no-build 停止。要编译请执行："
  echo "    cd $ROOT && source build/envsetup.sh && breakfast $DEVICE && m bootimage"
  exit 0
fi

echo "==================== 4. 编译 bootimage ===================="
cd "$ROOT"
# shellcheck disable=SC1091
source build/envsetup.sh
breakfast "$DEVICE"
m bootimage -j"$(nproc)"

echo
echo "==================== 完成 ===================="
OUT="$ROOT/out/target/product/$DEVICE/boot.img"
if [ -f "$OUT" ]; then
  ls -lh "$OUT"
  echo
  echo "下一步（务必先比对版本串，见 README 第 6 节）："
  echo "  adb shell uname -r        # 设备当前内核版本串"
  echo "  # 两者应一致（预期形如 5.10.xxx-gki），一致就只需刷 boot.img："
  echo "  fastboot flash boot $OUT"
  echo "  # 或先备份，再刷："
  echo "  adb shell su -c 'dd if=/dev/block/by-name/boot_a of=/sdcard/boot_stock.img'"
else
  echo "[!] 没找到 $OUT，检查编译日志"
fi
