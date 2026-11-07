#!/usr/bin/env bash

set -Eeuo pipefail

export LC_ALL=C LANG=C

WORKDIR="${WORKDIR:-${HOME}/openwrt}"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
CONFIG_URL="${CONFIG_URL:-https://raw.githubusercontent.com/NetForgeCN/OpenWrt-ScriptBuild/main/.config}"
RELEASE_DIR="${RELEASE_DIR:-}"
RUST_MAKEFILE="${RUST_MAKEFILE:-feeds/packages/lang/rust/Makefile}"
GOLANG_VALUES="${GOLANG_VALUES:-feeds/packages/lang/golang/golang-values.mk}"
GO_AMD64_LEVEL="${GO_AMD64_LEVEL:-v3}"
TARGET_SUBDIR="${TARGET_SUBDIR:-x86}"
KERNEL_CONFIG="${KERNEL_CONFIG:-}"
FEEDS_CONF="${FEEDS_CONF:-feeds.conf.default}"
JOBS="${JOBS:-}"
SKIP_UPDATE="${SKIP_UPDATE:-0}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
REFRESH_CONFIG="${REFRESH_CONFIG:-0}"
CLEAN_KERNEL="${CLEAN_KERNEL:-auto}"
CLEAN_GOLANG="${CLEAN_GOLANG:-auto}"
SINGLE_JOB_RETRY="${SINGLE_JOB_RETRY:-}"

RUST_CHANGED=0
GOLANG_CHANGED=0
KERNEL_CHANGED=0

FEEDS=(
    "ddnsgo|https://github.com/sirpdboy/luci-app-ddns-go.git"
    "kixdns|https://github.com/JohnsonRan/luci-app-kixdns.git"
    "diskman|https://github.com/sbwml/luci-app-diskman.git"
    "dae|https://github.com/QiuSimons/luci-app-dae.git"
    "opennexttrace|https://github.com/haohaoget/luci-app-open_nexttrace.git"
    "airplay2|https://github.com/NetForgeCN/luci-app-airplay2.git;main"
)

EXTRA_REPOS=(
    "https://github.com/gSpotx2f/luci-app-temp-status.git|package/luci-app-temp-status"
    "https://github.com/jerrykuku/luci-theme-argon.git|package/luci-theme-argon"
    "https://github.com/w9315273/luci-app-pulse.git|package/luci-app-pulse"
    "https://github.com/svenshi/luci-app-oxidns.git|package/luci-app-oxidns"
)

V2RAY_GEODATA_REPO="https://github.com/NetForgeCN/Loyalsoldier.git"
V2RAY_GEODATA_DIR="package/v2ray-geodata"
V2RAY_GEODATA_FEED_SRC="feeds/packages/net/v2ray-geodata"

KERNEL_OPTIONS=(
    "NETKIT|CONFIG_NETKIT=y"
    "X86_NATIVE_CPU|# CONFIG_X86_NATIVE_CPU is not set"
    "X86_SGX|# CONFIG_X86_SGX is not set"
)

if [[ -t 1 ]]; then
    C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

log()  { printf '\n%s[%s] %s%s\n' "$C_GREEN"  "$(date '+%F %T')" "$*" "$C_OFF"; }
warn() { printf '\n%s[警告] %s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die()  { printf '\n%s[错误] %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/openwrt-build.XXXXXX")"
cleanup() { rm -rf -- "$TMP_WORK"; }

on_err() {
    local rc=$?
    printf '\n%s[错误] 脚本在第 %s 行执行失败，退出码：%s%s\n' "$C_RED" "$1" "$rc" "$C_OFF" >&2
    printf '%s[错误] 失败命令：%s%s\n' "$C_RED" "$2" "$C_OFF" >&2
    exit "$rc"
}

trap 'cleanup' EXIT
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

sed_inplace() {
    local expr="$1" file="$2" tmp
    [[ -f "$file" ]] || { warn "sed_inplace: 文件不存在：$file"; return 1; }
    tmp="${TMP_WORK}/$(basename "$file").sed.$$"
    sed -E "$expr" "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    cat -- "$tmp" > "$file" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

detect_jobs() {
    local n=""
    if command -v nproc >/dev/null 2>&1; then n="$(nproc 2>/dev/null || true)"; fi
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=1
    printf '%s\n' "$n"
}

git_safe() {
    local dir="$1"
    git config --global --get-all safe.directory 2>/dev/null |
        grep -qxF "$dir" || git config --global --add safe.directory "$dir" 2>/dev/null || true
}

repo_is_dirty() {
    ! git -C "$1" diff --quiet --ignore-submodules -- 2>/dev/null ||
        ! git -C "$1" diff --cached --quiet --ignore-submodules -- 2>/dev/null
}

ensure_repo() {
    local url="$1" dir="$2" parent

    parent="$(dirname "$dir")"
    [[ -d "$parent" ]] || mkdir -p -- "$parent"

    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        log "首次克隆：$dir"
        git clone "$url" "$dir"
        return 0
    fi

    if [[ ! -d "$dir/.git" ]]; then
        die "目标已存在但不是 Git 仓库：$dir"
    fi

    git_safe "$(cd "$dir" && pwd -P)"

    if [[ "$SKIP_UPDATE" == "1" ]]; then
        log "跳过更新：$dir"
        return 0
    fi

    if repo_is_dirty "$dir"; then
        warn "$dir 存在未提交的本地修改，跳过更新"
        return 0
    fi

    if ! git -C "$dir" symbolic-ref -q HEAD >/dev/null; then
        warn "$dir 处于 detached HEAD 状态，跳过更新"
        return 0
    fi

    log "更新仓库：$dir"
    if ! git -C "$dir" pull --ff-only; then
        warn "$dir 无法快进更新，继续使用当前代码"
    fi
}

check_env() {
    log "检查运行环境"

    local required=(git make curl sed awk grep find tar)
    local optional=(gcc g++ cc patch perl python3 unzip xz gzip bzip2 flex bison gawk rsync file)
    local cmd missing=() missing_opt=()

    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    for cmd in "${optional[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_opt+=("$cmd")
    done

    ((${#missing[@]} == 0)) || die "缺少必需命令：${missing[*]}"
    ((${#missing_opt[@]} == 0)) || warn "建议安装的构建依赖缺失：${missing_opt[*]}"

    case "$(uname -s)" in
        Linux) : ;;
        *) warn "当前系统为 $(uname -s)，OpenWrt 官方仅支持 Linux" ;;
    esac

    JOBS="${JOBS:-$(detect_jobs)}"
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "无法获取有效的 CPU 并行任务数（JOBS=${JOBS}）"

    export LC_ALL=C LANG=C
    unset -v GREP_OPTIONS || true
}

prepare_source() {
    log "检查 OpenWrt 主仓库"

    if [[ ! -e "$WORKDIR" && ! -L "$WORKDIR" ]]; then
        mkdir -p -- "$(dirname "$WORKDIR")"
        log "首次运行：克隆 OpenWrt 主仓库 -> $WORKDIR"
        git clone "$OPENWRT_REPO" "$WORKDIR"
    else
        ensure_repo "$OPENWRT_REPO" "$WORKDIR"
    fi

    [[ -d "$WORKDIR/.git" ]] || die "$WORKDIR 不是有效的 Git 仓库"

    cd "$WORKDIR"
    git_safe "$WORKDIR"

    log "OpenWrt 分支：$(git branch --show-current 2>/dev/null || echo '(detached HEAD)')"
    log "OpenWrt 提交：$(git rev-parse --short HEAD)"
}

configure_feeds() {
    log "配置第三方 feeds"

    [[ -f "$FEEDS_CONF" ]] || die "找不到 ${FEEDS_CONF}（当前目录：$(pwd)）"

    sed_inplace 's;git\.openwrt\.org/(feed|project);github.com/openwrt;' "$FEEDS_CONF" || true

    local item name
    for item in "${FEEDS[@]}"; do
        name="${item%%|*}"
        sed_inplace "/^[[:space:]]*src-git[[:space:]]+${name}[[:space:]]/d" "$FEEDS_CONF"
    done

    local trimmed="${TMP_WORK}/feeds.conf.trimmed"
    awk '{ a[NR] = $0 }
         END {
             n = NR
             while (n > 0 && a[n] ~ /^[[:space:]]*$/) n--
             for (i = 1; i <= n; i++) print a[i]
         }' "$FEEDS_CONF" > "$trimmed"
    cat -- "$trimmed" > "$FEEDS_CONF"

    {
        printf '\n'
        for item in "${FEEDS[@]}"; do
            name="${item%%|*}"
            printf 'src-git %s %s\n' "$name" "${item#*|}"
        done
    } >> "$FEEDS_CONF"

    log "第三方 feeds 配置完成：$FEEDS_CONF"
}

update_feeds() {
    log "更新所有 feeds"
    ./scripts/feeds update -a

    remove_official_v2ray_geodata

    log "安装所有 feeds 软件包"
    ./scripts/feeds install -a

    install_airplay2_feed_pkgs
}

install_airplay2_feed_pkgs() {
    log "处理 airplay2 feed 专用包"

    ./scripts/feeds uninstall nqptp || warn "卸载 nqptp 未成功，继续安装 airplay2 feed 内版本"

    ./scripts/feeds install -p airplay2 airplay2 nqptp luci-app-airplay2 ||
        die "从 airplay2 feed 安装失败"

    log "airplay2 feed 相关包安装完成"
}

fix_rust_llvm() {
    log "检查 Rust LLVM 下载配置"

    [[ -f "$RUST_MAKEFILE" ]] || { warn "找不到 Rust Makefile：${RUST_MAKEFILE}，跳过"; return 0; }

    if grep -qF -- '--set=llvm.download-ci-llvm=true' "$RUST_MAKEFILE"; then
        log "Rust LLVM 下载参数已经是 true"
        return 0
    fi

    if grep -qE -- '--set=llvm\.download-ci-llvm=(falst|false)' "$RUST_MAKEFILE"; then
        sed_inplace \
            's/--set=llvm\.download-ci-llvm=(falst|false)/--set=llvm.download-ci-llvm=true/g' \
            "$RUST_MAKEFILE"
        log "已将 Rust LLVM 下载参数修改为 true"
        RUST_CHANGED=1
        return 0
    fi

    warn "没有找到预期的 Rust LLVM 参数，请检查：$RUST_MAKEFILE"
}

fix_golang_amd64() {
    log "检查 Golang GO_AMD64 设置（目标值：${GO_AMD64_LEVEL}）"

    [[ -f "$GOLANG_VALUES" ]] || { warn "找不到 golang-values.mk：${GOLANG_VALUES}，跳过"; return 0; }

    local lines
    lines="$(grep -nE '^[[:space:]]*GO_AMD64[[:space:]]*[:?]?=' "$GOLANG_VALUES" || true)"

    if [[ -z "$lines" ]]; then
        warn "在 $GOLANG_VALUES 中未找到 GO_AMD64 赋值行"
        return 0
    fi

    printf '%s\n' "$lines" | sed 's/^/    /'

    if grep -qE "^[[:space:]]*GO_AMD64[[:space:]]*[:?]?=[[:space:]]*${GO_AMD64_LEVEL}[[:space:]]*$" \
        "$GOLANG_VALUES"; then
        log "GO_AMD64 已经是 ${GO_AMD64_LEVEL}，无需修改"
        return 0
    fi

    sed_inplace \
        "s/^([[:space:]]*GO_AMD64)[[:space:]]*[:?]?=.*\$/\1:=${GO_AMD64_LEVEL}/" \
        "$GOLANG_VALUES"

    local after
    after="$(grep -nE "^[[:space:]]*GO_AMD64[[:space:]]*:=[[:space:]]*${GO_AMD64_LEVEL}[[:space:]]*\$" \
        "$GOLANG_VALUES" || true)"

    [[ -n "$after" ]] || die "GO_AMD64 修改失败，请检查 $GOLANG_VALUES"

    printf '%s\n' "$after" | sed 's/^/    /'
    log "GO_AMD64 已设置为 ${GO_AMD64_LEVEL}"

    GOLANG_CHANGED=1
}

remove_official_v2ray_geodata() {
    if [[ -e "$V2RAY_GEODATA_FEED_SRC" || -L "$V2RAY_GEODATA_FEED_SRC" ]]; then
        rm -rf -- "$V2RAY_GEODATA_FEED_SRC"
        log "已删除官方 v2ray-geodata 源"
    fi

    local link
    while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        rm -f -- "$link"
        log "已删除失效符号链接：$link"
    done < <(find package/feeds -maxdepth 2 -name 'v2ray-geodata' -type l -print 2>/dev/null || true)
}

replace_v2ray_geodata() {
    log "替换 v2ray-geodata"

    rm -rf -- "$V2RAY_GEODATA_DIR"
    git clone "$V2RAY_GEODATA_REPO" "$V2RAY_GEODATA_DIR"

    [[ -f "$V2RAY_GEODATA_DIR/Makefile" ]] || die "第三方 v2ray-geodata 缺少 Makefile"

    log "第三方 v2ray-geodata 就位：$V2RAY_GEODATA_DIR"
}

install_extra_repos() {
    log "处理普通第三方 Git 仓库"

    local item
    for item in "${EXTRA_REPOS[@]}"; do
        ensure_repo "${item%%|*}" "${item#*|}"
    done

    log "第三方 Git 仓库处理完成"
}

prepare_config() {
    log "检查固件配置文件 .config"

    if [[ -f .config && "$REFRESH_CONFIG" != "1" ]]; then
        log "检测到已有 .config，保留现有配置"
    else
        if [[ -f .config && "$REFRESH_CONFIG" == "1" ]]; then
            local backup=".config.bak.$(date '+%Y%m%d-%H%M%S')"
            cp -f -- .config "$backup"
            warn "旧配置已备份为 $backup"
        fi

        local tmp="${TMP_WORK}/config.download"
        if [[ -f "$CONFIG_URL" ]]; then
            cp -f -- "$CONFIG_URL" "$tmp"
        else
            curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
                "$CONFIG_URL" -o "$tmp" || die "下载 .config 失败：$CONFIG_URL"
        fi

        [[ -s "$tmp" ]] || die "下载的 .config 为空"
        grep -qE '^(CONFIG_|# CONFIG_)' "$tmp" || die "下载的 .config 无效：$CONFIG_URL"

        cat -- "$tmp" > .config
        log "配置文件就位（$(wc -l < .config | tr -d ' ') 行）"
    fi

    make defconfig
    [[ -f .config ]] || die "make defconfig 之后 .config 丢失"
}

detect_kernel_config() {
    local dir="target/linux/${TARGET_SUBDIR}" best="" f ver best_ver=0

    [[ -d "$dir" ]] || die "找不到内核配置目录：$dir"

    for f in "$dir"/config-*; do
        [[ -f "$f" ]] || continue
        ver="${f##*config-}"
        [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
        if [[ "$ver" =~ ^([0-9]+)(\.([0-9]+))? ]]; then
            local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[3]:-0}"
            local score=$((major * 1000 + minor))
            if ((score >= best_ver)); then
                best_ver=$score
                best="$f"
            fi
        fi
    done

    [[ -n "$best" ]] || die "在 $dir 下未找到任何 config-<版本> 文件"
    printf '%s\n' "$best"
}

set_kernel_config() {
    local key="$1" value="$2" file="$3" tmp count

    count="$(grep -cE "^(CONFIG_${key}=|# CONFIG_${key} is not set$)" "$file" || true)"

    if [[ "$count" == "1" ]] && grep -qxF -- "$value" "$file"; then
        log "内核配置 ${key} 已是目标值，跳过"
        return 1
    fi

    tmp="${TMP_WORK}/$(basename "$file").new"
    awk -v key="$key" '
        $0 ~ "^CONFIG_" key "="                 { next }
        $0 ~ "^# CONFIG_" key " is not set$"    { next }
        { print }
    ' "$file" > "$tmp"

    printf '%s\n' "$value" >> "$tmp"
    cat -- "$tmp" > "$file"
    rm -f -- "$tmp"

    log "已写入：${value}"
    return 0
}

patch_kernel_config() {
    log "处理 ${TARGET_SUBDIR} 内核配置"

    [[ -n "$KERNEL_CONFIG" ]] || KERNEL_CONFIG="$(detect_kernel_config)"
    [[ -f "$KERNEL_CONFIG" ]] || die "找不到内核配置文件：$KERNEL_CONFIG"

    local item key value changed=0
    for item in "${KERNEL_OPTIONS[@]}"; do
        key="${item%%|*}"
        value="${item#*|}"
        if set_kernel_config "$key" "$value" "$KERNEL_CONFIG"; then
            changed=1
        fi
    done

    grep -nE '^(CONFIG_NETKIT=y|# CONFIG_X86_NATIVE_CPU is not set|# CONFIG_X86_SGX is not set)$' \
        "$KERNEL_CONFIG" || warn "未能校验到全部目标内核配置"

    KERNEL_CHANGED=$changed
}

clean_stale_artifacts() {
    local do_clean="$CLEAN_KERNEL"

    if [[ "$do_clean" == "auto" ]]; then
        if [[ "$KERNEL_CHANGED" == "1" ]]; then do_clean=1; else do_clean=0; fi
    fi

    if [[ "$do_clean" == "1" && "$KERNEL_CHANGED" == "1" ]]; then
        log "清理内核构建目录"
        make target/linux/clean || warn "make target/linux/clean 失败，可忽略"
    fi

    if [[ "$RUST_CHANGED" == "1" ]] && compgen -G 'build_dir/*/rust*' >/dev/null; then
        log "清理 Rust 构建缓存"
        make package/feeds/packages/rust/clean 2>/dev/null || warn "Rust 缓存清理失败"
    fi

    if [[ "$GOLANG_CHANGED" == "1" && "$CLEAN_GOLANG" != "0" ]] &&
        compgen -G 'build_dir/*/golang*' >/dev/null; then
        log "清理 Golang 构建缓存"
        make package/feeds/packages/golang/clean 2>/dev/null || warn "Golang 缓存清理失败"
    fi
}

init_ccache() {
    if command -v ccache >/dev/null 2>&1 && [[ -n "${CCACHE_DIR:-}" ]]; then
        mkdir -p -- "$CCACHE_DIR"
        ccache -M 3G
        ccache -z
        log "ccache 目录：$CCACHE_DIR"
    fi
}

download_sources() {
    log "下载编译所需源码（并行任务数：${JOBS}）"

    if ! make download -j"$JOBS"; then
        warn "并行下载失败，改为单线程重试"
        make download -j1 V=s || die "make download 失败"
    fi

    local small
    small="$(find dl -type f -size -1024c -print 2>/dev/null | head -n 20 || true)"
    [[ -z "$small" ]] || warn "dl/ 中存在体积异常小的文件：${small}"

    log "源码下载完成"
}

build() {
    log "开始编译 OpenWrt"
    log "并行任务数：$JOBS"
    log "编译目录：$(pwd)"

    if [[ -z "$SINGLE_JOB_RETRY" ]]; then
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then SINGLE_JOB_RETRY=0; else SINGLE_JOB_RETRY=1; fi
    fi

    if [[ "$SINGLE_JOB_RETRY" == "1" ]]; then
        if ! time make -j"$JOBS"; then
            warn "并行编译失败，改用单线程 + 详细日志重试"
            make -j1 V=s || die "编译失败"
        fi
        return 0
    fi

    local attempt failed pkg log_file
    for attempt in 1 2 3; do
        log "并行编译第 ${attempt}/3 轮"
        if make -j"$JOBS" 2>&1 | tee build.log; then
            log "编译成功"
            return 0
        fi

        failed="$(grep -oE 'ERROR: [^ ]+ failed to build' build.log \
            | sed -E 's/^ERROR: //; s/ failed to build$//' \
            | sort -u | tr '\n' ' ')" || true

        [[ -n "${failed// /}" ]] || die "并行编译失败，未能从日志中识别出失败包"
        log "失败包：${failed}"

        for pkg in $failed; do
            log_file="retry-$(printf '%s' "$pkg" | tr '/' '_').log"
            log "单包重建：$pkg"
            make "${pkg}/clean" || true
            make "${pkg}/compile" -j1 V=s 2>&1 | tee "$log_file" || warn "单包重建失败：$pkg"
        done
    done

    die "已重试 3 轮仍未通过，请查看 build.log"
}

collect_assets() {
    local dir="${RELEASE_DIR:-$(pwd)/release-assets}"
    mkdir -p -- "$dir"

    find bin/targets -maxdepth 3 -type f \
        \( -name '*.img.gz' -o -name '*.img' -o -name '*.bin' -o -name '*.manifest' -o -name '*.buildinfo' \) \
        -exec cp -a {} "$dir/" \; 2>/dev/null || true

    [[ -n "$(find "$dir" -maxdepth 1 -type f \
        \( -name '*.img.gz' -o -name '*.img' -o -name '*.bin' \) -size +5M -print -quit)" ]] ||
        die "未生成有效的固件文件"

    {
        echo "Build Time: $(TZ=Asia/Shanghai date)"
        echo "OpenWrt Commit: $(git rev-parse HEAD)"
        echo "Toolchain Key: ${TOOLCHAIN_KEY:-unknown}"
    } > "$dir/release-notes.txt"

    log "发布资产已收集到：$dir"
}

usage() {
    cat <<'EOF'
用法: compile.sh [-j N|--jobs N] [-h|--help]
环境变量: WORKDIR OPENWRT_REPO CONFIG_URL RELEASE_DIR JOBS REFRESH_CONFIG
          SKIP_UPDATE SKIP_DOWNLOAD SKIP_BUILD GO_AMD64_LEVEL TARGET_SUBDIR
          KERNEL_CONFIG CLEAN_KERNEL CLEAN_GOLANG SINGLE_JOB_RETRY TOOLCHAIN_KEY
EOF
}

main() {
    while (($# > 0)); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -j|--jobs)
                [[ $# -ge 2 ]] || die "--jobs 需要一个数字参数"
                JOBS="$2"
                shift 2
                ;;
            *) die "未知参数：$1" ;;
        esac
    done

    RUST_CHANGED=0
    GOLANG_CHANGED=0
    KERNEL_CHANGED=0

    check_env
    prepare_source
    configure_feeds
    update_feeds
    fix_rust_llvm
    fix_golang_amd64
    replace_v2ray_geodata
    install_extra_repos
    prepare_config
    patch_kernel_config
    clean_stale_artifacts
    init_ccache

    if [[ "$SKIP_DOWNLOAD" == "1" ]]; then
        log "跳过源码下载"
    else
        download_sources
    fi

    if [[ "$SKIP_BUILD" == "1" ]]; then
        log "跳过编译"
    else
        build
        collect_assets
    fi

    log "脚本执行结束"
}

main "$@"
