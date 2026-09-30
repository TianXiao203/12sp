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
- 本机可 `git push`（SSH 已配）；`raw.githubusercontent.com` 不稳，优先用
  api.github.com contents（base64），注意 60 次/小时匿名限流
