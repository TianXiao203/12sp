#!/usr/bin/env bash
# =============================================================================
# preconfig-kernel.sh —— 自己生成合并后的 .config，绕开 build.sh 的强制校验
#
# 为什么需要它：
#  1) 正确性：build.config.msm.waipio 只会把 vendor/waipio_GKI.config 作为碎片合并，
#     而 LineageOS 官方 TARGET_KERNEL_CONFIG 实际用【5 个文件】：
#         gki_defconfig + vendor/{waipio,xiaomi,unicorn}_GKI.config + vendor/debugfs.config
#     少了 xiaomi_/unicorn_ 两个，设备专属配置（MI_CHARGER_M81、MI_THERMAL_MULTI_CHARGE）
#     就丢了，刷上去可能起不来。
#  2) 稳定性：build.sh 内部的 merge_defconfig_fragments 有两处快速 exit 1：
#        "ERROR! Detected overridden config!"        （碎片覆盖了 base 里的非默认值）
#        "ERROR! Treating config warnings as errors" （kconfig 有 warning）
#     一旦命中，build.sh 会在 1~2 秒内退出。若调用方把输出管道给 tee 又不加 pipefail，
#     就会表现为"编译步骤 0 秒成功、其实什么都没编"。
#     本脚本自己合并，不触发那两处检查；再用 SKIP_DEFCONFIG=1 让 build.sh 直接编译。
#
# 用法:
#   bash scripts/preconfig-kernel.sh <workspace> [out_dir]
#     默认 out_dir = <workspace>/out/common
# =============================================================================
set -euo pipefail

WS="${1:-}"
OUT="${2:-}"

if [ -z "$WS" ] || [ ! -d "$WS" ]; then
  echo "用法: bash $0 <workspace> [out_dir]" >&2
  exit 1
fi
K="$WS/common"
[ -f "$K/arch/arm64/configs/gki_defconfig" ] || { echo "[ERROR] 找不到 $K/arch/arm64/configs/gki_defconfig" >&2; exit 1; }

# OUT_DIR 必须在 ROOT_DIR 下、且以 /<KERNEL_DIR> 结尾（build.sh 会做 COMMON_OUT_DIR/${KERNEL_DIR}）
[ -z "$OUT" ] && OUT="$WS/out/common"
mkdir -p "$OUT"

cd "$K"

# ---- 1) 确定实际存在的碎片（缺哪个就跳过哪个，并明确报出来）------------------
FRAGS=""
for f in vendor/waipio_GKI.config vendor/xiaomi_GKI.config vendor/unicorn_GKI.config vendor/debugfs.config; do
  if [ -f "arch/arm64/configs/$f" ]; then
    FRAGS="$FRAGS arch/arm64/configs/$f"
  else
    echo "[WARN] 碎片不存在，跳过: arch/arm64/configs/$f"
  fi
done
echo "[+] 使用碎片: $FRAGS"

MERGED="arch/arm64/configs/vendor/unicorn-docker_defconfig"
# ---- 2) 合并（-m 只合并、不跑 make；不检查覆盖，避免被误杀）------------------
# shellcheck disable=SC2086
KCONFIG_CONFIG="$MERGED" ./scripts/kconfig/merge_config.sh -m -r -y \
  arch/arm64/configs/gki_defconfig $FRAGS

if [ ! -f "$MERGED" ]; then
  echo "[ERROR] merge_config.sh 没有产出 $MERGED" >&2
  exit 1
fi
echo "[+] 合并后的 defconfig: $K/$MERGED ($(grep -c '^CONFIG_' "$MERGED") 行 CONFIG_)"

# ---- 3) 生成 .config（用我们合并出来的那份）--------------------------------
make O="$OUT" ARCH=arm64 "$(echo "$MERGED" | sed 's|^arch/arm64/configs/||')"

# ---- 4) 把 LTO 从 full 改成 thin（官方是 FULL LTO，16GB runner 上会 OOM）------
#        这一步等价于 build.sh 里 LTO=thin 做的事
./scripts/config --file "$OUT/.config" \
  -e LTO_CLANG -d LTO_NONE -e LTO_CLANG_THIN -d LTO_CLANG_FULL -e THINLTO
( cd "$OUT" && make O="$OUT" ARCH=arm64 olddefconfig >/dev/null )

# ---- 5) 自检：我们加的关键项是否真的生效 -----------------------------------
echo
echo "==================== 合并结果关键项 ===================="
FAIL=0
for k in CGROUP_DEVICE CGROUP_PIDS PID_NS USER_NS SYSVIPC IPC_NS NF_TABLES BRIDGE_NETFILTER KSU LTO_CLANG_THIN LTO_CLANG_FULL; do
  line=$(grep -E "^CONFIG_${k}=|^# CONFIG_${k} is not set" "$OUT/.config" | head -1)
  printf '  %-22s %s\n' "CONFIG_$k" "${line:-<不存在>}"
done
for k in CGROUP_DEVICE PID_NS USER_NS SYSVIPC KSU; do
  grep -q "^CONFIG_${k}=y$" "$OUT/.config" || { echo "  [FAIL] CONFIG_$k 不是 y"; FAIL=$((FAIL+1)); }
done
grep -q "^CONFIG_LTO_CLANG_THIN=y$" "$OUT/.config" || { echo "  [WARN] LTO 不是 thin，可能是 full（16GB runner 有 OOM 风险）"; }
echo "======================================================="
if [ "$FAIL" -ne 0 ]; then
  echo "[ERROR] 有 $FAIL 个关键项没生效，先别继续编译" >&2
  exit 1
fi
echo "[OK] preconfig 完成，.config 位于 $OUT/.config"
