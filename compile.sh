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

# honk 核心的宿主机工具链：优先按当前 HONK_SRC_VERSION 从上游动态解析
# （pins.env / release.yml / ziglang.org/download/index.json）；网络或解析失败
# 回退下面这份本地 pin（离线 VM 仍能编译）。显式环境变量优先级最高，
# 所有下载仍强制 sha256sum -c 校验。
HONK_FALLBACK_SRC_URL="https://github.com/daeuniverse/honk.git"
HONK_FALLBACK_SRC_VERSION="00be4f01309ecf7620be01f0398e875295e9b942"
HONK_FALLBACK_ZIG_VERSION="0.14.1"
HONK_FALLBACK_BPF_VERSION="0.11.0"
HONK_FALLBACK_BPF_SHA_X86="10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450"
HONK_FALLBACK_BPF_SHA_AARCH64="d09ddd83303e9ab1443f51e0e284680154009646a3ce141c63d838ee61b73eb9"
HONK_FALLBACK_ZIG_SHA_X86="24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c"
HONK_FALLBACK_ZIG_SHA_AARCH64="f7a654acc967864f7a050ddacfaa778c7504a0eca8d2b678839c21eea47c992b"

# 空 = 交给动态解析；非空 = 调用方显式覆盖
HONK_ZIG_VERSION="${HONK_ZIG_VERSION:-}"
HONK_BPF_LINKER_VERSION="${HONK_BPF_LINKER_VERSION:-}"
HONK_BPF_LINKER_SHA256_X86_64="${HONK_BPF_LINKER_SHA256_X86_64:-${HONK_BPF_LINKER_SHA256:-}}"
HONK_BPF_LINKER_SHA256_AARCH64="${HONK_BPF_LINKER_SHA256_AARCH64:-}"
HONK_ZIG_SHA256_X86_64="${HONK_ZIG_SHA256_X86_64:-}"
HONK_ZIG_SHA256_AARCH64="${HONK_ZIG_SHA256_AARCH64:-}"
HONK_SRC_URL="${HONK_SRC_URL:-}"
HONK_SRC_VERSION="${HONK_SRC_VERSION:-}"
# honk feed 的包 Makefile 在 feeds/honk/honk/Makefile（兼容 feeds/honk/Makefile）
HONK_MAKEFILE="${HONK_MAKEFILE:-feeds/honk/honk/Makefile}"
HONK_ZIG_INDEX_URL="${HONK_ZIG_INDEX_URL:-https://ziglang.org/download/index.json}"
HONK_PINS_SOURCE=""
HONK_ZIG_SHA_SOURCE=""
HONK_HOST_ARCH=""
HONK_HOST_BPF_SHA=""
HONK_HOST_ZIG_SHA=""
# 空 = 自动判断：CI（GITHUB_ACTIONS）或免密 sudo 可用时自动装，否则只提示不装
HONK_TOOLCHAIN_AUTO="${HONK_TOOLCHAIN_AUTO:-}"

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
    "honk|https://github.com/QiuSimons/luci-app-honk.git"
    "photondns|https://github.com/c2h2/luci-app-photondns.git"
    "nikki|https://github.com/nikkinikki-org/OpenWrt-nikki.git"
    # mosdns 的默认分支是 v5（不是 main/master），这里显式钉住
    "mosdns|https://github.com/sbwml/luci-app-mosdns.git;v5"
    # openappfilter 的默认分支是 master，这里显式钉住（一个 feed 内含
    # luci-app-oaf / appfilter / kmod-oaf 三个包，feeds install -a 会自动装齐）
    "openappfilter|https://github.com/destan19/OpenAppFilter.git;master"
    # atomdns: 自有的一体化包，仓库根没有 Makefile，包目录是 luci-app-atomdns/，
    # 走 src-git feed 由 feeds install -a 扫描到。feed 短名只能是 atomdns
    # （名称段不含减号）：scripts/feeds 用 \w+ 解析 feeds.conf 的名称段。
    "atomdns|https://github.com/NetForgeCN/luci-app-atomdns.git;main"
)

EXTRA_REPOS=(
    "https://github.com/gSpotx2f/luci-app-temp-status.git|package/luci-app-temp-status"
    "https://github.com/jerrykuku/luci-theme-argon.git|package/luci-theme-argon"
    "https://github.com/w9315273/luci-app-pulse.git|package/luci-app-pulse"
    "https://github.com/NetForgeCN/luci-app-oxidns.git|package/luci-app-oxidns"
    "https://github.com/NetForgeCN/luci-app-lucky.git|package/luci-app-lucky"
    # hevsocks5: 仓库根就是包目录（Makefile 在根），不能当 src-git feed 用
    # （feeds 扫描的是 feed 下的子目录，根 Makefile 会被忽略），因此与
    # oxidns / lucky 一样直接 clone 到 package/。LUCI_DEPENDS 里的
    # +hev-socks5-server 由官方 packages feed 提供，无需额外克隆。
    "https://github.com/NetForgeCN/luci-app-hevsocks5.git|package/luci-app-hevsocks5"
)

# v2ray-geodata 打包层：与 openwrt-suite 的 geodata 源同源于此仓库（三库一致）。
# 仓库内唯一一份 Makefile 里 GEOIP_URL / GEOSITE_URL 都指向自建规则仓库
# NetForgeCN/v2ray-rules-dat 的 latest release（全量 .dat + .sha256sum）。
# 要换数据源只改那个仓库，不要在这里改回 sbwml/v2ray-geodata 或另加补丁：
# URL 存在两处就会让 suite 与两个构建库编译出内容不同的同名包。
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
LOCK_DIR=""
cleanup() {
    if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
        local pid=""
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        # 只清理自己的锁，避免误删另一并发运行重建的锁
        if [[ "$pid" == "$$" ]]; then rm -rf -- "$LOCK_DIR"; fi
    fi
    rm -rf -- "$TMP_WORK"
}

on_err() {
    local rc=$?
    printf '\n%s[错误] 脚本在第 %s 行执行失败，退出码：%s%s\n' "$C_RED" "$1" "$rc" "$C_OFF" >&2
    printf '%s[错误] 失败命令：%s%s\n' "$C_RED" "$2" "$C_OFF" >&2
    exit "$rc"
}

trap 'cleanup' EXIT
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# 同目录临时文件 + mv 原子替换；保留原权限/所有者，首次改动前备份以便回滚。
# 拒绝编辑符号链接，避免把内容写到源码树之外。
# ---------------------------------------------------------------------------

atomic_replace() {
    local src="$1" dest="$2" bak tmp
    [[ -f "$src" ]] || { warn "atomic_replace: 源文件不存在：$src"; return 1; }
    # 首次运行时目标可能尚不存在；已存在的目标必须是普通文件而非符号链接。
    if [[ -e "$dest" || -L "$dest" ]]; then
        [[ -f "$dest" && ! -L "$dest" ]] || { warn "atomic_replace: 目标不是普通文件（或为符号链接）：$dest"; return 1; }
    fi
    mkdir -p -- "${TMP_WORK}/backups" || return 1
    bak="${TMP_WORK}/backups/$(printf '%s' "$dest" | tr '/' '_').bak"
    if [[ -f "$dest" && ! -e "$bak" ]]; then
        cp -p -- "$dest" "$bak" || return 1
    fi
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").tmp.XXXXXX")" || return 1
    if [[ -f "$dest" ]]; then
        cp -p -- "$dest" "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    cat -- "$src" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

rollback_file() {
    local dest="$1"
    local bak="${TMP_WORK}/backups/$(printf '%s' "$dest" | tr '/' '_').bak"
    [[ -f "$bak" ]] || return 1
    cp -p -- "$bak" "$dest"
}

sed_inplace() {
    local expr="$1" file="$2" tmp
    [[ -f "$file" && ! -L "$file" ]] || { warn "sed_inplace: 文件不存在或为符号链接：$file"; return 1; }
    tmp="${TMP_WORK}/$(basename "$file").sed.$$"
    sed -E "$expr" "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    atomic_replace "$tmp" "$file" || {
        rm -f -- "$tmp"
        rollback_file "$file" || true
        return 1
    }
    rm -f -- "$tmp"
}

# 网络命令的有限重试（feeds update/install、克隆等）。全部参数按原样透传，
# 返回最后一次尝试的退出码，调用方用 || die 显式检查。
retry_cmd() {
    local attempts="$1" delay="$2" n=1
    shift 2
    while :; do
        if "$@"; then
            return 0
        fi
        if (( n >= attempts )); then
            return 1
        fi
        warn "命令失败，${delay}s 后重试（${n}/${attempts}）：$*"
        n=$((n + 1))
        sleep "$delay"
    done
}

clone_repo() {
    local url="$1" dir="$2" n=1
    while :; do
        if git clone "$url" "$dir"; then
            return 0
        fi
        rm -rf -- "$dir" || true
        if (( n >= 3 )); then
            return 1
        fi
        warn "克隆失败，5s 后重试（$n/3）：$url"
        n=$((n + 1))
        sleep 5
    done
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
        clone_repo "$url" "$dir" || die "克隆失败：$url -> $dir"
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

    # GO_AMD64_LEVEL 会被直接拼进 sed 表达式，先做白名单校验，避免注入。
    [[ "$GO_AMD64_LEVEL" =~ ^v[1-4]$ ]] ||
        die "GO_AMD64_LEVEL 必须是 v1/v2/v3/v4，当前值：${GO_AMD64_LEVEL}"

    local required=(git make curl sed awk grep find tar sha256sum)
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

    # 磁盘空间预检（OpenWrt 全量编译通常需要 10GB 以上）；只警告不阻断，
    # 因为不同 target / 缓存策略的实际需求差异很大。
    local avail
    avail="$(df -Pk "$(dirname "$WORKDIR")" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
    if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < 10485760 )); then
        warn "磁盘可用空间不足 10GB（$(dirname "$WORKDIR") 仅剩 ${avail} KiB），完整编译可能失败"
    fi

    export LC_ALL=C LANG=C
    unset -v GREP_OPTIONS || true
}

# 用 OpenWrt 源码 HEAD 的提交时间作为可复现构建时间戳（OpenWrt buildroot
# 原生支持 SOURCE_DATE_EPOCH）。调用者可用环境变量显式覆盖。
set_source_date_epoch() {
    local epoch
    if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
        [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] ||
            die "SOURCE_DATE_EPOCH 必须是整数秒，当前值：${SOURCE_DATE_EPOCH}"
        log "使用调用方指定的 SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}"
        return 0
    fi
    epoch="$(git log -1 --format=%ct 2>/dev/null || true)"
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        export SOURCE_DATE_EPOCH="$epoch"
        log "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}（取自 OpenWrt HEAD 提交时间）"
    else
        warn "无法确定 OpenWrt HEAD 提交时间，跳过 SOURCE_DATE_EPOCH 设置"
    fi
}

# 避免同一 WORKDIR 上两个 compile.sh 并发写坏源码树。锁目录放在 WORKDIR 内，
# 记录 PID；进程已退出的锁视为陈旧锁并清理。
acquire_lock() {
    LOCK_DIR="${WORKDIR}/.compile.lock"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" || die "写入锁文件失败：$LOCK_DIR"
        return 0
    fi
    local pid=""
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        die "另一个 compile.sh 正在使用 $WORKDIR（PID $pid）"
    fi
    warn "清理陈旧构建锁：$LOCK_DIR（PID=${pid:-unknown}）"
    rm -rf -- "$LOCK_DIR" || die "无法清理陈旧构建锁：$LOCK_DIR"
    mkdir "$LOCK_DIR" || die "无法创建构建锁：$LOCK_DIR"
    printf '%s\n' "$$" > "$LOCK_DIR/pid" || die "写入锁文件失败：$LOCK_DIR"
}

prepare_source() {
    log "检查 OpenWrt 主仓库"

    if [[ ! -e "$WORKDIR" && ! -L "$WORKDIR" ]]; then
        mkdir -p -- "$(dirname "$WORKDIR")"
        log "首次运行：克隆 OpenWrt 主仓库 -> $WORKDIR"
        clone_repo "$OPENWRT_REPO" "$WORKDIR" || die "克隆 OpenWrt 失败：$OPENWRT_REPO"
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

    sed_inplace 's;git\.openwrt\.org/(feed|project);github.com/openwrt;' "$FEEDS_CONF" ||
        die "改写官方 feeds 源失败：$FEEDS_CONF（已回滚）"

    local item name
    for item in "${FEEDS[@]}"; do
        name="${item%%|*}"
        sed_inplace "/^[[:space:]]*src-git[[:space:]]+${name}[[:space:]]/d" "$FEEDS_CONF"
    done

    # 一次性原子写入（trim + 追加），避免 `>` 截断 / `>>` 半写入损坏 feeds.conf
    local new_conf="${TMP_WORK}/feeds.conf.new"
    {
        awk '{ a[NR] = $0 }
             END {
                 n = NR
                 while (n > 0 && a[n] ~ /^[[:space:]]*$/) n--
                 for (i = 1; i <= n; i++) print a[i]
             }' "$FEEDS_CONF"
        printf '\n'
        for item in "${FEEDS[@]}"; do
            name="${item%%|*}"
            printf 'src-git %s %s\n' "$name" "${item#*|}"
        done
    } > "$new_conf"
    atomic_replace "$new_conf" "$FEEDS_CONF" ||
        die "写入 ${FEEDS_CONF} 失败（已回滚）"

    log "第三方 feeds 配置完成：$FEEDS_CONF"
}

update_feeds() {
    log "更新所有 feeds"
    retry_cmd 3 5 ./scripts/feeds update -a || die "./scripts/feeds update -a 失败（已重试 3 次）"

    remove_official_v2ray_geodata

    log "安装所有 feeds 软件包"
    retry_cmd 3 5 ./scripts/feeds install -a || die "./scripts/feeds install -a 失败（已重试 3 次）"

    install_airplay2_feed_pkgs
}

install_airplay2_feed_pkgs() {
    log "处理 airplay2 feed 专用包"

    ./scripts/feeds uninstall nqptp || warn "卸载 nqptp 未成功，继续安装 airplay2 feed 内版本"

    ./scripts/feeds install -p airplay2 airplay2 nqptp luci-app-airplay2 ||
        die "从 airplay2 feed 安装失败"

    log "airplay2 feed 相关包安装完成"
}

# ---------------------------------------------------------------------------
# photondns：给 feed 克隆补上 Cargo 工程
#
# 上游 c2h2/luci-app-photondns 仓库根是 Rust 工程（Cargo.toml/Cargo.lock/
# build.rs/src/），三个 OpenWrt 包在 openwrt/ 子目录。photondns 的 Makefile 用
# RustBinPackage 编译「包目录里的」Cargo 工程，但包里只有 Makefile 和 root/，
# 不补必然报 could not find Cargo.toml。feed 克隆自带工程，从仓库根拷进
# feeds/photondns/openwrt/photondns/src/ 即可（零网络、幂等、带结构校验；
# 与 openwrt-suite 的 patches/photondns.sh 等价）。
# ---------------------------------------------------------------------------

stage_photondns_cargo() {
    log "为 photondns 补齐 Cargo 工程"

    local feed="feeds/photondns"
    local pkg="$feed/openwrt/photondns"

    # 以前这里 warn + return 0，缺 feed 时一路放行，直到 Rust 编译期才报
    # "could not find Cargo.toml"，白等一整轮构建。与其余结构校验统一为 fail fast。
    if [[ ! -d "$feed/.git" ]]; then
        die "未找到 $feed（photondns 已在 FEEDS 中却未克隆）—— 先确认 ./scripts/feeds update -a 成功；上游目录布局若已变更，请同步修改本函数"
    fi

    local f
    for f in Cargo.toml Cargo.lock build.rs src src/main.rs; do
        [[ -e "$feed/$f" ]] ||
            die "photondns：feed 根缺少 $f —— 上游仓库结构变了，请更新 stage_photondns_cargo"
    done
    [[ -f "$pkg/Makefile" ]] ||
        die "photondns：缺少 $pkg/Makefile —— 上游目录布局变了，请更新 stage_photondns_cargo"

    mkdir -p "$pkg/src"
    rm -rf "$pkg/src/src"
    cp -a "$feed/Cargo.toml" "$feed/Cargo.lock" "$feed/build.rs" "$pkg/src/"
    cp -a "$feed/src" "$pkg/src/src"

    [[ -f "$pkg/src/Cargo.toml" && -f "$pkg/src/src/main.rs" ]] ||
        die "photondns：Cargo 工程 stage 后不完整"
    log "photondns Cargo 工程已 stage 到 $pkg/src/"
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

    local link links="${TMP_WORK}/v2ray-geodata-links.$$"
    find package/feeds -maxdepth 2 -name 'v2ray-geodata' -type l -print 2>/dev/null > "$links" || true
    while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        rm -f -- "$link"
        log "已删除失效符号链接：$link"
    done < "$links"
    rm -f -- "$links"
}

replace_v2ray_geodata() {
    log "替换 v2ray-geodata"

    rm -rf -- "$V2RAY_GEODATA_DIR"
    clone_repo "$V2RAY_GEODATA_REPO" "$V2RAY_GEODATA_DIR" ||
        die "克隆 v2ray-geodata 失败：$V2RAY_GEODATA_REPO"

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

    # 只接受 https 源或本地文件，禁止 http/ftp/file:// 等（阻止明文下载与
    # curl 参数注入）。CONFIG_URL 以 '-' 开头且不是本地文件时会在这里被拒。
    if [[ "$CONFIG_URL" != https://* && ! -f "$CONFIG_URL" ]]; then
        die "CONFIG_URL 必须是 https:// URL 或存在的本地文件：$CONFIG_URL"
    fi

    if [[ -L .config ]]; then
        die "拒绝通过符号链接写入 .config：$(readlink .config || true)"
    fi

    if [[ -f .config && "$REFRESH_CONFIG" != "1" ]]; then
        log "检测到已有 .config，保留现有配置"
    else
        if [[ -f .config && "$REFRESH_CONFIG" == "1" ]]; then
            local backup=".config.bak.$(date '+%Y%m%d-%H%M%S')"
            cp -p -- .config "$backup" || die "备份旧 .config 失败"
            warn "旧配置已备份为 $backup"
        fi

        local tmp="${TMP_WORK}/config.download"
        if [[ -f "$CONFIG_URL" ]]; then
            cp -f -- "$CONFIG_URL" "$tmp" || die "读取本地配置失败：$CONFIG_URL"
        else
            curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
                --connect-timeout 15 --max-time 300 -o "$tmp" -- "$CONFIG_URL" ||
                die "下载 .config 失败：$CONFIG_URL"
        fi

        [[ -s "$tmp" ]] || die "下载的 .config 为空"
        grep -qE '^(CONFIG_|# CONFIG_)' "$tmp" || die "下载的 .config 无效：$CONFIG_URL"

        atomic_replace "$tmp" .config || {
            rollback_file .config || true
            die "写入 .config 失败（已尝试回滚）"
        }
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
    atomic_replace "$tmp" "$file" || {
        rm -f -- "$tmp"
        rollback_file "$file" || true
        die "写入内核配置失败（已尝试回滚）：$file"
    }
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

honk_enabled() {
    [[ -f .config ]] || return 1
    grep -qE '^CONFIG_PACKAGE_honk=[ym]' .config
}

honk_valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
honk_valid_sha() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
honk_valid_revision() { [[ "$1" =~ ^[0-9a-f]{7,40}$ ]]; }
honk_valid_src_url() { [[ "$1" == https://github.com/* ]]; }

# 本地回退：动态解析不可用时保证离线 VM 仍能编译。
honk_apply_fallbacks() {
    HONK_ZIG_VERSION="${HONK_ZIG_VERSION:-$HONK_FALLBACK_ZIG_VERSION}"
    HONK_BPF_LINKER_VERSION="${HONK_BPF_LINKER_VERSION:-$HONK_FALLBACK_BPF_VERSION}"
    HONK_BPF_LINKER_SHA256_X86_64="${HONK_BPF_LINKER_SHA256_X86_64:-$HONK_FALLBACK_BPF_SHA_X86}"
    HONK_BPF_LINKER_SHA256_AARCH64="${HONK_BPF_LINKER_SHA256_AARCH64:-$HONK_FALLBACK_BPF_SHA_AARCH64}"
    HONK_ZIG_SHA256_X86_64="${HONK_ZIG_SHA256_X86_64:-$HONK_FALLBACK_ZIG_SHA_X86}"
    HONK_ZIG_SHA256_AARCH64="${HONK_ZIG_SHA256_AARCH64:-$HONK_FALLBACK_ZIG_SHA_AARCH64}"
    HONK_PINS_SOURCE="local-fallback"
    HONK_ZIG_SHA_SOURCE="local-default"
}

# zig / bpf-linker 资产按「宿主机」架构选（不是目标架构）。
honk_host_info() {
    case "$(uname -m)" in
        x86_64|amd64)
            HONK_HOST_ARCH=x86_64
            HONK_HOST_BPF_SHA="$HONK_BPF_LINKER_SHA256_X86_64"
            HONK_HOST_ZIG_SHA="$HONK_ZIG_SHA256_X86_64"
            ;;
        aarch64|arm64)
            HONK_HOST_ARCH=aarch64
            HONK_HOST_BPF_SHA="$HONK_BPF_LINKER_SHA256_AARCH64"
            HONK_HOST_ZIG_SHA="$HONK_ZIG_SHA256_AARCH64"
            ;;
        *)
            die "honk 工具链：暂不支持宿主机架构 $(uname -m)（只适配 x86_64 / aarch64；可手动装好 zig + bpf-linker 后设 HONK_TOOLCHAIN_AUTO=0）"
            ;;
    esac
}

# 版本/hash 白名单 + guard：版本升级但 hash 仍是本地旧默认值时明确失败，
# 绝不拿旧 hash 校验新资产（与 honk_toolchain.sh --check 同逻辑）。
validate_honk_pins() {
    local h
    honk_valid_version "$HONK_ZIG_VERSION" ||
        die "HONK_ZIG_VERSION 格式不合法：$HONK_ZIG_VERSION"
    honk_valid_version "$HONK_BPF_LINKER_VERSION" ||
        die "HONK_BPF_LINKER_VERSION 格式不合法：$HONK_BPF_LINKER_VERSION"
    for h in "$HONK_ZIG_SHA256_X86_64" "$HONK_ZIG_SHA256_AARCH64" \
             "$HONK_BPF_LINKER_SHA256_X86_64" "$HONK_BPF_LINKER_SHA256_AARCH64"; do
        honk_valid_sha "$h" || die "工具链 sha256 必须是 64 位小写十六进制：$h"
    done
    honk_host_info
    local fb_zig="$HONK_FALLBACK_ZIG_SHA_X86" fb_bpf="$HONK_FALLBACK_BPF_SHA_X86"
    if [[ "$HONK_HOST_ARCH" == aarch64 ]]; then
        fb_zig="$HONK_FALLBACK_ZIG_SHA_AARCH64"
        fb_bpf="$HONK_FALLBACK_BPF_SHA_AARCH64"
    fi
    if [[ "$HONK_ZIG_VERSION" != "$HONK_FALLBACK_ZIG_VERSION" && "$HONK_HOST_ZIG_SHA" == "$fb_zig" ]]; then
        die "zig 版本已升级到 ${HONK_ZIG_VERSION}，但 ${HONK_HOST_ARCH} 的 sha256 仍是本地旧默认值；请确认 zig index.json 解析成功，或显式设置 HONK_ZIG_SHA256_*"
    fi
    if [[ "$HONK_BPF_LINKER_VERSION" != "$HONK_FALLBACK_BPF_VERSION" && "$HONK_HOST_BPF_SHA" == "$fb_bpf" ]]; then
        die "bpf-linker 版本已升级到 ${HONK_BPF_LINKER_VERSION}，但 ${HONK_HOST_ARCH} 的 sha256 仍是本地旧默认值；请确认 pins.env 解析成功，或显式设置 HONK_BPF_LINKER_SHA256_*（aarch64 上游未提供 hash，必须显式指定）"
    fi
}

# 从 ziglang.org/download/index.json 按版本读取两个架构的 shasum。
# 成功设置 HONK_ZIG_SHA_SOURCE=zig-index；失败由调用方回退本地默认值。
resolve_zig_sha() {
    local version="$1" index_file="$2" key="" value=""
    local zx="" za="" out="${TMP_WORK}/honk-zig-sha.$$"
    command -v python3 >/dev/null 2>&1 || return 1
    # 用文件而非命令替换：解析失败（如版本不在索引里）不要触发全局 ERR trap。
    if ! python3 - "$index_file" "$version" > "$out" 2>/dev/null <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    entry = data[sys.argv[2]]
    for name, key in (("X86_64", "x86_64-linux"), ("AARCH64", "aarch64-linux")):
        sha = entry[key].get("sha256") or entry[key].get("shasum")
        if not isinstance(sha, str) or len(sha) != 64:
            raise ValueError(name)
        print("HONK_ZIG_SHA_%s=%s" % (name, sha))
except Exception:
    sys.exit(1)
PY
    then
        rm -f -- "$out"
        return 1
    fi
    while IFS='=' read -r key value; do
        case "$key" in
            HONK_ZIG_SHA_X86_64) zx="$value" ;;
            HONK_ZIG_SHA_AARCH64) za="$value" ;;
        esac
    done < "$out"
    rm -f -- "$out"
    honk_valid_sha "$zx" || return 1
    honk_valid_sha "$za" || return 1
    [[ -n "$HONK_ZIG_SHA256_X86_64" ]] || HONK_ZIG_SHA256_X86_64="$zx"
    [[ -n "$HONK_ZIG_SHA256_AARCH64" ]] || HONK_ZIG_SHA256_AARCH64="$za"
    HONK_ZIG_SHA_SOURCE="zig-index"
}

# 按当前 HONK_SRC_VERSION 动态解析上游 pins.env / release.yml / zig index。
# 显式环境变量优先；网络/解析失败自动回退本地 pin（不依赖其他仓库的脚本）。
resolve_honk_pins() {
    local mk="$HONK_MAKEFILE" url="$HONK_SRC_URL" rev="$HONK_SRC_VERSION"
    local m_url="" m_rev="" repo="" raw="" tmp="${TMP_WORK}/honk-pins"
    local dyn_bpf_version="" dyn_bpf_sha="" dyn_zig_version=""
    mkdir -p -- "$tmp"
    if [[ ! -f "$mk" && "$mk" == "feeds/honk/honk/Makefile" && -f "feeds/honk/Makefile" ]]; then
        mk="feeds/honk/Makefile"
    fi

    if [[ -f "$mk" ]]; then
        m_url="$(sed -n 's/^[[:space:]]*HONK_SRC_URL[[:space:]]*:=[[:space:]]*//p' "$mk" | head -n 1)"
        m_rev="$(sed -n 's/^[[:space:]]*HONK_SRC_VERSION[[:space:]]*:=[[:space:]]*//p' "$mk" | head -n 1)"
        [[ -n "$url" ]] || url="$m_url"
        [[ -n "$rev" ]] || rev="$m_rev"
    fi
    if ! honk_valid_src_url "$url"; then
        warn "HONK_SRC_URL 无效或缺失（$url），使用本地 pin"
        url="$HONK_FALLBACK_SRC_URL"
    fi
    if ! honk_valid_revision "$rev"; then
        warn "HONK_SRC_VERSION 无效或缺失（$rev），使用本地 pin"
        rev="$HONK_FALLBACK_SRC_VERSION"
    fi
    HONK_SRC_URL="$url"
    HONK_SRC_VERSION="$rev"

    repo="${url#https://github.com/}"
    repo="${repo%.git}"
    raw="https://raw.githubusercontent.com/${repo}/${rev}"
    if curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
            -fsSL --retry 1 --connect-timeout 5 --max-time 20 \
            "${raw}/.github/ci/pins.env" -o "${tmp}/pins.env" 2>/dev/null &&
       curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
            -fsSL --retry 1 --connect-timeout 5 --max-time 20 \
            "${raw}/.github/workflows/release.yml" -o "${tmp}/release.yml" 2>/dev/null; then
        dyn_bpf_version="$(sed -n 's/^[[:space:]]*BPF_LINKER_VERSION[[:space:]]*=[[:space:]]*//p' "${tmp}/pins.env" | head -n 1 | tr -d '\r\"')"
        dyn_bpf_sha="$(sed -n 's/^[[:space:]]*BPF_LINKER_SHA256[[:space:]]*=[[:space:]]*//p' "${tmp}/pins.env" | head -n 1 | tr -d '\r\"')"
        dyn_zig_version="$(awk '
          /setup-zig/ { seen = 1; next }
          seen && /^[[:space:]]*version:[[:space:]]*/ {
            sub(/^[[:space:]]*version:[[:space:]]*/, "")
            gsub(/[[:space:]\"]/, "")
            sub(/\r$/, "")
            print
            exit
          }
        ' "${tmp}/release.yml")"
        if ! honk_valid_version "$dyn_bpf_version" ||
           ! honk_valid_sha "$dyn_bpf_sha" ||
           ! honk_valid_version "$dyn_zig_version"; then
            warn "无法从 ${raw} 解析 pins.env / release.yml，回退到本地 pin（离线构建）"
            dyn_bpf_version=""; dyn_bpf_sha=""; dyn_zig_version=""
        fi
    else
        warn "无法从 ${raw} 拉取 pins.env / release.yml，回退到本地 pin（离线构建）"
    fi
    HONK_PINS_SOURCE="local-fallback"
    if [[ -n "$dyn_bpf_version" ]]; then
        HONK_PINS_SOURCE="upstream"
    fi

    HONK_ZIG_VERSION="${HONK_ZIG_VERSION:-${dyn_zig_version:-$HONK_FALLBACK_ZIG_VERSION}}"
    HONK_BPF_LINKER_VERSION="${HONK_BPF_LINKER_VERSION:-${dyn_bpf_version:-$HONK_FALLBACK_BPF_VERSION}}"

    # 上游 pins.env 只发布 x86_64 hash；aarch64 需显式提供，否则用本地保存值。
    if [[ -z "$HONK_BPF_LINKER_SHA256_X86_64" ]]; then
        if [[ "$HONK_PINS_SOURCE" == upstream && "$HONK_BPF_LINKER_VERSION" == "$dyn_bpf_version" ]]; then
            HONK_BPF_LINKER_SHA256_X86_64="$dyn_bpf_sha"
        else
            HONK_BPF_LINKER_SHA256_X86_64="$HONK_FALLBACK_BPF_SHA_X86"
        fi
    fi
    [[ -n "$HONK_BPF_LINKER_SHA256_AARCH64" ]] ||
        HONK_BPF_LINKER_SHA256_AARCH64="$HONK_FALLBACK_BPF_SHA_AARCH64"

    # zig 官方索引按版本 + 架构提供 hash；失败回退本地默认值，校验不降级。
    if [[ -n "$HONK_ZIG_SHA256_X86_64" && -n "$HONK_ZIG_SHA256_AARCH64" ]]; then
        HONK_ZIG_SHA_SOURCE="explicit"
    else
        HONK_ZIG_SHA_SOURCE="local-default"
        if curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
                -fsSL --retry 1 --connect-timeout 5 --max-time 20 \
                "$HONK_ZIG_INDEX_URL" -o "${tmp}/zig-index.json" 2>/dev/null; then
            resolve_zig_sha "$HONK_ZIG_VERSION" "${tmp}/zig-index.json" || true
        fi
    fi
    [[ -n "$HONK_ZIG_SHA256_X86_64" ]] || HONK_ZIG_SHA256_X86_64="$HONK_FALLBACK_ZIG_SHA_X86"
    [[ -n "$HONK_ZIG_SHA256_AARCH64" ]] || HONK_ZIG_SHA256_AARCH64="$HONK_FALLBACK_ZIG_SHA_AARCH64"

    log "honk 工具链版本来源：${HONK_PINS_SOURCE}（HONK_SRC_VERSION=${HONK_SRC_VERSION}，zig ${HONK_ZIG_VERSION} / bpf-linker ${HONK_BPF_LINKER_VERSION}）"
    log "honk zig sha256 来源：${HONK_ZIG_SHA_SOURCE}；下载后仍强制 sha256sum -c"
}

# 下载 zig tarball：从社区镜像优先尝试（官方 ziglang.org 在 CI 出口经常只有几十 KB/s，
# 49MB 包需要十几分钟且 --retry 会从头重下），镜像列表来自 zig 官方 community-mirrors.txt，
# 按实测速度排序，官网作为最后兜底。每个镜像下载后立即 sha256 校验，失败才换下一个。
# 用法：download_zig <version> <arch> <expected_sha256> <output_file>
download_zig() {
    local ver="$1" arch="$2" expected="$3" out="$4"
    local tarball="zig-${arch}-linux-${ver}.tar.xz"
    local mirrors=(
        "https://zigmirror.com/${tarball}"
        "https://zig.mirror.mschae23.de/zig/${tarball}"
        "https://pkg.earth/zig/${tarball}"
        "https://ziglang.org/download/${ver}/${tarball}"
    )
    local url
    for url in "${mirrors[@]}"; do
        log "尝试下载 zig：${url}"
        # 每个镜像独立限时 180s；下载完立刻校验，失败则删除残片换下一个镜像。
        if curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
            -fsSL --connect-timeout 15 --max-time 180 -o "$out" "$url" &&
           printf '%s  %s\n' "$expected" "$out" | sha256sum -c - >/dev/null 2>&1; then
            log "zig 下载并校验通过：${url}"
            return 0
        fi
        warn "镜像下载/校验失败：${url}"
        rm -f -- "$out"
    done
    return 1
}

install_honk_toolchain() {
    log "安装 honk 宿主机工具链（Rust / Zig ${HONK_ZIG_VERSION} / bpf-linker ${HONK_BPF_LINKER_VERSION}）"

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get -qq update
        sudo apt-get -qq install -y libbpf-dev cmake libclang-dev zstd \
            xz-utils pkg-config ca-certificates curl
    else
        warn "非 apt 系系统，跳过系统包安装；请自行保证 libbpf / clang / zstd / xz 已就绪"
    fi

    if ! command -v rustup >/dev/null 2>&1; then
        # 先下载到本地再执行：避免管道吞掉 curl 失败，也便于超时/重试。
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 \
            --connect-timeout 15 --max-time 120 -o "${TMP_WORK}/rustup-init.sh" \
            https://sh.rustup.rs || die "下载 rustup 安装脚本失败"
        sh "${TMP_WORK}/rustup-init.sh" -y --profile minimal || die "安装 rustup 失败"
    fi

    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        . "$HOME/.cargo/env"
    fi

    local tmp="${TMP_WORK}/honk-toolchain"
    mkdir -p -- "$tmp"

    # zig / bpf-linker 的资产名和 sha256 都随「宿主机」架构变（不是目标架构）。
    # 版本/hash 已由 resolve_honk_pins 动态解析并经 validate_honk_pins 校验。
    honk_host_info
    local host_arch="$HONK_HOST_ARCH" host_bpf_sha="$HONK_HOST_BPF_SHA" host_zig_sha="$HONK_HOST_ZIG_SHA"
    log "honk 工具链：宿主机架构 ${host_arch}（uname -m = $(uname -m)）"

    # bpf-linker：已装且「能跑」才跳过 —— 只看 command -v 会漏掉架构装错的情况
    if ! command -v bpf-linker >/dev/null 2>&1 ||
        ! bpf-linker --version >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 \
            --connect-timeout 15 --max-time 600 -o "$tmp/bpf-linker.tar.zst" \
            "https://github.com/aya-rs/bpf-linker/releases/download/v${HONK_BPF_LINKER_VERSION}/bpf-linker-${host_arch}-unknown-linux-musl.tar.zst" ||
            die "下载 bpf-linker 失败（宿主机 ${host_arch}）"
        printf '%s  %s\n' "$host_bpf_sha" "$tmp/bpf-linker.tar.zst" | sha256sum -c - ||
            die "bpf-linker sha256 校验失败（宿主机 ${host_arch}）"
        sudo tar --zstd -xf "$tmp/bpf-linker.tar.zst" -C /usr/local/bin ||
            die "解压 bpf-linker 失败"
    fi

    if ! command -v zig >/dev/null 2>&1 ||
        [[ "$(zig version 2>/dev/null)" != "$HONK_ZIG_VERSION" ]]; then
        download_zig "$HONK_ZIG_VERSION" "$host_arch" "$host_zig_sha" "$tmp/zig.tar.xz" ||
            die "下载 zig 失败（所有镜像均不可用，宿主机 ${host_arch}）"
        sudo tar -xJf "$tmp/zig.tar.xz" -C /usr/local || die "解压 zig 失败"
        sudo ln -sf "/usr/local/zig-${host_arch}-linux-${HONK_ZIG_VERSION}/zig" /usr/local/bin/zig
    fi

    # 收尾自检：两个工具都必须「能执行」，zig 版本还要精确匹配。
    # 架构装错时这里给出可读的错误，而不是等 honk 编译到一半才炸。
    local zig_ver
    zig_ver="$(zig version 2>/dev/null || true)"
    [[ -n "$zig_ver" ]] ||
        die "zig 无法执行（架构不匹配？宿主机 $(uname -m)，/usr/local/bin/zig -> $(readlink -f /usr/local/bin/zig 2>/dev/null || echo '?')）"
    [[ "$zig_ver" == "$HONK_ZIG_VERSION" ]] ||
        die "zig 版本不符：${zig_ver} != ${HONK_ZIG_VERSION}"
    bpf-linker --version >/dev/null 2>&1 ||
        die "bpf-linker 无法执行（架构不匹配？宿主机 $(uname -m)）"

    log "honk 工具链就绪：zig $(zig version) / bpf-linker $(bpf-linker --version 2>/dev/null | head -n 1) / $(cargo --version)"
}

ensure_honk_toolchain() {
    if ! honk_enabled; then
        log "未选中 honk（.config 里没有 CONFIG_PACKAGE_honk=y），跳过 honk 工具链"
        return 0
    fi

    # 动态解析优先（当前 HONK_SRC_VERSION → pins.env / release.yml / zig index），
    # 网络失败回退本地 pin；版本升级但 hash 未更新时 validate 明确失败。
    resolve_honk_pins
    validate_honk_pins

    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        . "$HOME/.cargo/env"
    fi

    # 逐项检查并记下具体原因：只说「缺少工具链」在 ARM 机器上根本定位不了问题
    # （装了错架构、rustup 没 source、PATH 里没有……表现都长一样）
    local why="" zig_ver=""

    if ! command -v cargo >/dev/null 2>&1; then
        why="${why}  - cargo 不在 PATH（rustup 已装但当前环境没 source ~/.cargo/env？）
"
    fi

    local bpf_out="" bpf_ver=""
    if ! command -v bpf-linker >/dev/null 2>&1; then
        why="${why}  - bpf-linker 未安装（PATH 里没有）
"
    elif ! bpf_out="$(bpf-linker --version 2>&1)"; then
        why="${why}  - bpf-linker 无法执行：$(command -v bpf-linker)
    原始回显：${bpf_out:-（无输出）}（架构装错？宿主机 $(uname -m)）
"
    else
        bpf_ver="$(printf '%s' "$bpf_out" | head -n 1)"
    fi

    local zig_out=""
    if ! command -v zig >/dev/null 2>&1; then
        why="${why}  - zig 未安装（PATH 里没有）
"
    elif ! zig_out="$(zig version 2>&1)"; then
        why="${why}  - zig 无法执行：$(command -v zig)
    原始回显：${zig_out:-（无输出）}（架构装错？宿主机 $(uname -m)）
"
    elif [[ "$zig_out" != "$HONK_ZIG_VERSION" ]]; then
        why="${why}  - zig 版本不符：${zig_out}（需要 ${HONK_ZIG_VERSION}，路径 $(command -v zig)）
"
    fi

    if [[ -z "$why" ]]; then
        zig_ver="$zig_out"
        log "honk 工具链已就绪：zig ${zig_ver} / ${bpf_ver} / $(cargo --version 2>/dev/null)"
        return 0
    fi

    local auto="$HONK_TOOLCHAIN_AUTO"
    if [[ -z "$auto" ]]; then
        if [[ -n "${GITHUB_ACTIONS:-}" ]] || sudo -n true 2>/dev/null; then
            auto=1
        else
            auto=0
        fi
    fi

    if [[ "$auto" != "1" ]]; then
        warn "选中了 honk，但宿主机工具链不完整："
        printf '%s' "$why" >&2
        if [[ -z "$HONK_TOOLCHAIN_AUTO" ]]; then
            printf '  （自动安装已跳过：非 CI 环境，且 sudo 需要密码；\n' >&2
            printf '   加 HONK_TOOLCHAIN_AUTO=1 让脚本自己装，或先 sudo -v 刷新凭据后重跑）\n' >&2
        else
            printf '  （HONK_TOOLCHAIN_AUTO=%s，已按设置跳过自动安装；设为 1 可让脚本自己装）\n' "$HONK_TOOLCHAIN_AUTO" >&2
        fi
        honk_host_info
        cat >&2 <<EOF
请手动安装（详见 openwrt-suite README「宿主机依赖（honk 核心专用）」）：
  当前解析结果（来源：${HONK_PINS_SOURCE} / zig sha：${HONK_ZIG_SHA_SOURCE}）：
  zig ${HONK_ZIG_VERSION} / bpf-linker ${HONK_BPF_LINKER_VERSION} / 宿主机架构 ${HONK_HOST_ARCH}
  sudo apt-get install -y libbpf-dev cmake libclang-dev zstd xz-utils pkg-config
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh && sh /tmp/rustup-init.sh -y --profile minimal
  curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/bpf-linker.tar.zst "https://github.com/aya-rs/bpf-linker/releases/download/v${HONK_BPF_LINKER_VERSION}/bpf-linker-${HONK_HOST_ARCH}-unknown-linux-musl.tar.zst"
  echo "${HONK_HOST_BPF_SHA}  /tmp/bpf-linker.tar.zst" | sha256sum -c -
  sudo tar --zstd -xf /tmp/bpf-linker.tar.zst -C /usr/local/bin
  curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/zig.tar.xz "https://zigmirror.com/zig-${HONK_HOST_ARCH}-linux-${HONK_ZIG_VERSION}.tar.xz"  # 社区镜像；官方源太慢
  echo "${HONK_HOST_ZIG_SHA}  /tmp/zig.tar.xz" | sha256sum -c -
  sudo tar -xJf /tmp/zig.tar.xz -C /usr/local
  sudo ln -sf "/usr/local/zig-${HONK_HOST_ARCH}-linux-${HONK_ZIG_VERSION}/zig" /usr/local/bin/zig
或设 HONK_TOOLCHAIN_AUTO=1 让本脚本自动安装（需要 sudo）。
EOF
        die "缺少 honk 构建工具链"
    fi

    install_honk_toolchain
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

        # 用数组遍历，避免裸 $failed 的 glob 展开 / 额外分词
        local -a failed_pkgs=()
        IFS=' ' read -r -a failed_pkgs <<< "$failed"
        for pkg in "${failed_pkgs[@]}"; do
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

    local notes="${TMP_WORK}/release-notes.txt"
    {
        echo "Build Time: $(TZ=Asia/Shanghai date)"
        echo "OpenWrt Commit: $(git rev-parse HEAD)"
        echo "Toolchain Key: ${TOOLCHAIN_KEY:-unknown}"
        echo "Source Date Epoch: ${SOURCE_DATE_EPOCH:-unset}"
    } > "$notes"
    mv -f -- "$notes" "$dir/release-notes.txt" || die "写入 release-notes.txt 失败"

    log "发布资产已收集到：$dir"
}

usage() {
    cat <<'EOF'
用法: compile.sh [-j N|--jobs N] [-h|--help]
环境变量: WORKDIR OPENWRT_REPO CONFIG_URL RELEASE_DIR JOBS REFRESH_CONFIG
          SKIP_UPDATE SKIP_DOWNLOAD SKIP_BUILD GO_AMD64_LEVEL TARGET_SUBDIR
          KERNEL_CONFIG CLEAN_KERNEL CLEAN_GOLANG SINGLE_JOB_RETRY TOOLCHAIN_KEY
          SOURCE_DATE_EPOCH HONK_TOOLCHAIN_AUTO HONK_ZIG_VERSION
          HONK_ZIG_SHA256_X86_64 HONK_ZIG_SHA256_AARCH64
          HONK_BPF_LINKER_VERSION HONK_BPF_LINKER_SHA256_X86_64
          HONK_BPF_LINKER_SHA256_AARCH64
          HONK_SRC_URL HONK_SRC_VERSION HONK_ZIG_INDEX_URL
          （ honk 工具链未显式指定时按 HONK_SRC_VERSION 动态解析，失败回退本地 pin ）
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
    acquire_lock
    set_source_date_epoch
    configure_feeds
    update_feeds
    stage_photondns_cargo
    fix_rust_llvm
    fix_golang_amd64
    replace_v2ray_geodata
    install_extra_repos
    prepare_config
    ensure_honk_toolchain
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