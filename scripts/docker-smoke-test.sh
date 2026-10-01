#!/bin/sh
# Docker 冒烟测试：只验证「容器能不能被创建出来」（namespace + cgroup 链路）
# 刻意关掉 iptables/bridge，避免动到手机宿主网络规则；网络留给你们自己的 forward-nat.sh。
ROOT=/data/local/ubuntu-chroot/rootfs
PATHX=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=$ROOT/tmp/dockerd-smoke.log

echo "== 0) 清掉可能残留的 dockerd/containerd =="
# 注意：这里必须用 -x（精确进程名）。用 pkill -f dockerd 会把本脚本自己
# （命令行里含 "dockerd" 字样，如 dockerd-smoke.sh）一起杀掉，实测踩过。
pkill -x dockerd 2>/dev/null
pkill -x containerd 2>/dev/null
sleep 1

echo "== 1) chroot 里的 cgroup 视图 =="
chroot "$ROOT" /usr/bin/env PATH="$PATHX" /bin/bash -c 'ls -la /sys/fs/cgroup; echo "--- cgroup2? ---"; grep -w cgroup2 /proc/filesystems; echo "--- /proc/self/ns ---"; ls /proc/self/ns'

echo
echo "== 2) 启动 dockerd（--iptables=false --ip6tables=false --bridge=none）=="
: > "$LOG"
nohup chroot "$ROOT" /usr/bin/env PATH="$PATHX" /usr/bin/dockerd \
      --iptables=false --ip6tables=false --bridge=none \
      --host=unix:///var/run/docker.sock >> "$LOG" 2>&1 &
sleep 18

echo "-- dockerd 日志（最后 35 行）--"
tail -35 "$LOG"
echo
echo "== 3) docker info 关键片段 =="
chroot "$ROOT" /usr/bin/env PATH="$PATHX" /usr/bin/docker info 2>&1 | grep -iE "server version|storage driver|cgroup|kernel version|warning|error|runtimes" | head -20

echo
echo "== 4) 已有镜像 =="
chroot "$ROOT" /usr/bin/env PATH="$PATHX" /usr/bin/docker images 2>&1 | head -10

echo
echo "== 5) 创建容器（--rm --ipc=private 默认值，最能暴露 namespace 问题）=="
chroot "$ROOT" /usr/bin/env PATH="$PATHX" /usr/bin/docker run --rm --network=none alpine:latest /bin/echo CONTAINER_OK 2>&1 | tail -12
echo "(退出码: $?)"
