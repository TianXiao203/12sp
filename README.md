# 小米 12S Pro (unicorn) + LineageOS：ReSukiSU 内核 + Docker cgroup 支持

环境：**LineageOS**（不是 MIUI/HyperOS）。目标是编译一个集成 **ReSukiSU**（不是原版 KernelSU）的
5.10 GKI 内核，开启 Docker 所需全部 cgroup / namespace 配置，让 `ravindu644/Ubuntu-Chroot`
里的 Docker 守护进程能正常启动，并让模块日志里的
`[WARN] Devices cgroup controller not available.` 消失。

---

## 0. 结论速览（参数已按你这台设备钉死）

> 下面每一条都来自 2026-09-30 通过 adb 对你手机的实测，不是推断。
> 实测记录见 `reference/device-config.txt`（设备真实内核配置）
> 与 `reference/config-changes.md`（变更清单）。

| 项目 | 你这台设备的实际值 |
|---|---|
| 设备 | `unicorn` / 型号 `2206122SC`（小米 12S Pro） |
| 系统 | **LineageOS 23.2**（Android 16），构建号 `23.2-20260925-NIGHTLY-unicorn` |
| 当前内核 | **`5.10.260-gki-gef362912d37b`** ← 这就是你要复现的目标版本串 |
| 内核源码 | `LineageOS/android_kernel_xiaomi_sm8450`，分支 **`lineage-23.2`** |
| 内核 commit | **`ef362912d37b761041709638c1e571d6394e9558`**（与设备 `-gef362912d37b` 完全对应） |
| 要改的 defconfig | `arch/arm64/configs/gki_defconfig`（**本体**，不是 `vendor/*.config` 碎片） |
| Docker 掉链子的原因 | **三处**：`CONFIG_CGROUP_DEVICE` 未开 + `CONFIG_PID_NS` 被关 + **`CONFIG_SYSVIPC` 未开导致 `CONFIG_IPC_NS` 连符号都没有** |
| 刷机方式 | **只刷 boot.img / AK3 就够**（AK3 只换 kernel Image，保留原机 DTB/ramdisk） |
| 为什么只刷 boot 就够 | 同分支同 commit → `uname -r` 完全一致 → vermagic 与 `CONFIG_MODVERSIONS` 符号 CRC 一致 |
| 当前活动槽位 | **`_b`**（boot_b = /dev/block/sde43；boot_a = /dev/block/sde14） |
| 引导状态 | bootloader 已解锁（`verifiedbootstate=orange`） |
| 最稳的构建方式 | 本机无 Linux 工具链 → 用 **GitHub Actions**（第 5 节），或自己的 WSL2 |

---

## 1. 你的配置清单：逐项核实结果（基于 LineageOS 内核树实际内容）

我读了两处并交叉验证：`LineageOS/android_kernel_xiaomi_sm8450`（branch `lineage-23.2`）的
`arch/arm64/configs/gki_defconfig`，以及**你手机里 `adb exec-out cat /proc/config.gz` 拉下来的真实配置**。
逐项结果如下（「设备实测」列即为权威值）：

| 配置项 | 在 LineageOS 的 gki_defconfig 中 | 你要做什么 |
|---|---|---|
| `CONFIG_CGROUPS` | `=y` | 无需改 |
| **`CONFIG_CGROUP_DEVICE`** | **ABSENT（文件里没有这一行，Kconfig 无 `default y` → 默认 n）** | **必须追加 `=y`** ← 核心 |
| `CONFIG_CGROUP_FREEZER` | `=y` | 无需改 |
| **`CONFIG_CGROUP_PIDS`** | **ABSENT（默认 n）** | 建议追加 `=y` |
| `CONFIG_CGROUP_SCHED` | `=y` | 无需改 |
| `CONFIG_CPUSETS` | `=y` | 无需改 |
| `CONFIG_MEMCG` | `=y` | 无需改 |
| `CONFIG_CGROUP_CPUACCT` | `=y` | 无需改 |
| `CONFIG_BLK_CGROUP` | `=y` | 无需改 |
| `CONFIG_NAMESPACES` | `=y` | 无需改 |
| `CONFIG_NET_NS` | 设备实测 `=y` | 无需改 |
| **`CONFIG_PID_NS`** | **`# CONFIG_PID_NS is not set`** | **必须改这一行** ← 核心 |
| `CONFIG_UTS_NS` | 设备实测 `=y` | 无需改 |
| **`CONFIG_USER_NS`** | **`# CONFIG_USER_NS is not set`（Kconfig `default n`）** | **必须追加 `=y`** |
| **`CONFIG_SYSVIPC`** | **`# CONFIG_SYSVIPC is not set`** | **必须追加 `=y`** ← 原清单漏项 |
| **`CONFIG_IPC_NS`** | **设备上连这一行都没有**（依赖 `IPC_NS depends on (SYSVIPC \|\| POSIX_MQUEUE)` 不满足） | **先开 SYSVIPC，它才会出现并成为 `=y`** ← 原清单漏项 |
| `CONFIG_VETH` | `=y` | 无需改 |
| `CONFIG_BRIDGE` | `=y` | 无需改 |
| **`CONFIG_BRIDGE_NETFILTER`** | `# ... is not set` | 建议追加 `=y` |
| **`CONFIG_NF_TABLES`** | `# ... is not set`（nftables 整族都没开） | chroot 里若用 iptables-nft 则追加 |
| **`CONFIG_NF_TABLES_BRIDGE`** | 符号行不存在（依赖 `NF_TABLES` + `BRIDGE`） | 开了 `NF_TABLES` 后追加 |
| `CONFIG_OVERLAY_FS` | `=y` | 无需改 |
| `CONFIG_SECCOMP` / `SECCOMP_FILTER` | **设备实测 `=y`** | 本来就开；显式写一遍便于校验 |
| `CONFIG_CGROUP_BPF` | `=y` | 无需改 |
| `CONFIG_BPF_SYSCALL` | `=y` | 无需改 |
| `CONFIG_KPROBES` | `=y` | 无需改（ReSukiSU 默认 hook 需要） |
| `CONFIG_KSU` | ABSENT | 追加 `=y` |

**关于"某项在源码里不存在时怎么办"**：你清单里的项在 5.10 都有对应 Kconfig 符号，
没有需要找替代方案的。但有两项要特别注意：

- `CONFIG_IPC_NS` 在**设备上连符号行都没有**（不是 `=n`，是根本没这一行），
  因为它的依赖 `SYSVIPC || POSIX_MQUEUE` 两个都是 `not set`。
  这类"依赖不满足因而不可见"的项，必须先开前置项，它才会出现。
- `CONFIG_NF_TABLES_BRIDGE` 同理，依赖 `NF_TABLES` + `BRIDGE`；
  `NF_TABLES=n` 时它在 .config 里也不存在。

这两条是你原清单里没有的信息，如果只照着清单加 `CONFIG_IPC_NS=y`，
`olddefconfig` 会因为你没开 `SYSVIPC` 而把它又关掉 —— 编译不报错，但功能没生效。

### 为什么 `CONFIG_CGROUP_DEVICE` 是"不存在"而不是"没开"

```kconfig
config CGROUP_DEVICE
	bool "Device controller"
	help
	  Provides a cgroup controller implementing whitelists for
	  devices which a process in the cgroup can mknod or open.
```

`bool` 且**没有 `default y`** → 默认 `n`；GKI 的 defconfig 也没写它。
所以 `grep -w devices /proc/cgroups` 那一行的 enabled 永远是 0，模块脚本就报警了。

### 为什么 `CONFIG_PID_NS` 才是 Docker 崩得更直接的原因

`PID_NS` 在 Kconfig 里本是 `default y`，但 GKI 在 defconfig 里**显式关掉了它**
（`# CONFIG_PID_NS is not set`）。而 Docker/runc 创建容器必须 `clone(CLONE_NEWPID)`。
**所以你其实有两个根因**，别只盯着 cgroup devices。

---

## 2. 关键陷阱：碎片只能"新增"，不能"改"

这条决定了配置该写进哪个文件，请务必看懂。

LineageOS 官方 device 树（`android_device_xiaomi_sm8450-common/BoardConfigCommon.mk`）里写着：

```make
TARGET_KERNEL_CONFIG := \
    gki_defconfig \
    vendor/waipio_GKI.config \
    vendor/xiaomi_GKI.config \
    vendor/$(PRODUCT_DEVICE)_GKI.config \
    vendor/debugfs.config
```

即 **`gki_defconfig` 是 base，其余 4 个是碎片**。

而内核树里的 `build.config.msm.common` 对碎片合并做了两道硬校验：

```sh
KCONFIG_CONFIG=... merge_config.sh -m -r -y ${DEFCONFIG_FRAGMENTS}
if grep -q -E -e "Previous value: [^=]+=[ym]" $output; then
    echo "ERROR! Detected overridden config!"
    exit 1
fi
```

```sh
diffconfig arch/${ARCH}/configs/${DEFCONFIG} ${OUT_DIR}/.config
if grep -q -v -E -e "^\+" -e "^CMDLINE " $output; then
    echo "ERROR! Defconfig fragment did not apply as expected"
    exit 1
fi
```

**两个硬约束的含义：**

1. 碎片**只能新增**配置；修改 defconfig 中已有的非默认值 → `ERROR! Detected overridden config!`
2. 最终 `.config` 与 defconfig 的差异**必须全部是新增行**，任何"改动/删除"→
   `ERROR! Defconfig fragment did not apply as expected`

所以：

- ❌ **不要**把 `CONFIG_PID_NS=y` 写进 `vendor/*_GKI.config`
  （base 里它是 `# CONFIG_PID_NS is not set`，会被判为覆盖 → 编译失败）。
- ✅ **正确做法：改 `arch/arm64/configs/gki_defconfig` 本体**。
- ✅ 唯一例外：要改 `CONFIG_LOCALVERSION` 必须改碎片
  （`vendor/waipio_GKI.config` 里是 `CONFIG_LOCALVERSION="-gki"`；
  写在 gki_defconfig 会被碎片反覆盖并报错）。**本方案不需要动它** —— 见第 6 节。

`scripts/apply-configs.sh` 已按这个规则实现，并会在发现碎片文件时提醒你。

---

## 3. 源码仓库与分支

### 3.1 权威仓库清单

来自 `LineageOS/android_device_xiaomi_unicorn/lineage.dependencies` 与
`LineageOS/android_device_xiaomi_sm8450-common/lineage.dependencies`：

| 仓库 | 检出路径 | 说明 |
|---|---|---|
| `LineageOS/android_device_xiaomi_unicorn` | `device/xiaomi/unicorn` | unicorn 设备树 |
| `LineageOS/android_device_xiaomi_sm8450-common` | `device/xiaomi/sm8450-common` | 公共设备树（`TARGET_KERNEL_CONFIG` 就在这里） |
| **`LineageOS/android_kernel_xiaomi_sm8450`** | `kernel/xiaomi/sm8450` | **内核主树** |
| `LineageOS/android_kernel_xiaomi_sm8450-devicetrees` | `kernel/xiaomi/sm8450-devicetrees` | DTB |
| `LineageOS/android_kernel_xiaomi_sm8450-modules` | `kernel/xiaomi/sm8450-modules` | techpack 外部模块（audio/display/camera/wlan…） |
| `LineageOS/android_hardware_xiaomi` | `hardware/xiaomi` | HAL |

工具链（内核树 `build.config.common` 里写死的要求）：

```
BRANCH=android12-5.10
KMI_GENERATION=9
CLANG_PREBUILT_BIN=prebuilts-master/clang/host/linux-x86/clang-r416183b/bin
BUILDTOOLS_PREBUILT_BIN=build/build-tools/path/linux-x86
HERMETIC_TOOLCHAIN=1
```

对应仓库：`LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b`（已确认存在）。

### 3.2 分支与 commit（**你这台已经确认好了**）

实测结果：设备跑的是 **LineageOS 23.2**，内核 `5.10.260-gki-gef362912d37b`。
`CONFIG_LOCALVERSION_AUTO=y`，所以版本串尾部会带上**内核树 git commit** 的前 12 位
（`-gef362912d37b`）。这正好等于 `android_kernel_xiaomi_sm8450` 分支 `lineage-23.2` 当前 HEAD：

| 项 | 值 |
|---|---|
| 内核分支 | **`lineage-23.2`** |
| 内核 commit | **`ef362912d37b761041709638c1e571d6394e9558`** |
| 期望 `uname -r` | **`5.10.260-gki-gef362912d37b`** |

> 因为版本串里带 commit sha，**必须钉住 commit**：如果分支已经往前走了，
> 用分支 HEAD 编出来的会是 `-g<新 sha>`，vermagic 不一致 → ROM 现成模块加载失败。
> 工作流和组装脚本都已默认钉住这个 commit。

如果你以后升级了 LineageOS，就重跑一次下面两条命令取新值：

```sh
adb shell getprop ro.lineage.build.version   # -> 例如 23.2
adb shell uname -r                           # -> 例如 5.10.260-gki-gef362912d37b
# 然后把 -g 后面那 12 位 sha 传给工作流的 kernel_commit 参数
```

> `uname -r` 的那个串非常关键：它决定了你新编的内核能不能直接加载 ROM 里现成的
> vendor 模块（第 6 节会用到）。

> ⚠️ 官方 MiCode（`MiCode/Xiaomi_Kernel_OpenSource`）**没有 unicorn 分支** —— 255 个分支里
> u 段只有 `uke-v-oss`、`ulysse-n-oss`；SM8450 只开源了 `zeus-s-oss`（小米 12/12 Pro，Android 12）。
> 12S 系列国内专供、未单独开源。**在 LineageOS 下你完全不需要它**，用上面 LineageOS 的仓库即可。

---

## 3.5 编译放在哪台机器跑？—— 已实测，结论是 GitHub Actions

### 先纠正一个身份：`192.168.0.10` 就是你手机自己

我用 `ssh root@192.168.0.10` 连上去核对过，它不是另一台电脑，而是**手机上的 Ubuntu chroot**：

| 证据 | 实测值 |
|---|---|
| `/proc/version` | `5.10.260-gki-gef362912d37b` ← 与设备内核完全同一个 |
| CPU | Cortex-X2×1 + A710×3 + A510×4，2.0~3.19 GHz（`nproc`=6） |
| Android 分区 | `/dev/block/by-name/boot_a`、`boot_b` 可见 |
| 根文件系统 | `/dev/block/loop41 on / type ext4`（loop 镜像 = chroot） |
| 外网 | 清华镜像通（`apt-get update` 正常），但 **`curl https://github.com` 连上后传不动数据** |

> 顺带白捡一条重要信息：`/proc/version` 里写着官方是用
> **clang 21.0.0（r563880c）** 编译的，而内核树的 `build.config.common` 却写着
> `clang-r416183b`。工作流已加 `clang_version` 参数处理这个差异（见文末）。

### 三台机器的实测条件

| | 手机 chroot `192.168.0.10` | 你的 PC | GitHub Actions |
|---|---|---|---|
| CPU | ARM 8 核，2.0~3.19 GHz | **Ryzen 7 5800H，8C/16T** | 4 vCPU |
| 内存 | 11.2 GB（可用 6.6 GB） | 13.9 GB，**仅 3.4 GB 空闲** | 16 GB |
| 编译工具链 | ❌ 无 make/gcc/clang/dtc（apt 里有 clang 21.1.6） | ❌ 无 Linux（需装 WSL2） | ✅ 官方 x86_64 clang |
| 拉到 GitHub 源码 | ⚠️ **实测传不动数据** | 同网络，情况相近 | ✅ 机房内网 |

### 时间估算

| 方案 | 拉源码（8~12 GB） | 编译 | 合计 | 判断 |
|---|---|---|---|---|
| A. 手机 chroot | **基本拉不下来** | 2~6 小时（ARM + 降频） | 不可行 | ❌ |
| B. PC + WSL2 | 1~3 小时（可能失败） | 40~70 分钟 | 2~4 小时 | ⚠️ 备选 |
| **C. GitHub Actions** | **2~5 分钟** | 40~70 分钟 | **约 1~1.5 小时** | ✅ **选这个** |

**关键点：瓶颈不是 CPU，是那 8~12 GB 源码。** 在 Actions 上这份下载走 GitHub 机房内网
（分钟级），在任何本地机器上都要走你家宽带从 GitHub 拉 —— 而这条路实测会卡住。
`LineageOS/android_kernel_xiaomi_sm8450` 在国内镜像站没有对应镜像，换源也救不了。
完整评估见 `reference/build-time-evaluation.md`。

### 操作步骤（选 C）

```sh
cd D:\Dev\12sp内核
git init && git add -A && git commit -m "unicorn kernel build kit"
# 在 GitHub 建一个空仓库（私有也行），然后：
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git branch -M main && git push -u origin main
```

推上去后：仓库 → **Actions** → 左侧选
`Build unicorn kernel (LineageOS + ReSukiSU + Docker cgroups)` → **Run workflow**。
参数已按你的设备填好默认值，直接点绿色按钮。约 1~1.5 小时后在 Artifacts 下载
`anykernel3-unicorn.zip`。

> ⚠️ **别把密码写进仓库。** 本工程的脚本全都从环境变量取凭据，仓库里不含任何密码。

### 备选：PC + WSL2（内存要设限）

```sh
# WSL2 里（Ubuntu 22.04），先限制内存，否则 13.9GB 总内存会被榨干
# 在 Windows 的 C:\Users\TX\.wslconfig 写：
#   [wsl2]
#   memory=7GB
#   swap=8GB

sudo apt update && sudo apt install -y bc bison build-essential ccache cpio curl flex \
  g++-multilib gcc-multilib git gnupg gperf lib32ncurses5-dev lib32readline-dev lib32z1-dev \
  libelf-dev liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev libxml2-utils \
  lzop pngcrush python3 python3-pip rsync schedtool squashfs-tools xsltproc zip zlib1g-dev \
  kmod unzip device-tree-compiler

cd /mnt/d/Dev/12sp内核
bash scripts/assemble-lineage-kernel.sh ~/kp lineage-23.2 ef362912d37b761041709638c1e571d6394e9558 clang-r416183b
bash scripts/apply-configs.sh  ~/kp/common
bash scripts/integrate-resukisu.sh ~/kp/common main kprobes
cd ~/kp && set -a && . ./build.env && set +a && ./build/build.sh -j8
```
> 注：`wsl.exe` 被我这边的沙箱黑名单拦着，这一步得你自己在终端里执行。

### 关于 `clang_version` 参数

- 默认 `clang-r416183b`：与内核树 `build.config.common` 里写的一致。
- 但设备内核 banner 显示官方用的是 **clang 21.0.0 (r563880c)**
  （LineageOS 用自己的 `KERNEL_CLANG_VERSION := $(LLVM_AOSP_PREBUILTS_VERSION)` 覆盖了树里的声明）。
- **clang 版本不影响 ABI**：`CONFIG_MODVERSIONS` 的 CRC 是 `genksyms` 从源码类型声明算出来的，
  与编译器无关；vermagic 也不含编译器信息。所以用哪个版本编，ROM 里现成的模块都能加载。
- **只影响"能不能编过"**。所以：**如果编译报 clang 相关错误，把 `clang_version` 改成
  `clang-r563880` 再跑一次。**

---

## 4. 构建路径 A（推荐）：在 LineageOS 源码树里编 `bootimage`

这是最稳的路径：内核、DTB、vendor 模块由同一棵树、同一套配置产出，ABI 天然自洽，
而且完全不用猜工具链路径。

```sh
# 0) 准备：已经有 LineageOS 源码树（否则先 repo init/sync，约 250GB）
cd ~/android/lineage

# 1) 写入配置（会自动定位 kernel/xiaomi/sm8450/arch/arm64/configs/gki_defconfig）
bash /path/to/kit/scripts/apply-configs.sh kernel/xiaomi/sm8450

# 2) 集成 ReSukiSU（5.10 GKI 用默认 kprobes）
bash /path/to/kit/scripts/integrate-resukisu.sh kernel/xiaomi/sm8450 main kprobes

# 3) 只编 boot 镜像，不用整包
source build/envsetup.sh
breakfast unicorn
m bootimage

# 4) 产物
ls -lh out/target/product/unicorn/boot.img
```

也可以让一条命令全做完：`bash /path/to/kit/scripts/lineage-tree-build.sh ~/android/lineage unicorn`。

编完先别刷，跳到第 6 节做版本串比对。

> 想省事也可以直接 `brunch unicorn` 出完整 OTA zip，但那是 2~4 小时的活；
> 我们只改了内核配置，`m bootimage` 就够了。

---

## 5. 构建路径 B：GitHub Actions 自组装

工作流：`.github/workflows/build-unicorn-kernel.yml`

### 5.0 当前实际流程（已按真机调试结果定型）

**不再走 `build/build.sh`**，原因见 5.1 末尾。现在的 20 步流程里，关键的是这几步：

| # | 步骤 | 要点 |
|---|---|---|
| 2 | 选择构建工作区 | **自动挑空间最大的挂载点**。GitHub runner 上 `/mnt` 默认约 70 GB 空闲，而 `/` 只有约 14 GB，所以源码放 `/mnt/kp` → **完全不需要删除系统目录** |
| 5 | 恢复缓存 | `actions/cache` 缓存内置核树与 clang，key 含 commit。重跑时不再重拉 10 GB |
| 6 | 组装工作区 | 内核树 + clang + modules（+ build/dtc，仅作备用） |
| 8 | 写入配置 | `apply-configs.sh` 把 Docker/cgroup + KSU 配置写进 `gki_defconfig` **本体** |
| 10 | 集成 ReSukiSU | 软链 `drivers/kernelsu` + 改 `drivers/Makefile`、`drivers/Kconfig` |
| 13 | 预生成 `.config` | `preconfig-kernel.sh`：`merge_config.sh` 合并 `gki_defconfig` + `waipio/xiaomi/unicorn_GKI.config` + `debugfs.config`，**再追加一个 thin-LTO 碎片**覆盖官方的 Full LTO |
| 14 | 编译 | **直接 `make O=… Image`**（= LineageOS `kernel.mk` 的做法），只编 `Image`，不编 modules/dtbs |
| 15~17 | 体检 / 打包 | `.config` 校验与版本串核对都设了 `continue-on-error`，**内核编出来了就不会被体检报告挡住打包** |

**开关说明**

- `free_disk`（默认 `false`）：源码已经在 `/mnt`，不需要清理任何系统目录。
  只有当你把工作区强制放到 `/` 时才建议打开。
- `enable_swap`（默认 `true`）：只加内存兜底，`swapon` 被拒也不会中断。
- `enable_nftables`（默认 `true`）：Ubuntu 22.04+ 的 `iptables` 默认走 nft 后端，Docker 需要它。

**失败时怎么定位**

Actions 的 job log 接口需要仓库 admin 权限（匿名调用返回 `403`），
但 **check-runs 的 annotations 是匿名可读的**。所以两个脚本在失败时都会用
`::error::` 把关键报错发成注解，同时把完整输出写进 `build.log`（随产物上传）。
这样即使没有仓库权限，也能直接看到失败原因。

### 5.1 为什么需要一个"组装"步骤

`LineageOS/android_kernel_xiaomi_sm8450` 是**扁平的 ACK 风格内核树**，
它的 `build.config.msm.waipio` 里写的是：

```sh
. ${ROOT_DIR}/common/build.config.common
. ${ROOT_DIR}/common/build.config.aarch64
...
. ${KERNEL_DIR}/build.config.msm.common
. ${KERNEL_DIR}/build.config.msm.gki
```

也就是说它期望的目录布局是：

```
$ROOT_DIR/
├── common/                                  <- 内核树（build.config.* 都在这一层）
├── build/                                   <- AOSP kernel/build（build.sh）
├── external/dtc/                            <- dtc 源码（PRE_DEFCONFIG_CMDS 会编译它）
└── prebuilts-master/clang/host/linux-x86/clang-r416183b/
```

所以 Actions 里先按这个布局组装，再执行：

```sh
ROOT_DIR=$PWD KERNEL_DIR=$PWD/common BUILD_CONFIG=common/build.config.msm.waipio \
  VARIANT=gki LTO=thin EXT_MODULES="modules/qcom/opensource/..." ./build/build.sh
```

`scripts/assemble-lineage-kernel.sh` 负责这个组装，并在动手前**逐项自检路径是否存在**，
缺什么直接告诉你，不会让你去猜一个失败的编译日志。

### 5.2 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `lineage_branch` | `lineage-23.2` | **已按你设备实测钉死** |
| `kernel_commit` | `ef362912d37b761041709638c1e571d6394e9558` | 设备 `uname -r` 里的 `-g<sha>`，必须一致 |
| `clang_version` | `clang-r416183b` | 与内核树 `build.config.common` 一致；报 clang 错误就换 `clang-r563880` |
| `device` | `unicorn` | 只影响日志与产物命名 |
| `variant` | `gki` | 建议 `gki` |
| `resukisu_branch` | `main` | ReSukiSU 的分支/标签 |
| `resukisu_hook` | `kprobes` | 5.10 GKI 首选；备选 `tracepoint` |
| `enable_nftables` | `true` | chroot 里 Docker 用 iptables-nft 时需要 |
| `enable_susfs` | `false` | 开了还得自己打 SUSFS 内核补丁 |
| `free_disk` | `false` | 源码放 `/mnt`，默认**不需要**清理系统目录 |
| `enable_swap` | `true` | 只做内存兜底，失败不中断 |

产物：`Image`、`boot.img`、`.config`、`anykernel3-unicorn.zip`、`build.log`。

> ⚠️ 老实说：**路径与工具链我都核实过**（`build/`、`external/dtc`、clang），
> 但整个 Actions 流程我没法在这里真正跑一遍（沙箱无网络、无 45GB 磁盘）。
> 我到目前做的验证是：脚本全部 `bash -n` 通过；用**你设备真实的 `.config`**
> 当输入、配一个伪造 `make`，对 `preconfig-kernel.sh` 做了两轮端到端测试
> （正常路径 26/26 项正确；源码树被污染路径能正确回退并清理干净）。

---

## 6. 刷入：只刷 boot.img 就够（含为什么）

### 6.1 先做版本串比对（决定你要不要多刷东西）

你这台设备的目标版本串已经实测确定：**`5.10.260-gki-gef362912d37b`**。

```sh
# 设备侧（不变，用于核对）
adb shell uname -r          # 期望: 5.10.260-gki-gef362912d37b

# 构建侧：自动比对（传内核树路径让它跑 make kernelrelease）
KERNEL_TREE=<out_dir>/../common bash scripts/verify-built-config.sh <out_dir>
```

因为：

- 同分支 + **同 commit**（`ef362912d37b`）→ `CONFIG_LOCALVERSION="-gki"` +
  `LOCALVERSION_AUTO` 附带的 `-gef362912d37b` 完全相同 → vermagic 相同
- 同一棵树 + 同一套 config → `CONFIG_MODVERSIONS` 的符号 CRC 相同

⇒ ROM 里现成的 `vendor_dlkm` / `vendor_boot` 模块**能直接加载**，**只需要刷 `boot.img`**。

**如果版本串不一致**（例如分支 HEAD 已经往前走、或者你以后升级了 LineageOS）：

1. **首选**：把 `kernel_commit` 改成设备 `uname -r` 里 `-g` 后面那 12 位对应的 commit；
2. 或连自编的 `vendor_dlkm.img` 一起刷（工作流会产出），
   但 SELinux 标签与文件清单可能和 ROM 不一致，风险更高。

### 6.2 刷入方式

**方式 1（推荐）：本次改的只是内核配置，用 AK3 只替换 kernel Image**

```sh
# 备份原 boot（你的设备当前活动槽位是 _b，即 boot_b = /dev/block/sde43）
adb exec-out su -c 'dd if=/dev/block/by-name/boot_b of=/sdcard/boot_stock.img'
adb pull /sdcard/boot_stock.img

# 刷 AK3 zip（Recovery：sideload；或 TWRP 直接安装；或用内核管理器 App 刷入）
adb sideload anykernel3-unicorn.zip
```

> ⚠️ 你这台设备的 adb shell 里 **`su` 不在 PATH**（实测 `su: inaccessible or not found`），
> 所以上面带 `su -c` 的命令需要在 **ReSukiSU 管理器自带的终端**里跑，
> 或者在管理器里把 shell 的 root 权限授权一下（`/data/adb/ksu` 目录是存在的，KSU 本身已装）。

AK3 包内**只有 `Image`**，不含 `dtb` → 原机 DTB、ramdisk 保持不动。
（`vendor/unicorn_GKI.config` 只有 `MI_CHARGER_M81` / `MI_THERMAL_MULTI_CHARGE`
两个电源相关配置，与设备树无关，所以不换 DTB 是安全的。）

**方式 2：直接刷自编 `boot.img`**

```sh
fastboot flash boot out/target/product/unicorn/boot.img
```

> LineageOS 的 boot 镜像规格（来自 `BoardConfigCommon.mk`）：
> `BOARD_BOOT_HEADER_VERSION := 4`、`BOARD_RAMDISK_USE_LZ4 := true`、
> `BOARD_KERNEL_IMAGE_NAME := Image`、`BOARD_INCLUDE_DTB_IN_BOOTIMG := true`。
> 所以**别用 header v3 的假设手工拼包**，要么用 AK3（让 magiskboot 处理），
> 要么直接用构建产物 `boot.img`。

卡开机时的救砖：

```sh
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
fastboot flash boot boot_stock.img      # 回滚
```

---

## 7. 验证（重点是第 2、3 条）

```sh
# 0) 装机后先确认 KSU 与内核版本
adb shell su -c 'uname -r'
adb shell su -c 'id'          # uid=0 说明 KSU 生效

# 1) 配置是否真的生效
adb shell su -c 'zcat /proc/config.gz | grep -E "CONFIG_(CGROUP_DEVICE|CGROUP_PIDS|PID_NS|USER_NS)"'
#    期望: 四项全 =y

# 2) devices 控制器（就是模块日志报的那一项）
adb shell su -c 'cat /proc/cgroups'
#    devices 行第 4 列必须为 1   <- 修之前是 0

# 3) PID namespace（Docker 起容器硬需求）
adb shell su -c 'ls -l /proc/self/ns/pid'
adb shell su -c 'unshare -p -f --mount-proc echo OK'    # 期望输出 OK

# 4) chroot 内的 cgroup 情况
#    Ubuntu Chroot 内执行：
mount | grep cgroup
cat /sys/fs/cgroup/cgroup.controllers     # cgroup v2 里【不会】有 devices，这是正常的
#    devices 只存在于 cgroup v1。要用它需要单独挂一个 v1 层级：
mkdir -p /sys/fs/cgroup/devices
mount -t cgroup -o devices devices /sys/fs/cgroup/devices
```

一键诊断：`scripts/device-verify.sh`（push 到手机后 `sh` 跑，只读不改系统）。

### WARN 消失之后，让 dockerd 真正跑起来还要注意

1. `CONFIG_PID_NS=y`（已开）—— 这个是硬需求。
2. `/sys/fs/cgroup` 在 chroot 内必须可挂载/可写。Android 侧通常是 cgroup v2，
   在 chroot 内挂新的层级：`mount -t cgroup2 none /sys/fs/cgroup`。
3. 先让 Docker 用 `--network none` / `host` 跑通，再开 bridge。chroot 内
   `/etc/docker/daemon.json` 建议先：

   ```json
   { "iptables": false, "ip-forward": false, "bridge": "none" }
   ```

4. 检查 `/proc/cmdline` 有没有 `cgroup_disable=xxx`（有的话会禁掉对应控制器）。
5. `overlay2` 存储驱动：`CONFIG_OVERLAY_FS=y` 已满足。

---

## 8. ReSukiSU 集成（已逐行核对官方 setup.sh）

### 8.1 命令

```sh
cd kernel/xiaomi/sm8450          # 或 Actions 里的 $WS/common
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s main
```

`setup.sh` 实际只做 4 件事（**完全不碰 defconfig**）：

1. `git clone https://github.com/ReSukiSU/ReSukiSU KernelSU`
2. `ln -s ../../KernelSU/kernel drivers/kernelsu`
3. `drivers/Makefile` 追加 `obj-$(CONFIG_KSU) += kernelsu/`
4. `drivers/Kconfig` 的 `endmenu` 前插入 `source "drivers/kernelsu/Kconfig"`

⇒ **`CONFIG_KSU=y` 必须自己写进 defconfig**，否则编出来没有 KSU。
（`--cleanup` 可回滚；参数是 ReSukiSU 的分支/标签，不是内核分支。）

当前分支：`main`、`test`、`auto-hook`、`32bit-on-64bit-kernel-lkm`、`uapi/mismatch`
（没有 `susfs-*` 分支，SUSFS 走标签 + 自行打补丁）。

### 8.2 Hook 模式：纠正一处常见误解

| 模式 | 适用 | 需要的 CONFIG |
|---|---|---|
| **kprobes（GKI 默认）** | GKI 内核 | **不需要** `CONFIG_KSU_MANUAL_HOOK`；要求 `CONFIG_KPROBES=y`（本内核已是 `y`） |
| Manual hook | 非 GKI / kprobe 不可用 | `CONFIG_KSU_MANUAL_HOOK=y` |
| Tracepoint hook | 可选替代 | `CONFIG_KSU_TRACEPOINT_HOOK=y` |

**"ReSukiSU 默认是 Tracepoint" 这个说法不准确** —— GKI 的默认是 kprobes。
你先用默认（只加 `CONFIG_KSU=y`）；万一刷入后管理器显示未安装/不支持，再改
`CONFIG_KSU_TRACEPOINT_HOOK=y` 重编。**两个 hook 开关不要同时开。**

### 8.3 模块签名：不影响 KSU

你这台设备的内核实测是 **`# CONFIG_MODULE_SIG is not set`**（没有模块签名校验）。
KSU 本身也是 built-in（`=y`）不是模块，所以完全不涉及。
真正要保证的是**内核与 ROM 里现成模块的 ABI 一致** —— 靠"同分支 + 同 commit"来保证（第 6 节）。

---

## 9. 本工程文件说明

```
README.md                                  本手册
configs/docker-cgroup.fragment             Docker/cgroup/ReSukiSU 配置（带逐条注释 + 设备实测值）
reference/device-config.txt                你设备的真实内核配置（adb 从 /proc/config.gz 导出）
reference/config-changes.md                设备当前值 → 目标值 的完整变更清单
reference/build-time-evaluation.md         三台机器编译方案的时间评估（含实测条件）
reference/pc-specs.txt                     你 PC 的硬件规格（wmic 采集）
scripts/apply-configs.sh                   写入 gki_defconfig 本体（自动处理 PID_NS，幂等）
scripts/integrate-resukisu.sh              集成 ReSukiSU + 校验软链/Makefile/Kconfig
scripts/lineage-tree-build.sh              路径 A：LineageOS 树里一键打配置+集成+m bootimage
scripts/assemble-lineage-kernel.sh         路径 B：组装编译工作区（含 commit 钉住 + 路径自检）
scripts/verify-built-config.sh             编译后核对 .config 并比对 kernelrelease
scripts/pack-anykernel3.sh                 生成只换 kernel 的 AnyKernel3 包
scripts/device-verify.sh                   手机上一键验证（只读）
anykernel3/anykernel.sh                    AnyKernel3 配置（device.name1=unicorn）
.github/workflows/build-unicorn-kernel.yml GitHub Actions 构建工作流
```

---

## 10. 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `ERROR! Detected overridden config!` | 把已有配置写进了 `vendor/*_GKI.config` 碎片 | 改 `gki_defconfig` 本体 |
| `ERROR! Defconfig fragment did not apply as expected` | 最终 `.config` 与 defconfig 有"改动/删除"差异 | 同上；`CONFIG_CMDLINE` 之外不应有非新增差异 |
| `ERROR! Treating config warnings as errors` | 配置里有 Kconfig 警告（例如新开项的依赖没满足） | 看日志里带 `warning:` 的行 |
| 编出来 KSU 不生效 | 只跑了 setup.sh，没写 `CONFIG_KSU=y` | 查 `out/**/.config` 里 `CONFIG_KSU=y` |
| `drivers/kernelsu` 消失 | 之后跑过 `make mrproper` / `git clean -fdx` | 重跑 `integrate-resukisu.sh` |
| 能开机但 Wi-Fi/蓝牙/音频没了 | 内核分支/commit 与设备不一致 → vermagic 不匹配 | 把 `kernel_commit` 钉到设备 `uname -r` 里 `-g` 后面的那个 commit |
| 加了 `CONFIG_IPC_NS=y` 但 `/proc/self/ns/ipc` 还是不存在 | 没先开 `CONFIG_SYSVIPC=y`，依赖不满足被 `olddefconfig` 关掉 | 两个一起写；`verify-built-config.sh` 现在把两者都列为必需项 |
| `cat /proc/cgroups` 里没 devices | 改错了文件，或碎片被覆盖 | 确认改的是 `arch/arm64/configs/gki_defconfig` |
| adb shell 里 `su` 找不到 | ReSukiSU 的 su 未对 adb shell 暴露 | 用 KSU 管理器自带的终端跑验证命令 |
| 开机卡在 logo | DTB 不匹配 | 用 AK3 只换 Image（不要换 dtb）；不要手工拼 v3 header 包 |
| `/proc/config.gz` 不存在 | 未开 `CONFIG_IKCONFIG_PROC` | 你设备本来就开了（实测 `=y`），无需处理 |
| 刷完 `uname -r` 没变 | 刷到了非活动槽位 | 你设备活动槽是 `_b`；用 AK3 会自动处理，手工刷时确认目标分区 |
