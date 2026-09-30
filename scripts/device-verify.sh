#!/system/bin/sh
# =============================================================================
# device-verify.sh —— 手机端一键验证（ReSukiSU + cgroup devices）
#
# 用法（任选）：
#   adb push scripts/device-verify.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/device-verify.sh'
#
#   或直接从电脑管道过去：
#   adb shell su -c 'sh -s' < scripts/device-verify.sh
#
# 只读脚本，不修改任何系统状态。
# =============================================================================

echo "==================== 1. 内核版本 ===================="
echo "uname -r  : $(uname -r)"
echo "proc/version: $(cat /proc/version 2>/dev/null)"
echo

echo "==================== 2. 启动参数（找 cgroup_disable） ===================="
if grep -q 'cgroup_disable' /proc/cmdline 2>/dev/null; then
  echo "[!] cmdline 里有 cgroup_disable，会禁掉对应控制器："
  tr ' ' '\n' < /proc/cmdline | grep cgroup | sed 's/^/    /'
else
  echo "[OK] /proc/cmdline 里没有 cgroup_disable"
fi
echo

echo "==================== 3. /proc/cgroups（核心检查） ===================="
echo "  列: subsys  hierarchy  num_cgroups  enabled"
if [ -f /proc/cgroups ]; then
  cat /proc/cgroups
  echo
  DEV_LINE="$(grep -w devices /proc/cgroups 2>/dev/null)"
  if [ -z "$DEV_LINE" ]; then
    echo "[FAIL] /proc/cgroups 里【没有】devices 控制器"
    echo "       -> CONFIG_CGROUP_DEVICE=y 没生效，模块一定会报"
    echo "          '[WARN] Devices cgroup controller not available.'"
  else
    echo "  devices 行: $DEV_LINE"
    if echo "$DEV_LINE" | awk '{print $4}' | grep -q '^1$'; then
      echo "[OK]  devices 控制器 enabled=1  <== WARN 应该消失了"
    else
      echo "[FAIL] devices 控制器存在但 enabled=0（等于没开）"
    fi
  fi
  PID_LINE="$(grep -w '^pid' /proc/cgroups 2>/dev/null)"
  [ -z "$PID_LINE" ] && PID_LINE="$(awk '$1=="pid"{print}' /proc/cgroups)"
  if [ -n "$PID_LINE" ]; then
    echo "  pid 行: $PID_LINE"
    echo "$PID_LINE" | awk '{print $4}' | grep -q '^1$' \
      && echo "[OK]  PID cgroup 控制器 enabled=1" \
      || echo "[!]  PID cgroup 控制器未启用"
  fi
else
  echo "[!] /proc/cgroups 不存在"
fi
echo

echo "==================== 4. 命名空间（Docker 起容器必需 PID_NS） ===================="
NS=""
[ -e /proc/self/ns/pid ] && NS="$NS pid"
[ -e /proc/self/ns/net ] && NS="$NS net"
[ -e /proc/self/ns/ipc ] && NS="$NS ipc"
[ -e /proc/self/ns/uts ] && NS="$NS uts"
[ -e /proc/self/ns/user ] && NS="$NS user"
[ -e /proc/self/ns/mnt ] && NS="$NS mnt"
echo "  可用 namespace:${NS:- (无)}"
echo "$NS" | grep -q pid \
  && echo "[OK]  PID namespace 可用（dockerd 起容器必需）" \
  || echo "[FAIL] 没有 pid namespace -> CONFIG_PID_NS 没开，dockerd 会失败"

echo "  unshare 测试:"
if command -v unshare >/dev/null 2>&1; then
  if unshare -p -f --mount-proc echo "    [OK]  unshare -p 成功（PID_NS 真的可用）" 2>/dev/null; then
    :
  else
    echo "    [FAIL] unshare -p 失败 -> PID_NS 不可用"
  fi
else
  echo "    (无 unshare 命令，跳过)"
fi
echo

echo "==================== 5. /proc/config.gz（若内核开了 IKCONFIG_PROC） ===================="
if [ -f /proc/config.gz ]; then
  for k in CGROUP_DEVICE CGROUP_PIDS PID_NS USER_NS NET_NS NF_TABLES NF_TABLES_BRIDGE \
           BRIDGE_NETFILTER VETH BRIDGE OVERLAY_FS SECCOMP_FILTER CGROUP_BPF BPF_SYSCALL KSU; do
    V="$(zcat /proc/config.gz 2>/dev/null | grep "^CONFIG_${k}=" | head -n1)"
    if [ -z "$V" ]; then
      V="$(zcat /proc/config.gz 2>/dev/null | grep "^# CONFIG_${k} is not set" | head -n1)"
    fi
    printf '  %-24s %s\n' "CONFIG_${k}" "${V:-<不存在>}"
  done
else
  echo "  [!] /proc/config.gz 不存在（未开 CONFIG_IKCONFIG_PROC），"
  echo "      只能靠 /proc/cgroups 与 namespace 反推。"
fi
echo

echo "==================== 6. ReSukiSU 状态 ===================="
if [ -d /data/adb/ksu ] || [ -f /data/adb/ksud ]; then
  echo "[OK]  检测到 /data/adb/ksu (或 ksud)，KernelSU/ReSukiSU 已就绪"
  ls -ld /data/adb/ksu 2>/dev/null
  [ -f /data/adb/ksu/version ] && echo "  version: $(cat /data/adb/ksu/version)"
else
  echo "[!]  /data/adb/ksu 不存在 —— KSU 可能没生效，或还没装管理器"
fi
ID_OUT="$(id 2>/dev/null)"
echo "  id: $ID_OUT"
echo "$ID_OUT" | grep -q 'uid=0' && echo "[OK]  当前是 root" || echo "[!]  当前不是 root"
echo

echo "==================== 7. cgroup 挂载情况 ===================="
echo "--- mount | grep cgroup ---"
mount 2>/dev/null | grep cgroup | sed 's/^/  /' || echo "  (没有 cgroup 挂载)"
echo
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  echo "  cgroup v2 已挂载，可用控制器:"
  echo "    $(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)"
  echo "  注意: cgroup v2 天然【没有】devices 控制器（devices 只在 v1）。"
  echo "        需要 devices 白名单时，在 chroot 内单独挂 v1 层级："
  echo "          mkdir -p /sys/fs/cgroup/devices"
  echo "          mount -t cgroup -o devices devices /sys/fs/cgroup/devices"
else
  echo "  cgroup v1 或未挂载（无 cgroup.controllers 文件）"
fi
echo

echo "==================== 8. Docker（若在 chroot 内执行） ===================="
if command -v docker >/dev/null 2>&1; then
  echo "  docker 版本: $(docker --version 2>/dev/null)"
  echo "  dockerd 进程: $(pgrep -l dockerd 2>/dev/null || echo '未运行')"
  echo "  --- docker info (前 30 行) ---"
  docker info 2>&1 | head -n 30 | sed 's/^/  /'
else
  echo "  (当前环境没有 docker 命令；请在 Ubuntu Chroot 内执行本脚本以验证 Docker)"
fi
echo

echo "==================== 结论 ===================="
echo "  1) /proc/cgroups 的 devices 行 enabled=1  -> 模块 WARN 消失"
echo "  2) /proc/self/ns/pid 存在 + unshare -p 成功 -> Docker 能创建容器"
echo "  3) dockerd 起不来时，先看: dockerd --debug 2>&1 | tail -50"
echo "     以及 chroot 内 /sys/fs/cgroup 是否可写、daemon.json 里是否关了 iptables/bridge"
