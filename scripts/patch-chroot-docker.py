#!/usr/bin/env python3
# =============================================================================
# patch-chroot-docker.py —— 给 Ubuntu chroot app 的脚本打「Docker 支持」补丁
#
# 背景（2026-10-01 全套实测结论，详见项目记忆）：
#   在小米 12S Pro / LineageOS 23.2 上，用自编的 ABI 安全内核跑 chroot 里的
#   Docker，需要三处修复。前两处属于 chroot app 的脚本，用本脚本自动打：
#
#   1) /sys/fs/cgroup 必须是真正的 cgroup2（而不是 app 挂的空 tmpfs）
#      原因：Docker 看到非 cgroup2 就按 cgroup v1 处理，而 v1 启动硬性要求
#            devices cgroup 挂载 → "failed to start daemon: Devices cgroup isn't mounted"
#      而本内核按 ABI 铁律不能开 CONFIG_CGROUP_DEVICE（会改 struct css_set 的
#      定长数组 → 295 个导出符号 CRC 变 → ROM 的 vendor 模块拒载 → 卡米标）。
#      cgroup v2 的设备控制走 BPF，只依赖 CONFIG_CGROUP_BPF（=y）。
#
#   2) 挂载树必须 rprivate，且 rootfs 递归自 bind
#      原因：runc 创建容器要 pivot_root，内核判定里有
#            IS_MNT_SHARED(root_parent) → EINVAL
#            !mnt_has_parent(root_mnt)  → EINVAL
#      Android 默认整棵挂载树是 shared，所以必须 rprivate。
#      （app 原本只在 sparse-image 布局里做过这步，目录布局走不到，
#        它自己的注释就写了 "prevents peer group conflicts that cause pivot_root to fail"。）
#
#   3) post_exec.sh 里自动起 dockerd（本脚本可选追加）
#
# 用法：
#   python3 patch-chroot-docker.py <chroot.sh> [post_exec.sh]
#   会自动备份为 <file>.bak-YYYYMMDD，幂等（已打过就跳过）。
#   注意：必须保持 LF 行尾！本脚本用 newline='' 打开，不会引入 CRLF。
# =============================================================================
import datetime
import os
import sys

ANCHOR = '''    log "Setting up minimal cgroups for Docker..."
    run_in_ns mkdir -p "$CHROOT_PATH/sys/fs/cgroup"
    if run_in_ns mount -t tmpfs -o mode=755 tmpfs "$CHROOT_PATH/sys/fs/cgroup" 2>/dev/null; then
        echo "$CHROOT_PATH/sys/fs/cgroup" >> "$MOUNTED_FILE"
        run_in_ns mkdir -p "$CHROOT_PATH/sys/fs/cgroup/devices"
        if grep -q devices /proc/cgroups 2>/dev/null; then
            if run_in_ns mount -t cgroup -o devices cgroup "$CHROOT_PATH/sys/fs/cgroup/devices" 2>/dev/null; then
                log "Cgroup devices mounted successfully."
                echo "$CHROOT_PATH/sys/fs/cgroup/devices" >> "$MOUNTED_FILE"
            else
                warn "Failed to mount cgroup devices."
            fi
        else
            warn "Devices cgroup controller not available."
        fi
    else
        warn "Failed to mount cgroup tmpfs."
    fi
'''

REPLACEMENT = '''    # ===================== [PATCH-DOCKER begin] =====================
    # 让 chroot 里的 Docker 能真正跑起来（配合自编 ABI 安全内核）。
    # 原逻辑（空 tmpfs + cgroup v1 devices）有两处不成立：
    #  1) 本内核按 ABI 铁律【不能】开 CONFIG_CGROUP_DEVICE —— 它会改
    #     include/linux/cgroup-defs.h 里 struct css_set 的定长数组
    #     (subsys[CGROUP_SUBSYS_COUNT]) → 295 个导出符号 CRC 变 →
    #     ROM 里预编译的 vendor 模块集体拒载 → 屏幕永远停在米标。
    #     所以 devices 控制器必然不存在，那句 warn 是必然的。
    #  2) Docker 看到 /sys/fs/cgroup 不是 cgroup2 就按 cgroup v1 处理，而 v1
    #     启动硬性要求 devices 挂载 → "Devices cgroup isn't mounted" 直接退出。
    # 修法一：挂真正的 cgroup2。v2 的设备控制走 BPF，只依赖 CONFIG_CGROUP_BPF（=y）。
    # 修法二：挂载树 rprivate。runc 要 pivot_root，内核要求「当前根是挂载点」且
    #     「其父挂载不是 shared」；Android 默认整棵树 shared。
    # 修法三：rootfs 递归自 bind，让 chroot 里的 "/" 成为挂载点。
    log "Setting up cgroups for Docker (cgroup2 + rprivate) [PATCH]..."
    if run_in_ns "${BUSYBOX}" mount --make-rprivate / 2>/dev/null; then
        log "  [PATCH] 挂载树已设为 rprivate（pivot_root 必需）"
    else
        warn "  [PATCH] make-rprivate 失败：Docker 会报 pivot_root invalid argument"
    fi
    run_in_ns mkdir -p "$CHROOT_PATH/sys/fs/cgroup"
    run_in_ns mount -o rbind "$CHROOT_PATH" "$CHROOT_PATH" 2>/dev/null \\
        && log "  [PATCH] rootfs 已递归 bind（让 / 成为挂载点）" \\
        || warn "  [PATCH] rootfs 递归 bind 失败"
    # 先解掉可能残留的旧挂载（连续重启 chroot 时会 busy）
    run_in_ns umount "$CHROOT_PATH/sys/fs/cgroup" 2>/dev/null
    if run_in_ns mount -t cgroup2 none "$CHROOT_PATH/sys/fs/cgroup" 2>/dev/null; then
        log "  [PATCH] cgroup2 已挂载（Docker 走 v2 路径，无需 devices 控制器）"
        echo "$CHROOT_PATH/sys/fs/cgroup" >> "$MOUNTED_FILE"
    else
        warn "  [PATCH] cgroup2 挂载失败：Docker 守护进程可能起不来"
    fi
    # ====================== [PATCH-DOCKER end] ======================
'''

POST_ADD = '''
# ===================== [PATCH-DOCKER] =====================
# 自动启动 dockerd（本机自编 ABI 安全内核已实测可用：pid/ipc/user ns + cgroup v2）。
# 前置条件由 chroot.sh 的 [PATCH] 段负责：cgroup2 挂在 /sys/fs/cgroup、
# 挂载树 rprivate、rootfs 递归 bind。
# 存储驱动固定 fuse-overlayfs：本机内核拒绝对 f2fs 用 overlayfs
#   （dmesg: overlayfs: filesystem on '...' not supported —— f2fs 带 casefold 特性），
#   vfs 能用但容器 rootfs 不是挂载点。
if command -v dockerd >/dev/null 2>&1 && ! pgrep -x dockerd >/dev/null 2>&1; then
    nohup dockerd > /var/log/dockerd.log 2>&1 &
    echo "[POST-EXEC] dockerd 已启动（日志 /var/log/dockerd.log）"
fi
# =================== [/PATCH-DOCKER] ======================
'''


def read(p):
    return open(p, encoding='utf-8', errors='surrogateescape', newline='').read()


def write(p, t):
    open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(t)


def backup(p, tag):
    bak = "%s.bak-%s" % (p, tag)
    if not os.path.exists(bak):
        write(bak, read(p))
        print("  已备份 ->", bak)
    return bak


def patch_chroot(path):
    t = read(path)
    if '[PATCH-DOCKER' in t:
        print("[=] 已打过补丁，跳过:", path)
        return True
    n = t.count(ANCHOR)
    if n != 1:
        print("[ERROR] 锚点匹配 %d 处（期望 1），app 版本可能变了，请人工核对。" % n)
        return False
    print("  匹配到锚点 1 处，开始替换")
    write(path, t.replace(ANCHOR, REPLACEMENT))
    print("[+] 已打补丁:", path)
    return True


def patch_post_exec(path):
    t = read(path)
    if '[PATCH-DOCKER' in t:
        print("[=] post_exec 已打过补丁，跳过:", path)
        return True
    if not t.endswith('\n'):
        t += '\n'
    write(path, t + POST_ADD)
    print("[+] 已追加 dockerd 自启:", path)
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    tag = datetime.date.today().strftime("%Y%m%d")
    chroot_sh = sys.argv[1]
    post = sys.argv[2] if len(sys.argv) > 2 else None
    backup(chroot_sh, tag)
    ok = patch_chroot(chroot_sh)
    if post and os.path.exists(post):
        backup(post, tag)
        patch_post_exec(post)
    # CRLF 自检（打过补丁的脚本被 Windows 编辑过就会带上 \r，mksh 会语法报错）
    for p in [chroot_sh] + ([post] if post else []):
        cr = open(p, 'rb').read().count(b'\r')
        print("  行尾自检 %s: CR 字节 = %d %s" % (p, cr, "(OK)" if cr == 0 else "(!! 有 CRLF，必须转成 LF)"))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
