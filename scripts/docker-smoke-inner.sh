#!/bin/sh
# =============================================================================
# docker-smoke-inner.sh —— 在 Ubuntu chroot 内部运行的 Docker 冒烟测试
#
# 设计要点：
#   1) 必须跑在 chroot 自己的 PID namespace 里（由 app 的 holder 进程提供）。
#      在宿主机 namespace 里对 rootfs 直接 chroot 时 /proc/self 解析不了，
#      容器创建会假失败。宿主侧进入方式：
#        nsenter -t $(cat /data/local/ubuntu-chroot/holder.pid) -a -- \
#          chroot /data/local/ubuntu-chroot/rootfs /bin/sh /root/docker-smoke-inner.sh
#   2) 不依赖网络：不用 docker pull，而是把 chroot 里现成的【静态】Go 二进制
#      （/usr/bin/docker 本身就是静态链接的）打成 rootfs 用 docker import 建一个
#      本地镜像，再 run 它 —— 这样 namespace / cgroup / pivot_root / runc 全链路
#      都会被真实走一遍，而不用管 Docker Hub 连不连得上。
#   3) daemon.json 里已有 {"iptables": false, "bridge": "none"}，所以
#      命令行【不能】再传 --iptables/--bridge，否则 dockerd 直接报
#      "specified both as a flag and in the configuration file" 退出。
# =============================================================================
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

echo "== 0) 环境自检 =="
echo "kernel: $(uname -r)"
echo "ns:     $(ls /proc/self/ns | tr '\n' ' ')"
echo "cgroup: $(ls /sys/fs/cgroup 2>/dev/null | tr '\n' ' ')"
for t in dockerd containerd runc docker; do printf '%-10s %s\n' "$t" "$(command -v $t || echo '<缺失>')"; done

echo
echo "== 1) 起 dockerd（走 /etc/docker/daemon.json）=="
pkill -x dockerd 2>/dev/null
pkill -x containerd 2>/dev/null
sleep 1
rm -f /var/run/docker.sock
nohup /usr/bin/dockerd > /tmp/dockerd.log 2>&1 &
i=0
while [ $i -lt 40 ]; do [ -S /var/run/docker.sock ] && break; i=$((i+1)); sleep 1; done
echo "-- socket 等待 ${i}s ；日志尾部 --"
tail -25 /tmp/dockerd.log

echo
echo "== 2) docker info（关键行）=="
docker info 2>&1 | grep -iE "server version|storage driver|cgroup driver|cgroup version|kernel version|warning|error|runtimes|docker root dir" | head -20

echo
echo "== 3) 离线建一个本地镜像（不联网）=="
rm -rf /tmp/img
mkdir -p /tmp/img/bin
cp /usr/bin/docker /tmp/img/bin/hello 2>/dev/null && echo "  放入静态二进制 /bin/hello"
if tar -C /tmp/img -c . | docker import - localtest:1 >/tmp/import.log 2>&1; then
  echo "  docker import 成功"
else
  echo "  docker import 失败："; tail -5 /tmp/import.log
fi

echo
echo "== 4) 创建并运行容器（--ipc=private 是默认值，最能暴露 namespace 问题）=="
docker run --rm --network=none --ipc=private localtest:1 /bin/hello --version 2>&1 | tail -8
echo "(docker run 退出码: $?)"

echo
echo "== 5) 容器内 cgroup / ns 复核 =="
docker run --rm --network=none localtest:1 /bin/hello --help >/dev/null 2>&1
echo "-- 跑完后 /sys/fs/cgroup 是否有 docker 子目录 --"
ls /sys/fs/cgroup 2>/dev/null | head -5
