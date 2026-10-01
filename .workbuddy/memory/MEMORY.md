# 项目长期记忆 —— 12sp 内核构建工程

## 目标
为小米 12S Pro（unicorn / SM8475，LineageOS 23.2）编一个集成 **ReSukiSU**、
并开启 Docker 所需 cgroup/namespace 的 5.10 GKI 内核；产物只换 `Image`（AnyKernel3）。

## 不可动摇的设备与构建事实（已实测钉死）
- 设备：`unicorn` / `2206122SC`，serial `b846f64b`，slot **`_b`**，已解锁（orange）
- 系统：**LineageOS 23.2**（`23.2-20260925-NIGHTLY-unicorn`）
- 设备内核：**`5.10.260-gki-gef362912d37b`**
- 内核树：`LineageOS/android_kernel_xiaomi_sm8450` @ **`lineage-23.2`**
  @ commit **`ef362912d37b761041709638c1e571d6394e9558`**
  （`CONFIG_LOCALVERSION_AUTO=y`，版本串尾部带该 sha；不一致 → vendor 模块加载失败）
- clang：`LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b`
  （设备 banner 显示官方实际用 clang 21.0.0 / r563880c；**clang 版本不影响 ABI**）
- 参考：`reference/device-config.txt` = 设备真实 `/proc/config.gz`（adb 导出）

## 配置必须写进哪里
**`arch/arm64/configs/gki_defconfig` 本体**（base），不能写 `vendor/*_GKI.config` 碎片
（`build.config.msm.gki` 的 `merge_defconfig_fragments()` 会 `ERROR! Detected overridden config!` 退出）。
唯一例外：`CONFIG_LOCALVERSION` 改碎片（碎片里本就是 `-gki`）。

LineageOS 官方用的是 5 件套（`gki_defconfig` 为 base）：
```
gki_defconfig + vendor/waipio_GKI.config + vendor/xiaomi_GKI.config
              + vendor/unicorn_GKI.config + vendor/debugfs.config
```

## Docker 崩溃的真实根因（三个，不是一个）
1. `CONFIG_CGROUP_DEVICE` 在 gki_defconfig 里**没有这一行**（Kconfig 无 default y）→ 默认 n
2. `# CONFIG_PID_NS is not set`（硬编码关闭）—— Docker 建容器必需
3. **`CONFIG_SYSVIPC` 也没开** → `IPC_NS` 的 `depends on (SYSVIPC || POSIX_MQUEUE)` 不满足，
   连符号都不出现，只写 `CONFIG_IPC_NS=y` 会被 olddefconfig 静默关掉

旁证：设备 `/proc/cgroups` 无 devices/pid；`/proc/self/ns/` 无 pid/ipc/user。

## 构建方式（现行）
**不走 `build/build.sh`**（它会把 `/../../preconfig-...` 两处硬检查变成 1~2 秒的 `exit 1`；
且只合并 `waipio_GKI.config`，会丢设备专属配置）。
改为：`merge_config.sh` 合并 5 件套 → **直接 `make O=… Image`**（= LineageOS `kernel.mk`）。
LTO 从官方 FULL 改成 **THIN**（16GB/4 核 runner 上 Full LTO 会 OOM）。
`Image` 是唯一交付物，不需要 modules/dtbs/vendor_dlkm。

## CI 排查手段（重要）
- Actions job log 接口需 admin（匿名 **403**）；artifact 下载需 auth（**401**）
- **`/repos/{o}/{r}/check-runs/{id}/annotations` 匿名可读（200）**
  → 失败路径必须主动 `echo "::error::<行>"` 才能远程取到报错
- 失败时 workflow 会把 `build.log` 推到 **`ci-diag` 分支**（可匿名 clone）
- 成功时把 AK3 包推到 **`ci-artifacts` 分支**（`publish_artifacts` 开关）；
  已有 run 的产物可用 `.github/workflows/publish-artifact.yml` 跨 run 转分支
  （`actions/download-artifact@v4` 的 `run-id` 参数 + `permissions: actions: read`），
  **不必重编**。nightly.link 对未注册仓库 404，不可用。
- **拿不到产物时的替代路径**：直接让用户在 run 页面点下载（他习惯下到手机
  `/sdcard/Download/微信输入法/...` 或 PC 的 Downloads）
- 本机可 `git push`（SSH 已配，但沙箱代理会间歇性拦截 SSH；
  被拦时用 HTTPS + `-c http.schannelCheckRevoke=false`，或让用户自己推）
- `raw.githubusercontent.com` 不稳，优先用 api.github.com contents（base64），
  注意 60 次/小时匿名限流

## 必须遵守的硬规则（全都踩过坑，按重要性排序）
1. **★ ABI 铁律：绝不能开会改变结构体布局的配置项**（比版本串更致命、更难查）。
   内核与 ROM 里 395 个预编译 `/vendor/lib/modules/*.ko` 是**分离编译**的：
   模块把所需符号的 CRC 写在 `__versions` 段，内核加载时比对，不一致就拒载。
   CRC 由 `genksyms` 从【类型定义】算出 → 改了结构体布局 = 所有相关导出符号
   CRC 全变 = 模块集体拒载 = **屏幕永远停在米标**（hang 不是 panic，
   所以无日志、pstore 空、dropbox 无 `SYSTEM_LAST_KMSG`）。
   已确认的杀手（都别开）：
     - `CONFIG_NF_TABLES=y` → `include/net/net_namespace.h:145` 给 `struct net`
       加 `netns_nftables nft;`
     - `CONFIG_SYSVIPC=y` → `include/linux/sched.h:973` 给 `struct task_struct`
       加 `sysv_sem sysvsem; sysv_shm sysvshm;`
       （所以 `IPC_NS` 的前置依赖要用 `POSIX_MQUEUE`，不是 `SYSVIPC`）
     - `CONFIG_POSIX_MQUEUE=y` → `include/linux/sched/user.h:24` 给
       `struct user_struct` 加 `unsigned long mq_bytes;`（经 `cred.user` 波及
       task/file/socket → **725 个符号 CRC 变**）。
       ★ 已修：`scripts/patch-abi-safe.sh` 用 `ANDROID_KABI_USE(2, unsigned long mq_bytes)`
       把它挪进 GKI 预设的保留槽（`__GENKSYMS__` 下等价于原 `u64 android_kabi_reserved2`，
       genksyms 文本与 ROM 逐字相同 → CRC 不变；编译器侧 8 字节 union → 布局也不变）。
       ⇒ 改完 `user.h` 千万**别**把 `ANDROID_KABI_USE` 改回 `ANDROID_KABI_RESERVE(2)`。
     - `CONFIG_CGROUP_DEVICE=y` / `CONFIG_CGROUP_PIDS=y` → `CGROUP_SUBSYS_COUNT`
       7→9，而 `include/linux/cgroup-defs.h` 里 `struct css_set`（以及 `struct cgroup`）
       的 `subsys[CGROUP_SUBSYS_COUNT]` / `e_cset_node[CGROUP_SUBSYS_COUNT]` 是**定长数组**
       → **295 个符号 CRC 变**。**KABI 保留槽救不了数组长度，只能不开**。
       代价：Docker 拿不到 devices/pids 控制器（/proc/cgroups 无这两行，
       "Devices cgroup controller not available." 告警依旧）；想真拿到只能连
       `modules/qcom/...` 那票 vendor 模块一起重编重刷。
   已验证安全（实测各 0 个符号变化）：`PID_NS`（gki_defconfig 自带 y，设备是 n）、
   `USER_NS`（5.10 里 `user_struct.locked_vm` 的条件是 PERF_EVENTS||BPF_SYSCALL||NET||IO_URING，
   **不是** USER_NS）、`IPC_NS`、`POSIX_MQUEUE_SYSCTL`、`KSU`（有无 KSU 失配集合完全一致）、
   `DEBUG_INFO=off`（genksyms 只看类型不看调试数据）。
   防护三层：fragment 不含危险项 + workflow 兜底 sed 删除 +
   **`ABI 预检`**（`scripts/check-abi-crc.py` 比对 `Module.symvers` 与
   `abi-baseline/abi-crcs.txt` 的 1613 个符号 CRC，不一致 CI 报红、别刷）。
   联网可行的查法：把候选配置名丢进内核源码头文件里 grep `#if*CONFIG_X`，
   看是否落在某个 struct 定义内。
   **定位方法论（比读源码猜快得多）**：CI push 即编，然后拿各次构建的
   `kernel.Module.symvers`（失败时在 `ci-diag/art/` 分支里，可匿名取）
   做集合运算（⊂/∩/∪）并逐符号比 CRC 值 —— 元凶是哪个配置、有几个，一目了然。
   （实测 295 ⊂ 725 且两者在 295 上的 CRC 值互不相同 ⇒ 两种机制独立叠加。）
2. **版本串必须精确等于 `5.10.260-gki-gef362912d37b`**，否则 ROM 现成的
   vendor 模块加载失败（vermagic 不一致）。
   `scripts/setlocalversion` 对脏工作树会追加 `-dirty`，而我们必然要改
   `gki_defconfig` / `drivers/Makefile` / `drivers/Kconfig`。
   对策：在**刚 checkout、树还干净时**写 `$WS/common/.scmversion` =
   `-g$(git rev-parse HEAD | cut -c1-12)`；setlocalversion 会优先读它并直接 return。
3. **clang 版本必须与设备内核一致**（`clang-r563880c`，clang 21.0.0 / build 14054515）。
   因为 `CONFIG_CFI_CLANG=y` 的**类型哈希由编译器算出来**。
   来源：`bluegreensea/android_prebuilts_clang_kernel_linux-x86_clang-r563880c`
   （LineageOS 侧**没有**这个仓库；且名字带 `c` 后缀，写成 r563880 会 404）。
4. **Windows 上写 `.gitignore` 必须逐个 `git check-ignore -v` 验证**：
   本机 `core.ignorecase=true`，gitignore 匹配不区分大小写。
   曾因写 `AnyKernel3/` 把仓库里的 `anykernel3/` 一起忽略，导致该文件从未入库、
   CI 上 `cp` 找不到源文件而静默秒退。**绝不能出现大小写只差的名字。**
5. **AnyKernel3 的 `anykernel.sh` 变量必须大写**（`BLOCK=` / `IS_SLOT_DEVICE=` /
   `RAMDISK_COMPRESSION=` / `PATCH_VBMETA_FLAG=`）：现行 ak3-core.sh 删掉了
   小写兼容层，写小写会报 `Unable to determine  partition`（两个空格=变量为空）。
   脚本文件名必须是规范小写 `anykernel.sh`（backend 里 `ash anykernel.sh` 写死）。

## A/B 双槽与 vbmeta 实测事实（2026-10-01）
- 设备是 A/B，活动槽 `_b`。**AK3 的 `IS_SLOT_DEVICE=auto` 会同时写两个槽** ——
  用户以前用 App 刷 AK3 都是双写，所以 boot_a/boot_b 里常是同一个内核。
- 只写一个槽（比如我用 dd 只写 boot_b）会让两槽不一致，但**不影响启动判断**：
  设备只从活动槽启动。
- **vbmeta 的 flags 在 offset 120，且 AVB 头字段是【大端】**：
  实测 vbmeta_b flags = 0x00000003 = HASHTREE_DISABLED|VERIFICATION_DISABLED
  ⇒ **引导校验是关闭的**，所以用 dd / magiskboot 生成的 boot.img 不会被拒；
  "卡米标"一定是内核自己跑起来后挂住（不是 bootloader 拒载，也不是回退另一槽）。
- 排查顺序（省时间）：先读 vbmeta flags 确认校验状态 → 再谈镜像/内核。

## 只编 Image 时没有 Module.symvers（重要）
`Module.symvers` 由 modpost 在为【模块】生成符号版本信息时才产出；
我们只跑 `make Image`，所以它不存在（Run#7 的 ABI 预检因此报"没测成"而非"不兼容"）。
替代：**从 vmlinux（ELF，一定存在）解析** `__ksymtab`/`__kcrctab`：
`scripts/check-abi-crc.py dump-vmlinux <out>/vmlinux -o crcs.txt`
（5.10 arm64 是 PREL32：3×int32；两表由链接脚本 SORT 保证同序；
名字必须落在 `__ksymtab_strings*` 节内）。

## 排查"卡米标"的判据（本次总结）
- pstore `/sys/fs/pstore/` 空 + dropbox 无 `SYSTEM_LAST_KMSG` + 无 tombstones
  ⇒ **是 hang 不是 panic**，别指望日志；往"启动早期就死"的方向查
  （ABI 不兼容 / 模块拒载 / DTB 不匹配）。
- 判断 ABI 不兼容的快速手段：`scripts/check-abi-crc.py check`。
- 米标由 bootloader 画；内核接手屏幕要靠 vendor 模块的显示驱动，
  所以"模块全拒载"的现象就是永远停在米标。

## 构建工作区
源码/JDK 都放 `/mnt/wbkernel/kp`（runner 上 `/mnt` 约 70~86GB 可用，`/` 只有约 14GB），
所以 `free_disk` 默认 `false`，**不需要清理任何系统目录**。
注意 `/mnt` 属于 root，要先 `sudo mkdir + chown` 才能写。

## AnyKernel3 的两个硬约束（都踩过）
1. **`anykernel.sh` 里的变量必须大写**：
   `BLOCK=` / `IS_SLOT_DEVICE=` / `RAMDISK_COMPRESSION=` / `PATCH_VBMETA_FLAG=`。
   AK3 现行 core（含 clone 的 HEAD）只读大写；旧版里的
   `[ "$block" ] && BLOCK="$block"` 小写兼容层已被删除。
   写小写 → `BLOCK` 为空 → 刷机报 `Unable to determine  partition`
   （**两个空格**就是 `$BLOCK` 为空的标志）。
2. **脚本文件名必须是规范的小写 `anykernel.sh`**：
   AK3 backend（`META-INF/com/google/android/update-binary`）里 `ash anykernel.sh`
   写死小写。打包时要先清掉 `Anykernel.sh` 等大小写变体。
   注意 Windows 文件系统不区分大小写，判断"是否存在大写变体"必须用
   `ls -1 | grep` 比对真实名字，不能用 `[ -e Anykernel.sh ]`。

## 免重编修 zip
内核 Image 已经在内核 zip 里、只是脚本有问题时，不必重跑 16 分钟编译：
`python scripts/patch-ak3-zip.py <原zip> anykernel3/anykernel.sh [输出zip]`

## 交付物形态
CI 产物【只有裸内核 `Image`】，没有 `boot.img`（刻意只做 `make Image`）。
`Image` 不能直接刷分区 —— 可刷 boot 镜像需要 ramdisk，而 ramdisk 只能来自 ROM。
要 `.img` 就用 `scripts/make-bootimg-via-adb.sh`（在手机上用 magiskboot 打），
需要一个现成 boot 镜像当底（当前 boot 分区的 dump 最准）。
**`adb shell` 里没有 su**，dump boot 分区得用 ReSukiSU 管理器的 root 终端。

## AK3 工具链架构
AK3 master 的 `tools/*` 是 **32 位 ARM** 静态二进制；设备 `CONFIG_COMPAT=y`，
所以能在手机上跑，不必换包。（`tools/$arch32` 子目录并不存在。）

## 提交状态（2026-10-01 晚）
- **`d1abe3b`（fix(abi)）→ Run#14 `36862135580` 全绿**：ABI 预检通过，
  AK3 包已发布到 `ci-artifacts`（zip 22297761 B，sha256 `3fea43a3…`，
  版本串 `5.10.260-gki-gef362912d37b` 与设备逐字一致）。
  ⇒ **`ANDROID_KABI_USE(2, unsigned long mq_bytes)` 这套修法实测有效**：
  725 个失配清零。交付配置固定为 `KSU=on` / `FRAGMENT=docker` / `DEBUG_INFO=off`。
- 之前的 Run#5（`02ae2a7`）也是全绿，但那时配置里没有 POSIX_MQUEUE/IPC_NS。
- 设备活动槽**已从 `_b` 变成 `_a`**（2026-10-01 实测）；AK3 的 `IS_SLOT_DEVICE=auto`
  双写两槽所以不影响刷机，但以后若要 dd 单槽必须先重新确认活动槽。
- ★ 设备 `uname -r` 与自编内核版本串**完全相同**，光看 uname 判不出刷没刷；
  要判断刷没刷成功，看 `/proc/self/ns/` 有没有 `pid`/`ipc`/`user`。

## 推送通道（2026-10-01 实测，结论明确）
- **SSH 是"间歇性"被拦 —— 直接重试就能过**（实测第 3 次成功推上 `d1abe3b`）。
  `~/.ssh/known_hosts` 里 github.com 三条就是 GitHub 官方当前公钥；被拦时报
  "Host key for github.com has changed"（对端 ECDSA 指纹不匹配）⇒ 是沙箱在做中间人。
  **绝不能**为图省事加 `StrictHostKeyChecking=no`（那等于把私钥交给中间人）。
  正确做法：写个 3~18 次的 `git push origin main` 重试循环，每次间隔 ~20s。
- SSH-over-443 不通：`Connection closed by 127.0.0.1 port 443`。
- HTTPS：`CRYPT_E_NO_REVOCATION_CHECK` 用 `GIT_SSL_NO_VERIFY=true` 可绕过
  （`-c http.schannelCheckRevoke=false` 无效），但本机没存 PAT（GCM 里也没有）
  ⇒ `could not read Password for 'https://TianXiao203@github.com'`。**只读操作用 HTTPS 没问题。**
- `git ls-remote` 不受影响（只传 ref 广告）；`git fetch/clone` 传 pack 会被拦。
- 取 CI 产物不要指望 codeload/raw（常超时）；用 api contents + `--ssl-no-revoke`
  （匿名 60/h，注意省着用），或让用户在 run 页面下载，或走 adb 从手机取。

## chroot 里的 Docker（2026-10-01 真机跑通，重启后仍生效）
**目标已达成**：自编 ABI 安全内核 + Ubuntu chroot 里 `docker run` 可用。
`Server Version 28.2.2 / Storage Driver fuse-overlayfs / Cgroup Version 2`；
容器内 `pid=1`、独立 hostname、`ns: cgroup ipc mnt net pid ... user uts` 全齐。

**三处修复（缺一不可）**
1. chroot 的 `/sys/fs/cgroup` 必须是**真 cgroup2**（app 原来挂空 tmpfs）。
   否则 Docker 走 cgroup v1 路径，启动硬性要求 devices 挂载 →
   `failed to start daemon: Devices cgroup isn't mounted`；而本内核不能开
   `CONFIG_CGROUP_DEVICE`。cgroup v2 的设备控制走 BPF，只依赖 `CONFIG_CGROUP_BPF`（=y）。
2. **挂载树 rprivate**：`busybox mount --make-rprivate /`，**必须在 chroot 外**对真实根做
   （`busybox nsenter -t <holder.pid> -m ...`）。内核 `fs/namespace.c` 的 pivot_root 有
   `IS_MNT_SHARED(root_parent) → EINVAL`，Android 默认整棵树 shared ⇒ runc 建容器恒报
   `pivot_root .: invalid argument`。★ `mount --make-rprivate` 是 **busybox** 语法，
   toybox mount 不认；app 自带 `/data/local/ubuntu-chroot/bin/busybox`。
3. **rootfs 递归自 bind**：`mount -o rbind $ROOT $ROOT`（必须 rbind，`--bind` 会遮住
   已挂好的 /proc /sys /dev）。否则 dockerd 找不到 `/var/lib/docker` 的挂载点 →
   `remount /, flags: 0x84000: invalid argument`。

**附带**：存储驱动用 **fuse-overlayfs** —— 本机内核拒绝对 f2fs 用 overlayfs
（dmesg: `overlayfs: filesystem on '...' not supported`，因 f2fs 带 casefold）。
daemon.json：`{"iptables": false, "bridge": "none", "ip6tables": false, "storage-driver": "fuse-overlayfs"}`。

**落地**：`scripts/patch-chroot-docker.py`（幂等 + 备份 + CRLF 自检）给 app 的
`chroot.sh` 打 `[PATCH-DOCKER]` 段、给 `post_exec.sh` 追加 dockerd 自启；
`scripts/docker-chroot-fix.sh` 是运行时补救/诊断版。
备份：`chroot.sh.bak-20261001`、`post_exec.sh.bak-20261001`、`daemon.json.bak-fuse`。
★ 回退：把 `.bak-20261001` 覆盖回去即可；app 若 OTA 更新会把补丁冲掉，重跑补丁脚本即可。

**给用户的操作**：`sh /data/local/ubuntu-chroot/chroot.sh run docker info`；进容器终端用
`sh /data/local/ubuntu-chroot/chroot.sh start`（或 app 里进 chroot 后直接 `docker ...`）。

**adb 操作铁律（本次踩实）**：嵌套 `sh -c` 引号会被本地层吃掉 → 一律 push 脚本文件执行；
本地会提前展开 `$(...)` → 设备侧展开要写 `\$(...)`；用 Python 改手机 .sh 必须 `newline=''`
（否则 CRLF 让 mksh 报 `syntax error: unexpected 'elif'`）；`pkill -f dockerd` 会自杀，用 `-x`。
