# 设备实测配置 → 目标配置 变更清单

数据来源：
- 设备：小米 12S Pro (unicorn)，LineageOS **23.2**（`23.2-20260925-NIGHTLY-unicorn`）
- 设备内核：`5.10.260-gki-gef362912d37b`（与 lineage-23.2 的 commit ef362912d37b 对应）
- 实测手段：`adb exec-out cat /proc/config.gz`（设备已开 `CONFIG_IKCONFIG_PROC=y`）
- 目标：`configs/docker-cgroup.fragment`（写入 gki_defconfig 本体，非碎片）

| 配置项 | 设备当前值 | 目标 | 备注 |
|---|---|---|---|
| `CONFIG_CGROUPS` | `CONFIG_CGROUPS=y` | `CONFIG_CGROUPS=y` |  |
| `CONFIG_CGROUP_DEVICE` | `# CONFIG_CGROUP_DEVICE is not set` | `CONFIG_CGROUP_DEVICE=y` | **核心修复**：devices 控制器，模块 WARN 的来源 |
| `CONFIG_CGROUP_FREEZER` | `CONFIG_CGROUP_FREEZER=y` | `CONFIG_CGROUP_FREEZER=y` |  |
| `CONFIG_CGROUP_PIDS` | `# CONFIG_CGROUP_PIDS is not set` | `CONFIG_CGROUP_PIDS=y` | pids 控制器，可选但建议 |
| `CONFIG_CGROUP_SCHED` | `CONFIG_CGROUP_SCHED=y` | `CONFIG_CGROUP_SCHED=y` |  |
| `CONFIG_CPUSETS` | `CONFIG_CPUSETS=y` | `CONFIG_CPUSETS=y` |  |
| `CONFIG_MEMCG` | `CONFIG_MEMCG=y` | `CONFIG_MEMCG=y` |  |
| `CONFIG_CGROUP_CPUACCT` | `CONFIG_CGROUP_CPUACCT=y` | `CONFIG_CGROUP_CPUACCT=y` |  |
| `CONFIG_BLK_CGROUP` | `CONFIG_BLK_CGROUP=y` | `CONFIG_BLK_CGROUP=y` |  |
| `CONFIG_NAMESPACES` | `CONFIG_NAMESPACES=y` | `CONFIG_NAMESPACES=y` |  |
| `CONFIG_NET_NS` | `CONFIG_NET_NS=y` | `CONFIG_NET_NS=y` |  |
| `CONFIG_PID_NS` | `# CONFIG_PID_NS is not set` | `CONFIG_PID_NS=y` | **核心修复**：Docker 建容器必需；base 里是注释行，必须改本体 |
| `CONFIG_UTS_NS` | `CONFIG_UTS_NS=y` | `CONFIG_UTS_NS=y` |  |
| `CONFIG_USER_NS` | `# CONFIG_USER_NS is not set` | `CONFIG_USER_NS=y` | 5.10 里 Kconfig default n |
| `CONFIG_SYSVIPC` | `# CONFIG_SYSVIPC is not set` | `CONFIG_SYSVIPC=y` | **新发现**：不先开它，IPC_NS 依赖不满足，符号行都不出现 |
| `CONFIG_IPC_NS` | `(符号行不存在)` | `CONFIG_IPC_NS=y` | **新发现**：Kconfig depends on (SYSVIPC || POSIX_MQUEUE) |
| `CONFIG_VETH` | `CONFIG_VETH=y` | `CONFIG_VETH=y` |  |
| `CONFIG_BRIDGE` | `CONFIG_BRIDGE=y` | `CONFIG_BRIDGE=y` |  |
| `CONFIG_BRIDGE_NETFILTER` | `# CONFIG_BRIDGE_NETFILTER is not set` | `CONFIG_BRIDGE_NETFILTER=y` | bridge 上的 netfilter 过滤 |
| `CONFIG_NF_TABLES` | `# CONFIG_NF_TABLES is not set` | `CONFIG_NF_TABLES=y` | nftables；Ubuntu 22.04+ 的 iptables 默认走 nft 后端 |
| `CONFIG_NF_TABLES_BRIDGE` | `(符号行不存在)` | `CONFIG_NF_TABLES_BRIDGE=y` | 依赖 NF_TABLES + BRIDGE，原本连符号都没有 |
| `CONFIG_OVERLAY_FS` | `CONFIG_OVERLAY_FS=y` | `CONFIG_OVERLAY_FS=y` |  |
| `CONFIG_SECCOMP` | `CONFIG_SECCOMP=y` | `CONFIG_SECCOMP=y` |  |
| `CONFIG_SECCOMP_FILTER` | `CONFIG_SECCOMP_FILTER=y` | `CONFIG_SECCOMP_FILTER=y` |  |
| `CONFIG_CGROUP_BPF` | `CONFIG_CGROUP_BPF=y` | `CONFIG_CGROUP_BPF=y` |  |
| `CONFIG_BPF_SYSCALL` | `CONFIG_BPF_SYSCALL=y` | `CONFIG_BPF_SYSCALL=y` |  |
| `CONFIG_KSU` | `(符号行不存在)` | `CONFIG_KSU=y` | ReSukiSU 主开关；setup.sh 不会帮你写这一行 |
| `CONFIG_KSU_TOOLKIT_SUPPORT` | `(符号行不存在)` | `CONFIG_KSU_TOOLKIT_SUPPORT=y` | ReSukiSU 可选增强 |
| `CONFIG_KSU_MULTI_MANAGER_SUPPORT` | `(符号行不存在)` | `CONFIG_KSU_MULTI_MANAGER_SUPPORT=y` | ReSukiSU 可选增强 |
| `CONFIG_IKCONFIG` | `CONFIG_IKCONFIG=y` | `CONFIG_IKCONFIG=y` | 便于用 /proc/config.gz 校验（设备本来就有） |
| `CONFIG_IKCONFIG_PROC` | `CONFIG_IKCONFIG_PROC=y` | `CONFIG_IKCONFIG_PROC=y` | 便于用 /proc/config.gz 校验（设备本来就有） |

## 说明

1. 「目标」列全部写进 `arch/arm64/configs/gki_defconfig` **本体**。
   写进 `vendor/*_GKI.config` 碎片会让 `merge_config.sh` 报
   `ERROR! Detected overridden config!`（因为 base 里已有非默认值）。
2. `CONFIG_PID_NS` 在 base 里是 `# CONFIG_PID_NS is not set`，脚本做行级替换而非追加。
3. `CONFIG_SYSVIPC` 与 `CONFIG_IPC_NS` 是本次通过设备实测才发现的缺口，原清单里没有这两项。
4. 设备 `/proc/cgroups` 实测只有 cpuset/cpu/cpuacct/blkio/memory/freezer/net_prio，
   **没有 devices、没有 pid**，与上表完全对应。
5. 设备 `/proc/self/ns/` 实测只有 cgroup/mnt/net/time/time_for_children/uts，
   **没有 pid、没有 ipc、没有 user** —— 三重印证了上面的判断。
