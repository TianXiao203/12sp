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
- 本机可 `git push`（SSH 已配）；`raw.githubusercontent.com` 不稳，优先用
  api.github.com contents（base64），注意 60 次/小时匿名限流

## 两个必须遵守的硬规则（都踩过坑）
1. **版本串必须精确等于 `5.10.260-gki-gef362912d37b`**，否则 ROM 现成的
   vendor 模块全部加载失败（能开机但 Wi-Fi/蓝牙/音频废）。
   `scripts/setlocalversion` 对脏工作树会追加 `-dirty`，而我们必然要改
   `gki_defconfig` / `drivers/Makefile` / `drivers/Kconfig`。
   对策：在**刚 checkout、树还干净时**写 `$WS/common/.scmversion` =
   `-g$(git rev-parse HEAD | cut -c1-12)`；setlocalversion 会优先读它并直接 return。
2. **clang 版本必须与设备内核一致**（`clang-r563880c`，clang 21.0.0 / build 14054515）。
   因为 `CONFIG_CFI_CLANG=y` 的**类型哈希由编译器算出来**，而 ROM 里的
   vendor_dlkm 模块是官方 clang 21 编的。内核换了 clang 版本 → 哈希对不上 →
   刷进去**卡在开机 logo**，屏幕无报错、pstore 也为空（是 hang 不是 panic）。
   实测：clang 12 编的刷进去卡 logo；用 clang 21 编的（用户当前内核）能启动。
3. **Windows 上写 `.gitignore` 必须逐个 `git check-ignore -v` 验证**：
   本机 `core.ignorecase=true`，gitignore 匹配不区分大小写。
   曾因写 `AnyKernel3/` 把仓库里的 `anykernel3/` 一起忽略，导致该文件从未入库、
   CI 上 `cp` 找不到源文件而静默秒退。**绝不能出现大小写只差的名字。**

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

## 提交状态（2026-10-01）
`origin/main` = `178a3c7`；Run#5（sha `02ae2a7`）已全绿，
版本串 `5.10.260-gki-gef362912d37b` 与设备逐字一致。
