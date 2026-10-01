#!/bin/sh
# =============================================================================
# docker-chroot-fix.sh —— 让 Ubuntu chroot 里的 Docker 跑起来（运行时修复 + 自检）
#
# 适用：小米 12S Pro / LineageOS 23.2 + 自编 ABI 安全内核（5.10.260-gki-gef362912d37b）。
# 首选做法是用 scripts/patch-chroot-docker.py 把修复写进 app 的 chroot.sh/post_exec.sh，
# 那样每次启动 chroot 都自动生效。本脚本用于：
#   - app 更新覆盖了 chroot.sh、补丁丢了的时候手动补
#   - 或者只想当场把 Docker 拉起来 / 诊断
#
# 必须在 chroot 自己的 mount namespace 里跑（app 的 holder 提供）：
#   P=$(cat /data/local/ubuntu-chroot/holder.pid)
#   nsenter -t $P -m -u -i -p /bin/sh /data/local/tmp/docker-chroot-fix.sh
#
# 三处修复的原因（全部实测）：
#   1) cgroup2：Docker 看到 /sys/fs/cgroup 不是 cgroup2 就走 cgroup v1 路径，
#      而 v1 启动硬性要求 devices cgroup 挂载 → "Devices cgroup isn't mounted"。
#      本内核按 ABI 铁律不能开 CONFIG_CGROUP_DEVICE（改 struct css_set 定长数组
#      → 295 个符号 CRC 变 → ROM 的 vendor 模块拒载 → 卡米标）。
#      cgroup v2 设备控制走 BPF，只依赖 CONFIG_CGROUP_BPF（=y）✓
#   2) rprivate：runc 建容器要 pivot_root，内核判定要求「当前根的父挂载不是 shared」；
#      Android 默认整棵树 shared → pivot_root 恒 EINVAL。
#   3) rootfs 递归自 bind：让 chroot 里的 "/" 成为挂载点（Docker 找不到 /var/lib/docker
#      的挂载点时会 fallback 到 remount / → EINVAL）。
#
# 另有两点属于 chroot 内部配置（本脚本会检查并提示）：
#   - 存储驱动用 fuse-overlayfs（本机内核拒绝对 f2fs 用 overlayfs：f2fs 带 casefold）
#   - daemon.json 里 iptables/ip6tables 关掉（内核无 nf_tables，按 ABI 要求）
# =============================================================================
ROOT=/data/local/ubuntu-chroot/rootfs
CGR="$ROOT/sys/fs/cgroup"
PATHX=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ic() { chroot "$ROOT" /usr/bin/env PATH="$PATHX" /bin/sh -c "$1"; }

echo "=== 1) 挂载树 rprivate（必须在 chroot 外改真实根，关键！）==="
if awk '$5=="/"{print $7}' /proc/self/mountinfo | grep -q 'shared:'; then
    if command -v busybox >/dev/null 2>&1; then BB=busybox; else BB=/data/local/ubuntu-chroot/bin/busybox; fi
    "$BB" mount --make-rprivate / 2>&1 && echo "  已设为 rprivate" || echo "  [FAIL] make-rprivate 失败"
else
    echo "  已经是 private，跳过"
fi

echo "=== 2) chroot 的 /sys/fs/cgroup 换成 cgroup2 ==="
if grep -F " $CGR " /proc/self/mountinfo | grep -q " - cgroup2 "; then
    echo "  已经是 cgroup2，跳过"
else
    umount "$CGR" 2>/dev/null
    mkdir -p "$CGR"
    mount -t cgroup2 none "$CGR" && echo "  cgroup2 挂载成功" || echo "  [FAIL] cgroup2 挂载失败"
fi
echo "  controllers = $(cat "$CGR/cgroup.controllers" 2>/dev/null)"

echo "=== 3) rootfs 递归自 bind（让 chroot 里的 / 是挂载点）==="
awk -v p="$ROOT" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo \
    && echo "  已挂载，跳过" \
    || { mount -o rbind "$ROOT" "$ROOT" && echo "  递归 bind 成功" || echo "  [FAIL] bind 失败"; }

echo "=== 4) chroot 侧配置自检 ==="
echo "  daemon.json: $(cat "$ROOT/etc/docker/daemon.json" 2>/dev/null)"
ic 'command -v fuse-overlayfs >/dev/null && echo "  fuse-overlayfs 已安装" || echo "  [!] 缺 fuse-overlayfs（apt-get install -y fuse-overlayfs）"'

echo "=== 5) 拉起 dockerd 并跑一个容器 ==="
ic '
pkill -x dockerd 2>/dev/null; sleep 1; rm -f /var/run/docker.sock
nohup dockerd >/tmp/dockerd-fix.log 2>&1 &
i=0; while [ $i -lt 40 ]; do [ -S /var/run/docker.sock ] && break; i=$((i+1)); sleep 1; done
echo "  dockerd $(pgrep -x dockerd >/dev/null && echo 存活 || echo 已退出)（等了 ${i}s）"
docker info 2>&1 | grep -iE "server version|storage driver|cgroup version" | head -3
if docker image inspect busybox:local >/dev/null 2>&1; then
    docker run --rm --network=none busybox:local /bin/busybox sh -c "echo 容器实测OK; ls /proc/self/ns | tr \"\n\" \" \""
else
    echo "  （没有 busybox:local 镜像，跳过容器实测；可用静态 busybox 自行 docker import）"
fi
'
