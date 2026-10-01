#!/usr/bin/env bash
# =============================================================================
# preconfig-kernel.sh —— 生成合并后的 .config（绕开 build.sh 的强制校验）
#
# 为什么需要它：
#  1) 正确性：build.config.msm.waipio 只把 vendor/waipio_GKI.config 当碎片合并，
#     而 LineageOS 官方 TARGET_KERNEL_CONFIG 实际用【5 个文件】：
#         gki_defconfig + vendor/{waipio,xiaomi,unicorn}_GKI.config + vendor/debugfs.config
#     少了 xiaomi_/unicorn_ 两个，设备专属配置（MI_CHARGER_M81、MI_THERMAL_MULTI_CHARGE）
#     就丢了，刷上去可能起不来。
#  2) 稳定性：build.sh 内部的 merge_defconfig_fragments 有两处快速 exit 1：
#        "ERROR! Detected overridden config!"        （碎片覆盖了 base 里的非默认值）
#        "ERROR! Treating config warnings as errors" （kconfig 有 warning）
#  3) LTO：默认保持官方/设备的 FULL LTO（append 一个“最后的碎片”显式钉住），
#     与设备上唯一"能启动"的那个内核一致。若 runner 内存不足导致 LTO 链接
#     被 OOM 杀掉，可用第 3 个参数（或 LTO_MODE 环境变量）传 thin 兜底。
#     注意：绝不能像以前那样用 `scripts/config -e THINLTO` —— 本内核树里
#     【没有 CONFIG_THINLTO 这个符号】，只有 LTO_CLANG_THIN / LTO_CLANG_FULL，
#     未知符号会让 scripts/config 退出非零，配合 set -e 直接让整步失败。
#
# 诊断说明：
#   Actions 的 job log 接口需要仓库 admin 权限（匿名调用是 403），
#   但 check-runs 的 annotations 是匿名可读的。
#   所以本脚本失败时会用 `::error::` 把关键输出发成注解，便于远程定位。
#
# 用法:
#   bash scripts/preconfig-kernel.sh <workspace> [out_dir]
#     默认 out_dir = <workspace>/out/common
# =============================================================================

# 刻意不用 `set -e`：每个关键步骤显式判错，失败时打印上下文并发出注解。
set -uo pipefail

WS="${1:-}"
OUT="${2:-}"
# 第 3 个参数（或环境变量 LTO_MODE）: full | thin，默认 full（与设备上能启动的内核一致）
LTO_MODE="${3:-${LTO_MODE:-full}}"
case "$LTO_MODE" in
  full|thin) ;;
  *) echo "[preconfig] LTO_MODE 只能是 full 或 thin（收到 '$LTO_MODE'）" >&2; exit 2 ;;
esac

say()  { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }

if [ -z "$WS" ] || [ ! -d "$WS" ]; then
  echo "用法: bash $0 <workspace> [out_dir]" >&2
  exit 2
fi
K="$WS/common"
LOG="${PRECONFIG_LOG:-${GITHUB_WORKSPACE:-$PWD}/preconfig.log}"
: > "$LOG"

# ---- 失败处理：打印上下文 + 发出可匿名读取的 ::error:: 注解 -----------------
fail() {
  local msg="$*"
  say ""
  say "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  say "PRE-CONFIG 失败: $msg"
  say "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  say ""
  say "----- 目录状态：$K/arch/arm64/configs/ -----"
  ls -la "$K/arch/arm64/configs/" 2>&1 | head -25
  say ""
  say "----- 目录状态：$K/arch/arm64/configs/vendor/ -----"
  ls -la "$K/arch/arm64/configs/vendor/" 2>&1 | head -40
  say ""
  say "----- 合并/配置 输出（末 40 行）-----"
  tail -n 40 "$LOG" 2>&1
  say ""
  say "----- 合并/配置 输出（前 25 行）-----"
  head -n 25 "$LOG" 2>&1
  say ""

  # 注解：每条输出一行，GitHub 会把它们挂在 run 页面/API 上
  printf '::error title=preconfig failed::%s\n' "$msg"
  tail -n 15 "$LOG" 2>/dev/null | while IFS= read -r l; do
    [ -n "$l" ] && printf '::error::%s\n' "$l"
  done
  exit 1
}

# ---- 清掉源码树里的构建产物 ------------------------------------------------
# 内核顶层 Makefile（5.10，outputmakefile 目标）在 O=（out-of-tree）构建时会检查：
#     [ -f $(srctree)/.config -o -d $(srctree)/include/config \
#       -o -d $(srctree)/arch/$(SRCARCH)/include/generated ]  -> 报错
#     "*** The source tree is not clean, please run 'make mrproper'"
# 而 `KCONFIG_CONFIG ?= .config` 是相对路径，配合 O= 时很容易把东西写进源码树，
# 所以这里按上面这三项精确清理，保证后续 `make O=... Image` 不会因此直接失败。
cleanup_in_tree() {
  local bak="$K/.preconfig-bak" moved=0 p
  for p in .config include/config arch/arm64/include/generated; do
    if [ -e "$K/$p" ]; then
      mkdir -p "$bak"
      mv -f "$K/$p" "$bak/$(printf '%s' "$p" | tr '/' '_')" 2>/dev/null && moved=1
    fi
  done
  [ "$moved" -eq 1 ] && say "[i] 源码树里的构建产物已移到 $bak（否则 O= 构建会报 source tree is not clean）"
  return 0
}

# 运行并把输出同时写到 stdout 和 $LOG；返回真实退出码（不受管道影响）
run() {
  say "+ $*"
  "$@" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

step "0. 环境自检"
say "WS   = $WS"
say "K    = $K"
say "LOG  = $LOG"
say "bash = $(bash --version | head -1)"
say "make = $(make --version 2>/dev/null | head -1 || echo '(无 make！)')"
say "nproc= $(nproc 2>/dev/null || echo '?')"
df -h "$WS" 2>/dev/null | tail -2 || true

[ -f "$K/arch/arm64/configs/gki_defconfig" ] || fail "找不到 $K/arch/arm64/configs/gki_defconfig"
[ -x "$K/scripts/kconfig/merge_config.sh" ] || [ -f "$K/scripts/kconfig/merge_config.sh" ] || \
  fail "找不到 $K/scripts/kconfig/merge_config.sh"
command -v make >/dev/null 2>&1 || fail "系统里没有 make"

# ---- 1) OUT 目录 ------------------------------------------------------------
[ -z "$OUT" ] && OUT="$WS/out/common"
mkdir -p "$OUT" || fail "无法创建 $OUT"
say "OUT  = $OUT"

# 源码树里若残留 in-tree 构建产物，O= 构建会直接报 "source tree is not clean"
cleanup_in_tree

# ---- 2) 放 clang 到 PATH（决定 Kconfig 里 HAS_LTO_CLANG 等能否成立）---------
step "1. 准备交叉工具链"
CLANG_BIN=""
for d in "$WS"/prebuilts-master/clang/host/linux-x86/*/bin; do
  [ -x "$d/clang" ] && { CLANG_BIN="$d"; break; }
done
if [ -n "$CLANG_BIN" ]; then
  export PATH="$CLANG_BIN:$PATH"
  say "[+] clang: $CLANG_BIN"
  "$CLANG_BIN/clang" --version 2>&1 | head -2
else
  say "[WARN] 没找到 clang prebuilt —— Kconfig 里依赖 CC_IS_CLANG 的符号"
  say "       （HAS_LTO_CLANG / LTO_CLANG_THIN / CFI_CLANG 等）会算不准。"
fi

# ---- 3) 生成 thin-LTO 覆盖碎片（放在最后一个，覆盖 gki_defconfig 的 FULL）---
step "2. 生成 thin-LTO 覆盖碎片"
# LTO 模式：默认跟官方一致用 FULL。
#   实测依据：设备上"能启动"的那个内核（第三方 ReSukiSU 包）是
#   CONFIG_LTO_CLANG_FULL=y，而我们之前为了省内存改成了 THIN —— 刷进去会卡米标，
#   所以现在默认回退到 FULL，与已知能启动的构建一模一样。
#   如果 runner 内存不够导致 LTO 链接被 OOM 杀掉，可以用 --lto=thin 换回来
#   （代价是与官方不一致，可能有问题）。
LTOFRAG_REL="arch/arm64/configs/vendor/zz-lto.config"
if [ "$LTO_MODE" = "thin" ]; then
  LTO_BODY='CONFIG_LTO=y
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y
# CONFIG_LTO_CLANG_FULL is not set
# CONFIG_LTO_NONE is not set'
  say "[i] LTO 模式 = THIN（与官方不同，仅用于内存不足时兜底）"
else
  LTO_BODY='CONFIG_LTO=y
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_FULL=y
# CONFIG_LTO_CLANG_THIN is not set
# CONFIG_LTO_NONE is not set'
  say "[i] LTO 模式 = FULL（与设备上能启动的内核一致）"
fi
{
  echo "# 由 scripts/preconfig-kernel.sh 生成（LTO_MODE=$LTO_MODE）。"
  echo "# 本内核树里只有 LTO_CLANG_THIN / LTO_CLANG_FULL 两个 choice 成员，"
  echo "# 并【没有】名为 THINLTO 的符号（用 scripts/config -e THINLTO 会直接失败）。"
  printf '%s\n' "$LTO_BODY"
} > "$K/$LTOFRAG_REL"
say "[+] $K/$LTOFRAG_REL"
sed 's/^/    /' "$K/$LTOFRAG_REL"

# ---- 4) 收集碎片（缺哪个就跳过哪个，并明确报出来）--------------------------
step "3. 收集 defconfig 碎片"
FRAGS=""
for f in vendor/waipio_GKI.config vendor/xiaomi_GKI.config \
         "vendor/unicorn_GKI.config" vendor/debugfs.config; do
  if [ -f "$K/arch/arm64/configs/$f" ]; then
    FRAGS="$FRAGS arch/arm64/configs/$f"
    say "  [OK]   arch/arm64/configs/$f"
  else
    say "  [WARN] 不存在，跳过: arch/arm64/configs/$f"
  fi
done
FRAGS="$FRAGS $LTOFRAG_REL"
say "碎片列表: $FRAGS"

# ---- 5) 合并 ---------------------------------------------------------------
step "4. merge_config.sh（-m 只合并 / -r 提示冗余 / -y builtin 优先）"
MERGED_REL="arch/arm64/configs/vendor/zz-merged-unicorn_defconfig"
: > "$K/$MERGED_REL"
( cd "$K" && KCONFIG_CONFIG="$MERGED_REL" ./scripts/kconfig/merge_config.sh -m -r -y \
      arch/arm64/configs/gki_defconfig $FRAGS ) 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || fail "merge_config.sh 退出码 $rc"
[ -s "$K/$MERGED_REL" ] || fail "merge_config.sh 没有产出 $MERGED_REL"
say "[+] 合并结果: $K/$MERGED_REL  ($(grep -c '^CONFIG_' "$K/$MERGED_REL") 行 CONFIG_)"

# ---- 6) 放到 O= 目录并跑 olddefconfig --------------------------------------
step "5. 生成 .config（在 O=$OUT）"
OUT_ABS="$(cd "$OUT" && pwd)"
say "OUT_ABS=$OUT_ABS"

MAKE_COMMON=(O="$OUT_ABS" ARCH=arm64 LLVM=1 LLVM_IAS=1)
MAKE_TOOLS=(CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \
            OBJDUMP=llvm-objdump READELF=llvm-readelf STRIP=llvm-strip \
            HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld)
if [ -z "$CLANG_BIN" ]; then
  MAKE_COMMON=(O="$OUT_ABS" ARCH=arm64)   # 没 clang 就别指定，否则 make 立刻报错
  MAKE_TOOLS=()
fi

# 路线 A（首选）：直接以 defconfig 为目标。
#   这正是 LineageOS kernel.mk / AOSP build.sh 的写法
#   （它们传的就是 "vendor/xxx_defconfig" 这种带斜杠的目标）。
#   同时把 KCONFIG_CONFIG 导出为【绝对路径】，彻底消掉
#   "make O= 时 .config 到底算 $K/.config 还是 $OUT/.config" 的歧义。
DEFCONFIG_TARGET="${MERGED_REL#arch/arm64/configs/}"
export KCONFIG_CONFIG="$OUT_ABS/.config"
say "[A] KCONFIG_CONFIG=$KCONFIG_CONFIG"
say "[A] make ${MAKE_COMMON[*]} $DEFCONFIG_TARGET"
cp -f "$K/$MERGED_REL" "$OUT_ABS/.config"
( cd "$K" && make "${MAKE_COMMON[@]}" "${MAKE_TOOLS[@]}" "$DEFCONFIG_TARGET" ) >> "$LOG" 2>&1
rc=$?

if [ "$rc" -ne 0 ] || [ ! -s "$OUT_ABS/.config" ] || [ -f "$K/.config" ]; then
  say "[WARN] 路线 A 未真正生效（rc=$rc, \$OUT/.config $([ -s "$OUT_ABS/.config" ] && echo 存在 || echo 缺失), \$K/.config $([ -f "$K/.config" ] && echo 出现 || echo 无)）"
  say "[B] 改走兜底：手放 merged defconfig + make olddefconfig"
  cp -f "$K/$MERGED_REL" "$OUT_ABS/.config"
  ( cd "$K" && make "${MAKE_COMMON[@]}" "${MAKE_TOOLS[@]}" olddefconfig ) >> "$LOG" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    say "[B2] 去掉工具链变量再试一次"
    ( cd "$K" && make O="$OUT_ABS" ARCH=arm64 olddefconfig ) >> "$LOG" 2>&1
    rc=$?
  fi
fi

# 兜底：万一 make 把 .config 写到了源码树里，搬回输出目录
if [ ! -s "$OUT_ABS/.config" ] && [ -f "$K/.config" ]; then
  say "[WARN] .config 落在源码树里了，搬到 $OUT_ABS/"
  mv -f "$K/.config" "$OUT_ABS/.config"
fi

# 无论如何都把源码树清干净：否则下一步 `make O=... Image` 会直接报
# "*** The source tree is not clean, please run 'make mrproper'"
cleanup_in_tree

if [ "$rc" -ne 0 ]; then
  fail "生成 .config 失败（最后一次 make 退出码 $rc）"
fi
[ -s "$OUT_ABS/.config" ] || fail "$OUT_ABS/.config 不存在或为空"

say "[+] .config 行数: $(wc -l < "$OUT_ABS/.config")"

# 生成 include/config/*（Image 构建会重跑，这里先做一次让后面的校验更准）
( cd "$K" && make "${MAKE_COMMON[@]}" "${MAKE_TOOLS[@]}" syncconfig ) >> "$LOG" 2>&1 \
  || say "[WARN] syncconfig 非零退出（可忽略，编译时会重跑）"
cleanup_in_tree

# ---- 7) 自检 ---------------------------------------------------------------
step "6. 关键项自检（$OUT_ABS/.config）"
FAIL=0
for k in CGROUP_DEVICE CGROUP_PIDS CGROUP_FREEZER CGROUP_SCHED CPUSETS MEMCG BLK_CGROUP \
         PID_NS USER_NS POSIX_MQUEUE IPC_NS NET_NS UTS_NS \
         VETH BRIDGE OVERLAY_FS SECCOMP SECCOMP_FILTER CGROUP_BPF BPF_SYSCALL \
         KSU LTO_CLANG_THIN LTO_CLANG_FULL LOCALVERSION IKCONFIG IKCONFIG_PROC \
         NF_TABLES NF_TABLES_BRIDGE BRIDGE_NETFILTER SYSVIPC; do
  # tail -1：defconfig 风格的输入里同一符号可能既有 "# ... is not set" 又有 "=y"，
  #          按 kconfig 的规则【后出现的胜出】，所以取最后一行才反映真实取值。
  line=$(grep -E "^CONFIG_${k}=|^# CONFIG_${k} is not set" "$OUT_ABS/.config" | tail -1)
  printf '  %-24s %s\n' "CONFIG_$k" "${line:-<符号行不存在>}"
done
for k in CGROUP_DEVICE CGROUP_PIDS PID_NS USER_NS POSIX_MQUEUE IPC_NS KSU; do
  grep -q "^CONFIG_${k}=y$" "$OUT_ABS/.config" || { say "  [FAIL] CONFIG_$k 不是 y"; FAIL=$((FAIL+1)); }
done
# ★ ABI 铁律：这几项必须【不是 y】——
#   NF_TABLES 会给 struct net 加成员、SYSVIPC 会给 struct task_struct 加成员，
#   一旦开启，所有相关导出符号的 CRC 都会变，ROM 里预编译的 vendor 模块
#   全部拒载 → 屏幕永远停在米标（无 panic、无日志）。详见 fragment 开头。
for k in NF_TABLES NF_TABLES_BRIDGE SYSVIPC; do
  if grep -q "^CONFIG_${k}=y$" "$OUT_ABS/.config"; then
    say "  [FAIL] CONFIG_$k=y —— 这是 ABI 危险项，会让 ROM 的 vendor 模块拒载（卡米标）"
    FAIL=$((FAIL+1))
  fi
done
WANT_LTO=$([ "$LTO_MODE" = "thin" ] && echo LTO_CLANG_THIN || echo LTO_CLANG_FULL)
if ! grep -q "^CONFIG_${WANT_LTO}=y$" "$OUT_ABS/.config"; then
  say "  [FAIL] LTO 不是 $WANT_LTO（期望 LTO_MODE=$LTO_MODE）"
  FAIL=$((FAIL+1))
else
  say "  [OK]   LTO = $WANT_LTO（LTO_MODE=$LTO_MODE）"
fi
say "  ------------------------------"
say "  自检失败项: $FAIL"
grep -E '^CONFIG_(LOCALVERSION|LOCALVERSION_AUTO|MODVERSIONS|MODULE_SIG)=' "$OUT_ABS/.config" \
  | sed 's/^/  /' || true
[ "$FAIL" -eq 0 ] || fail "有 $FAIL 个关键项没生效（.config 生成不对，先别编译）"

say ""
say "[OK] preconfig 完成，.config 位于 $OUT_ABS/.config"
say "     用时参考：这一步只做 kconfig，正常几秒到十几秒。"
exit 0
