"""Resource and service rollback regressions; no root or real service changes needed."""

import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SYSTEMCTL = """#!/bin/sh
set -eu
case "$1" in
  is-active) test -f "$TEST_ROOT/active" ;;
  is-enabled) test -f "$TEST_ROOT/enabled" ;;
  restart)
    rm -f "$TEST_ROOT/active"
    if [ -f "$TEST_ROOT/fail-once" ]; then rm "$TEST_ROOT/fail-once"; exit 1; fi
    touch "$TEST_ROOT/active" ;;
  stop) rm -f "$TEST_ROOT/active" ;;
  enable) touch "$TEST_ROOT/enabled" ;;
  disable) rm -f "$TEST_ROOT/enabled" ;;
  daemon-reload) : ;;
  *) exit 99 ;;
esac
"""


class ResourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="realm-resources-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        mock = self.root / "mock-bin"
        mock.mkdir()
        (mock / "systemctl").write_text(SYSTEMCTL)
        (mock / "systemctl").chmod(0o700)
        self.env = dict(os.environ, PATH=f"{mock}:{os.environ['PATH']}",
                        TEST_ROOT=str(self.root), RLM_INIT_SYSTEM="systemd",
                        RLM_ETC_DIR=str(self.root / "etc"), RLM_OPT_DIR=str(self.root / "opt"),
                        RLM_ENTRY=str(self.root / "bin/rnode"),
                        RLM_CORE_LINK=str(self.root / "bin/core"),
                        RLM_UNIT_FILE=str(self.root / "realm-deploy.service"),
                        RLM_OPENRC_FILE=str(self.root / "realm-openrc"),
                        RLM_LOG_FILE=str(self.root / "logs/realm.log"), RLM_SKIP_DEP_INSTALL="1")
        self.setting = self.root / "etc/logging"
        self.config = self.root / "etc/config.toml"
        self.unit = Path(self.env["RLM_UNIT_FILE"])
        self.log = Path(self.env["RLM_LOG_FILE"])
        self.versions = self.root / "opt/versions"
        self.core = Path(self.env["RLM_CORE_LINK"])
        self.backups = self.root / "etc/backups"
        self.shell("init_data")

    def shell(self, code, ok=True, input_text=""):
        result = subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(PROJECT / 'realm.sh'))}\ndetect_system\n{code}"],
            env=self.env, input=input_text, text=True, capture_output=True, timeout=20,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def version(self, name):
        path = self.versions / name / "realm"
        path.parent.mkdir(exist_ok=True)
        path.write_text("#!/bin/sh\nprintf 'realm 2.9.6\\n'\n")
        path.chmod(0o700)
        return path

    def activate(self):
        self.core.parent.mkdir(exist_ok=True)
        self.core.symlink_to(self.version("v2.9.5"))
        self.shell("install_service")
        for name in ("active", "enabled"):
            (self.root / name).touch()

    def release(self, slim=True, bad_digest=False):
        assets = []
        for executable in (["realm", "realm-slim"] if slim else ["realm"]):
            filename = executable + "-x86_64-unknown-linux-musl.tar.gz"
            archive = self.root / filename
            binary = b"#!/bin/sh\nprintf 'realm 2.9.6\\n'\n"
            with tarfile.open(archive, "w:gz") as package:
                member = tarfile.TarInfo(executable)
                member.size = len(binary)
                package.addfile(member, io.BytesIO(binary))
            digest = "0" * 64 if bad_digest else hashlib.sha256(archive.read_bytes()).hexdigest()
            assets.append(dict(name=filename, digest="sha256:" + digest,
                               browser_download_url="https://github.com/zhboner/realm/releases/download/v2.9.6/" + filename))
        (self.root / "release.json").write_text(json.dumps(dict(tag_name="v2.9.6", assets=assets)))

    def install(self, ok=True):
        return self.shell("""
init_data
uname() { if [[ "$1" == -m ]]; then printf '%s\\n' x86_64; else command uname "$@"; fi; }
fetch() {
  if [[ "$1" == "$API/"* ]]; then cp "$TEST_ROOT/release.json" "$2"
  else cp "$TEST_ROOT/${1##*/}" "$2"
  fi
}
wait_service() { return 0; }
install_core latest
""", ok=ok)

    def test_fresh_install_discards_logs_without_creating_a_log_directory(self):
        self.assertEqual(self.setting.read_text(), "off\n")
        self.assertIn('level = "off"', self.config.read_text())
        self.assertIn('output = "stdout"', self.config.read_text())
        self.shell("install_service")
        self.assertIn("StandardOutput=null", self.unit.read_text())
        self.assertIn("StandardError=null", self.unit.read_text())
        self.assertIn("LimitCORE=0", self.unit.read_text())
        self.assertFalse(self.log.parent.exists())

    def test_logging_switch_persists_and_preserves_running_and_enabled_state(self):
        self.activate()
        self.shell("wait_service() { return 0; }; set_logging on")
        self.shell("init_data")
        self.assertEqual(self.setting.read_text(), "on\n")
        self.assertIn('level = "warn"', self.config.read_text())
        self.assertIn("StandardOutput=journal", self.unit.read_text())
        self.shell("wait_service() { return 0; }; set_logging off")
        self.assertEqual(self.setting.read_text(), "off\n")
        for name in ("active", "enabled"):
            self.assertTrue((self.root / name).exists())

    def test_stopped_service_stays_stopped_when_logging_changes(self):
        self.shell("install_service; set_logging on")
        self.assertFalse((self.root / "active").exists())
        self.assertFalse((self.root / "enabled").exists())

    def test_logging_restart_failure_restores_files_and_running_state(self):
        self.activate()
        before = [path.read_bytes() for path in (self.setting, self.config, self.unit)]
        (self.root / "fail-once").touch()
        self.shell("wait_service() { return 0; }; set_logging on", ok=False)
        self.assertEqual([path.read_bytes() for path in (self.setting, self.config, self.unit)], before)
        self.assertTrue((self.root / "active").exists())
        self.assertTrue((self.root / "enabled").exists())
        self.assertEqual(list(self.setting.parent.glob(".logging.*")), [])

    def test_legacy_upgrade_closes_logs_and_clears_only_the_dedicated_file(self):
        self.activate()
        self.setting.unlink()
        self.config.write_text(self.config.read_text().replace('level = "off"', 'level = "warn"'))
        self.log.parent.mkdir()
        self.log.write_text("old Realm warnings\n")
        self.shell("wait_service() { return 0; }; init_data")
        self.assertEqual(self.setting.read_text(), "off\n")
        self.assertEqual(self.log.read_bytes(), b"")
        self.assertIn("StandardOutput=null", self.unit.read_text())
        self.assertTrue((self.root / "active").exists())

    def test_failed_migration_can_retry_and_preserves_old_logs(self):
        self.activate()
        self.setting.unlink()
        self.config.write_text(self.config.read_text().replace('level = "off"', 'level = "warn"'))
        before = self.config.read_bytes()
        self.log.parent.mkdir()
        self.log.write_text("old diagnostic evidence\n")
        (self.root / "fail-once").touch()
        self.shell("wait_service() { return 0; }; init_data", ok=False)
        self.assertFalse(self.setting.exists())
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.log.read_text(), "old diagnostic evidence\n")
        self.assertTrue((self.root / "active").exists())
        self.shell("wait_service() { return 0; }; init_data")

    def test_openrc_logs_go_to_dev_null_when_disabled_and_file_when_enabled(self):
        self.shell("INIT_SYSTEM=openrc; install_service")
        service = Path(self.env["RLM_OPENRC_FILE"])
        self.assertIn('output_log="/dev/null"', service.read_text())
        self.assertIn('error_log="/dev/null"', service.read_text())
        self.assertFalse(self.log.parent.exists())
        self.shell("INIT_SYSTEM=openrc; service_active() { return 1; }; set_logging on")
        self.assertIn(f'output_log="{self.log}"', service.read_text())
        self.log.write_text("warning\n")
        self.shell("INIT_SYSTEM=openrc; service_active() { return 1; }; set_logging off")
        self.assertEqual(self.log.read_bytes(), b"")
        subprocess.run(["sh", "-n", str(service)], check=True)

    def test_log_setting_symlink_is_rejected_and_file_log_symlink_is_not_truncated(self):
        target = self.root / "unrelated"
        target.write_text("keep me\n")
        self.setting.unlink()
        self.setting.symlink_to(target)
        self.shell("init_data", ok=False)
        self.setting.unlink()
        self.setting.write_text("off\n")
        self.shell("INIT_SYSTEM=openrc; install_service")
        self.log.parent.mkdir()
        self.log.symlink_to(target)
        self.shell("INIT_SYSTEM=openrc; service_active() { return 1; }; set_logging on", ok=False)
        self.shell("set_logging off")
        self.assertEqual(target.read_text(), "keep me\n")

    def test_slim_is_selected_extracted_and_keeps_one_rollback_core(self):
        self.core.parent.mkdir()
        previous = self.version("v2.9.5")
        self.core.symlink_to(previous)
        self.release()
        self.install()
        self.assertEqual(self.core.readlink(), self.versions / "slim-v2.9.6/realm")
        self.assertTrue(previous.exists())
        self.assertEqual(list((self.root / "opt").glob(".download.*")), [])
        self.install()
        self.assertEqual(len(list(self.versions.glob("*/realm"))), 2)

    def test_versions_without_slim_still_install(self):
        self.release(slim=False)
        self.install()
        self.assertEqual(self.core.readlink(), self.versions / "v2.9.6/realm")

    def test_static_standard_build_is_preferred_to_slim_requiring_glibc(self):
        self.release()
        release_path = self.root / "release.json"
        release = json.loads(release_path.read_text())
        for asset in release["assets"]:
            if asset["name"].startswith("realm-slim-"):
                for field in ("name", "browser_download_url"):
                    asset[field] = asset[field].replace("linux-musl", "linux-gnu")
        release_path.write_text(json.dumps(release))
        self.install()
        self.assertEqual(self.core.readlink(), self.versions / "v2.9.6/realm")

    def test_bad_slim_checksum_keeps_current_core_and_cleans_downloads(self):
        self.activate()
        previous = self.core.readlink()
        self.release(bad_digest=True)
        self.install(ok=False)
        self.assertEqual(self.core.readlink(), previous)
        self.assertTrue(previous.exists())
        self.assertEqual(list((self.root / "opt").glob(".download.*")), [])

    def test_failed_slim_restart_rolls_back_before_old_core_is_pruned(self):
        self.activate()
        previous = self.core.readlink()
        self.release()
        (self.root / "fail-once").touch()
        self.install(ok=False)
        self.assertEqual(self.core.readlink(), previous)
        self.assertTrue(previous.exists())
        self.assertTrue((self.root / "active").exists())

    def test_pruning_preserves_current_previous_and_unrelated_files(self):
        self.core.parent.mkdir()
        current = self.version("slim-v2.9.6")
        previous = self.version("v2.9.5")
        obsolete = self.version("v2.9.4")
        unrelated = self.version("notes")
        self.core.symlink_to(current)
        self.shell(f"prune_core_versions {shlex.quote(str(previous))}")
        for path in (current, previous, unrelated):
            self.assertTrue(path.exists())
        self.assertFalse(obsolete.exists())

    def test_automatic_backup_retention_preserves_manual_and_legacy_backups(self):
        manual = self.backups / "manual.json"
        legacy = self.backups / "20261001-010000-ABC123.json"
        for path in (manual, legacy):
            path.write_text("keep\n")
        for index in range(14):
            path = self.backups / f"auto-20261022-120000-{index:06d}.json"
            path.write_text("{}\n")
            os.utime(path, (1000 + index, 1000 + index))
        self.shell("init_data")
        kept = sorted(path.name for path in self.backups.glob("auto-*.json"))
        self.assertEqual(kept, [f"auto-20261022-120000-{index:06d}.json" for index in range(4, 14)])
        for path in (manual, legacy):
            self.assertEqual(path.read_text(), "keep\n")
        self.shell("apply_state \"$STATE\"")
        self.assertEqual(len(list(self.backups.glob("auto-*.json"))), 10)
        self.assertTrue(any(json.loads(path.read_text()) == {"version": 1, "rules": []}
                            for path in self.backups.glob("auto-*.json")))

    def test_backup_menu_shows_newest_first_across_manual_and_automatic_names(self):
        automatic = self.backups / "auto-20261022-120000-ABC123.json"
        manual = self.backups / "20261022-120001-DEF456.json"
        for index, path in enumerate((automatic, manual)):
            path.write_text('{"version":1,"rules":[]}\n')
            os.utime(path, (1000 + index, 1000 + index))
        output = self.shell("backup_menu", input_text="2\n0\n").stdout
        self.assertIn(f"1）{manual.name}", output)
        self.assertIn(f"2）{automatic.name}", output)


if __name__ == "__main__":
    unittest.main()
