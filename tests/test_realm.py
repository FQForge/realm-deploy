"""Offline checks: real sockets and files; GitHub and service operations are simulated."""

import copy
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import secrets
import socket
import subprocess
import tarfile
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("realm_data", PROJECT / "realm-data.py")
DATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DATA)

try:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
    CAN_BIND = True
except PermissionError:
    CAN_BIND = False


def free_port():
    if not CAN_BIND:
        return 20000 + secrets.randbelow(30000)
    for _ in range(50):
        with socket.socket() as tcp:
            tcp.bind(("127.0.0.1", 0))
            number = tcp.getsockname()[1]
            with socket.socket(type=socket.SOCK_DGRAM) as udp:
                try:
                    udp.bind(("127.0.0.1", number))
                except OSError:
                    continue
                return number
    raise RuntimeError("No free TCP+UDP port")


def rule(number=None, enabled=True):
    return {
        "id": 1, "name": "测试入口", "listen_host": "127.0.0.1", "listen_port": number or free_port(),
        "remote_host": "example.com", "remote_port": 443, "public_host": "203.0.113.10",
        "public_port": 20000, "enabled": enabled,
    }


def state(item=None):
    return {"version": 1, "rules": [] if item is None else [item]}


class DataTests(unittest.TestCase):
    def test_addresses_and_ports(self):
        self.assertEqual(DATA.port("0080"), 80)
        self.assertEqual(DATA.host("[2001:db8::1]"), "2001:db8::1")
        self.assertEqual(DATA.host("EXAMPLE.COM."), "example.com")
        self.assertEqual(DATA.host("例子.测试"), "xn--fsqu00a.xn--0zwm56d")
        for value in ("0", "65536", "-1", "1e3", "$(id)"):
            with self.subTest(value=value), self.assertRaises(DATA.Invalid):
                DATA.port(value)
        for value in ("https://example.com", "256.1.1.1", "example.com:443", "x\n.invalid", "0.0.0.0", "::"):
            with self.subTest(value=value), self.assertRaises(DATA.Invalid):
                DATA.host(value)

    def test_schema_rejects_duplicates_and_loops(self):
        original = state(rule())
        DATA.validate(original)
        mutations = []
        duplicate = copy.deepcopy(original)
        duplicate["rules"].append(dict(duplicate["rules"][0], id=2))
        mutations.append(duplicate)
        for key, value in (("enabled", "yes"), ("listen_port", True), ("name", "bad\x1bname")):
            changed = copy.deepcopy(original)
            changed["rules"][0][key] = value
            mutations.append(changed)
        loop = copy.deepcopy(original)
        loop["rules"][0].update(remote_host="localhost", remote_port=loop["rules"][0]["listen_port"])
        mutations.append(loop)
        for changed in mutations:
            with self.subTest(changed=changed), self.assertRaises(DATA.Invalid):
                DATA.validate(changed)

    def test_render_ipv6_and_disabled_rules(self):
        entry = rule()
        entry.update(listen_host="::", remote_host="2001:db8::1234")
        text = DATA.render(state(entry))
        self.assertIn(f'listen = "[::]:{entry["listen_port"]}"', text)
        self.assertIn('remote = "[2001:db8::1234]:443"', text)
        self.assertIn("use_udp = true", text)
        entry["enabled"] = False
        self.assertNotIn("[[endpoints]]", DATA.render(state(entry)))

    @unittest.skipUnless(CAN_BIND, "Current sandbox forbids network sockets")
    def test_listener_check_requires_both_tcp_and_udp(self):
        with socket.socket() as tcp:
            tcp.bind(("127.0.0.1", 0))
            tcp.listen()
            number = tcp.getsockname()[1]
            current = state(rule(number))
            self.assertFalse(DATA.listening(current))
            with socket.socket(type=socket.SOCK_DGRAM) as udp:
                udp.bind(("127.0.0.1", number))
                self.assertTrue(DATA.listening(current))

    @unittest.skipUnless(CAN_BIND, "Current sandbox forbids network sockets")
    def test_udp_only_occupation_is_detected(self):
        with socket.socket(type=socket.SOCK_DGRAM) as udp:
            udp.bind(("127.0.0.1", 0))
            with self.assertRaises(DATA.Invalid):
                DATA.check_ports(state(rule(udp.getsockname()[1])), state())


SYSTEMCTL = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
root = Path(os.environ["TEST_ROOT"])
active, enabled, fail = (root / name for name in ("active", "enabled", "fail-once"))
command = sys.argv[1]
if command == "is-active":
    sys.exit(0 if active.exists() else 3)
if command == "is-enabled":
    sys.exit(0 if enabled.exists() else 1)
if command == "restart":
    active.unlink(missing_ok=True)
    if fail.exists():
        fail.unlink()
        sys.exit(1)
    active.touch()
elif command == "stop":
    active.unlink(missing_ok=True)
elif command == "enable":
    enabled.touch()
elif command == "disable":
    enabled.unlink(missing_ok=True)
elif command != "daemon-reload":
    sys.exit("Unexpected systemctl command: " + command)
'''

CURL = '''#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys
args = sys.argv[1:]
output = args[args.index("-o") + 1] if "-o" in args else None
url = args[-1]
root = Path(os.environ["TEST_ROOT"])
with (root / "downloads.log").open("a") as log:
    log.write(url + "\\n")
if url.startswith("https://api.github.com/repos/zhboner/realm/releases/"):
    source = root / "release.json"
elif url.startswith("https://github.com/zhboner/realm/releases/download/"):
    source = root / "realm.tar.gz"
elif url.startswith("https://raw.githubusercontent.com/"):
    source = Path(os.environ["TEST_PROJECT"]) / url.rsplit("/", 1)[1]
else:
    sys.exit("Unexpected URL: " + url)
if output:
    shutil.copyfile(source, output)
else:
    sys.stdout.buffer.write(source.read_bytes())
'''

# The production helper is unchanged. Only sandboxed integration tests replace
# bind/listener checks, while the three real-socket tests explicitly skip.
PYTHON_WITH_SIMULATED_PORTS = '''#!/usr/bin/python3
import importlib.util
import os
from pathlib import Path
import sys
if len(sys.argv) > 1 and Path(sys.argv[1]).name == "realm-data.py":
    spec = importlib.util.spec_from_file_location("sandbox_realm_data", sys.argv[1])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.bind_test = lambda address, number: None
    module.listening = lambda state: True
    try:
        sys.exit(module.main(sys.argv[2:]))
    except (module.Invalid, OSError, ValueError, KeyError, TypeError) as error:
        print(f"[错误] {error}", file=sys.stderr)
        sys.exit(1)
os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
'''


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="realm-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        mock = self.root / "mock-bin"
        mock.mkdir()
        for filename, content in (("systemctl", SYSTEMCTL), ("curl", CURL), ("journalctl", "#!/bin/sh\necho 'simulated service log'\n")):
            path = mock / filename
            path.write_text(content)
            path.chmod(0o700)
        if not CAN_BIND:
            python_wrapper = mock / "python3"
            python_wrapper.write_text(PYTHON_WITH_SIMULATED_PORTS)
            python_wrapper.chmod(0o700)
        self.env = dict(os.environ, PATH=f"{mock}:{os.environ['PATH']}", TEST_ROOT=str(self.root), TEST_PROJECT=str(PROJECT),
                        RLM_ETC_DIR=str(self.root / "etc"), RLM_OPT_DIR=str(self.root / "opt"),
                        RLM_ENTRY=str(self.root / "bin/rnode"), RLM_HELPER_TARGET=str(self.root / "lib/realm-data.py"),
                        RLM_CORE_LINK=str(self.root / "bin/realm-core"), RLM_UNIT_FILE=str(self.root / "systemd/realm-deploy.service"),
                        RLM_OPENRC_FILE=str(self.root / "init/realm-deploy"), RLM_LOG_FILE=str(self.root / "log/realm.log"),
                        RLM_INIT_SYSTEM="systemd", RLM_SKIP_DEP_INSTALL="1", NO_COLOR="1")
        self.run_bash("detect_system; ensure_dependencies; init_data")
        self.state_path = self.root / "etc/rules.json"
        self.config_path = self.root / "etc/config.toml"
        self.core_link = self.root / "bin/realm-core"
        old_core = self.root / "opt/versions/v9.9.8/realm"
        old_core.parent.mkdir(parents=True)
        old_core.write_text("#!/bin/sh\nprintf 'realm 9.9.8\\n'\n")
        old_core.chmod(0o700)
        self.core_link.parent.mkdir()
        self.core_link.symlink_to(old_core)
        self.make_release()

    def run_command(self, args, *, input_text="", ok=True, env=None):
        result = subprocess.run(args, input=input_text, text=True, capture_output=True, env=env or self.env,
                                cwd=PROJECT, timeout=25)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def run_bash(self, code, **kwargs):
        return self.run_command(["bash", "-c", f"source {shlex.quote(str(PROJECT / 'realm.sh'))}\n{code}"], **kwargs)

    def cli(self, *args, **kwargs):
        return self.run_command(["bash", str(PROJECT / "realm.sh"), *args], **kwargs)

    def write_state(self, content):
        DATA.write(self.state_path, content)
        self.config_path.write_text(DATA.render(content))

    def candidate(self, content):
        path = self.root / "candidate.json"
        DATA.write(path, content)
        return shlex.quote(str(path))

    def make_release(self, bad_digest=False):
        architecture = os.uname().machine
        targets = {"x86_64": "x86_64-unknown-linux-musl", "aarch64": "aarch64-unknown-linux-musl"}
        self.asset = "realm-" + targets.get(architecture, architecture + "-unknown-linux-musl") + ".tar.gz"
        archive = self.root / "realm.tar.gz"
        executable = b"#!/bin/sh\nprintf 'realm 9.9.9\\n'\n"
        with tarfile.open(archive, "w:gz") as tar:
            member = tarfile.TarInfo("realm")
            member.size = len(executable)
            member.mode = 0o755
            tar.addfile(member, io.BytesIO(executable))
        digest = "0" * 64 if bad_digest else hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.root / "release.json").write_text(json.dumps({
            "tag_name": "v9.9.9", "assets": [{"name": self.asset, "digest": "sha256:" + digest,
            "browser_download_url": "https://github.com/zhboner/realm/releases/download/v9.9.9/" + self.asset}]
        }))

    def test_quick_wizard_selects_port_and_name_and_can_cancel(self):
        answers = "example.com\n443\n\n203.0.113.10\ny\n"
        result = self.run_bash("detect_system; init_data; wait_service() { return 0; }; rule_wizard", input_text=answers)
        saved = DATA.load(self.state_path)["rules"][0]
        self.assertEqual(saved["listen_host"], "0.0.0.0")
        self.assertEqual(saved["public_port"], saved["listen_port"])
        self.assertEqual(saved["remote_host"], "example.com")
        self.assertEqual(saved["remote_port"], 443)
        self.assertEqual(saved["name"], "转发-1")
        self.assertIn(f'listen = "0.0.0.0:{saved["listen_port"]}"', self.config_path.read_text())
        self.assertIn('remote = "example.com:443"', self.config_path.read_text())
        self.assertIn("客户端服务器地址：203.0.113.10", result.stdout)
        self.assertIn(f'客户端服务器端口：{saved["listen_port"]}', result.stdout)
        self.assertTrue((self.root / "enabled").exists())
        before = self.state_path.read_bytes()
        self.run_bash("detect_system; init_data; rule_wizard", input_text="q\n")
        self.assertEqual(self.state_path.read_bytes(), before)

    def test_quick_wizard_declining_confirmation_does_not_install_or_save(self):
        before = self.state_path.read_bytes()
        self.core_link.unlink()
        answers = "example.com\n443\n\n203.0.113.10\nn\n"
        self.run_bash("detect_system; init_data; rule_wizard", input_text=answers)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(list((self.root / "etc/backups").glob("*.json")), [])
        self.assertFalse(self.core_link.exists())
        self.assertFalse((self.root / "downloads.log").exists())

    def test_custom_menu_creates_nat_rule_with_separate_public_port(self):
        number = free_port()
        public_port = 31415 if number != 31415 else 31416
        answers = f"4\nexample.com\n443\n127.0.0.1\n{number}\n203.0.113.10\n{public_port}\n中文入口\ny\n"
        result = self.run_bash("detect_system; init_data; wait_service() { return 0; }; advanced_menu", input_text=answers)
        saved = DATA.load(self.state_path)["rules"][0]
        self.assertEqual(saved["listen_host"], "127.0.0.1")
        self.assertEqual(saved["listen_port"], number)
        self.assertEqual(saved["public_port"], public_port)
        self.assertEqual(saved["name"], "中文入口")
        self.assertIn(f"客户端服务器端口：{public_port}", result.stdout)
        self.assertIn(f"公网 {public_port} → 本机 {number}", result.stdout)

    def test_editing_nat_rule_keeps_public_mapping_and_name(self):
        original = rule()
        original["public_port"] = original["listen_port"] + 1
        self.write_state(state(original))
        number = free_port()
        while number in (original["listen_port"], original["public_port"]):
            number = free_port()
        answers = f"\n8443\n\n{number}\n\n\n\ny\n"
        self.run_bash("detect_system; init_data; wait_service() { return 0; }; rule_wizard 1", input_text=answers)
        expected = dict(original, remote_port=8443, listen_port=number)
        self.assertEqual(DATA.load(self.state_path), state(expected))

    def test_successful_apply_saves_previous_backup(self):
        before = state(rule())
        self.write_state(before)
        after = copy.deepcopy(before)
        after["rules"][0]["remote_port"] = 8443
        self.run_bash(f"detect_system; init_data; install_service; wait_service() {{ return 0; }}; apply_state {self.candidate(after)}")
        self.assertEqual(DATA.load(self.state_path), after)
        backups = list((self.root / "etc/backups").glob("*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(DATA.load(backups[0]), before)
        self.assertIn(':8443"', self.config_path.read_text())

    def test_failed_restart_restores_files_and_service_flags(self):
        before = state(rule())
        self.write_state(before)
        config_before = self.config_path.read_bytes()
        for filename in ("active", "enabled", "fail-once"):
            (self.root / filename).touch()
        after = copy.deepcopy(before)
        after["rules"][0]["remote_port"] = 8443
        result = self.run_bash(f"detect_system; init_data; install_service; wait_service() {{ return 0; }}; apply_state {self.candidate(after)}", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("正在恢复", result.stderr)
        self.assertEqual(DATA.load(self.state_path), before)
        self.assertEqual(self.config_path.read_bytes(), config_before)
        self.assertTrue((self.root / "active").exists())
        self.assertTrue((self.root / "enabled").exists())

    def test_disabling_last_rule_stops_and_disables_service(self):
        before = state(rule())
        self.write_state(before)
        after = copy.deepcopy(before)
        after["rules"][0]["enabled"] = False
        for filename in ("active", "enabled"):
            (self.root / filename).touch()
        self.run_bash(f"detect_system; init_data; install_service; apply_state {self.candidate(after)}")
        self.assertFalse((self.root / "active").exists())
        self.assertFalse((self.root / "enabled").exists())
        self.assertNotIn("[[endpoints]]", self.config_path.read_text())

    @unittest.skipUnless(CAN_BIND, "Current sandbox forbids network sockets")
    def test_port_conflict_keeps_state_and_creates_no_backup(self):
        before = self.state_path.read_bytes()
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            proposed = state(rule(occupied.getsockname()[1]))
            result = self.run_bash(f"detect_system; init_data; apply_state {self.candidate(proposed)}", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(list((self.root / "etc/backups").glob("*.json")), [])

    def test_corrupted_current_state_can_be_restored_through_cli(self):
        with contextlib.ExitStack() as cleanup:
            if CAN_BIND:
                tcp = cleanup.enter_context(socket.socket())
                udp = cleanup.enter_context(socket.socket(type=socket.SOCK_DGRAM))
                tcp.bind(("127.0.0.1", 0))
                tcp.listen()
                number = tcp.getsockname()[1]
                udp.bind(("127.0.0.1", number))
            else:
                number = free_port()
            desired = state(rule(number))
            backup = self.root / "valid-backup.json"
            DATA.write(backup, desired)
            self.state_path.write_text("broken JSON\n")
            self.cli("restore", str(backup), input_text="y\n")
        self.assertEqual(DATA.load(self.state_path), desired)
        self.assertIn("[[endpoints]]", self.config_path.read_text())

    def test_install_downloads_verifies_and_switches_core(self):
        result = self.cli("install")
        self.assertIn("SHA256 校验通过", result.stdout)
        self.assertEqual(self.core_link.readlink(), self.root / "opt/versions/v9.9.9/realm")
        self.assertIn("# RLM-MANAGED:", Path(self.env["RLM_UNIT_FILE"]).read_text())

    def test_bad_download_does_not_replace_existing_core(self):
        previous = self.core_link.readlink()
        self.make_release(bad_digest=True)
        result = self.cli("install", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA256 校验失败", result.stderr)
        self.assertEqual(self.core_link.readlink(), previous)

    def test_empty_executable_is_rejected_even_with_correct_checksum(self):
        previous = self.core_link.readlink()
        archive = self.root / "realm.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            member = tarfile.TarInfo("realm")
            member.size = 0
            tar.addfile(member, io.BytesIO())
        metadata_path = self.root / "release.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["assets"][0]["digest"] = "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
        metadata_path.write_text(json.dumps(metadata))
        result = self.cli("install", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("文件为空", result.stderr)
        self.assertEqual(self.core_link.readlink(), previous)

    def test_failed_core_switch_restores_previous_symlink(self):
        previous = self.core_link.readlink()
        for filename in ("active", "fail-once"):
            (self.root / filename).touch()
        self.run_bash("detect_system; init_data; install_service")
        result = self.cli("install", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.core_link.readlink(), previous)
        self.assertTrue((self.root / "active").exists())

    def test_installer_command_uses_installed_helper(self):
        self.run_command(["sh", str(PROJECT / "install.sh"), "--help"])
        self.assertEqual(Path(self.env["RLM_HELPER_TARGET"]).read_bytes(), (PROJECT / "realm-data.py").read_bytes())
        result = self.run_command([self.env["RLM_ENTRY"], "list"])
        self.assertIn("还没有转发规则", result.stdout)

    def test_installer_preserves_unrelated_command(self):
        entry = Path(self.env["RLM_ENTRY"])
        entry.write_text("unrelated command\n")
        result = self.run_command(["sh", str(PROJECT / "install.sh"), "--help"], ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(entry.read_text(), "unrelated command\n")

    def test_online_installer_fetches_all_required_files(self):
        env = dict(self.env, RLM_GITHUB_OWNER="example-user", RLM_GITHUB_REPO="custom-realm",
                   RLM_GITHUB_REF="v1.0", RLM_GITHUB_PATH="tools", TMPDIR=str(self.root))
        self.run_command(["sh", str(PROJECT / "install-realm.sh"), "--help"], env=env)
        self.assertTrue(Path(env["RLM_ENTRY"]).is_file())
        urls = (self.root / "downloads.log").read_text().splitlines()
        self.assertEqual(urls, [f"https://raw.githubusercontent.com/example-user/custom-realm/v1.0/tools/{filename}"
                                for filename in ("install.sh", "realm.sh", "realm-data.py")])
        self.assertEqual(list(self.root.glob("realm-install.*")), [])

    def test_one_command_install_opens_menu_without_repository_settings(self):
        env = {key: value for key, value in self.env.items() if not key.startswith("RLM_GITHUB_")}
        env["TMPDIR"] = str(self.root)
        command = 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/fengqi0216/realm-deploy/main/install-realm.sh)"'
        result = self.run_command(["sh", "-c", command], input_text="0\n", env=env)
        self.assertIn("Realm 中文转发管理", result.stdout)
        self.assertIn("快速创建转发", result.stdout)
        self.assertEqual(Path(env["RLM_ENTRY"]).read_bytes(), (PROJECT / "realm.sh").read_bytes())
        self.assertEqual(Path(env["RLM_HELPER_TARGET"]).read_bytes(), (PROJECT / "realm-data.py").read_bytes())
        urls = (self.root / "downloads.log").read_text().splitlines()
        self.assertEqual(urls, [f"https://raw.githubusercontent.com/fengqi0216/realm-deploy/main/{filename}"
                                for filename in ("install-realm.sh", "install.sh", "realm.sh", "realm-data.py")])
        self.assertEqual(list(self.root.glob("realm-install.*")), [])

    def test_uninstall_requires_phrase_then_keeps_external_backup(self):
        self.run_command(["sh", str(PROJECT / "install.sh"), "--help"])
        self.write_state(state(rule(enabled=False)))
        self.run_bash("detect_system; init_data; install_service")
        cancelled = self.cli("uninstall", input_text="no\n", ok=False)
        self.assertNotEqual(cancelled.returncode, 0)
        self.assertTrue(self.state_path.exists())
        self.cli("uninstall", input_text="确认卸载\n")
        self.assertFalse(self.state_path.parent.exists())
        self.assertFalse(Path(self.env["RLM_ENTRY"]).exists())
        backups = list(self.root.glob("realm-deploy-backup-*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(DATA.load(backups[0])["rules"][0]["name"], "测试入口")


if __name__ == "__main__":
    unittest.main()
