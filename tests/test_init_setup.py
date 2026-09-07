"""在临时目录中验证初始化脚本，不执行真实的服务和系统配置命令。"""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_ROOT / "init_setup.sh"


def bash_path(path):
    value = Path(path).resolve().as_posix()
    if os.name == "nt":
        return "/" + value[0].lower() + value[2:]
    return value


def make_test_directory():
    parent = Path(tempfile.gettempdir()).resolve()
    return Path(tempfile.mkdtemp(prefix="debian_init_test_", dir=parent)).resolve()


def remove_test_directory(path):
    resolved = path.resolve()
    if resolved.parent != Path(tempfile.gettempdir()).resolve() or not resolved.name.startswith("debian_init_test_"):
        raise RuntimeError("拒绝清理测试临时目录以外的路径")
    shutil.rmtree(resolved)


class InitSetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = shutil.which("bash")
        if not cls.bash:
            raise RuntimeError("回归测试需要 Bash")
        source = SCRIPT.read_text(encoding="utf-8")
        cls.definitions, separator, main = source.partition('\nparse_args "$@"\n')
        if not separator:
            raise RuntimeError("找不到主流程边界，拒绝执行脚本")
        cls.main = separator + main
        cls.key_directory = make_test_directory()
        cls.addClassCleanup(remove_test_directory, cls.key_directory)
        cls.key_file = cls.key_directory / "test_key"
        subprocess.run(
            [cls.bash, "--noprofile", "--norc", "-c",
             'ssh-keygen -q -t ed25519 -N "" -C debian-init-test -f "$1"', "test-key", bash_path(cls.key_file)],
            check=True, capture_output=True, timeout=20,
        )
        cls.public_key = cls.key_file.with_suffix(".pub").read_text(encoding="utf-8").strip()

    def setUp(self):
        self.root = make_test_directory()
        self.addCleanup(remove_test_directory, self.root)
        self.ssh_config = self.root / "etc" / "ssh" / "sshd_config"
        self.ssh_config.parent.mkdir(parents=True)
        self.original_ssh_config = "Port 22\nPasswordAuthentication yes\n"
        self.ssh_config.write_text(self.original_ssh_config, encoding="utf-8")
        self.trace_file = self.root / "calls.log"
        self.authorized_keys = self.root / "root" / ".ssh" / "authorized_keys"
        self.hardening_file = self.ssh_config.parent / "sshd_config.d" / "000-init-setup-hardening.conf"

    def run_script(self, body, expected=0, main_arguments=None):
        definitions = self.definitions
        for original, replacement in (
            ("/etc/", bash_path(self.root / "etc") + "/"),
            ("/root/.ssh", bash_path(self.root / "root" / ".ssh")),
            ("/run/sshd", bash_path(self.root / "run" / "sshd")),
            ("/proc/", bash_path(self.root / "proc") + "/"),
            ("/boot/", bash_path(self.root / "boot") + "/"),
        ):
            definitions = definitions.replace(original, replacement)
        setup = f"""
TEST_ROOT={shlex.quote(bash_path(self.root))}
TEST_LOG="$TEST_ROOT/calls.log"
TEST_PUBLIC_KEY={shlex.quote(bash_path(self.key_file.with_suffix('.pub')))}
TEST_PRIVATE_KEY={shlex.quote(bash_path(self.key_file))}
BACKUP_ROOT="$TEST_ROOT/backups"
BACKUP_ID="2026-01-01-000000-1"
BACKUP_DIR="$BACKUP_ROOT/$BACKUP_ID"
LOGFILE="$TEST_ROOT/init.log"
LOCKFILE="$TEST_ROOT/init.lock"
export TMPDIR="$TEST_ROOT"
record_call() {{ printf '%s\\n' "$*" >> "$TEST_LOG"; }}
apt_install() {{ record_call apt_install "$@"; }}
systemctl() {{ record_call systemctl "$@"; return 1; }}
sysctl() {{ record_call sysctl "$@"; }}
update-grub() {{ record_call update-grub "$@"; }}
ss() {{ return 1; }}
sshd() {{ return 1; }}
ufw() {{ record_call ufw "$@"; }}
ip() {{ record_call ip "$@"; return 99; }}
chown() {{ :; }}
sleep() {{ :; }}
trap 'on_exit $?' EXIT
"""
        if os.name == "nt":
            # Git Bash 无法可靠地设置 Linux 目录权限，只在 Windows 模拟目录安装。
            setup += r'''
install() {
  local directory="${@: -1}" arg create_directory=no
  for arg in "$@"; do [ "$arg" != '-d' ] || create_directory=yes; done
  if [ "$create_directory" != yes ]; then return 99; fi
  case "$directory" in
    "$TEST_ROOT"/*) command mkdir -p -- "$directory" ;;
    *) return 99 ;;
  esac
}
'''
        if main_arguments is not None:
            body += "\nset -- " + shlex.join(main_arguments) + "\n" + self.main
        result = subprocess.run(
            [self.bash, "--noprofile", "--norc", "-s"],
            input=definitions + "\n" + setup + "\n" + body,
            text=True, encoding="utf-8", errors="replace", capture_output=True,
            cwd=PROJECT_ROOT, timeout=20,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def calls(self):
        return self.trace_file.read_text(encoding="utf-8") if self.trace_file.exists() else ""

    def assert_ssh_config_unchanged(self):
        self.assertEqual(self.ssh_config.read_text(encoding="utf-8"), self.original_ssh_config)
        self.assertFalse(self.hardening_file.exists())

    def write_fixture(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8", newline="\n")
        return target

    def prepare_ipv6_fixture(self, kernel_disabled=False):
        self.write_fixture("proc/cmdline", "quiet" + (" ipv6.disable=1" if kernel_disabled else "") + "\n")
        self.write_fixture("proc/sys/kernel/random/boot_id", "test-boot\n")
        for interface in ("all", "default", "lo", "eth0"):
            self.write_fixture(f"proc/sys/net/ipv6/conf/{interface}/disable_ipv6", "1\n")
        self.ipv6_sysctl = self.write_fixture(
            "etc/sysctl.d/99-disable-ipv6.conf",
            "".join(f"net.ipv6.conf.{interface}.disable_ipv6 = 1\n" for interface in ("all", "default", "lo")),
        )
        self.ipv6_grub = self.write_fixture(
            "etc/default/grub",
            'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n'
            'GRUB_CMDLINE_LINUX="console=ttyS0"\n'
            '# init-setup：在内核启动阶段彻底关闭 IPv6，避免网络管理器重新启用具体接口。\n'
            'GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+${GRUB_CMDLINE_LINUX} }ipv6.disable=1"\n',
        )
        self.ipv6_ufw = self.write_fixture("etc/default/ufw", "IPV6=no\nDEFAULT_INPUT_POLICY=DROP\n")
        self.write_fixture("etc/ufw/ufw.conf", "ENABLED=yes\n")

    def prepare_ipv6_snapshot(self, boot_id="test-boot\n", interfaces="1\tlo\n2\teth0\n"):
        for name, value in (("boot-id", boot_id), ("interfaces", interfaces),
                            ("addresses", "saved-addresses\n"), ("routes", "saved-routes\n")):
            self.write_fixture("backups/ipv6-runtime/" + name, value)
        return self.root / "backups" / "ipv6-runtime"

    IPV6_IP_MOCK = r'''
ip() {
  record_call ip "$@"
  case "$*" in
    '-o link show') printf '1: lo: <UP>\n2: eth0: <UP>\n' ;;
    '-6 address save scope global') printf 'saved-addresses\n' ;;
    '-6 route save table all') printf 'saved-routes\n' ;;
    '-6 address restore') cat > "$TEST_ROOT/restored-addresses" ;;
    '-6 route restore') cat > "$TEST_ROOT/restored-routes" ;;
    '-6 -o address show scope global'*)
      if [ "${TEST_IPV6_NO_ADDRESS:-0}" -eq 0 ]; then
        printf '2: eth0 inet6 2001:db8::2/64 scope global\n'
      fi ;;
    '-6 route show default')
      if [ "${TEST_IPV6_NO_ROUTE:-0}" -eq 0 ]; then
        printf 'default via 2001:db8::1 dev eth0\n'
      fi ;;
    'link show dev '*|'-6 address replace '*|'-6 route replace '*) return 0 ;;
    *) return 99 ;;
  esac
}
'''

    def test_mode_defaults(self):
        for mode, expected in (
            ("recommended", {"ENABLE_SYSTEM_UPDATE": "yes", "ENABLE_COMMON_TOOLS": "yes", "ENABLE_NEXTTRACE_MTR": "yes", "ENABLE_BBR": "yes", "ENABLE_SSH_BASELINE": "yes", "ENABLE_UFW": "yes", "ENABLE_FAIL2BAN": "yes", "ENABLE_JOURNAL_LIMIT": "yes", "ENABLE_TIMEZONE": "yes", "ENABLE_DISABLE_IPV6": "no", "ENABLE_DOCKER": "no"}),
            ("minimal", {"ENABLE_SYSTEM_UPDATE": "yes", "ENABLE_COMMON_TOOLS": "no", "ENABLE_NEXTTRACE_MTR": "no", "ENABLE_BBR": "yes", "ENABLE_SSH_BASELINE": "yes", "ENABLE_UFW": "yes", "ENABLE_FAIL2BAN": "no", "ENABLE_JOURNAL_LIMIT": "yes", "ENABLE_TIMEZONE": "yes", "ENABLE_DISABLE_IPV6": "no", "ENABLE_DOCKER": "no"}),
            ("full", {"ENABLE_SYSTEM_UPDATE": "yes", "ENABLE_COMMON_TOOLS": "yes", "ENABLE_NEXTTRACE_MTR": "yes", "ENABLE_BBR": "yes", "ENABLE_SSH_BASELINE": "yes", "ENABLE_UFW": "yes", "ENABLE_FAIL2BAN": "yes", "ENABLE_JOURNAL_LIMIT": "yes", "ENABLE_TIMEZONE": "yes", "ENABLE_DISABLE_IPV6": "yes", "ENABLE_DOCKER": "yes"}),
            ("custom", {"ENABLE_SYSTEM_UPDATE": "no", "ENABLE_COMMON_TOOLS": "no", "ENABLE_NEXTTRACE_MTR": "no", "ENABLE_BBR": "no", "ENABLE_SSH_BASELINE": "no", "ENABLE_UFW": "no", "ENABLE_FAIL2BAN": "no", "ENABLE_JOURNAL_LIMIT": "no", "ENABLE_TIMEZONE": "no", "ENABLE_DISABLE_IPV6": "no", "ENABLE_DOCKER": "no"}),
        ):
            result = self.run_script(f"MODE={mode}\napply_mode_defaults\nprintf '%s\\n' \"$ENABLE_SYSTEM_UPDATE $ENABLE_COMMON_TOOLS $ENABLE_NEXTTRACE_MTR $ENABLE_BBR $ENABLE_SSH_BASELINE $ENABLE_UFW $ENABLE_FAIL2BAN $ENABLE_JOURNAL_LIMIT $ENABLE_TIMEZONE $ENABLE_DISABLE_IPV6 $ENABLE_DOCKER\"\n")
            self.assertIn(" ".join(expected.values()), result.stdout.splitlines())

    def test_removed_swap_and_htop_are_not_referenced(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("configure_zram_swap", source)
        self.assertNotIn("configure_swapfile", source)
        self.assertNotIn(" htop", source)

    def run_custom_menu(self, answers, *arguments, expected=0):
        options = shlex.join(("--interactive", "--mode", "custom", *arguments))
        # 菜单回答使用独立输入，避免读取测试脚本自身。
        body = (
            f"parse_args {options}\n"
            "apply_mode_defaults\napply_environment_overrides\napply_cli_overrides\n"
            "prompt_configuration <<'MENU_ANSWERS'\n"
            + "".join(answer + "\n" for answer in answers)
            + "MENU_ANSWERS\napply_cli_overrides\nprint_config_summary\n"
        )
        return self.run_script(body, expected=expected)

    def test_interactive_custom_enter_keeps_all_modules_enabled(self):
        result = self.run_custom_menu([""] * 11)
        self.assertEqual(result.stdout.count(": 开启\n"), 11, result.stdout)
        self.assertNotIn(": 关闭/跳过", result.stdout)

    def test_interactive_custom_no_disables_only_selected_module(self):
        result = self.run_custom_menu([""] * 9 + ["n", ""])
        self.assertEqual(result.stdout.count(": 开启\n"), 10, result.stdout)
        self.assertIn("关闭 IPv6: 关闭/跳过", result.stdout)
        self.assertIn("Docker: 开启", result.stdout)

    def test_interactive_custom_enter_respects_explicit_disabled_modules(self):
        result = self.run_custom_menu([""] * 11, "--disable", "ipv6,docker")
        self.assertEqual(result.stdout.count(": 开启\n"), 9, result.stdout)
        self.assertIn("关闭 IPv6: 关闭/跳过", result.stdout)
        self.assertIn("Docker: 关闭/跳过", result.stdout)

    def test_interactive_custom_input_interruption_stops(self):
        result = self.run_custom_menu([], expected=1)
        self.assertIn("未读取到选择，已停止执行", result.stdout)
        self.assertNotIn("本次执行配置摘要", result.stdout)

    def test_mode_selection_input_interruption_stops(self):
        result = self.run_script(
            "INTERACTIVE_MODE=yes\nMODE_EXPLICIT=0\n"
            "prompt_mode_selection < /dev/null\nrecord_call after_prompt\n",
            expected=1,
        )
        self.assertIn("未读取到选择，已停止执行", result.stdout)
        self.assertNotIn("after_prompt", self.calls())

    def test_cli_module_overrides_follow_argument_order(self):
        result = self.run_script("parse_args --mode custom --enable docker --disable docker\napply_mode_defaults\napply_cli_overrides\nprintf 'docker=%s\\n' \"$ENABLE_DOCKER\"\n")
        self.assertIn("docker=no", result.stdout)
        result = self.run_script("parse_args --mode custom --disable docker --enable docker\napply_mode_defaults\napply_cli_overrides\nprintf 'docker=%s\\n' \"$ENABLE_DOCKER\"\n")
        self.assertIn("docker=yes", result.stdout)

    def test_environment_toggles_override_presets_and_cli_wins(self):
        environment = os.environ.copy()
        environment.update(ENABLE_DOCKER="no", ENABLE_COMMON_TOOLS="no")
        for arguments, docker_state in (([], "关闭/跳过"), (["--enable", "docker"], "开启")):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [self.bash, "--noprofile", "--norc", bash_path(SCRIPT),
                     "--dry-run", "--mode", "full", *arguments],
                    text=True, encoding="utf-8", errors="replace", capture_output=True,
                    env=environment, cwd=PROJECT_ROOT, timeout=20,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                docker_line = next(line for line in result.stdout.splitlines() if "安装 Docker" in line)
                tools_line = next(line for line in result.stdout.splitlines() if "安装常用工具" in line)
                self.assertTrue(docker_line.endswith(docker_state), result.stdout)
                self.assertTrue(tools_line.endswith("关闭/跳过"), result.stdout)

    def test_non_interactive_entry_requires_yes(self):
        result = subprocess.run(
            [self.bash, "--noprofile", "--norc", bash_path(SCRIPT), "--mode", "recommended"],
            text=True, encoding="utf-8", errors="replace", capture_output=True,
            cwd=PROJECT_ROOT, timeout=20,
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("--yes", result.stdout + result.stderr)

    def test_restore_ipv6_entry_does_not_run_initialization_modules(self):
        self.prepare_ipv6_fixture()
        snapshot = self.prepare_ipv6_snapshot()
        result = self.run_script(self.IPV6_IP_MOCK + r'''
require_root() { :; }
prepare_logfile() { :; }
acquire_run_lock() { :; }
ENABLE_DOCKER=invalid
''', main_arguments=["--yes", "--restore-ipv6", "--mode", "full", "--enable", "all"])
        self.assertIn("IPv6 已启用", result.stdout)
        self.assertFalse(snapshot.exists())
        self.assertEqual((self.root / "restored-addresses").read_text(encoding="utf-8"), "saved-addresses\n")
        self.assertEqual((self.root / "restored-routes").read_text(encoding="utf-8"), "saved-routes\n")
        self.assertFalse(self.ipv6_sysctl.exists())
        self.assertNotIn("ipv6.disable=1", self.ipv6_grub.read_text(encoding="utf-8"))
        self.assertIn("IPV6=yes", self.ipv6_ufw.read_text(encoding="utf-8"))
        for setting in (self.root / "proc/sys/net/ipv6/conf").glob("*/disable_ipv6"):
            self.assertEqual(setting.read_text(encoding="utf-8"), "0\n")
        for forbidden in ("apt_install ", "systemctl ", "sysctl --system", "ip -4 "):
            self.assertNotIn(forbidden, self.calls())
        self.assert_ssh_config_unchanged()

    def test_restore_ipv6_dry_run_has_no_system_side_effects(self):
        result = self.run_script("", main_arguments=["--restore-ipv6", "--dry-run", "--mode", "full"])
        self.assertIn("模拟执行：只恢复 IPv6", result.stdout)
        self.assertNotIn("安装 Docker", result.stdout)
        self.assertEqual(self.calls(), "")
        self.assertFalse((self.root / "init.log").exists())
        self.assertFalse((self.root / "backups").exists())

    def test_restore_ipv6_rejects_conflicting_maintenance_options(self):
        for option in ("--restore", "--check", "--status"):
            with self.subTest(option=option):
                result = self.run_script("", expected=2, main_arguments=["--yes", "--restore-ipv6", option])
                self.assertIn("不能与", result.stdout)
                self.assertEqual(self.calls(), "")

    def test_restore_ipv6_non_interactive_entry_requires_yes(self):
        result = self.run_script(
            "ORIGINAL_STDIN_IS_TTY=0\nORIGINAL_STDOUT_IS_TTY=0\n",
            expected=2, main_arguments=["--restore-ipv6"],
        )
        self.assertIn("没有显式提供 --yes", result.stdout)
        self.assertEqual(self.calls(), "")

    def test_restore_ipv6_kernel_disabled_reports_pending_reboot(self):
        self.prepare_ipv6_fixture(kernel_disabled=True)
        result = self.run_script(self.IPV6_IP_MOCK + "RESTORE_IPV6_ONLY=1\nconfigure_restore_ipv6\n")
        self.assertIn("需要重启服务器", result.stdout)
        self.assertNotIn("执行结果: 全部成功", result.stdout)
        self.assertFalse(self.ipv6_sysctl.exists())
        self.assertNotIn("ipv6.disable=1", self.ipv6_grub.read_text(encoding="utf-8"))
        self.assertIn("IPV6=yes", self.ipv6_ufw.read_text(encoding="utf-8"))
        self.assertNotIn("ufw reload", self.calls())
        self.assertNotIn("ip ", self.calls())
        self.assertEqual((self.root / "proc/sys/net/ipv6/conf/eth0/disable_ipv6").read_text(encoding="utf-8"), "1\n")

    def test_restore_ipv6_missing_grub_command_stops_before_runtime_changes(self):
        self.prepare_ipv6_fixture()
        original = self.ipv6_grub.read_text(encoding="utf-8")
        result = self.run_script(self.IPV6_IP_MOCK + r'''
command() {
  if [ "$1" = '-v' ] && [ "$2" = 'update-grub' ]; then return 1; fi
  builtin command "$@"
}
configure_restore_ipv6
''', expected=1)
        self.assertIn("缺少 update-grub", result.stdout)
        self.assertEqual(self.ipv6_grub.read_text(encoding="utf-8"), original)
        self.assertTrue(self.ipv6_sysctl.exists())
        self.assertNotIn("ufw reload", self.calls())
        self.assertNotIn("ip ", self.calls())

    def test_restore_ipv6_grub_preserves_unrelated_arguments_and_can_repeat(self):
        self.prepare_ipv6_fixture()
        self.ipv6_grub.write_text(
            'GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX="console=ttyS0 ipv6.disable=1"\n'
            "GRUB_CMDLINE_LINUX_DEFAULT='quiet ipv6.disable=1 ipv6.disable=10'\n",
            encoding="utf-8",
        )
        self.run_script("restore_ipv6_grub_persistence\nrestore_ipv6_grub_persistence\n")
        restored = self.ipv6_grub.read_text(encoding="utf-8")
        self.assertIn("GRUB_DEFAULT=0", restored)
        self.assertIn("console=ttyS0", restored)
        self.assertIn("quiet", restored)
        self.assertIn("ipv6.disable=10", restored)
        self.assertEqual(restored.count("ipv6.disable="), 1)
        self.assertEqual(self.calls().splitlines().count("update-grub"), 2)

    def test_restore_ipv6_grub_dropin_conflict_leaves_configuration_untouched(self):
        self.prepare_ipv6_fixture()
        self.write_fixture("etc/default/grub.d/provider.cfg", 'GRUB_CMDLINE_LINUX="ipv6.disable=1"\n')
        original = self.ipv6_grub.read_text(encoding="utf-8")
        result = self.run_script("restore_ipv6_grub_persistence\n", expected=1)
        self.assertIn("另有 GRUB 配置禁用 IPv6", result.stdout)
        self.assertEqual(self.ipv6_grub.read_text(encoding="utf-8"), original)
        self.assertEqual(self.calls(), "")

    def test_restore_ipv6_backup_failure_preserves_each_configuration(self):
        self.prepare_ipv6_fixture()
        for function, file in (("restore_ipv6_grub_persistence", self.ipv6_grub),
                               ("restore_ipv6_sysctl_config", self.ipv6_sysctl),
                               ("restore_ipv6_ufw", self.ipv6_ufw)):
            with self.subTest(function=function):
                original = file.read_text(encoding="utf-8")
                self.run_script("backup_file() { return 1; }\n" + function + "\n", expected=1)
                self.assertEqual(file.read_text(encoding="utf-8"), original)
                self.assertEqual(self.calls(), "")

    def test_restore_ipv6_grub_generation_failure_can_be_retried(self):
        self.prepare_ipv6_fixture()
        result = self.run_script(r'''
update-grub() {
  record_call update-grub
  if [ ! -f "$TEST_ROOT/grub-failed-once" ]; then
    touch "$TEST_ROOT/grub-failed-once"
    return 1
  fi
}
if restore_ipv6_grub_persistence; then exit 99; fi
restore_ipv6_grub_persistence
''')
        self.assertIn("update-grub 执行失败", result.stdout)
        self.assertNotIn("ipv6.disable=1", self.ipv6_grub.read_text(encoding="utf-8"))
        self.assertEqual(self.calls().splitlines().count("update-grub"), 2)

    def test_restore_ipv6_detects_remaining_generated_boot_argument(self):
        self.prepare_ipv6_fixture()
        self.write_fixture("boot/grub/grub.cfg", "linux /boot/vmlinuz root=/dev/vda1 ipv6.disable=1\n")
        result = self.run_script(self.IPV6_IP_MOCK + "configure_restore_ipv6\n", expected=1)
        self.assertIn("生成的 GRUB 配置仍包含", result.stdout)
        self.assertTrue(self.ipv6_sysctl.exists())
        self.assertNotIn("ip ", self.calls())

    def test_restore_ipv6_sysctl_keeps_unrelated_settings(self):
        self.prepare_ipv6_fixture()
        self.ipv6_sysctl.write_text(
            "net.ipv6.conf.all.disable_ipv6 = 1\n"
            "net.ipv6.conf.default.disable_ipv6 = 1 # 禁用设置\n"
            "net.ipv6.conf.lo.disable_ipv6=1\n"
            "net.ipv4.ip_forward = 1\n# 保留说明\n",
            encoding="utf-8",
        )
        self.run_script("restore_ipv6_sysctl_config\nrestore_ipv6_sysctl_config\n")
        self.assertEqual(self.ipv6_sysctl.read_text(encoding="utf-8"), "net.ipv4.ip_forward = 1\n# 保留说明\n")
        self.assertNotIn("sysctl --system", self.calls())

    def test_restore_ipv6_firewall_reload_failure_stops_runtime_changes(self):
        self.prepare_ipv6_fixture()
        result = self.run_script(self.IPV6_IP_MOCK + r'''
ufw() { record_call ufw "$@"; return 1; }
configure_restore_ipv6
''', expected=1)
        self.assertIn("IPv6 支持重载失败", result.stdout)
        self.assertNotIn("ip ", self.calls())
        self.assertEqual((self.root / "proc/sys/net/ipv6/conf/eth0/disable_ipv6").read_text(encoding="utf-8"), "1\n")

    def test_restore_ipv6_does_not_enable_an_inactive_firewall(self):
        self.prepare_ipv6_fixture()
        self.write_fixture("etc/ufw/ufw.conf", "ENABLED=no\n")
        self.run_script("restore_ipv6_ufw\n")
        self.assertEqual(self.ipv6_ufw.read_text(encoding="utf-8"), "IPV6=yes\nDEFAULT_INPUT_POLICY=DROP\n")
        self.assertEqual(self.calls(), "")

    def test_disable_ipv6_preserves_first_network_snapshot(self):
        self.prepare_ipv6_fixture()
        self.run_script(self.IPV6_IP_MOCK + "save_ipv6_runtime_state\nip() { return 99; }\nsave_ipv6_runtime_state\n")
        snapshot = self.root / "backups/ipv6-runtime"
        self.assertEqual((snapshot / "addresses").read_text(encoding="utf-8"), "saved-addresses\n")
        self.assertEqual((snapshot / "routes").read_text(encoding="utf-8"), "saved-routes\n")
        self.assertEqual(self.calls().splitlines().count("ip -6 address save scope global"), 1)

    @unittest.skipUnless(Path("/proc/sys/kernel/random/boot_id").is_file(), "需要 Linux 的 /proc 启动标识")
    def test_ipv6_snapshot_reads_real_proc_boot_id_contents(self):
        self.prepare_ipv6_fixture()
        boot_id = self.root / "proc/sys/kernel/random/boot_id"
        boot_id.unlink()
        # 使用真正的 /proc 只读文件，覆盖文件大小为 0、实际内容非空的情况。
        boot_id.symlink_to("/proc/sys/kernel/random/boot_id")
        self.run_script(self.IPV6_IP_MOCK +
                        "save_ipv6_runtime_state\nsave_ipv6_runtime_state\nrestore_ipv6_network_state\n")
        self.assertEqual(self.calls().splitlines().count("ip -6 address save scope global"), 1)
        self.assertEqual((self.root / "restored-addresses").read_text(encoding="utf-8"), "saved-addresses\n")
        self.assertEqual((self.root / "restored-routes").read_text(encoding="utf-8"), "saved-routes\n")

    def test_disable_ipv6_snapshot_failure_stops_before_disabling_network(self):
        self.prepare_ipv6_fixture()
        original = self.ipv6_grub.read_text(encoding="utf-8")
        self.run_script(r'''
ip() {
  record_call ip "$@"
  if [ "$*" = '-6 route save table all' ]; then return 1; fi
  printf 'state\n'
}
configure_disable_ipv6
''', expected=1)
        self.assertEqual(self.ipv6_grub.read_text(encoding="utf-8"), original)
        self.assertNotIn("sysctl ", self.calls())
        self.assertFalse((self.root / "backups/ipv6-runtime/boot-id").exists())

    def test_restore_ipv6_does_not_replay_snapshots_after_boot_or_interface_changes(self):
        self.prepare_ipv6_fixture()
        for boot_id, interfaces in (("old-boot\n", "1\tlo\n2\teth0\n"),
                                    ("test-boot\n", "1\tlo\n3\teth0\n")):
            with self.subTest(boot_id=boot_id, interfaces=interfaces):
                self.trace_file.unlink(missing_ok=True)
                self.prepare_ipv6_snapshot(boot_id, interfaces)
                self.run_script(self.IPV6_IP_MOCK + r'''
TEST_IPV6_NO_ADDRESS=1
restore_ifupdown_ipv6() { record_call restore_ifupdown_ipv6; }
restore_ipv6_network_state
''')
                self.assertIn("restore_ifupdown_ipv6", self.calls())
                self.assertNotIn("ip -6 address restore", self.calls())
                self.assertNotIn("ip -6 route restore", self.calls())

    def test_restore_ipv6_incomplete_snapshot_is_reported_and_retained(self):
        self.prepare_ipv6_fixture()
        snapshot = self.prepare_ipv6_snapshot()
        (snapshot / "routes").unlink()
        result = self.run_script(self.IPV6_IP_MOCK + "configure_restore_ipv6\n", expected=1)
        self.assertIn("IPv6 网络状态备份不完整", result.stdout)
        self.assertTrue((snapshot / "addresses").exists())
        self.assertNotIn("ip -6 address restore", self.calls())

    def test_restore_ipv6_requires_both_usable_address_and_default_route(self):
        for missing in ("TEST_IPV6_NO_ADDRESS", "TEST_IPV6_NO_ROUTE"):
            with self.subTest(missing=missing):
                self.prepare_ipv6_fixture()
                snapshot = self.prepare_ipv6_snapshot()
                result = self.run_script(self.IPV6_IP_MOCK + missing + "=1\nconfigure_restore_ipv6\n", expected=1)
                self.assertIn("尚未取得可用的全局地址和默认路由", result.stdout)
                self.assertNotIn("IPv6 已启用，已有可用", result.stdout)
                self.assertTrue((snapshot / "addresses").exists())
                self.assertIn("-tentative -dadfailed", self.calls())

    def test_restore_ifupdown_ipv6_ignores_ipv4_and_preserves_ipv6_gateway_metric(self):
        self.prepare_ipv6_fixture()
        self.write_fixture(
            "ifquery-output",
            "address: 192.0.2.2\nnetmask: 255.255.255.0\ngateway: 192.0.2.1\n"
            "address: 2001:db8::2\ngateway: fe80::1\nnetmask: 64\nmetric: 42\n"
            "post-up: invalid-command\naddress: 2001:db8::3/64\n",
        )
        self.run_script(self.IPV6_IP_MOCK + r'''
systemctl() { record_call systemctl "$@"; }
ifquery() {
  if [ "$1" = '--list' ]; then printf 'lo\neth0\n'; else cat "$TEST_ROOT/ifquery-output"; fi
}
restore_ifupdown_ipv6
''')
        self.assertIn("ip -6 address replace 2001:db8::2/64 dev eth0", self.calls())
        self.assertIn("ip -6 address replace 2001:db8::3/64 dev eth0", self.calls())
        self.assertIn("ip -6 route replace default via fe80::1 dev eth0 onlink metric 42", self.calls())
        for forbidden in ("192.0.2.", "invalid-command", "systemctl restart", "ip -4 "):
            self.assertNotIn(forbidden, self.calls())

    def test_restore_ifupdown_ipv6_missing_prefix_does_not_apply_partial_addresses(self):
        self.prepare_ipv6_fixture()
        result = self.run_script(self.IPV6_IP_MOCK + r'''
systemctl() { return 0; }
ifquery() {
  if [ "$1" = '--list' ]; then
    printf 'eth0\n'
  else
    printf 'address: 2001:db8::2/64\naddress: 2001:db8::3\ngateway: fe80::1\n'
  fi
}
restore_ifupdown_ipv6
''', expected=1)
        self.assertIn("缺少有效前缀", result.stdout)
        self.assertNotIn("ip -6 address replace", self.calls())
        self.assertNotIn("ip -6 route replace", self.calls())

    def test_unsafe_log_directory_is_rejected_before_permission_changes(self):
        log_directory = self.root / "logs"
        log_directory.mkdir()
        self.run_script(r'''
LOGFILE="$TEST_ROOT/logs/init.log"
install() { record_call install "$@"; }
find() { printf '%s\n' "$TEST_ROOT/logs"; }
prepare_logfile
''', expected=1)
        self.assertFalse((log_directory / "init.log").exists())
        self.assertNotIn("install ", self.calls())

    def test_run_lock_preserves_existing_directory_permissions(self):
        lock_directory = self.root / "locks"
        lock_directory.mkdir()
        self.run_script(r'''
LOCKFILE="$TEST_ROOT/locks/init.lock"
install() { record_call install "$@"; }
flock() { record_call flock "$@"; }
acquire_run_lock
''')
        self.assertTrue((lock_directory / "init.lock").is_file())
        self.assertNotIn("install ", self.calls())

    def test_latest_backup_can_restore_original_file(self):
        target = self.root / "etc" / "example.conf"
        target.write_text("before\n", encoding="utf-8")
        self.run_script(f"backup_file {shlex.quote(bash_path(target))}\nprintf 'after\\n' > {shlex.quote(bash_path(target))}\nrestore_latest_backup\n")
        self.assertEqual(target.read_text(encoding="utf-8"), "before\n")

    def test_missing_backup_is_reported_without_reloading_services(self):
        result = self.run_script(r'''
backup_file "$SSH_CONFIG"
printf 'changed\n' > "$SSH_CONFIG"
rm -- "${BACKUP_DIR}${SSH_CONFIG}"
restore_latest_backup
''', expected=1)
        self.assertIn("备份恢复未完全成功", result.stdout)
        self.assertEqual(self.ssh_config.read_text(encoding="utf-8"), "changed\n")
        self.assertNotIn("systemctl ", self.calls())
        self.assertNotIn("sysctl ", self.calls())

    def test_existing_container_runtime_stops_docker_module(self):
        for package in ("podman", "docker.io", "docker-ce", "containerd.io"):
            with self.subTest(package=package):
                self.trace_file.unlink(missing_ok=True)
                self.run_script(f"TEST_RUNTIME_PACKAGE={shlex.quote(package)}\n" + r'''
dpkg-query() {
  local package="${@: -1}"
  [ "$package" = "$TEST_RUNTIME_PACKAGE" ] || return 1
  printf 'install ok installed\n'
}
apt_install() { record_call apt_install "$@"; return 99; }
install_docker_engine
''', expected=1)
                self.assertNotIn("apt_install", self.calls())

    def test_unmanaged_container_runtime_stops_docker_module(self):
        self.run_script(r'''
dpkg-query() { return 1; }
docker() { :; }
apt_install() { record_call apt_install "$@"; return 99; }
install_docker_engine
''', expected=1)
        self.assertNotIn("apt_install", self.calls())

    def test_explicit_runtime_replacement_allows_installation_to_start(self):
        self.run_script(r'''
dpkg-query() {
  [ "${@: -1}" = docker-ce ] || return 1
  printf 'install ok installed\n'
}
REPLACE_EXISTING_RUNTIME=1
apt_install() { record_call apt_install "$@"; return 99; }
install_docker_engine
''', expected=99)
        self.assertIn("apt_install ca-certificates curl gnupg", self.calls())

    def test_invalid_public_keys_do_not_change_ssh_configuration(self):
        for value in ("", "   ", "not-a-key", "ssh-ed25519 invalid-base64"):
            with self.subTest(value=value):
                self.run_script(f"SSH_PUBLIC_KEY={shlex.quote(value)}\nconfigure_ssh_baseline\n", expected=1)
                self.assert_ssh_config_unchanged()
                self.assertFalse(self.authorized_keys.exists())
                self.assertNotIn("systemctl ", self.calls())

    def test_private_key_and_multiple_keys_are_rejected(self):
        for expression in ('"$(cat "$TEST_PRIVATE_KEY")"',
                           '"$(cat "$TEST_PUBLIC_KEY")"$\'\\n\'"$(cat "$TEST_PUBLIC_KEY")"'):
            with self.subTest(expression=expression):
                self.run_script(f"SSH_PUBLIC_KEY={expression}\nconfigure_ssh_baseline\n", expected=1)
                self.assert_ssh_config_unchanged()

    def test_public_key_append_is_separate_and_idempotent(self):
        self.authorized_keys.parent.mkdir(parents=True)
        self.authorized_keys.write_text("# 已有注释，没有结尾换行", encoding="utf-8")
        self.run_script('SSH_PUBLIC_KEY="$(cat "$TEST_PUBLIC_KEY")"\nadd_root_ssh_key\nadd_root_ssh_key\n')
        lines = self.authorized_keys.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines.count(self.public_key), 1)
        self.assertEqual(lines[0], "# 已有注释，没有结尾换行")

    def test_public_key_write_failure_stops_ssh_changes(self):
        self.run_script(r'''
SSH_PUBLIC_KEY="$(cat "$TEST_PUBLIC_KEY")"
install() { return 1; }
configure_ssh_baseline
''', expected=1)
        self.assert_ssh_config_unchanged()
        self.assertNotIn("systemctl ", self.calls())

    def test_ssh_backup_failure_preserves_authorized_keys(self):
        self.authorized_keys.parent.mkdir(parents=True)
        original_keys = "# 原有登录配置\n"
        self.authorized_keys.write_text(original_keys, encoding="utf-8")
        self.run_script(self.listener() + r'''
SSH_PUBLIC_KEY="$(cat "$TEST_PUBLIC_KEY")"
backup_file() { return 1; }
configure_ssh_baseline
''', expected=1)
        self.assertEqual(self.authorized_keys.read_text(encoding="utf-8"), original_keys)
        self.assert_ssh_config_unchanged()
        self.assertNotIn("systemctl ", self.calls())

    def test_ssh_rollback_failure_is_reported(self):
        result = self.run_script(r'''
SSH_TRANSACTION_FILES=("$SSH_CONFIG")
SSH_SERVICE_RELOADED=1
restore_file_from_backup() { return 1; }
rollback_ssh_configuration
''', expected=1)
        self.assertIn("SSH 配置恢复失败", result.stdout)
        self.assertNotIn("systemctl ", self.calls())

    def test_reload_and_restart_failures_are_propagated(self):
        self.run_script("reload_ssh_service\n", expected=1)
        self.assertIn("systemctl reload ssh", self.calls())
        self.assertIn("systemctl restart ssh", self.calls())
        self.assertNotIn("systemctl enable", self.calls())

    def test_restart_fallback_requires_active_service(self):
        self.run_script(r'''
systemctl() {
  record_call systemctl "$@"
  [ "$1" != reload ]
}
reload_ssh_service
''')
        self.assertIn("systemctl restart ssh", self.calls())
        self.assertIn("systemctl is-active --quiet ssh", self.calls())

    def test_inactive_service_is_not_accepted(self):
        self.run_script(r'''
systemctl() {
  record_call systemctl "$@"
  [ "$1" != is-active ]
}
reload_ssh_service
''', expected=1)
        self.assertNotIn("systemctl enable", self.calls())

    @staticmethod
    def listener(process="sshd", port=10721):
        return f'''ss() {{ printf '%s\\n' 'LISTEN 0 128 0.0.0.0:{port} 0.0.0.0:* users:(("{process}",pid=1234,fd=5))'; }}\n'''

    def test_listener_must_belong_to_sshd(self):
        self.run_script(self.listener("nginx") + "verify_ssh_listening\n", expected=1)
        self.run_script(self.listener() + "verify_ssh_listening\n")

    def test_occupied_port_stops_before_ssh_config_changes(self):
        self.run_script(self.listener("nginx") + r'''
SSH_PUBLIC_KEY="$(cat "$TEST_PUBLIC_KEY")"
configure_ssh_baseline
''', expected=1)
        self.assert_ssh_config_unchanged()
        self.assertNotIn("systemctl ", self.calls())

    def test_live_port_wins_over_stale_or_invalid_configuration(self):
        for configured in ("sshd() { return 1; }", "sshd() { printf 'port 22\\n'; }"):
            with self.subTest(configured=configured):
                result = self.run_script(self.listener(port=2222) + configured + '\nprintf "detected=%s\\n" "$(detect_sshd_port_numbers)"\n')
                self.assertIn("detected=2222", result.stdout)

    def test_port_detection_can_fall_back_to_configuration(self):
        result = self.run_script('sshd() { printf "port 2222\\n"; }\nprintf "detected=%s\\n" "$(detect_sshd_port_numbers)"\n')
        self.assertIn("detected=2222", result.stdout)

    UFW_SETUP = "ENABLE_SSH_BASELINE=no\nENABLE_DISABLE_IPV6=no\n"

    def test_ufw_does_not_enable_when_port_is_unknown(self):
        self.run_script(self.UFW_SETUP + "configure_ufw_firewall\n", expected=1)
        self.assertFalse(any(line.startswith("ufw ") for line in self.calls().splitlines()))

    def test_ufw_does_not_trust_configuration_without_live_listener(self):
        self.run_script(self.UFW_SETUP + 'sshd() { printf "port 2222\\n"; }\nconfigure_ufw_firewall\n', expected=1)
        self.assertFalse(any(line.startswith("ufw ") for line in self.calls().splitlines()))

    def test_ufw_adds_only_detected_ssh_ports_and_preserves_rules(self):
        self.run_script(self.UFW_SETUP + self.listener(port=2222) + "configure_ufw_firewall\n")
        calls = self.calls()
        rules = [line for line in calls.splitlines() if line.startswith("ufw allow ")]
        self.assertEqual(rules, ["ufw allow 2222/tcp"])
        self.assertFalse(any({"reset", "delete"} & set(line.split()) for line in calls.splitlines()))
        self.assertLess(calls.index("ufw allow 2222/tcp"), calls.index("ufw --force enable"))

    def test_ufw_ignores_retired_extra_ports_and_reports_verified_ssh_port(self):
        result = self.run_script(r'''
ENABLE_DISABLE_IPV6=no
SSH_READY=1
SSH_PORT=10721
UFW_EXTRA_PORTS='80/tcp,443/tcp,8443/tcp'
configure_ufw_firewall
printf 'allowed_ssh=%s\n' "${UFW_ALLOWED_SSH_PORTS[*]}"
''')
        rules = [line for line in self.calls().splitlines() if line.startswith("ufw allow ")]
        self.assertEqual(rules, ["ufw allow 10721/tcp"])
        self.assertIn("allowed_ssh=10721", result.stdout)

    def test_ufw_keeps_ipv6_rules_while_disabling_ipv6_support(self):
        self.write_fixture("etc/default/ufw", "IPV6=yes\n")
        original = "# 已有 IPv6 规则\n-A ufw6-user-input -p tcp --dport 443 -j ACCEPT\n"
        rules = self.write_fixture("etc/ufw/user6.rules", original)
        self.run_script(r'''
ENABLE_DISABLE_IPV6=yes
SSH_READY=1
ufw() {
  record_call ufw "$@"
  : > "$TEST_ROOT/etc/ufw/user6.rules"
}
configure_ufw_firewall
''')
        self.assertEqual(rules.read_text(encoding="utf-8"), original)
        self.assertIn("IPV6=no", (self.root / "etc/default/ufw").read_text(encoding="utf-8"))
        self.assertIn("ufw --force enable", self.calls())

    def test_ufw_failure_retains_ipv6_rules_and_stops_configuration(self):
        self.write_fixture("etc/default/ufw", "IPV6=no\n")
        original = "# 已有 IPv6 规则\n-A ufw6-user-input -p tcp --dport 443 -j ACCEPT\n"
        rules = self.write_fixture("etc/ufw/user6.rules", original)
        self.run_script(r'''
ENABLE_DISABLE_IPV6=no
SSH_READY=1
ufw() {
  record_call ufw "$@"
  : > "$TEST_ROOT/etc/ufw/user6.rules"
  return 1
}
configure_ufw_firewall
''', expected=1)
        self.assertEqual(rules.read_text(encoding="utf-8"), original)
        self.assertNotIn("ufw --force enable", self.calls())

    def test_bbr_without_modprobe_applies_only_its_own_configuration(self):
        (self.root / "etc" / "sysctl.d").mkdir()
        self.run_script(r'''
command() {
  if [ "$1" = '-v' ] && [ "$2" = 'modprobe' ]; then return 1; fi
  builtin command "$@"
}
sysctl() {
  record_call sysctl "$@"
  if [ "$1" = '-n' ]; then
    case "$2" in
      net.ipv4.tcp_congestion_control) printf 'bbr\n' ;;
      net.core.default_qdisc) printf 'fq\n' ;;
    esac
  fi
  return 0
}
configure_bbr_fq
''')
        calls = self.calls()
        self.assertNotIn("apt_install ", calls)
        self.assertNotIn("sysctl --system", calls)
        self.assertIn(f"sysctl -p {bash_path(self.root / 'etc' / 'sysctl.d' / '99-bbr-fq.conf')}", calls)

    def test_successful_ssh_configuration_can_become_ready(self):
        result = self.run_script(self.listener() + r'''
SSH_PUBLIC_KEY="$(cat "$TEST_PUBLIC_KEY")"
systemctl() { record_call systemctl "$@"; }
sshd() {
  if [ "$1" = '-T' ]; then
    printf '%s\n' 'port 10721' 'permitrootlogin prohibit-password' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes'
  fi
  return 0
}
configure_ssh_baseline
printf 'ssh_ready=%s\n' "$SSH_READY"
''')
        self.assertIn("ssh_ready=1", result.stdout)
        self.assertIn("PasswordAuthentication no", self.hardening_file.read_text(encoding="utf-8"))
        self.assertIn(self.public_key, self.authorized_keys.read_text(encoding="utf-8"))

    def test_invalid_effective_config_is_rejected_before_reload(self):
        self.run_script(self.listener() + r'''
SSH_PUBLIC_KEY="$(cat "$TEST_PUBLIC_KEY")"
sshd() {
  if [ "$1" = '-T' ]; then printf 'port 22\n'; fi
  return 0
}
configure_ssh_baseline
''', expected=1)
        self.assert_ssh_config_unchanged()
        self.assertNotIn("systemctl reload", self.calls())
        self.assertNotIn("systemctl restart", self.calls())

    def test_exit_status_reports_soft_errors_and_preserves_fatal_errors(self):
        self.run_script(":\n")
        result = self.run_script("record_soft_error '模拟模块失败'\n", expected=1)
        self.assertIn("部分错误", result.stdout)
        self.assertNotIn("致命错误", result.stdout)
        self.run_script("record_soft_error '模拟模块失败'\nexit 7\n", expected=7)


if __name__ == "__main__":
    unittest.main()
