#!/usr/bin/env bash
# =============================================================================
# assemble-lineage-kernel.sh
#   为「小米 12S Pro (unicorn) + LineageOS」组装一个可独立编译的 5.10 GKI 内核工作区。
#
# 用法:
#   bash scripts/assemble-lineage-kernel.sh [workspace] [branch] [commit] [clang_version]
#     默认 workspace      = ./kp
#     默认 branch         = lineage-23.2
#     默认 commit         = ef362912d37b761041709638c1e571d6394e9558
#        （实测设备 uname -r = 5.10.260-gki-gef362912d37b，
#          因为 CONFIG_LOCALVERSION_AUTO=y，版本串尾部带内核树的 git sha。
#          只有钉住同一个 commit，编出来的 vermagic 才与设备一致，
#          ROM 里现成的 vendor 模块才能加载。）
#     默认 clang_version  = clang-r416183b（与内核树 build.config.common 一致）
#        注意：设备内核 banner 显示官方其实是用 clang 21.0.0 (r563880c) 编的，
#        clang 版本不影响 ABI（CRC 由 genksyms 从源码声明算，与编译器无关），
#        只影响"能不能编过"。若报 clang 相关错误，传 clang-r563880 再试。
#
# 为什么要组装：
#   LineageOS/android_kernel_xiaomi_sm8450 是扁平 ACK 风格内核树，它的
#   build.config.msm.waipio 里写的是：
#       . ${ROOT_DIR}/common/build.config.common
#       . ${KERNEL_DIR}/build.config.msm.common
#   所以它期望的布局就是下面这样（ROOT_DIR 是内核树的上一层）：
#
#   $WS/
#   ├── common/                 内核树（build.config.* 就在这一层）
#   ├── build/                  AOSP kernel/build（build.sh）
#   ├── external/dtc/           dtc 源码（PRE_DEFCONFIG_CMDS 会现场编译它）
#   ├── prebuilts-master/clang/host/linux-x86/clang-r416183b/
#   ├── modules/                sm8450-modules（techpack 外部模块）
#   └── devicetrees/            sm8450-devicetrees（DTB）
#
# 脚本会逐项自检，缺什么直接报出来。
# =============================================================================
set -uo pipefail

WS="${1:-$PWD/kp}"
BRANCH="${2:-lineage-23.2}"
COMMIT="${3:-ef362912d37b761041709638c1e571d6394e9558}"
CLANG_VER="${4:-clang-r416183b}"

CLANG_DIR="$WS/prebuilts-master/clang/host/linux-x86/$CLANG_VER"

log()  { echo "[assemble] $*"; }
warn() { echo "[assemble][WARN] $*"; }

mkdir -p "$WS"
cd "$WS"

# ---------------------------------------------------------------------------
# 1) 内核主树 -> $WS/common
# ---------------------------------------------------------------------------
clone_repo() {
  # $1=url $2=dest $3=branch(可空) $4=浅克隆(--depth=1 或空)
  local url="$1" dest="$2" br="${3:-}" opt="${4:-}"
  if [ -d "$dest/.git" ]; then
    log "已存在，跳过: $dest"
    return 0
  fi
  log "clone $url -> $dest (branch=${br:-default})"
  if [ -n "$br" ]; then
    git clone $opt --branch "$br" "$url" "$dest"
  else
    git clone $opt "$url" "$dest"
  fi
}

clone_repo "https://github.com/LineageOS/android_kernel_xiaomi_sm8450" \
           "$WS/common" "$BRANCH" "--depth=1" || {
  echo "[assemble][ERROR] 内核树 clone 失败（分支 $BRANCH 可能不存在）"
  echo "          可用分支: lineage-23.2 / lineage-23.1 / lineage-23.0 / lineage-22.2"
  exit 1
}

# 钉住 commit：CONFIG_LOCALVERSION_AUTO=y，版本串尾部带 -g<sha>，
# 必须与设备内核同 commit 才能保证 vermagic 一致（模块才能加载）。
if [ -n "$COMMIT" ]; then
  echo "[assemble] 钉住内核树 commit: $COMMIT"
  ( cd "$WS/common" && git fetch -q --depth=1 origin "$COMMIT" 2>/dev/null ) || true
  # -f：缓存恢复出来的树可能已被 assemble 自己 sed 过 build.config.common，
  #     强行 checkout 保证源码树与目标 commit 完全一致（defconfig 的改动在 assemble 之后才做）。
  if ( cd "$WS/common" && git checkout -f -q "$COMMIT" 2>/dev/null ); then
    SHA="$(cd "$WS/common" && git rev-parse HEAD)"
    echo "[assemble] 当前 HEAD = $SHA"
    case "$SHA" in
      "$COMMIT"*) echo "[assemble][OK] commit 与设备一致" ;;
      *) warn "HEAD 与目标 commit 不一致，版本串可能对不上" ;;
    esac
  else
    warn "checkout $COMMIT 失败（浅克隆可能不含该对象），将继续使用分支 HEAD"
    warn "若构建出来的 uname -r 不是 5.10.260-gki-gef362912d37b，请改用完整 clone 后重试"
  fi
fi

# ---------------------------------------------------------------------------
# 1b) 冻结 scm 版本串 -> $WS/common/.scmversion
#
# 为什么必须做：
#   scripts/setlocalversion 第 110~121 行会在【工作树有未提交改动】时追加 -dirty。
#   而我们要改 gki_defconfig、drivers/Makefile、drivers/Kconfig 并加 KSU 源码，
#   所以不加处理的话编出来会是：
#       5.10.260-gki-gef362912d37b-dirty      （设备实际是 ...-gef362912d37b）
#   vermagic 不一致 -> ROM 里现成的 vendor_dlkm / vendor_boot 模块【全部加载失败】
#   -> 能开机但 Wi-Fi / 蓝牙 / 音频 / 相机废掉。
#
#   同一个脚本第 56~59 行：
#       if test -e .scmversion; then cat .scmversion; return; fi
#   —— 只要存在 .scmversion，就直接返回它的内容，后面的 -dirty 判断根本不会执行。
#   所以这里在【刚 checkout、树还干净】时冻结成 -g<12 位 sha>，
#   得到的完整版本串就是 5.10.260 + "-gki"(CONFIG_LOCALVERSION) + "-g<sha>"
#   = 5.10.260-gki-gef362912d37b，与设备完全一致。
#
#   另外 sha 取前 12 位：setlocalversion 自己也是这么截的（第 100 行 cut -c1-12），
#   这样不受 git 版本 / core.abbrev 设置 / 仓库对象数量影响。
# ---------------------------------------------------------------------------
SCM_FILE="$WS/common/.scmversion"
SHORT_SHA="$(cd "$WS/common" && git rev-parse HEAD 2>/dev/null | cut -c1-12)"
if [ -n "$SHORT_SHA" ]; then
  printf '%s' "-g$SHORT_SHA" > "$SCM_FILE"
  echo "[assemble][OK] 已冻结 scm 版本串: $(cat "$SCM_FILE")  ->  $SCM_FILE"
else
  warn "取不到 HEAD sha，未能写 .scmversion（版本串可能带 -dirty，会导致 vendor 模块加载失败）"
fi

# ---------------------------------------------------------------------------
# 2) 工具链 / 构建脚本 / dtc
# ---------------------------------------------------------------------------
echo "[assemble] clang 版本: $CLANG_VER"

if [ ! -x "$CLANG_DIR/bin/clang" ]; then
  clone_repo "https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_$CLANG_VER" \
             "$CLANG_DIR" "" "--depth=1" || true
fi

# 回退：从 AOSP googlesource 直接取该版本目录的 tar.gz（LineageOS 没有对应仓库时用）
if [ ! -x "$CLANG_DIR/bin/clang" ]; then
  warn "LineageOS 侧没有 $CLANG_VER 仓库，改从 android.googlesource.com 取目录归档"
  mkdir -p "$CLANG_DIR"
  URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/$CLANG_VER.tar.gz"
  if curl -fL --retry 3 -m 1800 "$URL" | tar xz -C "$CLANG_DIR" 2>/dev/null; then
    echo "[assemble] tar 方式获取 clang 成功"
  else
    warn "clang 获取失败。可用的 LineageOS clang 仓库（已确认存在）:"
    warn "  https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b"
    warn "  或改用 clang_version=clang-r563880（设备内核实际使用的版本）"
  fi
fi

# 把内核树里写死的 CLANG_PREBUILT_BIN 改成实际使用的版本
BCC="$WS/common/build.config.common"
if [ -f "$BCC" ] && [ -x "$CLANG_DIR/bin/clang" ]; then
  if grep -q '^CLANG_PREBUILT_BIN=' "$BCC"; then
    sed -i "s|^CLANG_PREBUILT_BIN=.*|CLANG_PREBUILT_BIN=prebuilts-master/clang/host/linux-x86/${CLANG_VER}/bin|" "$BCC"
    echo "[assemble] 已把 build.config.common 的 CLANG_PREBUILT_BIN 指向 $CLANG_VER"
    grep -n '^CLANG_PREBUILT_BIN=' "$BCC"
  fi
fi

if [ ! -f "$WS/build/build.sh" ]; then
  rm -rf "$WS/build"
  log "获取 build/（需要 build/build.sh）"
  # 源顺序：GitHub 镜像优先（内容已核实含 build.sh / build-tools / android / envsetup.sh），
  # googlesource 放后面（在 GitHub runner 上通常可达，但优先级低一些）。
  try_build_src() {
    local url="$1" br="${2:-}"
    log "尝试: $url ${br:+(-b $br)}"
    if [ -n "$br" ]; then
      git clone --depth=1 -b "$br" "$url" "$WS/build" 2>/dev/null
    else
      git clone --depth=1 "$url" "$WS/build" 2>/dev/null
    fi
    [ -f "$WS/build/build.sh" ]
  }

  MIRROR="https://github.com/xiaomi-sm8450-kernel/android_kernel_platform_build"
  if try_build_src "$MIRROR" "zeus-s-oss"; then
    echo "[assemble][OK] build/ 来自 GitHub 镜像 (zeus-s-oss)"
  else
    rm -rf "$WS/build"
    if try_build_src "$MIRROR"; then
      echo "[assemble][OK] build/ 来自 GitHub 镜像 (默认分支)"
    else
      rm -rf "$WS/build"
      if try_build_src "$MIRROR" "kernel.lnx.5.10.r1-rel"; then
        echo "[assemble][OK] build/ 来自 GitHub 镜像 (kernel.lnx.5.10.r1-rel)"
      else
        rm -rf "$WS/build"
        if try_build_src "https://android.googlesource.com/kernel/build" "main"; then
          echo "[assemble][OK] build/ 来自 AOSP googlesource"
        else
          rm -rf "$WS/build"
        fi
      fi
    fi
  fi

  if [ -f "$WS/build/build.sh" ]; then
    echo "[assemble][OK] build/build.sh 就绪"
  else
    warn "build/ 获取失败 —— 编译需要一个提供 build/build.sh 的仓库，请检查网络或换源"
  fi
fi

if [ ! -d "$WS/external/dtc" ]; then
  log "获取 external/dtc ..."
  git clone --depth=1 https://android.googlesource.com/platform/external/dtc "$WS/external/dtc" 2>/dev/null \
    || git clone --depth=1 https://git.codelinaro.org/clo/la/kernel_platform/external/dtc "$WS/external/dtc" 2>/dev/null \
    || true
  if [ ! -f "$WS/external/dtc/Makefile" ]; then
    warn "external/dtc 拉取失败，改用系统 dtc 打桩（依赖 apt 的 device-tree-compiler）"
    rm -rf "$WS/external/dtc"
    mkdir -p "$WS/external/dtc"
    cat > "$WS/external/dtc/Makefile" <<'EOF'
# 打桩 Makefile：把系统 dtc 安装到 PREFIX/bin，满足 build.config.msm.common 的
# compile_external_dtc()（它会执行 make all install PREFIX=${COMMON_OUT_DIR}/host）
all:
	@command -v dtc >/dev/null 2>&1 || { echo "需要 dtc，请 apt install device-tree-compiler"; exit 1; }
install: all
	@mkdir -p $(PREFIX)/bin
	@cp -f "$$(command -v dtc)" $(PREFIX)/bin/dtc
	@echo "installed stub dtc -> $(PREFIX)/bin/dtc"
EOF
    echo "[assemble] 已写入 dtc 打桩 Makefile"
  fi
fi

# ---------------------------------------------------------------------------
# 3) 外部模块（techpack）与 DTB（可选，只编 Image 时非必需）
# ---------------------------------------------------------------------------
clone_repo "https://github.com/LineageOS/android_kernel_xiaomi_sm8450-modules" \
           "$WS/modules" "$BRANCH" "--depth=1" || warn "modules clone 失败（只编 Image 时影响不大）"

clone_repo "https://github.com/LineageOS/android_kernel_xiaomi_sm8450-devicetrees" \
           "$WS/devicetrees" "$BRANCH" "--depth=1" || warn "devicetrees clone 失败（AK3 方案不需要自编 DTB）"

# 尽力把 DTS 接进内核树，让 `make dtbs` 能过
DTS_DIR="$WS/common/arch/arm64/boot/dts/vendor"
if [ -d "$WS/devicetrees" ] && [ ! -e "$DTS_DIR/qcom" ]; then
  CAND=""
  for c in "$WS/devicetrees/qcom" "$WS/devicetrees/arch/arm64/boot/dts/vendor/qcom" \
           "$WS/devicetrees/vendor/qcom" "$WS/devicetrees"; do
    [ -d "$c" ] && { CAND="$c"; break; }
  done
  if [ -n "$CAND" ]; then
    mkdir -p "$DTS_DIR"
    ln -sfn "$CAND" "$DTS_DIR/qcom"
    log "已把 DTS 接入内核树: $DTS_DIR/qcom -> $CAND"
  else
    warn "在 devicetrees 里没找到 qcom DTS 目录，make dtbs 可能失败"
  fi
fi

# ---------------------------------------------------------------------------
# 4) 生成环境文件（供 workflow / 本地使用）
# ---------------------------------------------------------------------------
cat > "$WS/build.env" <<EOF
export ROOT_DIR="$WS"
# KERNEL_DIR 必须是【相对】ROOT_DIR 的路径！
# build.sh 内部会做 cd \${ROOT_DIR}/\${KERNEL_DIR}，
# 若传绝对路径会拼成 \$WS//home/... 而失败。
# 默认值就是 "common"，正好对应我们的布局（内核树放在 \$WS/common）。
export KERNEL_DIR="common"
export BUILD_CONFIG="common/build.config.msm.waipio"
export VARIANT="gki"
export LTO="thin"
export OUT_DIR="$WS/out"
export EXT_MODULES="modules/qcom/opensource/mmrm-driver modules/qcom/opensource/audio-kernel modules/qcom/opensource/camera-kernel modules/qcom/opensource/cvp-kernel modules/qcom/opensource/dataipa/drivers/platform/msm modules/qcom/opensource/datarmnet/core modules/qcom/opensource/datarmnet-ext/aps modules/qcom/opensource/datarmnet-ext/offload modules/qcom/opensource/datarmnet-ext/shs modules/qcom/opensource/datarmnet-ext/perf modules/qcom/opensource/datarmnet-ext/perf_tether modules/qcom/opensource/datarmnet-ext/sch modules/qcom/opensource/datarmnet-ext/wlan modules/qcom/opensource/display-drivers/msm modules/qcom/opensource/eva-kernel modules/qcom/opensource/video-driver modules/qcom/opensource/wlan/qcacld-3.0/.qca6490 modules/qcom/opensource/wlan/qcacld-3.0/.qca6750"
EOF
log "已写出 $WS/build.env"

# ---------------------------------------------------------------------------
# 5) 路径自检
# ---------------------------------------------------------------------------
echo
echo "================= 组装结果自检 ================="
FAIL=0
chk() {
  if [ -e "$2" ]; then printf '  [OK]   %-46s %s\n' "$1" "$2"
  else printf '  [MISS] %-46s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); fi
}
chk "内核树"              "$WS/common/Makefile"
chk "gki_defconfig"       "$WS/common/arch/arm64/configs/gki_defconfig"
chk "drivers/（KSU 集成点）" "$WS/common/drivers"
chk "clang"               "$CLANG_DIR/bin/clang"
chk "主要碎片 waipio_GKI.config" "$WS/common/arch/arm64/configs/vendor/waipio_GKI.config"

# build/ 与 external/dtc 现在只用于"备选"构建方式（默认走 directly make Image，不需要它们），
# 所以缺失只告警、不阻断。
for extra in "$WS/build/build.sh" "$WS/external/dtc/Makefile"; do
  if [ -e "$extra" ]; then printf '  [OK]   %-46s %s\n' "备选依赖" "$extra"
  else printf '  [WARN] %-46s 缺失（默认构建方式不需要）\n' "备选依赖" ; fi
done

# 外部模块只是附带产物：我们的交付物是内核 Image（AK3 只换 Image），
# 所以 EXT_MODULES 缺失只告警、不阻断（否则会白白浪费一次构建）。
MISS_EXT=0
for k in mmrm-driver audio-kernel camera-kernel display-drivers video-driver; do
  if [ -e "$WS/modules/qcom/opensource/$k" ]; then
    printf '  [OK]   %-46s %s\n' "EXT_MODULE $k" "$WS/modules/qcom/opensource/$k"
  else
    printf '  [WARN] %-46s 缺失（不影响编出 Image）\n' "EXT_MODULE $k"
    MISS_EXT=$((MISS_EXT+1))
  fi
done
[ "$MISS_EXT" -ne 0 ] && warn "有 $MISS_EXT 个外部模块源缺失：Image 仍可编译，但 vendor_dlkm.img 会不完整（本方案用不到）"

echo "================================================"
if [ "$FAIL" -ne 0 ]; then
  echo "[assemble][ERROR] 有 $FAIL 项缺失，先修好再编译。"
  echo "  常见原因：分支名写错（换 lineage-23.2 试试）、网络到 googlesource 不通（可换镜像）、磁盘不足。"
  exit 1
fi
echo "[assemble] 全部就绪。下一步："
echo "  bash scripts/apply-configs.sh $WS/common"
echo "  bash scripts/integrate-resukisu.sh $WS/common main kprobes"
echo "  cd $WS && source build.env && ./build/build.sh"
