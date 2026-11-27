#!/usr/bin/env bash
# Resolve the host toolchain pins for the honk commit pinned by the package Makefile.
#
#   ./honk/honk_toolchain.sh [--src DIR] [Makefile]
#   ./honk/honk_toolchain.sh --check     # 只校验 env 里的版本/hash，不联网
#
# 输出（stdout 只有 KEY=value，便于 eval 或写入 GITHUB_ENV）：
#   HONK_SRC_URL / HONK_SRC_VERSION / ZIG_VERSION / BPF_LINKER_VERSION
#   BPF_LINKER_SHA256 / HONK_BPF_LINKER_SHA256_X86_64 / ..._AARCH64
#   HONK_ZIG_SHA256_X86_64 / HONK_ZIG_SHA256_AARCH64
#   HONK_PINS_SOURCE / HONK_ZIG_SHA_SOURCE（upstream / local-fallback 等）
#
# 优先级：显式环境变量 > 上游 pins.env / release.yml > 本地保存的 pin。
# 网络失败、解析失败、Makefile 缺失都回退到本地 pin（离线构建可用）；
# zig 资产 hash 从 ziglang.org/download/index.json 按 ZIG_VERSION 与架构读取。
# 日志一律走 stderr，避免污染 eval。
set -euo pipefail
export LC_ALL=C LANG=C

# 本地回退 pin：与当前 HONK_SRC_VERSION 对应，离线时保证本地编译可继续。
FALLBACK_SRC_URL="https://github.com/daeuniverse/honk.git"
FALLBACK_SRC_VERSION="00be4f01309ecf7620be01f0398e875295e9b942"
FALLBACK_ZIG_VERSION="0.14.1"
FALLBACK_BPF_VERSION="0.11.0"
FALLBACK_BPF_SHA_X86="10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450"
FALLBACK_BPF_SHA_AARCH64="d09ddd83303e9ab1443f51e0e284680154009646a3ce141c63d838ee61b73eb9"
FALLBACK_ZIG_SHA_X86="24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c"
FALLBACK_ZIG_SHA_AARCH64="f7a654acc967864f7a050ddacfaa778c7504a0eca8d2b678839c21eea47c992b"

ZIG_INDEX_URL="${HONK_ZIG_INDEX_URL:-https://ziglang.org/download/index.json}"

log() { printf 'honk_toolchain: %s\n' "$*" >&2; }
valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_sha() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
valid_revision() { [[ "$1" =~ ^[0-9a-f]{7,40}$ ]]; }
valid_src_url() { [[ "$1" == https://github.com/* ]]; }

# guard：版本升级但 hash 仍是本地旧默认值时 fail closed（与 compile.sh / workflow 一致）。
check_pins() {
  local zig="$1" bpf="$2" zx="$3" za="$4" bx="$5" ba="$6" host
  valid_version "$zig" || { echo "ERROR: ZIG_VERSION 格式不合法：$zig" >&2; return 1; }
  valid_version "$bpf" || { echo "ERROR: BPF_LINKER_VERSION 格式不合法：$bpf" >&2; return 1; }
  local h
  for h in "$zx" "$za" "$bx" "$ba"; do
    valid_sha "$h" || { echo "ERROR: 工具链 sha256 必须是 64 位小写十六进制：$h" >&2; return 1; }
  done

  host="$(uname -m)"
  case "$host" in
    x86_64|amd64)
      if [[ "$zig" != "$FALLBACK_ZIG_VERSION" && "$zx" == "$FALLBACK_ZIG_SHA_X86" ]]; then
        echo "ERROR: zig 版本已升级到 ${zig}，但 x86_64 sha256 仍是本地旧默认值 ${zx}。" >&2
        echo "       请确认 ziglang.org/download/index.json 解析成功，或显式设置 HONK_ZIG_SHA256_X86_64。" >&2
        return 1
      fi
      if [[ "$bpf" != "$FALLBACK_BPF_VERSION" && "$bx" == "$FALLBACK_BPF_SHA_X86" ]]; then
        echo "ERROR: bpf-linker 版本已升级到 ${bpf}，但 x86_64 sha256 仍是本地旧默认值 ${bx}。" >&2
        echo "       请确认上游 pins.env 解析成功，或显式设置 HONK_BPF_LINKER_SHA256_X86_64。" >&2
        return 1
      fi
      ;;
    aarch64|arm64)
      if [[ "$zig" != "$FALLBACK_ZIG_VERSION" && "$za" == "$FALLBACK_ZIG_SHA_AARCH64" ]]; then
        echo "ERROR: zig 版本已升级到 ${zig}，但 aarch64 sha256 仍是本地旧默认值 ${za}。" >&2
        echo "       请确认 ziglang.org/download/index.json 解析成功，或显式设置 HONK_ZIG_SHA256_AARCH64。" >&2
        return 1
      fi
      if [[ "$bpf" != "$FALLBACK_BPF_VERSION" && "$ba" == "$FALLBACK_BPF_SHA_AARCH64" ]]; then
        echo "ERROR: bpf-linker 版本已升级到 ${bpf}，但 aarch64 sha256 仍是本地旧默认值 ${ba}。" >&2
        echo "       上游 pins.env 只发布 x86_64 hash，aarch64 请显式设置 HONK_BPF_LINKER_SHA256_AARCH64。" >&2
        return 1
      fi
      ;;
    *)
      # 未知架构：两边都查，避免把未校验的资产装上去。
      if [[ "$zig" != "$FALLBACK_ZIG_VERSION" ]] &&
         [[ "$zx" == "$FALLBACK_ZIG_SHA_X86" || "$za" == "$FALLBACK_ZIG_SHA_AARCH64" ]]; then
        echo "ERROR: zig 版本已升级到 ${zig}，但 sha256 仍是本地旧默认值；请显式设置 HONK_ZIG_SHA256_*。" >&2
        return 1
      fi
      if [[ "$bpf" != "$FALLBACK_BPF_VERSION" ]] &&
         [[ "$bx" == "$FALLBACK_BPF_SHA_X86" || "$ba" == "$FALLBACK_BPF_SHA_AARCH64" ]]; then
        echo "ERROR: bpf-linker 版本已升级到 ${bpf}，但 sha256 仍是本地旧默认值；请显式设置 HONK_BPF_LINKER_SHA256_*。" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

if [[ "${1:-}" == "--check" ]]; then
  # 兼容本脚本输出的非 HONK_ 前缀变量名（workflow / compile.sh 用它做 guard）。
  HONK_ZIG_VERSION="${HONK_ZIG_VERSION:-${ZIG_VERSION:-}}"
  HONK_BPF_LINKER_VERSION="${HONK_BPF_LINKER_VERSION:-${BPF_LINKER_VERSION:-}}"
  HONK_BPF_LINKER_SHA256_X86_64="${HONK_BPF_LINKER_SHA256_X86_64:-${BPF_LINKER_SHA256_X86_64:-${BPF_LINKER_SHA256:-}}}"
  HONK_BPF_LINKER_SHA256_AARCH64="${HONK_BPF_LINKER_SHA256_AARCH64:-${BPF_LINKER_SHA256_AARCH64:-}}"
  check_pins \
    "${HONK_ZIG_VERSION:-$FALLBACK_ZIG_VERSION}" \
    "${HONK_BPF_LINKER_VERSION:-$FALLBACK_BPF_VERSION}" \
    "${HONK_ZIG_SHA256_X86_64:-$FALLBACK_ZIG_SHA_X86}" \
    "${HONK_ZIG_SHA256_AARCH64:-$FALLBACK_ZIG_SHA_AARCH64}" \
    "${HONK_BPF_LINKER_SHA256_X86_64:-$FALLBACK_BPF_SHA_X86}" \
    "${HONK_BPF_LINKER_SHA256_AARCH64:-$FALLBACK_BPF_SHA_AARCH64}"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC_DIR=""
MAKEFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC_DIR="${2:?--src needs a directory}"; shift 2 ;;
    *) MAKEFILE="$1"; shift ;;
  esac
done
MAKEFILE="${MAKEFILE:-${HONK_MAKEFILE:-$SCRIPT_DIR/Makefile}}"

URL="${HONK_SRC_URL:-}"
REV="${HONK_SRC_VERSION:-}"
if [[ -f "$MAKEFILE" ]]; then
  m_url="$(sed -n 's/^[[:space:]]*HONK_SRC_URL[[:space:]]*:=[[:space:]]*//p' "$MAKEFILE" | head -n 1)"
  m_rev="$(sed -n 's/^[[:space:]]*HONK_SRC_VERSION[[:space:]]*:=[[:space:]]*//p' "$MAKEFILE" | head -n 1)"
  [[ -n "$URL" ]] || URL="$m_url"
  [[ -n "$REV" ]] || REV="$m_rev"
else
  log "Makefile 不存在（$MAKEFILE），使用本地 pin"
fi
if ! valid_src_url "$URL"; then
  log "HONK_SRC_URL 无效或缺失（$URL），使用本地 pin：$FALLBACK_SRC_URL"
  URL="$FALLBACK_SRC_URL"
fi
if ! valid_revision "$REV"; then
  log "HONK_SRC_VERSION 无效或缺失（$REV），使用本地 pin：$FALLBACK_SRC_VERSION"
  REV="$FALLBACK_SRC_VERSION"
fi

PINS_SOURCE="local-fallback"
DYN_BPF_VERSION=""
DYN_BPF_SHA=""
DYN_ZIG_VERSION=""

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/honk-toolchain.XXXXXX")"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

fetch_file() {
  # 返回 0/1，交给调用方决定回退；超时+有限重试保证离线机器不会长时间卡住。
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
    -fsSL --retry 1 --connect-timeout 5 --max-time 20 "$1" -o "$2" >/dev/null 2>&1
}

read_pins() {
  local pins="$1" release="$2"
  local v s z
  v="$(sed -n 's/^[[:space:]]*BPF_LINKER_VERSION[[:space:]]*=[[:space:]]*//p' "$pins" | head -n 1 | tr -d '\r\"')"
  s="$(sed -n 's/^[[:space:]]*BPF_LINKER_SHA256[[:space:]]*=[[:space:]]*//p' "$pins" | head -n 1 | tr -d '\r\"')"
  z="$(awk '
    /setup-zig/ { seen = 1; next }
    seen && /^[[:space:]]*version:[[:space:]]*/ {
      sub(/^[[:space:]]*version:[[:space:]]*/, "")
      gsub(/[[:space:]"]/, "")
      sub(/\r$/, "")
      print
      exit
    }
  ' "$release")"
  # 上游 honk 自 2026-11 起移除了 release.yml 里的 setup-zig pin
  # （ZIG_VERSION 改为 latest），因此 zig 版本经常抓不到。bpf-linker 的
  # pin 仍在 pins.env 里，值得单独采用；zig 版本缺失时留给本地 pin。
  valid_version "$v" && valid_sha "$s" || return 1
  DYN_BPF_VERSION="$v"
  DYN_BPF_SHA="$s"
  if valid_version "$z"; then
    DYN_ZIG_VERSION="$z"
  else
    log "上游 release.yml 无 setup-zig pin（zig 已改为 latest），zig 版本用本地 pin"
  fi
}

if [[ -n "$SRC_DIR" && -f "$SRC_DIR/.github/ci/pins.env" && -f "$SRC_DIR/.github/workflows/release.yml" ]]; then
  if read_pins "$SRC_DIR/.github/ci/pins.env" "$SRC_DIR/.github/workflows/release.yml"; then
    PINS_SOURCE="local-checkout"
  else
    log "本地 checkout 的 pins.env / release.yml 解析失败，回退到本地 pin"
  fi
elif [[ -n "$SRC_DIR" ]]; then
  log "$SRC_DIR 不是完整的 honk checkout，回退到本地 pin"
else
  REPO_PATH="${URL#https://github.com/}"
  REPO_PATH="${REPO_PATH%.git}"
  RAW="https://raw.githubusercontent.com/${REPO_PATH}/${REV}"
  if fetch_file "${RAW}/.github/ci/pins.env" "$TMP_DIR/pins.env" &&
     fetch_file "${RAW}/.github/workflows/release.yml" "$TMP_DIR/release.yml" &&
     read_pins "$TMP_DIR/pins.env" "$TMP_DIR/release.yml"; then
    PINS_SOURCE="upstream"
  else
    log "无法从 ${RAW} 动态解析 pins.env / release.yml，回退到本地 pin（离线构建）"
  fi
fi

ZIG_VERSION="${HONK_ZIG_VERSION:-${DYN_ZIG_VERSION:-$FALLBACK_ZIG_VERSION}}"
BPF_VERSION="${HONK_BPF_LINKER_VERSION:-${DYN_BPF_VERSION:-$FALLBACK_BPF_VERSION}}"

# bpf-linker：上游 pins.env 只给一个 x86_64 hash；aarch64 需显式提供，否则回退本地值。
BX="${HONK_BPF_LINKER_SHA256_X86_64:-${HONK_BPF_LINKER_SHA256:-}}"
BA="${HONK_BPF_LINKER_SHA256_AARCH64:-}"
if [[ -z "$BX" ]]; then
  if [[ "$PINS_SOURCE" == upstream || "$PINS_SOURCE" == local-checkout ]] &&
     [[ "$BPF_VERSION" == "$DYN_BPF_VERSION" ]]; then
    BX="$DYN_BPF_SHA"
  else
    BX="$FALLBACK_BPF_SHA_X86"
  fi
fi
[[ -n "$BA" ]] || BA="$FALLBACK_BPF_SHA_AARCH64"

# zig：上游不发布资产 hash，从官方 index.json 按 ZIG_VERSION + 宿主机架构平台读取。
ZX="${HONK_ZIG_SHA256_X86_64:-}"
ZA="${HONK_ZIG_SHA256_AARCH64:-}"
ZIG_SHA_SOURCE="local-default"
if [[ -n "$ZX" && -n "$ZA" ]]; then
  ZIG_SHA_SOURCE="explicit"
elif command -v python3 >/dev/null 2>&1 &&
     fetch_file "$ZIG_INDEX_URL" "$TMP_DIR/zig-index.json"; then
  parsed=""
  if parsed="$(python3 - "$TMP_DIR/zig-index.json" "$ZIG_VERSION" <<'PY'
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
)"; then
    while IFS='=' read -r key value; do
      case "$key" in
        HONK_ZIG_SHA_X86_64) [[ -n "$ZX" ]] || ZX="$value" ;;
        HONK_ZIG_SHA_AARCH64) [[ -n "$ZA" ]] || ZA="$value" ;;
      esac
    done <<< "$parsed"
    if valid_sha "$ZX" && valid_sha "$ZA"; then
      ZIG_SHA_SOURCE="zig-index"
    else
      ZX=""; ZA=""
    fi
  fi
fi
[[ -n "$ZX" ]] || ZX="$FALLBACK_ZIG_SHA_X86"
[[ -n "$ZA" ]] || ZA="$FALLBACK_ZIG_SHA_AARCH64"

check_pins "$ZIG_VERSION" "$BPF_VERSION" "$ZX" "$ZA" "$BX" "$BA" || exit 1

log "HONK_SRC_VERSION=${REV}；版本来源=${PINS_SOURCE}（zig ${ZIG_VERSION} / bpf-linker ${BPF_VERSION}）"
log "zig sha256 来源=${ZIG_SHA_SOURCE}；bpf-linker x86_64 sha256 来源=${PINS_SOURCE}"

printf 'HONK_SRC_URL=%s\n' "$URL"
printf 'HONK_SRC_VERSION=%s\n' "$REV"
printf 'BPF_LINKER_VERSION=%s\n' "$BPF_VERSION"
printf 'BPF_LINKER_SHA256=%s\n' "$BX"
printf 'ZIG_VERSION=%s\n' "$ZIG_VERSION"
printf 'HONK_BPF_LINKER_SHA256_X86_64=%s\n' "$BX"
printf 'HONK_BPF_LINKER_SHA256_AARCH64=%s\n' "$BA"
printf 'HONK_ZIG_SHA256_X86_64=%s\n' "$ZX"
printf 'HONK_ZIG_SHA256_AARCH64=%s\n' "$ZA"
printf 'HONK_PINS_SOURCE=%s\n' "$PINS_SOURCE"
printf 'HONK_ZIG_SHA_SOURCE=%s\n' "$ZIG_SHA_SOURCE"
