#!/usr/bin/env bash
# =============================================================================
# verify-built-config.sh —— 编译后核对最终 .config，确认目标项真的生效
#
# 用法: bash scripts/verify-built-config.sh <out_dir>
#   <out_dir> 例如 ~/unicorn-kernel/out/msm-kernel-zeus
#
# 注意：编译期 merge_config.sh / diffconfig 只保证"配置被写进去"，
#       只有最终 .config 才是真相（Kconfig 依赖可能把它推翻）。
# =============================================================================
set -uo pipefail

OUT_DIR="${1:-}"
if [ -z "$OUT_DIR" ] || [ ! -d "$OUT_DIR" ]; then
  echo "用法: bash $0 <out_dir>   例如 out/msm-kernel-zeus" >&2
  exit 1
fi

CONFIG_FILE="$(find "$OUT_DIR" -type f -name '.config' -print -quit 2>/dev/null || true)"
if [ -z "$CONFIG_FILE" ]; then
  CONFIG_FILE="$(find "$OUT_DIR" -type f -name '*gki_defconfig' -print -quit 2>/dev/null || true)"
fi
if [ -z "$CONFIG_FILE" ]; then
  echo "[ERROR] 在 $OUT_DIR 下找不到 .config" >&2
  find "$OUT_DIR" -maxdepth 4 -type d | head -40 >&2
  exit 1
fi
echo "[+] 使用配置文件: $CONFIG_FILE"
echo

# 期望 =y 的项
# 注：CONFIG_SYSVIPC 与 CONFIG_IPC_NS 是本机备份出来的设备 /proc/config.gz
#     实测发现缺失后补上的（设备上 SYSVIPC/POSIX_MQUEUE 都是 not set，
#     导致 IPC_NS 依赖不满足、连符号行都没有）。
REQUIRED_Y="
CONFIG_CGROUPS
CONFIG_CGROUP_DEVICE
CONFIG_CGROUP_FREEZER
CONFIG_CGROUP_PIDS
CONFIG_CGROUP_SCHED
CONFIG_CPUSETS
CONFIG_MEMCG
CONFIG_CGROUP_CPUACCT
CONFIG_BLK_CGROUP
CONFIG_NAMESPACES
CONFIG_NET_NS
CONFIG_PID_NS
CONFIG_SYSVIPC
CONFIG_IPC_NS
CONFIG_UTS_NS
CONFIG_USER_NS
CONFIG_VETH
CONFIG_BRIDGE
CONFIG_OVERLAY_FS
CONFIG_SECCOMP
CONFIG_SECCOMP_FILTER
CONFIG_CGROUP_BPF
CONFIG_BPF_SYSCALL
CONFIG_KSU
"

# 期望开启但允许缺失（不同内核版本符号名可能不同）
OPTIONAL_Y="
CONFIG_BRIDGE_NETFILTER
CONFIG_NF_TABLES
CONFIG_NF_TABLES_BRIDGE
CONFIG_KSU_TOOLKIT_SUPPORT
CONFIG_KSU_MULTI_MANAGER_SUPPORT
CONFIG_IKCONFIG
CONFIG_IKCONFIG_PROC
"

PASS=0; FAIL=0; WARN=0
printf '%-38s %s\n' "配置项" "结果"
printf '%-38s %s\n' "--------------------------------------" "------"

for k in $REQUIRED_Y; do
  if grep -q "^${k}=y$" "$CONFIG_FILE"; then
    printf '%-38s %s\n' "$k" "OK =y"
    PASS=$((PASS+1))
  elif grep -q "^${k}=m$" "$CONFIG_FILE"; then
    printf '%-38s %s\n' "$k" "FAIL =m（必须是 y，built-in）"
    FAIL=$((FAIL+1))
  elif grep -q "^# ${k} is not set$" "$CONFIG_FILE"; then
    printf '%-38s %s\n' "$k" "FAIL 未开启"
    FAIL=$((FAIL+1))
  else
    printf '%-38s %s\n' "$k" "FAIL 符号不存在"
    FAIL=$((FAIL+1))
  fi
done

echo
for k in $OPTIONAL_Y; do
  if grep -q "^${k}=y$" "$CONFIG_FILE"; then
    printf '%-38s %s\n' "$k" "OK =y"
    PASS=$((PASS+1))
  else
    printf '%-38s %s\n' "$k" "SKIP 未开启（可选）"
    WARN=$((WARN+1))
  fi
done

echo
echo "本地版本串 / LOCALVERSION（关系到 ROM 里现成 vendor 模块能否加载）："
grep -E '^CONFIG_(LOCALVERSION|LOCALVERSION_AUTO|MODVERSIONS|MODULE_SIG)' "$CONFIG_FILE" | sed 's/^/      /' || true

# 设备实测：uname -r = 5.10.260-gki-gef362912d37b
#   = LOCALVERSION("-gki") + LOCALVERSION_AUTO 附带的 -g<内核树 git sha>
# 只要 clone 的 commit 是 ef362912d37b761041709638c1e571d6394e9558，版本串就会完全一致。
EXPECTED_RELEASE="${EXPECTED_RELEASE:-5.10.260-gki-gef362912d37b}"
echo "      设备当前内核版本串(目标): $EXPECTED_RELEASE"
if [ -n "${KERNEL_TREE:-}" ] && [ -d "$KERNEL_TREE" ]; then
  REL="$(make -s -C "$KERNEL_TREE" kernelrelease 2>/dev/null || true)"
  if [ -n "$REL" ]; then
    echo "      本树 kernelrelease       : $REL"
    if [ "$REL" = "$EXPECTED_RELEASE" ]; then
      echo "      [OK] 与设备完全一致 -> 只需刷 boot.img，ROM 里现成的 vendor 模块可直接加载"
    else
      echo "      [!] 与设备不一致 -> 刷完可能 WiFi/蓝牙/音频失效；"
      echo "          请确认内核树 commit 是否为 ef362912d37b761041709638c1e571d6394e9558"
    fi
  fi
else
  echo "      (设置 KERNEL_TREE=<内核树路径> 可自动比对 kernelrelease)"
fi

echo
echo "==== 汇总: PASS=$PASS  FAIL=$FAIL  SKIP=$WARN ===="
if [ "$FAIL" -ne 0 ]; then
  echo
  echo "[!] 有 $FAIL 项没生效。排查顺序："
  echo "    1) 确认改的是 msm-kernel/arch/arm64/configs/gki_defconfig（defconfig 本体），"
  echo "       而不是 arch/arm64/configs/vendor/zeus_GKI.config 碎片；"
  echo "    2) 看编译日志里 merge_config.sh 的输入文件列表是否符合预期；"
  echo "    3) 若报 'Defconfig fragment did not apply as expected'，说明有非新增差异，"
  echo "       检查是否在碎片里改动了已有配置；"
  echo "    4) CONFIG_PID_NS 必须在 defconfig 本体里从 '# CONFIG_PID_NS is not set' 改成 '=y'。"
  exit 1
fi

echo
echo "[+] 全部必需项已 =y。"
echo "    设备端复核："
echo "      adb shell su -c 'zcat /proc/config.gz | grep -E \"CGROUP_DEVICE|PID_NS|USER_NS\"'"
echo "      adb shell su -c 'cat /proc/cgroups'   # devices 行第 4 列必须为 1"
