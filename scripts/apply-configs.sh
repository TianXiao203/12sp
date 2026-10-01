#!/usr/bin/env bash
# =============================================================================
# apply-configs.sh —— 把 Docker/cgroup + ReSukiSU 配置写入 5.10 GKI defconfig 本体
#
# 用法:
#   # LineageOS 内核树（推荐）
#   bash scripts/apply-configs.sh ~/android/lineage/kernel/xiaomi/sm8450
#   # 或者 Actions 组装出的工作区
#   bash scripts/apply-configs.sh ./kp/common
#
# 脚本会自动寻找下列位置中的 gki_defconfig：
#   <root>/arch/arm64/configs/gki_defconfig            <- LineageOS 内核树
#   <root>/msm-kernel/arch/arm64/configs/gki_defconfig  <- kernel_platform 布局
#   <root>/common/arch/arm64/configs/gki_defconfig
#
# 关键点（为什么不能直接用 merge_config.sh / 写碎片）:
#   build.config.msm.common 的 merge_defconfig_fragments() 一旦检测到
#   "Previous value: CONFIG_X=[ym]" 就 "ERROR! Detected overridden config!" 退出；
#   之后 check_merged_defconfig() 又要求最终 .config 与 defconfig 的差异【全是新增行】。
#   LineageOS 的 TARGET_KERNEL_CONFIG 是
#       gki_defconfig + vendor/{waipio,xiaomi,unicorn}_GKI.config + vendor/debugfs.config
#   所以：本脚本直接改 defconfig 本体（= base），并对 PID_NS 做行级替换。
# =============================================================================
set -euo pipefail

KP_ROOT="${1:-}"
FRAGMENT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/configs/docker-cgroup.fragment}"

if [ -z "$KP_ROOT" ]; then
  echo "用法: bash $0 <kernel_root> [fragment_file]" >&2
  echo "  例: bash $0 ~/android/lineage/kernel/xiaomi/sm8450" >&2
  exit 1
fi
if [ ! -f "$FRAGMENT" ]; then
  echo "[ERROR] 找不到配置片段: $FRAGMENT" >&2
  exit 1
fi

# --- 定位 defconfig ----------------------------------------------------------
DEFCONFIG=""
for cand in \
  "$KP_ROOT/msm-kernel/arch/arm64/configs/gki_defconfig" \
  "$KP_ROOT/arch/arm64/configs/gki_defconfig" \
  "$KP_ROOT/common/arch/arm64/configs/gki_defconfig"
do
  if [ -f "$cand" ]; then DEFCONFIG="$cand"; break; fi
done

if [ -z "$DEFCONFIG" ]; then
  echo "[ERROR] 没找到 gki_defconfig，请确认 <kernel_platform_root> 是 kernel_platform 目录。" >&2
  echo "        已尝试:" >&2
  echo "          $KP_ROOT/msm-kernel/arch/arm64/configs/gki_defconfig" >&2
  echo "          $KP_ROOT/arch/arm64/configs/gki_defconfig" >&2
  echo "          $KP_ROOT/common/arch/arm64/configs/gki_defconfig" >&2
  exit 1
fi

echo "[+] defconfig: $DEFCONFIG"
cp -n "$DEFCONFIG" "$DEFCONFIG.orig" 2>/dev/null || true
echo "[+] 已备份原始 defconfig -> $DEFCONFIG.orig"

# --- 提示本树实际使用的碎片（防止有人把配置写进碎片）-------------------------
FRAG_DIR="$(dirname "$DEFCONFIG")/vendor"
if [ -d "$FRAG_DIR" ]; then
  echo "[i] 检测到碎片目录: $FRAG_DIR"
  echo "    碎片只能【新增】配置；改动 base 里已有的非默认值会触发"
  echo "    'ERROR! Detected overridden config!' 而直接编译失败。"
  ls -1 "$FRAG_DIR"/*.config 2>/dev/null | sed 's|.*/|      |' || true
  echo "    -> 本脚本只改 gki_defconfig 本体，这是正确做法。"
fi

# --- 1) PID_NS：必须改这一行，不能靠追加 --------------------------------------
if grep -q '^# CONFIG_PID_NS is not set' "$DEFCONFIG"; then
  sed -i 's/^# CONFIG_PID_NS is not set$/CONFIG_PID_NS=y/' "$DEFCONFIG"
  echo "[+] 已把 '# CONFIG_PID_NS is not set' 改为 'CONFIG_PID_NS=y'"
elif grep -q '^CONFIG_PID_NS=y' "$DEFCONFIG"; then
  echo "[=] CONFIG_PID_NS 已经是 y"
else
  echo "[!] defconfig 里没有 PID_NS 行，追加 CONFIG_PID_NS=y"
  echo 'CONFIG_PID_NS=y' >> "$DEFCONFIG"
fi

# --- 2) 收集片段里的 key（只处理 “CONFIG_XXX=<val>” 或 “# CONFIG_XXX is not set”）---
mapfile -t KEYS < <(
  grep -E '^[[:space:]]*(# )?CONFIG_[A-Z0-9_]+' "$FRAGMENT" \
  | sed -E 's/^[[:space:]]*//; s/^(# )?CONFIG_([A-Z0-9_]+).*/\2/' \
  | sort -u
)

echo "[+] 片段包含 ${#KEYS[@]} 个配置项，开始幂等写入"

# --- 3) 先删除 defconfig 里同名旧行（保证幂等，避免重复 key）------------------
for k in "${KEYS[@]}"; do
  # 跳过 PID_NS（上面已单独处理）
  if [ "$k" = "PID_NS" ]; then continue; fi
  sed -i "/^CONFIG_${k}=/d; /^# CONFIG_${k} is not set$/d" "$DEFCONFIG"
done

# --- 4) 追加片段（过滤掉注释与空行）------------------------------------------
{
  echo ""
  echo "# ---------------------------------------------------------------------------"
  echo "# Docker/cgroup + ReSukiSU  (added by apply-configs.sh)"
  echo "# ---------------------------------------------------------------------------"
  # 注意：PID_NS 已在上面做过行级替换，这里必须排除，避免出现重复 key
  grep -E '^[[:space:]]*(CONFIG_[A-Z0-9_]+=[^[:space:]]+|# CONFIG_[A-Z0-9_]+ is not set)' "$FRAGMENT" \
    | grep -vE '^[[:space:]]*CONFIG_PID_NS=' || true
} >> "$DEFCONFIG"

echo "[+] 已追加配置到 $DEFCONFIG"

# --- 5) 自检：重复 key / 冲突 -------------------------------------------------
DUP=$(grep -cE '^(# )?CONFIG_(CGROUP_DEVICE|PID_NS|USER_NS|KSU)=' "$DEFCONFIG" || true)
echo "[i] 关键项命中次数（CGROUP_DEVICE/PID_NS/USER_NS/KSU 合计应为 4）: $DUP"

# 检测同名 key 重复定义（kconfig 会警告）
DUPES=$(grep -oE '^CONFIG_[A-Z0-9_]+' "$DEFCONFIG" | sort | uniq -d || true)
if [ -n "$DUPES" ]; then
  echo "[!] 警告：defconfig 里存在重复定义（后出现的生效）："
  echo "$DUPES" | sed 's/^/      /'
else
  echo "[+] 没有重复 key"
fi

echo
echo "[+] 关键项最终状态："
grep -E '^(# )?CONFIG_(CGROUP_DEVICE|CGROUP_PIDS|PID_NS|USER_NS|POSIX_MQUEUE|IPC_NS|SECCOMP_FILTER|KSU|KSU_TRACEPOINT_HOOK)=' "$DEFCONFIG" | sed 's/^/      /' || true

echo
echo "[i] ABI 铁律：下面几项必须【不在】defconfig 里（=n），否则 ROM 的 vendor 模块会拒载："
for k in CONFIG_NF_TABLES CONFIG_NF_TABLES_BRIDGE CONFIG_SYSVIPC; do
  if grep -qE "^${k}=" "$DEFCONFIG"; then
    echo "      [FAIL] $k 出现了！"
  else
    echo "      [OK]   $k 未出现"
  fi
done

echo
echo "完成。下一步：bash scripts/integrate-resukisu.sh $KP_ROOT main kprobes"
