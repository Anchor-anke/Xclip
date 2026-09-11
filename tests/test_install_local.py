"""No real app bundles, system signatures, processes, or user data are changed."""

import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "install_local", Path(__file__).resolve().parents[1] / "scripts/install-local.py"
)
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)
NATIVE_ATOMIC_MOVE = installer.atomic_move
REGISTER_BUNDLE = installer.register_bundle
VERIFY_PROJECT_SIGNATURE = installer.verify_project_signature
SIGNING_CERTIFICATE = installer.signing_certificate


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        # resolve() removes macOS /var -> /private/var from synthetic fixture paths.
        self.repo = Path(self.temporary.name).resolve() / "repo"
        self.repo.mkdir()
        self.source = self.bundle(".build/build.fixture/Xclip.app", "new")
        self.target = self.repo / "src/dist/Xclip.app"
        self.desktop = self.repo.parent / "user/Desktop/Xclip.app"
        self.user_applications = self.repo.parent / "user/Applications/Xclip.app"
        self.system_applications = self.repo.parent / "Applications/Xclip.app"
        self.messages = []
        self.patches = [
            patch.object(installer, "verify_signature"),
            patch.object(installer, "running_executables", return_value=[]),
            patch.object(installer, "tracked_files", return_value=[]),
            patch.object(installer, "copy_bundle", side_effect=shutil.copytree),
            patch.object(installer, "atomic_move", side_effect=self.exchange),
            patch.object(installer, "register_bundle"),
            patch.object(installer, "external_copy_paths", return_value=[self.desktop, self.user_applications, self.system_applications]),
            patch.object(installer, "signing_certificate", return_value="0123456789abcdef0123456789abcdef01234567"),
            patch.object(installer, "verify_project_signature"),
        ]
        (self.sign, self.processes, self.tracked, self.copy, self.rename, self.registration,
         self.external_paths, self.certificate, self.project_sign) = [p.start() for p in self.patches]
        self.addCleanup(lambda: [p.stop() for p in reversed(self.patches)])
        self.addCleanup(self.temporary.cleanup)

    def bundle(self, relative, value, identifier="local.cclip.app"):
        path = self.repo / relative
        binary = path / "Contents/MacOS/Xclip"
        binary.parent.mkdir(parents=True)
        binary.write_text(value)
        binary.chmod(0o755)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "Xclip",
            "CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "2",
        }))
        (path / "Contents/_CodeSignature").mkdir()
        (path / "Contents/_CodeSignature/CodeResources").write_bytes(plistlib.dumps({"files2": {}}))
        return path

    def metadata(self, app, **values):
        path = app / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update(values)
        path.write_bytes(plistlib.dumps(info))

    def value(self, app=None):
        return ((app or self.target) / "Contents/MacOS/Xclip").read_text()

    def make(self, source=None, cleanup=True, destination=None):
        return installer.Installer(self.repo, source or self.source, cleanup, self.messages.append, destination)

    @staticmethod
    def exchange(source, target, exchange=False):
        if exchange:
            temporary = source.parent / "swap.tmp"
            target.rename(temporary)
            source.rename(target)
            temporary.rename(source)
        else:
            if target.exists():
                raise FileExistsError(target)
            source.rename(target)

    def test_installs_at_stable_path_and_cleans_only_product_bundles(self):
        self.bundle("src/dist/Xclip.app", "old")
        preview = self.bundle(".build/capture-upgrade/Preview.app", "preview", "local.cclip.capture-preview")
        qa = self.bundle(".build/qa/Xclip.app", "qa", "local.cclip.qa")
        other = self.bundle(".build/other/Other.app", "other", "other.app")
        outside = self.bundle("archive/Xclip.app", "archive")
        data = self.repo / ".build/preview-data/history.json"
        data.parent.mkdir()
        data.write_text("private history")
        source_file = self.repo / "src/OneClip/Source.swift"
        source_file.parent.mkdir()
        source_file.write_text("source")
        self.assertEqual(self.make().run(), self.target)
        self.assertEqual(self.value(), "new")
        for old in [self.source, preview, qa]:
            self.assertFalse(old.exists())
        self.assertTrue(other.exists())
        self.assertTrue(outside.exists())
        self.assertEqual(data.read_text(), "private history")
        self.assertEqual(source_file.read_text(), "source")
        self.assertEqual(list(self.target.parent.glob(".xclip-install-*")), [])

    def test_dry_run_does_not_create_destination_or_delete_copies(self):
        self.make().run(dry_run=True)
        self.assertFalse(self.target.parent.exists())
        self.assertTrue(self.source.exists())
        self.copy.assert_not_called()
        self.rename.assert_not_called()
        self.registration.assert_not_called()

    def test_no_cleanup_preserves_build_source_and_previous_copies(self):
        preview = self.bundle(".build/preview/Xclip.app", "preview", "local.cclip.qa")
        self.bundle("src/dist/Xclip.app", "old")
        self.make(cleanup=False).run()
        self.assertTrue(preview.exists())
        self.assertTrue(self.source.exists())
        self.assertEqual(self.value(), "new")
        self.registration.assert_called_once_with(self.target)

    def test_custom_destination_requires_no_cleanup(self):
        custom = self.repo / "custom/Xclip.app"
        with self.assertRaisesRegex(installer.InstallError, "no-cleanup"):
            self.make(destination=custom)
        self.assertFalse(custom.exists())

    def test_custom_destination_does_not_clean_or_modify_stable_install(self):
        self.bundle("src/dist/Xclip.app", "stable")
        custom = self.bundle("custom/Xclip.app", "old-custom")
        self.make(cleanup=False, destination=custom).run()
        self.assertEqual(self.value(custom), "new")
        self.assertEqual(self.value(), "stable")
        self.assertTrue(self.source.exists())

    def test_custom_destination_only_accepts_xclip_app_name(self):
        with self.assertRaisesRegex(installer.InstallError, "命名"):
            self.make(cleanup=False, destination=self.repo / "custom/Other.app")

    def test_external_custom_destination_checks_its_git_repository(self):
        external_repo = self.repo.parent / "other-repo"
        (external_repo / ".git").mkdir(parents=True)
        custom = external_repo / "build/Xclip.app"
        tracked_file = custom / "Contents/Info.plist"
        self.tracked.side_effect = lambda repo: [tracked_file] if repo == external_repo else []
        with self.assertRaisesRegex(installer.InstallError, "Git"):
            self.make(cleanup=False, destination=custom).run()
        self.assertFalse(custom.exists())

    def test_can_clean_copies_when_source_is_already_the_stable_target(self):
        self.bundle("src/dist/Xclip.app", "latest")
        self.make(source=self.target).run()
        self.copy.assert_not_called()
        self.assertFalse(self.source.exists())
        self.assertEqual(self.value(), "latest")
        self.assertEqual(self.registration.call_args_list[0].args, (self.target,))

    def test_unsigned_source_leaves_old_install_unchanged(self):
        self.bundle("src/dist/Xclip.app", "old")
        self.sign.side_effect = installer.InstallError("bad signature")
        with self.assertRaises(installer.InstallError):
            self.make().run()
        self.assertEqual(self.value(), "old")
        self.rename.assert_not_called()

    def test_bad_staging_signature_preserves_old_install(self):
        self.bundle("src/dist/Xclip.app", "old")
        def verify(path):
            if ".xclip-install-" in str(path):
                self.assertEqual(self.value(), "old")
                raise installer.InstallError("bad stage")
        self.sign.side_effect = verify
        with self.assertRaises(installer.InstallError):
            self.make().run()
        self.assertEqual(self.value(), "old")
        self.assertTrue(self.source.exists())
        self.rename.assert_not_called()

    def test_failed_post_install_verification_rolls_back(self):
        self.bundle("src/dist/Xclip.app", "old")
        def verify(path):
            if path == self.target:
                self.assertEqual(self.value(), "new")
                backup = list(self.target.parent.glob(".xclip-install-*/Xclip.app"))
                self.assertEqual(self.value(backup[0]), "old")
                raise installer.InstallError("post install failure")
        self.sign.side_effect = verify
        with self.assertRaisesRegex(installer.InstallError, "已恢复"):
            self.make().run()
        self.assertEqual(self.value(), "old")
        self.assertTrue(self.source.exists())

    def test_failed_first_install_verification_restores_absent_target(self):
        def verify(path):
            if path == self.target:
                raise installer.InstallError("post install failure")
        self.sign.side_effect = verify
        with self.assertRaisesRegex(installer.InstallError, "已恢复"):
            self.make().run()
        self.assertFalse(self.target.exists())
        self.assertTrue(self.source.exists())

    def test_registration_failure_rolls_back_and_registers_old_bundle(self):
        self.bundle("src/dist/Xclip.app", "old")
        registered_values = []
        def register(path, unregister=False):
            self.assertFalse(unregister)
            registered_values.append(self.value(path))
            if self.value(path) == "new":
                raise installer.InstallError("registration failed")
        self.registration.side_effect = register
        with self.assertRaisesRegex(installer.InstallError, "已恢复"):
            self.make().run()
        self.assertEqual(self.value(), "old")
        self.assertEqual(registered_values, ["new", "old"])
        self.assertTrue(self.source.exists())

    def test_first_install_registration_failure_unregisters_before_rollback(self):
        actions = []
        def register(path, unregister=False):
            actions.append((path, unregister, path.exists()))
            if not unregister:
                raise installer.InstallError("registration failed")
        self.registration.side_effect = register
        with self.assertRaisesRegex(installer.InstallError, "已恢复"):
            self.make().run()
        self.assertEqual(actions, [(self.target, False, True), (self.target, True, True)])
        self.assertFalse(self.target.exists())
        self.assertTrue(self.source.exists())

    def test_target_registration_precedes_each_copy_unregistration_and_deletion(self):
        preview = self.bundle(".build/qa/Xclip.app", "qa", "local.cclip.qa")
        events = []
        original_remove = shutil.rmtree
        def register(path, unregister=False):
            if not unregister:
                self.assertEqual(self.value(path), "new")
                self.assertTrue(self.source.exists())
                self.assertTrue(preview.exists())
            self.assertTrue(path.exists())
            events.append(("unregister" if unregister else "register", path))
        def remove(path, *args, **kwargs):
            if path in [self.source, preview]:
                self.assertEqual(events[-1], ("unregister", path))
                events.append(("delete", path))
            return original_remove(path, *args, **kwargs)
        self.registration.side_effect = register
        with patch.object(installer.shutil, "rmtree", side_effect=remove):
            self.make().run()
        self.assertEqual(events[0], ("register", self.target))
        self.assertEqual(len(events), 5)

    def test_failed_copy_unregistration_preserves_copy_after_successful_install(self):
        def register(path, unregister=False):
            if unregister:
                raise installer.InstallError("unregistration failed")
        self.registration.side_effect = register
        with self.assertRaisesRegex(installer.InstallError, "unregistration failed"):
            self.make().run()
        self.assertEqual(self.value(), "new")
        self.assertTrue(self.source.exists())

    def test_never_registered_copy_is_removed_only_after_exact_path_lookup(self):
        self.registration.side_effect = REGISTER_BUNDLE
        def run(arguments, **kwargs):
            if arguments[1] == "-u":
                return subprocess.CompletedProcess(arguments, 1, f"failed to scan {self.source}: -10814\n from spotlight\n", "")
            return subprocess.CompletedProcess(arguments, 0, "", "")
        with patch.object(installer.subprocess, "run", side_effect=run) as process, \
             patch.object(installer, "registered_bundle_paths", return_value={self.target}) as lookup:
            self.make().run()
        self.assertFalse(self.source.exists())
        self.assertEqual(self.value(), "new")
        lookup.assert_called_once_with("local.cclip.app")
        self.assertEqual([call.args[0][1:] for call in process.call_args_list], [
            ["-f", str(self.target)], ["-u", str(self.source)],
        ])

    def test_not_found_error_still_preserves_copy_if_path_is_registered(self):
        result = subprocess.CompletedProcess([], 1, f"failed to scan {self.source}: -10814\n from spotlight\n", "")
        with patch.object(installer.subprocess, "run", return_value=result), \
             patch.object(installer, "registered_bundle_paths", return_value={self.source}):
            with self.assertRaisesRegex(installer.InstallError, "注销旧应用"):
                REGISTER_BUNDLE(self.source, unregister=True)
        self.assertTrue(self.source.exists())

    def test_not_found_error_preserves_copy_when_registry_query_is_uncertain(self):
        result = subprocess.CompletedProcess([], 1, "", f"failed to scan {self.source}: -10814\n from spotlight\n")
        with patch.object(installer.subprocess, "run", return_value=result), \
             patch.object(installer, "registered_bundle_paths", side_effect=installer.InstallError("registry unavailable")):
            with self.assertRaisesRegex(installer.InstallError, "registry unavailable"):
                REGISTER_BUNDLE(self.source, unregister=True)
        self.assertTrue(self.source.exists())

    def test_other_errors_never_trigger_not_registered_exception(self):
        cases = [
            (1, f"failed to scan {self.source}: -10814", False),
            (1, f"failed to scan {self.source}: -10811", True),
            (1, f"failed to scan {self.source.parent / 'Other.app'}: -10814", True),
            (1, f"failed to scan {self.source}: -10814\npermission denied", True),
            (1, f"failed to scan {self.source}: -10814\nfrom spotlight\nfrom spotlight", True),
            (2, f"failed to scan {self.source}: -10814", True),
        ]
        for status, output, unregister in cases:
            with self.subTest(status=status, output=output, unregister=unregister):
                result = subprocess.CompletedProcess([], status, output, "")
                with patch.object(installer.subprocess, "run", return_value=result), \
                     patch.object(installer, "registered_bundle_paths", return_value=set()) as lookup:
                    with self.assertRaises(installer.InstallError):
                        REGISTER_BUNDLE(self.source, unregister=unregister)
                    lookup.assert_not_called()

    def test_failed_old_registration_still_restores_files_and_reports_registration(self):
        self.bundle("src/dist/Xclip.app", "old")
        self.registration.side_effect = installer.InstallError("registry unavailable")
        with self.assertRaisesRegex(installer.InstallError, "已恢复"):
            self.make().run()
        self.assertEqual(self.value(), "old")
        self.assertTrue(any("系统登记仍需检查" in message for message in self.messages))

    def test_already_installed_source_registration_failure_preserves_other_copies(self):
        self.bundle("src/dist/Xclip.app", "stable")
        self.registration.side_effect = installer.InstallError("registration failed")
        with self.assertRaisesRegex(installer.InstallError, "registration failed"):
            self.make(source=self.target).run()
        self.assertTrue(self.source.exists())
        self.assertEqual(self.value(), "stable")
        self.registration.assert_called_once_with(self.target)

    def test_failed_atomic_swap_preserves_old_install(self):
        self.bundle("src/dist/Xclip.app", "old")
        self.rename.side_effect = OSError("swap failed")
        with self.assertRaises(OSError):
            self.make().run()
        self.assertEqual(self.value(), "old")

    @unittest.skipUnless(sys.platform == "darwin", "macOS renamex_np primitive")
    def test_native_atomic_swap_of_nonempty_fixture_directories(self):
        first = self.repo / "first-directory"
        second = self.repo / "second-directory"
        first.mkdir()
        second.mkdir()
        (first / "payload").write_text("first")
        (second / "payload").write_text("second")
        NATIVE_ATOMIC_MOVE(first, second, exchange=True)
        self.assertEqual((first / "payload").read_text(), "second")
        self.assertEqual((second / "payload").read_text(), "first")
        with self.assertRaises(OSError):
            NATIVE_ATOMIC_MOVE(first, second)
        self.assertEqual((first / "payload").read_text(), "second")
        self.assertEqual((second / "payload").read_text(), "first")

    def test_copy_failure_keeps_old_install(self):
        self.bundle("src/dist/Xclip.app", "old")
        self.copy.side_effect = OSError("copy failed")
        with self.assertRaisesRegex(OSError, "copy failed"):
            self.make().run()
        self.assertEqual(self.value(), "old")
        self.assertTrue(self.source.exists())
        self.rename.assert_not_called()

    def test_failed_rollback_keeps_recovery_bundle(self):
        self.bundle("src/dist/Xclip.app", "old")
        def verify(path):
            if path == self.target:
                raise installer.InstallError("post install failure")
        def rename(source, target, exchange=False):
            if source == self.target:
                raise OSError("rollback failed")
            self.exchange(source, target, exchange)
        self.sign.side_effect = verify
        self.rename.side_effect = rename
        with self.assertRaisesRegex(installer.InstallError, "保留恢复副本"):
            self.make().run()
        backups = list(self.target.parent.glob(".xclip-install-*/Xclip.app"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.value(backups[0]), "old")
        self.assertTrue(self.source.exists())

    def test_refuses_active_target_and_source_copy_without_stopping_them(self):
        self.bundle("src/dist/Xclip.app", "old")
        for active in [self.target, self.source]:
            with self.subTest(active=active):
                self.processes.return_value = [(123, active / "Contents/MacOS/Xclip")]
                with self.assertRaisesRegex(installer.InstallError, "PID 123"):
                    self.make().run()
                self.assertEqual(self.value(), "old")
                self.copy.assert_not_called()

    def test_no_cleanup_can_copy_a_running_source_but_never_replace_active_target(self):
        self.processes.return_value = [(123, self.source / "Contents/MacOS/Xclip")]
        self.make(cleanup=False).run()
        self.assertTrue(self.source.exists())
        self.assertEqual(self.value(), "new")

    def test_copy_started_after_planning_is_not_deleted(self):
        def verify(path):
            if path == self.target:
                self.processes.return_value = [(123, self.source / "Contents/MacOS/Xclip")]
        self.sign.side_effect = verify
        with self.assertRaisesRegex(installer.InstallError, "PID 123"):
            self.make().run()
        self.assertTrue(self.source.exists())
        self.assertEqual(self.value(), "new")

    def test_refuses_git_tracked_target_or_cleanup_candidate(self):
        self.bundle("src/dist/Xclip.app", "old")
        for path in [self.target, self.source]:
            with self.subTest(path=path):
                self.tracked.return_value = [path / "Contents/Info.plist"]
                with self.assertRaisesRegex(installer.InstallError, "Git"):
                    self.make().run()
                self.assertEqual(self.value(), "old")
                self.copy.assert_not_called()

    def test_rejects_source_path_traversal_and_symlink(self):
        with self.assertRaisesRegex(installer.InstallError, r"\.\."):
            self.make(source=self.source.parent / ".." / "new" / "Xclip.app")
        link = self.repo / "linked.app"
        link.symlink_to(self.source)
        with self.assertRaisesRegex(installer.InstallError, "符号链接"):
            self.make(source=link)

    def test_rejects_symlink_inside_source_bundle(self):
        data = self.repo / "history.json"
        data.write_text("private")
        (self.source / "Contents/history").symlink_to(data)
        with self.assertRaisesRegex(installer.InstallError, "符号链接"):
            self.make().run()
        self.assertEqual(data.read_text(), "private")

    def test_rejects_symlinked_install_parent(self):
        outside = self.repo / "outside"
        outside.mkdir()
        (self.repo / "src").mkdir()
        (self.repo / "src/dist").symlink_to(outside)
        with self.assertRaisesRegex(installer.InstallError, "符号链接"):
            self.make()
        self.assertEqual(list(outside.iterdir()), [])

    def test_cleanup_does_not_follow_symlinked_apps_or_directories(self):
        external = self.bundle("outside/External.app", "external")
        link = self.repo / ".build/Linked.app"
        link.symlink_to(external)
        directory_link = self.repo / ".build/linked-directory"
        directory_link.symlink_to(external.parent)
        self.make().run()
        self.assertTrue(link.is_symlink())
        self.assertTrue(directory_link.is_symlink())
        self.assertEqual(self.value(external), "external")

    def test_user_bundles_in_fixture_data_and_arbitrary_folders_are_preserved(self):
        paths = [
            ".build/capture-upgrade/preview-data/attachments/Xclip.app",
            ".build/qa/qa-data/Xclip.app",
            ".build/screenshot-direct/data/Xclip.app",
            ".build/tests/history/Xclip.app",
            ".build/capture-upgrade/attachments/Xclip.app",
            ".build/personal-archive/Xclip.app",
        ]
        saved = [self.bundle(path, "user saved") for path in paths]
        self.make().run()
        for app in saved:
            self.assertEqual(self.value(app), "user saved")

    def test_custom_data_path_from_bundle_is_preserved(self):
        qa = self.bundle(".build/qa/Xclip.app", "qa", "local.cclip.qa")
        data_root = self.repo / ".build/capture-upgrade/unusual-fixtures"
        data_app = self.bundle(str(data_root.relative_to(self.repo) / "Xclip.app"), "user saved")
        info_path = qa / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CClipTestDataDirectory"] = str(data_root)
        info_path.write_bytes(plistlib.dumps(info))
        self.make().run()
        self.assertFalse(qa.exists())
        self.assertEqual(self.value(data_app), "user saved")

    def test_recovery_bundle_survives_later_successful_install(self):
        recovery = self.bundle("src/dist/.xclip-install-recovery/Xclip.app", "recovery")
        self.make().run()
        self.assertEqual(self.value(recovery), "recovery")

    def test_refuses_unknown_bundle_at_fixed_target(self):
        self.bundle("src/dist/Xclip.app", "unrelated", "another.app")
        with self.assertRaisesRegex(installer.InstallError, "其他应用"):
            self.make().run()
        self.assertEqual(self.value(), "unrelated")

    def test_refuses_preview_as_install_source(self):
        preview = self.bundle(".build/Preview.app", "preview", "local.cclip.capture-preview")
        with self.assertRaisesRegex(installer.InstallError, "正式 Xclip"):
            self.make(source=preview).run()

    def test_remove_copy_rechecks_scope_and_identity(self):
        outside = self.bundle("archive/Xclip.app", "keep")
        unrelated = self.bundle(".build/Other.app", "keep", "other.app")
        for app in [outside, unrelated, self.target]:
            with self.subTest(app=app):
                with self.assertRaises(installer.InstallError):
                    self.make().remove_copy(app)
        self.assertTrue(outside.exists())
        self.assertTrue(unrelated.exists())

    def test_verified_external_copies_are_removed_after_target_registration(self):
        candidates = [self.bundle(path, "old external") for path in [self.desktop, self.user_applications, self.system_applications]]
        self.metadata(self.user_applications, CFBundleShortVersionString="0.2.9", CFBundleVersion="99")
        self.make().run()
        self.assertEqual(self.value(), "new")
        for app in candidates:
            self.assertFalse(app.exists())
            self.assertIn(((app,), {"unregister": True}), self.registration.call_args_list)
            self.assertGreaterEqual(sum(call.args[0] == app for call in self.project_sign.call_args_list), 3)
        self.assertEqual(self.registration.call_args_list[0].args, (self.target,))

    def test_external_dry_run_lists_exact_candidates_without_mutations(self):
        self.bundle(self.desktop, "desktop")
        self.make().run(dry_run=True)
        self.assertEqual(self.value(self.desktop), "desktop")
        self.assertTrue(any("验证新版成功后删除" in message and str(self.desktop) in message for message in self.messages))
        self.registration.assert_not_called()
        self.copy.assert_not_called()

    def test_no_cleanup_never_discovers_or_unregisters_external_copies(self):
        self.bundle(self.desktop, "desktop")
        self.make(cleanup=False).run()
        self.assertEqual(self.value(self.desktop), "desktop")
        self.external_paths.assert_not_called()
        self.project_sign.assert_not_called()
        self.registration.assert_called_once_with(self.target)

    def test_external_source_cleanup_uses_verified_target_after_build_source_deleted(self):
        self.bundle(self.desktop, "desktop")
        checked = []
        def certificate(path):
            self.assertTrue(path.exists())
            checked.append(path)
            return "0123456789abcdef0123456789abcdef01234567"
        self.certificate.side_effect = certificate
        self.make().run()
        self.assertFalse(self.source.exists())
        self.assertFalse(self.desktop.exists())
        self.assertEqual(checked[-1], self.target)

    def test_external_cleaning_with_canonical_source_keeps_canonical_bundle(self):
        self.bundle("src/dist/Xclip.app", "latest")
        self.bundle(self.desktop, "desktop")
        self.make(source=self.target).run()
        self.assertEqual(self.value(), "latest")
        self.assertFalse(self.desktop.exists())
        self.copy.assert_not_called()

    def test_higher_external_release_or_build_is_preserved(self):
        self.bundle(self.desktop, "future release")
        self.bundle(self.user_applications, "future build")
        self.metadata(self.desktop, CFBundleShortVersionString="0.4.0", CFBundleVersion="1")
        self.metadata(self.user_applications, CFBundleVersion="3")
        self.make().run()
        self.assertEqual(self.value(self.desktop), "future release")
        self.assertEqual(self.value(self.user_applications), "future build")
        self.assertTrue(any("版本比安装源更新" in message for message in self.messages))
        self.project_sign.assert_not_called()

    def test_higher_canonical_version_prevents_downgrade(self):
        self.bundle("src/dist/Xclip.app", "newer installed")
        self.metadata(self.target, CFBundleVersion="3")
        with self.assertRaisesRegex(installer.InstallError, "拒绝降级"):
            self.make().run()
        self.assertEqual(self.value(), "newer installed")
        self.copy.assert_not_called()

    def test_unknown_external_version_is_preserved(self):
        self.bundle(self.desktop, "unknown")
        self.metadata(self.desktop, CFBundleVersion="2-beta")
        self.make().run()
        self.assertEqual(self.value(self.desktop), "unknown")
        self.assertTrue(any("无法确定版本先后" in message for message in self.messages))

    def test_other_identity_or_unverified_signature_is_preserved(self):
        self.bundle(self.desktop, "another signer")
        self.bundle(self.user_applications, "other product", identifier="another.app")
        self.bundle(self.system_applications, "preview", identifier="local.cclip.qa")
        self.project_sign.side_effect = lambda app, _: (_ for _ in ()).throw(installer.InstallError("different signer")) if app == self.desktop else None
        self.make().run()
        self.assertEqual(self.value(self.desktop), "another signer")
        self.assertEqual(self.value(self.user_applications), "other product")
        self.assertEqual(self.value(self.system_applications), "preview")
        self.assertTrue(any("different signer" in message for message in self.messages))

    def test_missing_reference_certificate_keeps_external_copy(self):
        self.bundle(self.desktop, "unproven")
        self.certificate.side_effect = installer.InstallError("no signing leaf")
        self.make().run()
        self.assertEqual(self.value(self.desktop), "unproven")
        self.assertEqual(self.value(), "new")

    def test_similarly_named_apps_and_nested_application_archives_are_not_scanned(self):
        names = [self.desktop.with_name("Xclip-old.app"), self.desktop.parent / "archive/Xclip.app",
                 self.user_applications.with_name("MyXclip.app"), self.system_applications.parent / "Archive/Xclip.app"]
        copies = [self.bundle(path, "saved") for path in names]
        self.make().run()
        for app in copies:
            self.assertEqual(self.value(app), "saved")
        self.project_sign.assert_not_called()

    def test_external_symlink_and_symlinked_parent_are_preserved(self):
        outside = self.bundle("archive/Xclip.app", "saved")
        self.desktop.parent.mkdir(parents=True)
        self.desktop.symlink_to(outside)
        self.user_applications.parent.symlink_to(outside.parent, target_is_directory=True)
        self.make().run()
        self.assertTrue(self.desktop.is_symlink())
        self.assertTrue(self.user_applications.parent.is_symlink())
        self.assertEqual(self.value(outside), "saved")

    def test_extra_external_user_file_and_declared_test_data_are_preserved(self):
        self.bundle(self.desktop, "desktop")
        note = self.desktop / "Contents/Resources/private-note.txt"
        note.parent.mkdir(); note.write_text("user content")
        self.bundle(self.user_applications, "test app")
        user_data = self.repo.parent / "history.json"; user_data.write_text("private history")
        self.metadata(self.user_applications, CClipTestDataDirectory=str(user_data))
        self.make().run()
        self.assertEqual(note.read_text(), "user content")
        self.assertTrue(self.user_applications.exists())
        self.assertEqual(user_data.read_text(), "private history")

    def test_even_sealed_history_directories_are_preserved(self):
        self.bundle(self.desktop, "desktop")
        history = self.desktop / "Contents/Resources/history/private.txt"
        history.parent.mkdir(parents=True); history.write_text("private")
        (self.desktop / "Contents/_CodeSignature/CodeResources").write_bytes(plistlib.dumps({"files2": {"Resources/history/private.txt": b"sealed"}}))
        self.make().run()
        self.assertEqual(history.read_text(), "private")

    def test_missing_resource_manifest_preserves_external_copy(self):
        self.bundle(self.desktop, "desktop")
        (self.desktop / "Contents/_CodeSignature/CodeResources").unlink()
        self.make().run()
        self.assertEqual(self.value(self.desktop), "desktop")

    def test_running_verified_external_copy_blocks_install_without_killing(self):
        self.bundle(self.desktop, "running")
        self.processes.return_value = [(456, self.desktop / "Contents/MacOS/Xclip")]
        with self.assertRaisesRegex(installer.InstallError, "PID 456"):
            self.make().run()
        self.assertEqual(self.value(self.desktop), "running")
        self.copy.assert_not_called()
        self.registration.assert_not_called()

    def test_git_tracked_external_copy_is_preserved_before_install(self):
        self.bundle(self.desktop, "tracked")
        repository = self.desktop.parent.parent
        (repository / ".git").mkdir()
        self.tracked.side_effect = lambda root: [self.desktop / "Contents/Info.plist"] if root == repository else []
        with self.assertRaisesRegex(installer.InstallError, "Git"):
            self.make().run()
        self.assertEqual(self.value(self.desktop), "tracked")
        self.copy.assert_not_called()

    def test_external_identity_is_rechecked_immediately_before_removal(self):
        self.bundle(self.desktop, "changed after planning")
        installed = False
        def register(path, unregister=False):
            nonlocal installed
            if path == self.target and not unregister:
                installed = True
        self.registration.side_effect = register
        def verify(path, certificate):
            if installed and path == self.desktop:
                raise installer.InstallError("identity changed")
        self.project_sign.side_effect = verify
        with self.assertRaisesRegex(installer.InstallError, "identity changed"):
            self.make().run()
        self.assertEqual(self.value(), "new")
        self.assertEqual(self.value(self.desktop), "changed after planning")
        self.assertNotIn(((self.desktop,), {"unregister": True}), self.registration.call_args_list)

    def test_external_process_started_after_planning_is_preserved(self):
        self.bundle(self.desktop, "started later")
        def register(path, unregister=False):
            if path == self.target and not unregister:
                self.processes.return_value = [(789, self.desktop / "Contents/MacOS/Xclip")]
        self.registration.side_effect = register
        with self.assertRaisesRegex(installer.InstallError, "PID 789"):
            self.make().run()
        self.assertEqual(self.value(self.desktop), "started later")

    def test_external_removal_requires_a_validated_plan(self):
        self.bundle(self.desktop, "keep")
        with self.assertRaisesRegex(installer.InstallError, "清理范围"):
            self.make().remove_copy(self.desktop)
        self.assertEqual(self.value(self.desktop), "keep")

    def test_process_started_during_final_signature_check_is_preserved(self):
        self.bundle(self.desktop, "started during verification")
        installed = False
        def register(path, unregister=False):
            nonlocal installed
            if path == self.target and not unregister:
                installed = True
        self.registration.side_effect = register
        def verify(path, certificate):
            if installed and path == self.desktop:
                self.processes.return_value = [(987, self.desktop / "Contents/MacOS/Xclip")]
        self.project_sign.side_effect = verify
        with self.assertRaisesRegex(installer.InstallError, "PID 987"):
            self.make().run()
        self.assertEqual(self.value(self.desktop), "started during verification")
        self.assertNotIn(((self.desktop,), {"unregister": True}), self.registration.call_args_list)

    def test_project_signature_checks_signed_identity_and_every_architecture(self):
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as process:
            VERIFY_PROJECT_SIGNATURE(self.source, "f" * 40)
        command = process.call_args.args[0]
        self.assertIn("--all-architectures", command)
        self.assertEqual(command[command.index("-R") + 1], '=identifier "local.cclip.app" and certificate leaf = H"' + "f" * 40 + '"')
        self.sign.assert_called_once_with(self.source)

    def test_certificate_fingerprint_comes_from_extracted_leaf_bytes(self):
        def run(arguments, **kwargs):
            prefix = next(item.split("=", 1)[1] for item in arguments if item.startswith("--extract-certificates="))
            Path(prefix + "0").write_bytes(b"synthetic certificate")
            return subprocess.CompletedProcess(arguments, 0, "", "")
        with patch.object(installer.subprocess, "run", side_effect=run):
            self.assertEqual(SIGNING_CERTIFICATE(self.source), installer.hashlib.sha1(b"synthetic certificate").hexdigest())


if __name__ == "__main__":
    unittest.main()
