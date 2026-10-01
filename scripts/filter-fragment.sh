#!/usr/bin/env bash
# =============================================================================
# 从完整 Docker 碎片里按分组抽取子集，用于 ABI bisect。
#
# 背景：Run#10/11/13 实测 —— 设备原版配置（control）ABI 全绿，而加了整个
# Docker 碎片就稳定 725/1241 符号 CRC 不一致。需要把碎片拆开、逐组验证。
#
# 用法: bash scripts/filter-fragment.sh <源碎片> <模式> <输出文件>
#   模式 all     —— 原样复制（不过滤）；★ 含 ABI 危险项，只用于对照/复现 bisect
#   docker      —— 【最终交付配置】all 减去两个真危险的 cgroup 项
#                  （CGROUP_DEVICE / CGROUP_PIDS → struct css_set 定长数组变长）
#   ns          —— 只保留命名空间组（PID_NS/USER_NS/IPC_NS/POSIX_MQUEUE...）
#   userns      —— 命名空间组里只留 USER_NS（bisect 细分）
#   ipc         —— 命名空间组里只留 IPC_NS/POSIX_MQUEUE(+SYSCTL)（bisect 细分）
#   cgroup      —— 只保留 cgroup 组（CGROUP_DEVICE/CGROUP_PIDS/...）
#   none        —— 只保留"本来就是 y"的对齐项（IKCONFIG 等）
#
# 注意：过滤按"允许的 key 白名单"进行（docker 例外，用黑名单），
#       注释行一律保留（便于事后核对）。
# =============================================================================
set -euo pipefail

SRC="${1:?用法: filter-fragment.sh <源碎片> <模式> <输出>}"
MODE="${2:?模式: all|docker|ns|userns|ipc|cgroup|none}"
OUT="${3:?缺少输出文件路径}"

if [ ! -f "$SRC" ]; then
  echo "[filter-fragment] 源碎片不存在: $SRC" >&2
  exit 2
fi

case "$MODE" in
  all)
    cp -f "$SRC" "$OUT"
    echo "[filter-fragment] 模式 all：原样复制 $(basename "$SRC")"
    echo "[filter-fragment]   ★ 警告：all 模式含 ABI 危险项（CGROUP_DEVICE/CGROUP_PIDS），"
    echo "[filter-fragment]     编出来会被 ABI 预检拦下，只用于对照实验。"
    exit 0
    ;;
  docker)
    # 黑名单模式：整份碎片都保留，只剔除两个【会改 struct css_set 定长数组】的项。
    #   CGROUP_DEVICE / CGROUP_PIDS 会让 CGROUP_SUBSYS_COUNT 7→9，
    #   而 struct css_set{ ... subsys[N]; e_cset_node[N]; } 的 N 是定长的，
    #   没有任何 KABI 保留槽手段能补数组长度 → 只能不开。
    #   （POSIX_MQUEUE 的坑已由 scripts/patch-abi-safe.sh 用保留槽解决，故保留。）
    DENY="CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS"
    PAT=$(printf '%s\n' "$DENY" | tr -s ' \n' '\n' | grep -v '^$' | sed 's/^/^/; s/$/$/' | paste -sd'|' -)
    awk -v pat="$PAT" '
      /^[[:space:]]*(#|$)/ { print; next }
      /^[[:space:]]*[^#]/ {
        key = $0; sub(/[[:space:]]*=.*$/, "", key)
        if (key !~ pat) print
        next
      }
    ' "$SRC" > "$OUT"
    echo "[filter-fragment] 模式 docker → $(basename "$OUT")"
    echo "[filter-fragment]   已剔除（ABI 危险，需重编 vendor 模块才能开）："
    for k in $DENY; do
      if grep -qE "^#?[[:space:]]*${k}[= ]" "$SRC"; then echo "      - $k"; fi
    done
    echo "[filter-fragment]   保留的 CONFIG 行："
    grep -E '^CONFIG_' "$OUT" | sed 's/^/    /' || echo "    （无）"
    exit 0
    ;;
  ns)
    ALLOW="CONFIG_NAMESPACES CONFIG_NET_NS CONFIG_PID_NS CONFIG_UTS_NS CONFIG_USER_NS
CONFIG_POSIX_MQUEUE CONFIG_IPC_NS CONFIG_POSIX_MQUEUE_SYSCTL"
    ;;
  userns)
    ALLOW="CONFIG_NAMESPACES CONFIG_NET_NS CONFIG_PID_NS CONFIG_UTS_NS CONFIG_USER_NS"
    ;;
  ipc)
    ALLOW="CONFIG_NAMESPACES CONFIG_NET_NS CONFIG_PID_NS CONFIG_UTS_NS
CONFIG_POSIX_MQUEUE CONFIG_IPC_NS CONFIG_POSIX_MQUEUE_SYSCTL"
    ;;
  cgroup)
    ALLOW="CONFIG_CGROUPS CONFIG_CGROUP_DEVICE CONFIG_CGROUP_FREEZER CONFIG_CGROUP_PIDS
CONFIG_CGROUP_SCHED CONFIG_CPUSETS CONFIG_MEMCG CONFIG_CGROUP_CPUACCT CONFIG_BLK_CGROUP"
    ;;
  none)
    ALLOW="CONFIG_IKCONFIG CONFIG_IKCONFIG_PROC CONFIG_PAGE_EXTENSION
CONFIG_VETH CONFIG_BRIDGE CONFIG_OVERLAY_FS CONFIG_SECCOMP CONFIG_SECCOMP_FILTER
CONFIG_CGROUP_BPF CONFIG_BPF_SYSCALL"
    ;;
  *)
    echo "[filter-fragment] 未知模式 '$MODE'（只能是 all|docker|ns|userns|ipc|cgroup|none）" >&2
    exit 2
    ;;
esac

# 允许列表转成 grep -E 的模式：精确匹配 key（CONFIG_X）
PAT=$(printf '%s\n' "$ALLOW" | tr -s ' \n' '\n' | grep -v '^$' | sed 's/^/^/; s/$/$/' | paste -sd'|' -)

awk -v pat="$PAT" '
  /^[[:space:]]*(#|$)/ { print; next }              # 注释与空行原样保留
  /^[[:space:]]*[^#]/ {
    # 非注释行：只看 key（= 之前的部分），命中白名单才输出
    key = $0; sub(/[[:space:]]*=.*$/, "", key)
    if (key ~ pat) print
    next
  }
' "$SRC" > "$OUT"

echo "[filter-fragment] 模式 $MODE → $(basename "$OUT")"
echo "[filter-fragment] 保留的 CONFIG 行："
grep -E '^CONFIG_' "$OUT" | sed 's/^/    /' || echo "    （无）"
