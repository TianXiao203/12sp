#!/usr/bin/env bash
# =============================================================================
# patch-abi-safe.sh —— 按【设备配置】决定是否打（2026-10-25 恢复启用）
#
# 什么时候要打、什么时候绝不能打，取决于设备 /proc/config.gz 里
# CONFIG_POSIX_MQUEUE 是 n 还是 y：
#
#   A) 设备 POSIX_MQUEUE=n（当前情况：LineageOS 24.0 / 5.10.269-geff4b40407a1）
#      Droidspaces 的 MUST HAVE 需要 IPC namespace，而
#        config IPC_NS depends on NAMESPACES && (SYSVIPC || POSIX_MQUEUE)
#      只能选 POSIX_MQUEUE（SYSVIPC 会给 task_struct 加 sysvsem/sysvshm，
#      那三个成员没有任何保留槽能补，开了必卡米标）。
#      而 POSIX_MQUEUE 会给 struct user_struct 加 mq_bytes，经 cred.user
#      波及 task/file/socket → 725 个导出符号 CRC 变化。
#      ⇒ 把这个成员挪进 Android GKI 早就预留的 KABI 保留槽：
#          -    ANDROID_KABI_RESERVE(2);
#          +    ANDROID_KABI_USE(2, unsigned long mq_bytes);
#        include/linux/android_kabi.h 在 __GENKSYMS__ 下
#        _ANDROID_KABI_REPLACE(_orig,_new) == _orig，所以 genksyms 读到的文本
#        仍是 `u64 android_kabi_reserved2`（与 ROM 逐字相同）→ CRC 不变；
#        编译器侧是 8 字节 union（unsigned long 与 u64 同尺寸同对齐）→
#        实际布局也没变。这不是糊弄检查，正是保留槽的设计用途。
#        该手法已在 23.2@5.10.269 上实测把 725 个失配清零。
#
#   B) 设备 POSIX_MQUEUE=y（2026-10-24 那版 23.2 nightly 就是这种）
#      官方布局里 mq_bytes 就在正常位置，ABI 基线也按它算。
#      ⇒ 绝不能打补丁，否则改字段顺序 → 725 个符号变 → 卡米标。
#      workflow 里会自动判断并做防呆检查。
#
# 最终裁判永远是 ABI 预检（abi-baseline/abi-crcs.txt，由设备全部 .ko 生成）。
#
# -----------------------------------------------------------------------------
# 历史说明（5.10.260 时代）：让「Docker 必需的配置」不再破坏 GKI ABI
#
# 背景（本次 bisect 实测结论，务必先读）：
#   LineageOS 23.2 的设备内核配置里，下面这些开关全是【关闭】的：
#       CONFIG_POSIX_MQUEUE=n   CONFIG_IPC_NS 不存在   CONFIG_USER_NS=n
#       CONFIG_CGROUP_DEVICE=n  CONFIG_CGROUP_PIDS=n   CONFIG_SYSVIPC=n
#   而 ROM 里 395 个预编译 vendor 模块的符号 CRC，就是按「全关」的局面算出来的。
#   一旦我们打开它们，被导出符号可见的结构体布局就变了 → CRC 全变 → 模块拒载
#   → 屏幕永远停在米标。bisect 实测（725 / 295 两个失配集合）：
#
#     CONFIG_POSIX_MQUEUE=y  → 725 个符号 CRC 变
#         include/linux/sched/user.h:  struct user_struct 多一个成员
#             #ifdef CONFIG_POSIX_MQUEUE
#                 unsigned long mq_bytes;
#             #endif
#         user_struct 经 cred.user 被 task/file/socket 广泛引用 → 面极大
#     CONFIG_CGROUP_DEVICE / CGROUP_PIDS =y → 295 个符号 CRC 变
#         include/linux/cgroup-defs.h:  struct css_set / struct cgroup 里的
#             ... subsys[CGROUP_SUBSYS_COUNT] / e_cset_node[CGROUP_SUBSYS_COUNT]
#         子系统数 7→9，数组定长随之变化（没有任何 KABI 手段能补数组长度）
#     CONFIG_USER_NS=y      → 0 个符号变（5.10 这棵树里它不 gate 任何结构体成员）
#     CONFIG_PID_NS=y       → 0 个符号变
#
# 本脚本处理【可以救的那一个】：
#   POSIX_MQUEUE 是 IPC_NS 的前置依赖（IPC_NS depends on SYSVIPC || POSIX_MQUEUE），
#   而 SYSVIPC 会给 task_struct 加 sysvsem/sysvshm（更致命）。所以只能走
#   POSIX_MQUEUE 这条路，把 user_struct 里那个成员挪进 Android GKI 早就预留好的
#   KABI 保留槽（android_kabi_reserved2）：
#
#       -	ANDROID_KABI_RESERVE(2);
#       +	ANDROID_KABI_USE(2, unsigned long mq_bytes);
#
#   为什么这样 ABI 安全（关键，别改成别的写法）：
#     include/linux/android_kabi.h 里
#         #ifdef __GENKSYMS__
#         #define _ANDROID_KABI_REPLACE(_orig, _new)  _orig
#         #else
#         #define _ANDROID_KABI_REPLACE(_orig, _new)  union { _new; struct { _orig; }; ...静态断言... }
#         #endif
#     ⇒ genksyms 眼里这一行仍然是 `u64 android_kabi_reserved2;`【逐字与 ROM 相同】，
#       所以 CRC 不变；
#     ⇒ 编译器眼里是个 8 字节 union（unsigned long 与 u64 同尺寸同对齐），
#       实际布局与 ROM 也完全一致。
#   这不是"糊弄检查"：布局真的没变，这正是 Android KABI 保留槽的设计用途。
#
#   而 CGROUP_DEVICE / CGROUP_PIDS 无法用同样手法救（数组长度不是保留槽能补的），
#   所以【最终交付配置里没有它们】，代价是 Docker 拿不到 devices / pids 控制器。
#
# 用法: bash scripts/patch-abi-safe.sh <kernel_root>
# =============================================================================
set -euo pipefail

ROOT="${1:?用法: patch-abi-safe.sh <kernel_root>（内核树根目录，里面应有 include/linux/sched/user.h）}"

USER_H=""
for cand in \
  "$ROOT/include/linux/sched/user.h" \
  "$ROOT/common/include/linux/sched/user.h" \
  "$ROOT/msm-kernel/include/linux/sched/user.h"
do
  if [ -f "$cand" ]; then USER_H="$cand"; break; fi
done

if [ -z "$USER_H" ]; then
  echo "[ERROR] 找不到 include/linux/sched/user.h（ROOT=$ROOT）" >&2
  exit 1
fi

echo "[+] 目标头文件: $USER_H"
cp -n "$USER_H" "$USER_H.orig" 2>/dev/null || true

# --- 0) 先看一下 KABI 保留槽是不是真的开着（否则保留槽会消失，方案不成立）------
KABI_ON=$( { grep -rhoE '^CONFIG_ANDROID_KABI_RESERVE=y' "$ROOT/arch/arm64/configs" 2>/dev/null || true; } | head -1 )
# 兜底：本项目的 .config 基座是设备真实配置，那里才是最终裁决。
if [ "$KABI_ON" != "CONFIG_ANDROID_KABI_RESERVE=y" ]; then
  for f in "${BASE_CONFIG_FILE:-}" \
           "${GITHUB_WORKSPACE:-}/reference/device-config.txt" \
           "$ROOT/../../reference/device-config.txt"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if grep -qE '^CONFIG_ANDROID_KABI_RESERVE=y' "$f"; then
      KABI_ON="CONFIG_ANDROID_KABI_RESERVE=y"
      echo "[i] CONFIG_ANDROID_KABI_RESERVE=y 来自 $f"
      break
    fi
  done
fi
if [ "$KABI_ON" != "CONFIG_ANDROID_KABI_RESERVE=y" ]; then
  echo "[ERROR] 没找到 CONFIG_ANDROID_KABI_RESERVE=y。" >&2
  echo "        该配置决定 user_struct 里那两个 8 字节保留槽是否存在。" >&2
  echo "        若它为 n，保留槽会被 ANDROID_KABI_RESERVE() 展开成空，" >&2
  echo "        本补丁就变成「凭空加一个成员」→ 反而破坏 ABI。" >&2
  echo "        拒绝继续。（请先确认 arch/arm64/configs 或 reference/device-config.txt）" >&2
  exit 1
fi

# --- 1) 幂等：已经打过补丁就直接退出 -----------------------------------------
if grep -qE '^[[:space:]]*ANDROID_KABI_USE\(2, *unsigned long +mq_bytes\);' "$USER_H"; then
  echo "[=] 补丁已存在（ANDROID_KABI_USE(2, unsigned long mq_bytes)），跳过"
else
  # --- 2) 删掉原来的 POSIX_MQUEUE 条件成员块 --------------------------------
  python3 - "$USER_H" <<'PYEOF'
import re, sys, io
p = sys.argv[1]
src = open(p, encoding='utf-8', errors='surrogateescape').read()

# 原来的写法（include/linux/sched/user.h，5.10）：
#	#ifdef CONFIG_POSIX_MQUEUE
#		/* protected by mq_lock	*/
#		unsigned long mq_bytes;	/* How many bytes can be allocated to mqueue? */
#	#endif
block = re.compile(
    r'[ \t]*#ifdef[ \t]+CONFIG_POSIX_MQUEUE\r?\n'
    r'(?:[ \t]*(?:/\*.*?\*/|//.*)?\r?\n)*?'
    r'[ \t]*unsigned long[ \t]+mq_bytes;[^\n]*\r?\n'
    r'[ \t]*#endif[^\n]*\r?\n',
    re.S)
new, n = block.subn('', src, count=1)
if n == 0:
    sys.stderr.write('[ERROR] 没匹配到 user_struct 里的 CONFIG_POSIX_MQUEUE/mq_bytes 块；'
                     '内核源码可能变了，请人工核对。\n')
    sys.exit(3)

# 把第 2 号保留槽改造成 mq_bytes
lines = new.split('\n')
hit = 0
for i, l in enumerate(lines):
    if re.match(r'^[ \t]*ANDROID_KABI_RESERVE\(2\);[ \t]*$', l):
        lines[i] = l.replace('ANDROID_KABI_RESERVE(2);',
                             'ANDROID_KABI_USE(2, unsigned long mq_bytes);')
        hit += 1
        break
if hit == 0:
    sys.stderr.write('[ERROR] 没找到 ANDROID_KABI_RESERVE(2); 这一行，无法改造保留槽。\n')
    sys.exit(4)

open(p, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(lines))
print('[+] 已删除 POSIX_MQUEUE 条件成员块，并把 ANDROID_KABI_RESERVE(2) 改造为 mq_bytes')
PYEOF
fi

# --- 3) 打印结果，便于在 CI 注解/日志里核对 -----------------------------------
echo "== 补丁后的 struct user_struct =="
awk '/^struct user_struct \{/,/^\};/' "$USER_H" | sed 's/^/    /'
echo
echo "== 确认 mq_bytes 仍然可用（ipc/mqueue.c 会引用 user->mq_bytes）=="
grep -n "mq_bytes" "$USER_H" | sed 's/^/    /' || true
echo "[OK] ABI 安全补丁应用完毕"
