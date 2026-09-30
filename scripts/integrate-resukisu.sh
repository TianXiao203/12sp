#!/usr/bin/env bash
# =============================================================================
# integrate-resukisu.sh —— 集成 ReSukiSU（不是原版 KernelSU）
#
# 用法:
#   bash scripts/integrate-resukisu.sh <kernel_root> [reSukiSU_branch] [hook_mode]
#     <kernel_root>        内核树根（kernel_platform 或 kernel_platform/msm-kernel 或 LineageOS kernel 树根）
#     reSukiSU_branch      ReSukiSU 的分支/标签/commit，默认 main
#     hook_mode            kprobes（默认，GKI 推荐） | tracepoint | manual
#
# setup.sh 真实行为（已逐行核对源码）:
#   1) git clone https://github.com/ReSukiSU/ReSukiSU  ->  ./KernelSU
#   2) ln -s ../../KernelSU/kernel  drivers/kernelsu
#   3) drivers/Makefile  追加  obj-$(CONFIG_KSU) += kernelsu/
#   4) drivers/Kconfig   在 endmenu 前插入 source "drivers/kernelsu/Kconfig"
#   **它不会修改任何 defconfig** —— CONFIG_KSU=y 必须自己写，否则编出来没有 KSU。
# =============================================================================
set -euo pipefail

ROOT="${1:-}"
KSU_BRANCH="${2:-main}"
HOOK_MODE="${3:-kprobes}"

if [ -z "$ROOT" ]; then
  echo "用法: bash $0 <kernel_root> [reSukiSU_branch] [kprobes|tracepoint|manual]" >&2
  exit 1
fi
[ -d "$ROOT" ] || { echo "[ERROR] 目录不存在: $ROOT" >&2; exit 1; }

# --- 定位真正含 drivers/ 的内核根（setup.sh 要求如此）------------------------
KROOT=""
for cand in "$ROOT/msm-kernel" "$ROOT" "$ROOT/common"; do
  if [ -d "$cand/drivers" ]; then KROOT="$cand"; break; fi
done
[ -n "$KROOT" ] || { echo "[ERROR] 在 $ROOT 下找不到含 drivers/ 的内核树" >&2; exit 1; }

echo "[+] 内核树根: $KROOT"

# --- 1) 运行 ReSukiSU 官方 setup.sh ------------------------------------------
cd "$KROOT"

if [ -d "$KROOT/KernelSU/.git" ]; then
  echo "[=] KernelSU/ 已存在，跳过 clone，直接切分支"
  ( cd KernelSU && git fetch --all --tags --prune && git checkout "$KSU_BRANCH" && git pull --ff-only || git checkout "$KSU_BRANCH" )
else
  echo "[+] 拉取 ReSukiSU 并打补丁..."
  # 官方推荐写法；参数是 ReSukiSU 的分支/标签
  curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s "$KSU_BRANCH"
fi

# --- 2) 校验集成结果 ---------------------------------------------------------
echo
echo "[i] 集成结果校验"
FAIL=0
check() {
  if eval "$2"; then echo "      [OK]  $1"; else echo "      [FAIL] $1"; FAIL=1; fi
}
check "KernelSU/ 存在"                      "[ -d '$KROOT/KernelSU' ]"
check "drivers/kernelsu 软链存在"           "[ -e '$KROOT/drivers/kernelsu' ]"
check "drivers/Makefile 含 kernelsu"        "grep -q kernelsu '$KROOT/drivers/Makefile'"
check "drivers/Kconfig 含 drivers/kernelsu/Kconfig" "grep -q 'drivers/kernelsu/Kconfig' '$KROOT/drivers/Kconfig'"

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "[ERROR] 集成不完整。常见原因："
  echo "        - 网络无法访问 raw.githubusercontent.com / github.com"
  echo "        - 之后又跑过 make mrproper / 执行过 git clean -fdx（会删掉软链）"
  echo "        可手动执行:"
  echo "          cd $KROOT && git clone https://github.com/ReSukiSU/ReSukiSU KernelSU"
  echo "          cd drivers && ln -sf ../../KernelSU/kernel kernelsu"
  echo "          printf '\\nobj-\$(CONFIG_KSU) += kernelsu/\\n' >> Makefile"
  echo "          sed -i '/endmenu/i source \"drivers/kernelsu/Kconfig\"' Kconfig"
  exit 1
fi

# --- 3) 按 hook 模式校正 defconfig 里的 KSU 相关开关 --------------------------
DEFCONFIG=""
for cand in "$KROOT/arch/arm64/configs/gki_defconfig" \
            "$ROOT/msm-kernel/arch/arm64/configs/gki_defconfig" \
            "$ROOT/arch/arm64/configs/gki_defconfig"; do
  [ -f "$cand" ] && { DEFCONFIG="$cand"; break; }
done

echo
if [ -z "$DEFCONFIG" ]; then
  echo "[!] 没找到 gki_defconfig，请自行确认 CONFIG_KSU=y 已写入正确的 defconfig"
else
  echo "[i] defconfig: $DEFCONFIG"
  # 先清掉三个 hook 开关，避免同时开启
  sed -i '/^CONFIG_KSU_MANUAL_HOOK=/d; /^# CONFIG_KSU_MANUAL_HOOK is not set$/d' "$DEFCONFIG"
  sed -i '/^CONFIG_KSU_TRACEPOINT_HOOK=/d; /^# CONFIG_KSU_TRACEPOINT_HOOK is not set$/d' "$DEFCONFIG"

  case "$HOOK_MODE" in
    kprobes)
      # GKI 默认 hook：只需要 CONFIG_KPROBES=y，不设任何 hook 开关
      echo "[+] hook=kprobes  -> 不写 KSU_MANUAL_HOOK / KSU_TRACEPOINT_HOOK（保持默认）"
      grep -q '^CONFIG_KPROBES=y' "$DEFCONFIG" \
        && echo "      [OK]  CONFIG_KPROBES=y 已存在" \
        || { echo 'CONFIG_KPROBES=y' >> "$DEFCONFIG"; echo "      [+] 已追加 CONFIG_KPROBES=y"; }
      ;;
    tracepoint)
      echo 'CONFIG_KSU_TRACEPOINT_HOOK=y' >> "$DEFCONFIG"
      echo "[+] hook=tracepoint -> 已追加 CONFIG_KSU_TRACEPOINT_HOOK=y"
      ;;
    manual)
      echo 'CONFIG_KSU_MANUAL_HOOK=y' >> "$DEFCONFIG"
      echo "[+] hook=manual -> 已追加 CONFIG_KSU_MANUAL_HOOK=y"
      echo "      [!] Manual hook 还需要把 ReSukiSU 的 hook 调用手动加进内核源码，"
      echo "          参考 https://resukisu.org/zh-Hans/guide/manual-integrate.html"
      ;;
    *)
      echo "[ERROR] 未知 hook 模式: $HOOK_MODE（可选 kprobes|tracepoint|manual）" >&2
      exit 1
      ;;
  esac

  echo
  echo "[i] KSU 相关最终状态："
  grep -E '^(# )?CONFIG_(KSU|KSU_[A-Z_]+|KPROBES)=' "$DEFCONFIG" | sed 's/^/      /' || true
fi

echo
echo "完成。下一步：编译  ./build.sh zeus"
