# Debian 初始化脚本

面向 Debian 服务器的模块化初始化脚本，支持推荐、精简、完整和自定义模式。

- 当前版本：`3.0.5`
- 主脚本：`init_setup.sh`

## 支持的模块

| 模块 | 作用 |
| --- | --- |
| `update` | 更新系统软件包并执行升级 |
| `tools` | 安装 curl、wget、git、openssh-server 和 iproute2 |
| `nexttrace-mtr` | 安装 NextTrace 和 mtr |
| `bbr` | 配置 BBR + fq |
| `ssh` | 配置 SSH 端口、密钥登录和密码登录策略 |
| `ufw` | 启用 UFW，只放行确认过的 SSH 端口 |
| `fail2ban` | 安装并启用 Fail2ban，保护 SSH |
| `journald` | 限制 systemd journal 日志大小 |
| `timezone` | 设置时区并安装启用 chrony |
| `ipv6` | 关闭 IPv6 并尝试写入 GRUB 启动参数 |
| `docker` | 安装 Docker Engine、Buildx 和 Compose 插件 |

脚本不负责配置 ZRAM、swapfile 或 htop。

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

启用：

```text
update, tools, nexttrace-mtr, bbr, ssh, ufw,
fail2ban, journald, timezone
```

不执行关闭 IPv6，不安装 Docker：

```bash
bash init_setup.sh --yes --mode recommended
```

### 精简模式

只启用：

```text
update, bbr, ssh, ufw, journald, timezone
```

```bash
bash init_setup.sh --yes --mode minimal
```

### 完整模式

启用当前脚本提供的全部模块：

```bash
bash init_setup.sh --yes --mode full
```

完整模式包含关闭 IPv6 和安装 Docker。Docker 模块检测到已有 Docker、Podman、containerd 命令或相关软件包时会停止，包括通过 Docker 官方软件源安装的版本。确认需要替换时使用：

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
bash init_setup.sh --yes --mode custom --enable update,bbr,ssh,ufw,journald,timezone
```

可用模块名：

```text
update tools nexttrace-mtr bbr ssh ufw fail2ban journald timezone ipv6 docker all
```

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

检查和维护：

```bash
bash init_setup.sh --check
bash init_setup.sh --dry-run --mode recommended
bash init_setup.sh --status
bash init_setup.sh --restore
```

- `--check` 只检查运行环境；
- `--dry-run` 只显示将启用的模块；
- `--status` 输出当前服务和配置状态；
- `--restore` 恢复最近一次由脚本创建的配置备份。

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

## 版本记录

### 3.0.5

- 自定义交互菜单默认开启全部模块，回车确认开启，输入 `n` 关闭；显式设置的环境变量和命令行开关仍按原有优先级生效。
- 区分回车和输入中断，读取不到回答时停止执行。
- 保留无人值守自定义模式从全部关闭开始的行为。
- 增加回车默认值、单项关闭、显式覆盖和输入中断的回归测试。

### 3.0.4

- 在线入口统一使用 `--interactive` 显示模式菜单，移除并列的无人值守在线命令。

### 3.0.3

- 精简 README 和命令文件中的在线启动命令，保留交互菜单和非交互执行所需的 `--yes` 参数。

### 3.0.2

- 将日志路径检查和恢复后的命令判断改为明确的条件分支，修复 GitHub ShellCheck 检查失败。
- 在线运行示例已使用实际仓库地址，可直接复制执行。

### 3.0.1

- 修复模块环境变量被模式默认值覆盖的问题，保持命令行开关优先。
- 修复 SSH 备份失败后仍写入登录配置、自动恢复失败未报告的问题。
- Docker 已有运行时检查覆盖官方软件包和未通过软件包安装的命令。
- 日志、运行锁和配置恢复不再更改已有父目录权限。
- 补充上述分支及备份文件缺失的回归测试，隔离测试中的系统参数和 GRUB 命令。
- 在线运行示例使用 `main` 分支，上传文件后无需先创建版本标签。

### 3.0.0

- 增加推荐、精简、完整和自定义模式。
- 非交互执行必须显式传入 `--yes`。
- 在线下载到文件后执行时保留交互菜单。
- 移除 htop、ZRAM 和 swapfile 功能。
- 推荐模式不启用 IPv6 和 Docker。
- 精简模式只启用系统更新、BBR + fq、SSH、UFW、journald 限制、时区和 chrony。
- 增加运行环境检查、模拟执行、状态查看和最近备份恢复。
- 增加 SSH 配置失败回滚、运行锁和独立备份目录。
- Docker 检测到已有容器运行时后默认停止，替换需要显式参数。

### 2.0.0

- UFW 只添加 SSH 端口放行，保留已有规则。
- 移除额外端口自动放行配置。
- BBR 只加载自身的系统参数。
