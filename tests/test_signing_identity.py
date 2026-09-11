#!/usr/bin/env python3
"""Signing selection tests use fixtures; they never sign code or edit keychains."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("signing", Path(__file__).resolve().parents[1] / "scripts/select-signing-identity.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
A, B = "A" * 40, "B" * 40


class SigningIdentityTests(unittest.TestCase):
    def test_parse_valid_identity_output(self):
        output = f'  1) {A} "Apple Development: Example (TEAM)"\n     1 valid identities found\n'
        self.assertEqual(signing.parse_identities(output), {A: "Apple Development: Example (TEAM)"})

    def test_parse_deduplicates_same_certificate(self):
        self.assertEqual(signing.parse_identities(f'1) {A} "One"\n2) {A} "One"'), {A: "One"})

    def test_no_certificate_initial_build_uses_adhoc(self):
        self.assertEqual(signing.choose_identity({}), "-")

    def test_only_valid_certificate_is_selected(self):
        self.assertEqual(signing.choose_identity({A: "One"}), A)

    def test_multiple_certificates_need_choice(self):
        with self.assertRaises(signing.SigningError):
            signing.choose_identity({A: "One", B: "Two"})

    def test_installed_certificate_is_reused_among_multiple(self):
        self.assertEqual(signing.choose_identity({A: "One", B: "Two"}, installed=B), B)

    def test_missing_installed_certificate_never_falls_back_to_adhoc(self):
        with self.assertRaises(signing.SigningError):
            signing.choose_identity({}, installed=A)

    def test_missing_installed_certificate_never_silently_changes_identity(self):
        with self.assertRaises(signing.SigningError):
            signing.choose_identity({B: "Two"}, installed=A)

    def test_explicit_hash_accepts_lowercase(self):
        self.assertEqual(signing.choose_identity({A: "One"}, explicit=A.lower()), A)

    def test_explicit_name_is_exact(self):
        self.assertEqual(signing.choose_identity({A: "One", B: "Two"}, explicit="Two"), B)
        with self.assertRaises(signing.SigningError):
            signing.choose_identity({A: "One"}, explicit="On")

    def test_duplicate_names_need_hash(self):
        with self.assertRaises(signing.SigningError):
            signing.choose_identity({A: "Same", B: "Same"}, explicit="Same")

    def test_invalid_explicit_certificate_does_not_fallback(self):
        with self.assertRaises(signing.SigningError):
            signing.choose_identity({A: "One"}, explicit=B)

    def test_explicit_adhoc_is_allowed_without_installed_certificate(self):
        self.assertEqual(signing.choose_identity({A: "One"}, explicit="-"), "-")

    def test_explicit_adhoc_cannot_downgrade_installed_certificate(self):
        with self.assertRaises(signing.SigningError):
            signing.choose_identity({A: "One"}, explicit="-", installed=A)

    def test_explicit_valid_certificate_can_rotate_identity(self):
        self.assertEqual(signing.choose_identity({B: "Two"}, explicit=B, installed=A), B)

    def test_empty_explicit_value_is_an_error(self):
        with self.assertRaises(signing.SigningError):
            signing.choose_identity({A: "One"}, explicit="")

    def test_missing_installation_has_no_certificate(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertIsNone(signing.installed_certificate(Path(folder) / "missing.app"))

    def test_adhoc_installation_is_detected_explicitly(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(signing.subprocess, "run") as run:
            run.side_effect = [subprocess.CompletedProcess([], 0, "", ""),
                               subprocess.CompletedProcess([], 0, "", "Signature=adhoc\n")]
            self.assertIsNone(signing.installed_certificate(Path(folder)))
            self.assertTrue(run.call_args_list[0].args[0][2].startswith("--extract-certificates="))

    def test_unreadable_installed_signature_stops_build(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(signing.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 1, "", "unsigned")
            with self.assertRaises(signing.SigningError):
                signing.installed_certificate(Path(folder))

    def test_missing_certificate_is_not_assumed_adhoc(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(signing.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "", "Authority=(unavailable)\n")
            with self.assertRaises(signing.SigningError):
                signing.installed_certificate(Path(folder))


if __name__ == "__main__":
    unittest.main()
