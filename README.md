# OpenWrt-ScriptBuild

基于 OpenWrt 官方 `main` 分支的 x86-64 固件构建仓库。全部构建逻辑集中在一个 `compile.sh` 脚本里：克隆源码、配置 feeds、写入配置、下载、编译、收集产物一气呵成，本地与 GitHub Actions 共用同一个入口。仓库根目录的 `.config` 由使用者自行维护，构建脚本不会改写它。

<a id="build"></a>

## 编译固件

NetForgeCN 提供三套 OpenWrt x86-64 固件构建仓库，编译入口不同，产物都是固件 Release。三份 `.config` 由使用者自行维护，构建脚本不会改写它。

| 仓库 | 编译方式 | 编译入口 |
|---|---|---|
| [openwrt-suite](https://github.com/NetForgeCN/openwrt-suite#build) | 聚合 feed + 一键脚本 | `build/compile.sh`、`build.yml` |
| [OpenWRT](https://github.com/NetForgeCN/OpenWRT#build) | GitHub Actions 分步编排 | `OpenWRT.yml` + `diy-part1.sh` / `diy-part2.sh` |
| [OpenWrt-ScriptBuild](https://github.com/NetForgeCN/OpenWrt-ScriptBuild#build) | 单脚本全流程 | `compile.sh`、`build.yml` |

三个仓库的完整编译说明见各自 README 的「编译固件」章节（上表链接）。

### 本仓库：单脚本本地构建

在任意目录直接运行即可，脚本会自行克隆 OpenWrt 源码到 `WORKDIR`：

```bash
git clone https://github.com/NetForgeCN/OpenWrt-ScriptBuild.git
cd OpenWrt-ScriptBuild
./compile.sh
```

命令行选项：

```
用法: compile.sh [-j N|--jobs N] [-h|--help]
  -j, --jobs N   指定并行编译任务数（默认自动探测 CPU 核心数）
  -h, --help     显示帮助
```

全部行为可用环境变量覆盖：

| 变量 | 默认值 / 说明 |
|---|---|
| `WORKDIR` | OpenWrt 源码目录（默认 `$HOME/openwrt`） |
| `OPENWRT_REPO` | OpenWrt 主仓库地址 |
| `CONFIG_URL` | 构建用的 `.config`（默认取本仓库根目录的 `.config`） |
| `RELEASE_DIR` | 产物收集目录 |
| `JOBS` | 并行任务数 |
| `REFRESH_CONFIG` | `1` = 用 `CONFIG_URL` 覆盖本地已有 `.config` |
| `GO_AMD64_LEVEL` | GOAMD64 微架构级别（默认 `v3`，可选 v1/v2/v3/v4） |
| `TARGET_SUBDIR` / `KERNEL_CONFIG` | 目标子目录与内核配置文件 |
| `CLEAN_KERNEL` / `CLEAN_GOLANG` | 内核配置或 golang 版本变更后是否清理重建（默认 `auto`） |
| `SINGLE_JOB_RETRY` | 全量编译失败后是否按失败包单线程重试 |
| `SKIP_UPDATE` / `SKIP_DOWNLOAD` / `SKIP_BUILD` | 分别跳过源码更新 / `make download` / 编译 |
| `SOURCE_DATE_EPOCH` | 可复现构建时间戳（默认取 OpenWrt HEAD 提交时间） |
| `HONK_TOOLCHAIN_AUTO` / `HONK_ZIG_VERSION` / `HONK_BPF_LINKER_VERSION` | honk 核心所需的宿主机工具链 |
| `HONK_ZIG_SHA256_X86_64` / `HONK_ZIG_SHA256_AARCH64` | zig 资产校验值（默认钉住官方 0.14.1；升级版本时必须同步更新） |
| `HONK_BPF_LINKER_SHA256_X86_64` / `HONK_BPF_LINKER_SHA256_AARCH64` | bpf-linker 资产校验值（兼容旧变量 `HONK_BPF_LINKER_SHA256`） |

脚本内部依次完成：配置第三方 feeds → `feeds update/install -a`（失败有限重试） → Rust / golang / 内核配置补丁 → 写入 `.config` + `make defconfig` → 按需安装 honk 宿主机工具链 → `make download` → 编译 → 收集固件与构建说明到 `RELEASE_DIR`。所有步骤幂等，可重复执行。

安全与可复现性：feeds.conf / `.config` / 内核配置等改动采用「同目录临时文件 + `mv`」原子替换，写入前备份、失败回滚，并拒绝通过符号链接写入；`CONFIG_URL` 只接受 https 或本地文件；feeds / 克隆 / 下载均有限重试；honk 的 zig 与 bpf-linker 资产下载后强制校验 SHA256（zig 校验值取自 ziglang.org 官方索引）；`SOURCE_DATE_EPOCH` 默认取 OpenWrt HEAD 的提交时间。workflow 中的 Actions 全部钉到 commit SHA，清理 Release 时永不删除 `backup-*` 不可变备份。

### 本仓库：GitHub Actions 构建

`.github/workflows/build.yml` 支持两种触发方式：

- 手动：仓库页 → Actions → **OpenWrt Script Build** → Run workflow；
- 自动：以 `repository_dispatch` 接收外部派发。

workflow 负责初始化宿主机依赖、克隆 OpenWrt 源码、恢复 dl / 工具链 / ccache 缓存，随后直接调用 `./compile.sh` 完成构建，产物上传到 `firmware-x86-64` artifact 并发布固件 Release（保留最近 7 个）。失败时会额外上传构建日志 artifact。构建使用 `ubuntu-26.04` runner，单次超时 360 分钟，同一 workflow 的构建排队执行不取消。

## 第三方组件与配置

- **第三方 feeds**：`compile.sh` 内的 `FEEDS` 数组。
- **额外克隆仓库**：`compile.sh` 内的 `EXTRA_REPOS` 数组，用于根目录即包目录、不通过 feed 提供的包（hevsocks5、oxidns、lucky、argon 等）。
- **v2ray-geodata**：删除官方同名包源与链接后，克隆 `NetForgeCN/Loyalsoldier` 到 `package/v2ray-geodata`，数据取自自建规则仓库 `NetForgeCN/v2ray-rules-dat`。
- **.config**：仓库根目录，由使用者自行维护。

## 许可证

本仓库以 **MIT** 授权，见 [LICENSE](LICENSE)。构建时拉取的第三方组件按各自的许可证分发。
