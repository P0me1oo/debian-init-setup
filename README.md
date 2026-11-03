# Debian 初始化脚本

面向 Debian 服务器的模块化初始化脚本，支持推荐、精简、完整和自定义模式。

- 当前版本：`4.1.0`
- 主脚本：`init_setup.sh`
- 版本记录：[CHANGELOG.md](CHANGELOG.md)

## 支持的模块

| 模块 | 作用 |
| --- | --- |
| `update` | 更新系统软件包并执行升级 |
| `kernel` | 升级到当前软件源提供的最新 Linux 内核，不自动重启 |
| `tools` | 安装 curl、wget、git、openssh-server、iproute2、sudo 和 iperf3 |
| `nexttrace-mtr` | 安装 NextTrace 和 mtr |
| `bbr` | 配置 BBR + fq |
| `ssh` | 配置 SSH 端口、密钥登录和密码登录策略 |
| `ufw` | 启用 UFW，只放行确认过的 SSH 端口 |
| `fail2ban` | 安装并启用 Fail2ban，保护 SSH |
| `journald` | 限制 systemd journal 日志大小 |
| `timezone` | 设置时区并安装启用 chrony |
| `ipv6-dns` | 只移除 DNS 配置中的 IPv6 nameserver，保留 IPv6 联网能力；兼容旧模块名 `ipv6` |
| `docker` | 安装 Docker Engine、Buildx 和 Compose 插件 |

脚本不负责配置 ZRAM、swapfile 或 htop。

## Linux 内核升级

推荐、精简和完整模式默认启用内核升级；交互式自定义模式也默认开启。每次运行都会获取当前 Debian 发行版软件源提供的最新内核，不固定到某个漏洞的修复版本。普通软件包升级可能跳过需要新增依赖的内核更新，因此此模块会单独安装或更新内核跟踪包及其依赖。

保留云内核、实时内核等现有类型，使用不限定内核系列的跟踪包；例如已安装的 `linux-image-6.1-amd64` 会改用 `linux-image-amd64` 跟踪当前软件源的最新系列。没有跟踪包时，按当前运行的 Debian 内核类型补装，例如 AMD64 的 `linux-image-amd64`、云内核的 `linux-image-cloud-amd64` 和 ARM64 的 `linux-image-arm64`。遵循现有软件源和版本锁定设置，保留已有内核；依赖冲突需要移除软件包时停止。

这里的“最新”以当前发行版已配置软件源的候选版本为准，不额外引入第三方内核源或切换到 kernel.org 主线。若自行设置了版本锁定或软件源优先级，仍需先解除相应限制才能获取更新。

脚本不会自动重启服务器。执行结束时会提示自行安排重启；即使后续模块失败，已完成内核安装时仍会显示提示。重启后用 `uname -r` 确认实际运行的内核。

CVE-2026-98432 的修复需要软件源提供包含补丁的内核，并在重启后运行该内核。安装步骤完成不代表漏洞已修复；应同时对照 [Debian 漏洞跟踪记录](https://security-tracker.debian.org/tracker/CVE-2026-98432) 核对内核软件包版本。请确保当前 Debian 版本对应的安全更新源已启用。

单独升级内核：

```bash
bash init_setup.sh --yes --mode custom --enable kernel
```

跳过内核升级可使用 `--disable kernel`、`--no-kernel-upgrade` 或环境变量 `ENABLE_KERNEL_UPGRADE=no`。此开关只控制独立内核模块，常规系统更新仍可能更新已安装的内核软件包。

共用宿主机内核的容器会停止此模块，需在宿主机上升级；无法识别且未安装 Debian 内核跟踪包的第三方内核也会报错，避免切换内核类型。

## 只移除 IPv6 DNS

`ipv6-dns` 模块只移除 IPv6 DNS 服务器地址，保留 IPv4 DNS。IPv6 接口开关、地址、路由、系统参数、GRUB 和 UFW 的 IPv6 支持均保持原样。通过 IPv4 DNS 仍可查询域名的 IPv6 地址（AAAA 记录），因此程序仍能使用 IPv6 联网；此模块不设置 IPv4 访问优先级。

只执行 DNS 修改，以 root 身份运行：

```bash
bash init_setup.sh --yes --mode custom --enable ipv6-dns
```

推荐和精简模式默认跳过此模块，完整模式默认启用。处理的文件：

| 文件 | 处理的配置项 |
| --- | --- |
| `/etc/systemd/resolved.conf`、`/etc/systemd/resolved.conf.d/*.conf` | `DNS=`、`FallbackDNS=` |
| `/etc/systemd/network/*.network`、`/etc/systemd/network/*.network.d/*.conf` | `DNS=` |
| `/etc/resolvconf/resolv.conf.d/head`、`base`、`tail` | `nameserver` |
| `/etc/network/interfaces`、`/etc/network/interfaces.d/*` | `dns-nameservers`、`dns-nameserver` |
| `/etc/resolv.conf` | `nameserver` |

- 只改动 DNS 服务器地址，同一文件里的地址、网关、`search`、`options` 和注释行保持原样。`1.1.1.1:53`、`1.1.1.1#cloudflare-dns.com` 这类带端口或 DoT 名称的 IPv4 写法会被保留。
- 一行里的地址全是 IPv6 时，`DNS=` 和 `FallbackDNS=` 保留键名写成空值（systemd 视为清空该列表），`dns-nameservers` 整行删除。
- 改完上游配置后会执行 `resolvconf -u`、`networkctl reload` 和重启 `systemd-resolved`（仅在对应命令存在且服务在运行时），让 `/etc/resolv.conf` 重新生成。`/etc/resolv.conf` 是符号链接时不直接改写，交由生成它的服务处理。
- 修改前检查 `/etc/resolv.conf` 是否配置了 IPv4 DNS；使用 systemd-resolved 的本地解析地址时，通过 `resolvectl dns` 检查上游。没有 IPv4 DNS 或无法读取上游时停止，保留原配置，不自动添加公共 DNS。此检查不验证 DNS 服务器的外网连通性。
- 不覆盖 NetworkManager 连接配置和 DHCP 客户端的 `supersede` 设置。这些来源可能重新下发 IPv6 DNS；检查发现 `/etc/resolv.conf` 仍有 IPv6 nameserver 时会告警，需要在对应网络服务中处理。
- 执行 `--restore-ipv6-dns` 可单独恢复原 DNS 配置，无需重启服务器。

## 运行前提

- Debian 系统；
- 以 root 身份运行；
- systemd 正常运行；
- 网络可以访问 Debian 软件源及脚本使用的第三方软件源；
- 远程运行前确认当前 SSH 连接不会因为端口或防火墙设置而中断。

脚本会在修改系统前检查系统版本、必要命令、systemd 和根分区可用空间。

## 本地运行

```bash
chmod +x init_setup.sh
bash init_setup.sh
```

直接运行会显示模式菜单。也可以指定模式：

```bash
bash init_setup.sh --mode recommended
bash init_setup.sh --mode minimal
bash init_setup.sh --mode full
bash init_setup.sh --mode custom
```

## 在线下载并保留交互菜单

以 root 身份在终端中执行，下载完成后会显示推荐、精简、完整、自定义四种模式的菜单：

```bash
curl -fsSL https://raw.githubusercontent.com/P0me1oo/debian-init-setup/main/init_setup.sh -o /tmp/init.sh && bash /tmp/init.sh --interactive
```

## 三种预设模式

### 推荐模式

默认启用：

```text
update, kernel, tools, nexttrace-mtr, bbr, ssh, ufw,
fail2ban, journald, timezone
```

默认跳过：移除 IPv6 DNS、安装 Docker。

```bash
bash init_setup.sh --yes --mode recommended
```

### 精简模式

默认启用：

```text
update, kernel, bbr, ssh, ufw, journald, timezone
```

默认跳过：安装常用工具、安装 NextTrace 和 mtr、启用 Fail2ban、移除 IPv6 DNS、安装 Docker。

```bash
bash init_setup.sh --yes --mode minimal
```

### 完整模式

默认启用：全部模块。

```bash
bash init_setup.sh --yes --mode full
```

Docker 模块检测到已有 Docker、Podman、containerd 命令或相关软件包时会停止，包括通过 Docker 官方软件源安装的版本。确认需要替换时使用：

```bash
bash init_setup.sh --yes --mode full --replace-existing-runtime
```

## 自定义模式

交互式自定义默认开启全部模块，提示 `[Y/n]`。直接回车保持开启，输入 `n` 关闭该项：

```bash
bash init_setup.sh --interactive --mode custom
```

无人值守运行示例（`custom` 默认全部关闭，再通过 `--enable` 指定模块）：

```bash
bash init_setup.sh --yes --mode recommended --disable fail2ban,nexttrace-mtr
bash init_setup.sh --yes --mode minimal --enable tools
bash init_setup.sh --yes --mode custom --enable update,kernel,bbr,ssh,ufw,journald,timezone
```

可用模块名：

```text
update kernel tools nexttrace-mtr bbr ssh ufw fail2ban journald timezone ipv6-dns docker all
```

旧模块名 `ipv6`、`disable-ipv6` 现在也只执行 DNS 修改。新环境变量为 `ENABLE_IPV6_DNS`，兼容旧变量 `ENABLE_DISABLE_IPV6`；两者同时设置时使用新变量。`--no-ipv6-dns` 和旧参数 `--no-ipv6`、`--no-disable-ipv6` 均跳过 DNS 修改。

模块配置依次应用模式默认值、环境变量和命令行开关，后者覆盖前者。多个 `--enable`、`--disable` 按出现顺序处理；命令行开关也会覆盖自定义菜单的选择。例如：

```bash
ENABLE_DOCKER=no bash init_setup.sh --yes --mode full
```

这会执行完整模式的其他模块，跳过 Docker；如果再加上 `--enable docker`，则重新启用 Docker。

## 常用参数

```bash
bash init_setup.sh --help
```

常用配置参数：

```text
--ssh-port PORT
--ssh-key "KEY"
--timezone TZ
--journal-max-use SIZE
--logfile PATH
```

默认时区为新加坡（`Asia/Singapore`，UTC+8），可通过 `--timezone` 参数或 `TARGET_TIMEZONE` 环境变量覆盖。

检查和维护：

```bash
bash init_setup.sh --check
bash init_setup.sh --dry-run --mode recommended
bash init_setup.sh --status
bash init_setup.sh --restore
bash init_setup.sh --yes --restore-ipv6-dns
bash init_setup.sh --yes --restore-ipv6
```

- `--check` 只检查运行环境；
- `--dry-run` 只显示将启用的模块；
- `--status` 输出当前服务和配置状态；
- `--restore` 恢复最近一次由脚本创建的配置备份。
- `--restore-ipv6-dns` 只恢复被移除的 IPv6 DNS，不执行初始化模块。
- `--restore-ipv6` 用于恢复旧版脚本彻底关闭的 IPv6。

## 独立恢复 DNS

以 root 身份执行：

```bash
bash init_setup.sh --yes --restore-ipv6-dns
```

此参数直接恢复 DNS，不显示初始化菜单；即使同时指定模式或模块开关，也只执行 DNS 恢复。不能与 `--restore`、`--restore-ipv6`、`--check`、`--status` 同时使用。可以先预览：

```bash
bash init_setup.sh --restore-ipv6-dns --dry-run
```

恢复会按修改前的原始内容写回 DNS 配置，再刷新解析服务，不操作 IPv6 系统开关、地址、路由或防火墙。DNS 原始配置保存在 `/var/backups/debian-init-setup/ipv6-dns/`，全部恢复并刷新成功后清理；重复修改保留第一次的原始内容，重复恢复不会覆盖后续改动。

如果文件在 DNS 修改后被用户或网络服务改动，脚本保留现状并提示原始内容位置，返回非零退出码。刷新失败时也保留恢复记录。按提示处理后，可以重复执行同一命令。

## 恢复旧版脚本关闭的 IPv6

本版本不再关闭 IPv6。此前使用旧版关闭过 IPv6 的机器，仍可用原命令恢复：

```bash
bash init_setup.sh --yes --restore-ipv6
```

此参数直接进入 IPv6 恢复流程，不显示初始化菜单；即使同时指定模式或模块开关，也只执行 IPv6 恢复。不能与 `--restore`、`--restore-ipv6-dns`、`--check`、`--status` 同时使用。可以先预览：

```bash
bash init_setup.sh --restore-ipv6 --dry-run
```

恢复流程会备份并清理脚本写入的 IPv6 禁用系统参数和 GRUB 启动参数，恢复 UFW 的 IPv6 支持，并在 UFW 已启用时重载现有规则。随后写回被移除的 IPv6 DNS，开启各接口的 IPv6，并恢复地址和路由。本版本的 UFW 配置流程会保留已有 IPv6 规则，避免它们在禁用 IPv6 支持时被 UFW 清空；旧版运行时已经丢失的自定义规则仍需从原备份恢复。

- `3.1.0` 至 `3.2.1` 关闭 IPv6 时会保存地址、路由和网卡编号。同一次系统启动内、网卡编号未变化时，恢复会使用这份快照。
- 旧版关闭时没有快照，或快照因重启、网卡变化而不再适用时，会尝试从 Debian 的 ifupdown 静态网络配置恢复 IPv6 地址和网关。其他网络管理服务需要按自身配置重新分配地址。
- DNS 配置按关闭前的原始内容整文件写回。如果某个文件在关闭之后被改动过，脚本不覆盖它，只提示原始内容的保存位置，需要手工处理。
- 如果当前内核已经通过 `ipv6.disable=1` 启动，脚本会撤销禁用配置并提示重启，不会自动重启服务器。重启后可再次执行恢复命令检查结果。
- 即时恢复只有在接口开关开启、存在可用的全局地址和默认路由时才报告成功；配置、备份或服务操作失败会返回非零退出码。地址和路由检查不代表已验证外部网络连通性。

IPv6 恢复快照保存在 `/var/backups/debian-init-setup/ipv6-runtime/`，即时恢复验证成功后清理。DNS 原始配置保存在 `/var/backups/debian-init-setup/ipv6-dns/`，全部写回后清理。配置文件备份仍按原有规则保留。恢复失败时根据错误提示处理后，可以重复执行同一命令。

## 备份和日志

配置备份目录：

```text
/var/backups/debian-init-setup/
```

默认日志文件：

```text
/var/log/debian_init_setup.log
```

脚本使用运行锁，避免多个实例同时修改系统。默认锁文件是 `/run/debian-init-setup.lock`。

SSH 配置在备份失败时停止写入；语法检查、服务重载或监听校验失败时会尝试恢复本次修改前的文件。恢复本身失败时会报告具体文件或服务错误，并保留备份供检查。

日志目录不能允许组用户或其他用户写入。检查日志和运行锁时不会更改已有目录的权限。

`--restore` 只恢复脚本备份过的配置文件，不卸载软件包，也不自动撤销已经完成的软件升级。

## 测试

```bash
python -m unittest discover -s tests -v
```

测试使用临时目录和模拟命令，不会修改当前机器的 SSH、防火墙或 Docker。真实服务、内核参数、软件源和重启后的状态仍需在 Debian 测试机上验证。

内核升级测试覆盖默认选项、独立执行、最新系列跟踪、内核类型保留、缺少跟踪包、容器和未知内核、安装失败及手动重启提示；未在 Debian 实机安装内核或执行重启。

`3.1.0` 已在 Debian 12、静态 IPv6、已启用 UFW 的服务器上验证新版关闭后恢复、重复关闭与恢复，以及 `3.0.5` 关闭后由新版恢复。各次恢复后的 IPv6 HTTPS 访问均成功，IPv4 地址和路由、SSH 配置、已有 IPv4/IPv6 防火墙规则通过一致性检查。测试结束后已恢复原始配置。需要重启才能生效的分支通过隔离测试验证，未执行实机重启。

`3.2.0` 的 DNS 处理目前只通过上述回归测试验证，未在实机上验证 `resolvconf -u`、`networkctl reload` 和 `systemd-resolved` 重启后的重新生成结果。

`4.0.0` 补充 DNS 单独执行和恢复、IPv6 网络配置保持原样、IPv4 DNS 检查、恢复冲突和刷新失败重试等隔离测试。此版本尚未在 Debian 实机上验证。
