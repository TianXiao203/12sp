# 编译方案时间评估（2026-09-30 实测）

## 三台机器的实测条件

| | 手机 chroot `192.168.0.10` | 你的 PC（Windows） | GitHub Actions |
|---|---|---|---|
| 身份 | **就是手机本体**（Ubuntu 26.04 chroot / `/dev/block/loop41`） | 本机 | ubuntu-22.04 托管 runner |
| CPU | Cortex-X2×1 + A710×3 + A510×4，2.0~3.19 GHz（`nproc`=6） | **AMD Ryzen 7 5800H，8C/16T** | 4 vCPU |
| 内存 | 11.2 GB（可用 6.6 GB）+ 4 GB swap | 13.9 GB（**仅 3.4 GB 空闲**） | 16 GB |
| 磁盘可用 | 247 GB（loop 镜像） | C:127 / D:113 / E:47 GB | ~45 GB（清盘后） |
| 工具链现状 | ❌ 无 make/gcc/clang/dtc；apt 里有 clang 21.1.6 | ❌ 无 Linux 环境（需装 WSL2） | ✅ 官方 x86_64 clang，一条命令装好 |
| 到 GitHub 的网络 | ⚠️ **DNS 通、但 `curl https://github.com` 连上后传不动数据**；清华镜像正常（apt 可用） | 同网络环境，情况相近 | ✅ **机房内网，10 GB 分钟级** |
| 温度/散热 | 待机 28 °C，满载必然降频 | 笔记本，需注意散热 | 不涉及 |

## 关键洞察：瓶颈不是 CPU，是那 10 GB 源码

内核树 `android_kernel_xiaomi_sm8450` 是完整的 5.10 历史（150 万+ commit），
浅克隆也要数 GB；加上 devicetrees / modules / clang prebuilt，总量约 8~12 GB。

- 在 **Actions** 上：这份下载发生在 GitHub 机房内网 → **2~5 分钟**
- 在**任何本地机器**上：要从 GitHub 拉 8~12 GB。实测你的网络到 github.com
  连接可以建立但数据传输卡住 → 这一步就是 **1~3 小时甚至直接失败**
  （LineageOS 的 kernel 仓库在国内镜像站没有对应镜像，换源救不了）

所以"本地编译更快"这个直觉在这里不成立。

## 三种方案的时间估算

### 方案 A：手机 chroot 本地编译 —— ❌ 不可行（不推荐）

| 阶段 | 估算 |
|---|---|
| 拉源码（8~12 GB） | **基本拉不下来**（GitHub 传输卡死） |
| 装工具链 | apt 可装 clang 21.1.6（aarch64 原生，架构正好匹配） |
| 编译 | 8 核 ARM + 持续满载降频，`-j4` 保守 → **2~6 小时** |
| 附加风险 | 内存 6.6 GB 可用，LTO 会 OOM；手机是全家人日常在用的设备，数小时满载会烫手、卡顿；而且这是你要刷内核的那台机器 |

**结论：卡在拉源码这一步。** 另外它是 ARM64，而树里声明的工具链
`prebuilts-master/clang/host/linux-x86/...` 是 x86_64 二进制，直接跑不了，
必须绕开 AOSP 的 `build/build.sh` 手写 `make`。

### 方案 B：你的 PC + WSL2 —— ⚠️ 可用，但不是最短

| 阶段 | 估算 |
|---|---|
| 装 WSL2 + Ubuntu | 10~20 分钟（`HypervisorPresent=True`，支持） |
| 拉源码（8~12 GB） | **1~3 小时，且可能失败**（同网络瓶颈） |
| 编译（5800H，`-j8`） | 40~70 分钟 |
| **合计** | **2~4 小时** |

⚠️ 内存是硬伤：总 13.9 GB 里只剩 **3.4 GB 空闲**。WSL2 默认会吃掉一半内存，
必须写 `.wslconfig` 限制（`memory=7GB`、`swap=8GB`）并把并行度降到 `-j6/-j8`，
否则会 OOM。5800H 的算力是三台里最强的，但被下载和内存拖住。

### 方案 C：推送 GitHub Actions —— ✅ **最短，选这个**

| 阶段 | 估算 |
|---|---|
| push 本工程（< 1 MB） | 秒级 |
| runner 排队 | 0~5 分钟 |
| 拉源码（机房内网，8~12 GB） | **2~5 分钟** |
| 装依赖 + 组装工作区 | 3~5 分钟 |
| 编译（4 vCPU / 16 GB，LTO=thin） | **40~70 分钟** |
| 打包 + 上传产物 | 2~3 分钟 |
| 下载 AK3 zip（~60 MB） | 1~2 分钟 |
| **合计** | **约 1 ~ 1.5 小时** |

## 结论

| 方案 | 合计耗时 | 判断 |
|---|---|---|
| A. 手机 chroot | 不可行 | ❌ 拉源码卡死 + ARM 弱 + 会让手机发烫 |
| B. PC + WSL2 | 2~4 小时 | ⚠️ 备选，内存紧张，下载是瓶颈 |
| **C. GitHub Actions** | **1~1.5 小时** | ✅ **最短，且用官方 x86_64 工具链，失败风险最低** |

**选 C。** 核心原因：`8~12 GB 源码下载在 Actions 上走机房内网，在本地走你家宽带`,
后者是实测会卡住的那一段。

### 如果你更想本地跑

那就用方案 B，但**先把源码拉到能访问 GitHub 的地方**（比如用 Actions 的
`actions/cache` 或直接 `git bundle`），再拷到 WSL 里编译。或者：
在 WSL 里用 Gitee/GitCode 上别人同步的 LineageOS 内核镜像（需要自己核对 commit 是否为
`ef362912d37b761041709638c1e571d6394e9558`，commit 不一致 = 版本串不一致 = 白刷）。

## 附：关于 clang 版本的一处修正

设备内核 banner 显示官方是用 **clang 21.0.0（r563880c）** 编译的：

```
Linux version 5.10.260-gki-gef362912d37b (root@18326dc725e2)
(Android (14054515, +pgo, +bolt, +lto, +mlgo, based on r563880c)
 clang version 21.0.0 ... LLD 21.0.0) #1 SMP PREEMPT Fri Sep 25 07:52:59 UTC 2026
```

而内核树里的 `build.config.common` 写的是 `clang-r416183b`（clang 12）。
这是因为 LineageOS 自己的构建系统用 `KERNEL_CLANG_VERSION := $(LLVM_AOSP_PREBUILTS_VERSION)`
覆盖了它（见 `vendor/lineage/config/BoardConfigKernel.mk`），
`build/build.sh` 那条路读的是树里的 `build.config.common`。

**对本方案的影响：**

- **不影响 ABI**：`CONFIG_MODVERSIONS` 的符号 CRC 由 `genksyms` 根据**源码里的类型声明**算出，
  与编译器版本无关；vermagic 也不含编译器信息。也就是说——
  就算用 r416183b 编，ROM 里现成的 vendor 模块照样能加载。
- **只影响"能不能编过"**：官方用 clang 21 编过，用 clang 12 可能撞上新的警告升级为错误的坑。
- 因此工作流加了 `clang_version` 参数（默认 `clang-r416183b`，与树里声明一致）。
  **如果编译报 clang 相关的错误，把它改成 `clang-r563880` 再跑一次。**
