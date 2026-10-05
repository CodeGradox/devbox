#!/usr/bin/env python3
"""Credential-free regression tests for Developer ID selection."""

import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from signing_identity import main, resolve_identity


NAME = "Developer ID Application: Example Å Name (TEAM123456)"
FINGERPRINT = "A" * 40
OTHER_FINGERPRINT = "B" * 40


def identity(name=NAME, fingerprint=FINGERPRINT):
    return f'  1) {fingerprint} "{name}"\n     1 valid identities found\n'


class SigningIdentityTests(unittest.TestCase):
    def test_resolves_exact_name_to_fingerprint(self):
        self.assertEqual(resolve_identity(NAME, identity()), FINGERPRINT)

    def test_accepts_quotes_in_certificate_name(self):
        quoted = NAME.replace("Example", 'Example "Tools"')
        self.assertEqual(resolve_identity(quoted, identity(quoted)), FINGERPRINT)

    def test_accepts_canonically_equivalent_unicode(self):
        decomposed = NAME.replace("Å", "A\u030a")
        self.assertEqual(resolve_identity(NAME, identity(decomposed)), FINGERPRINT)
        self.assertEqual(resolve_identity(decomposed, identity()), FINGERPRINT)

    def test_ignores_other_identities(self):
        output = identity("Devbox Local Development", OTHER_FINGERPRINT) + identity()
        self.assertEqual(resolve_identity(NAME, output), FINGERPRINT)

    def test_duplicate_listing_of_same_certificate_is_not_ambiguous(self):
        self.assertEqual(resolve_identity(NAME, identity() * 2), FINGERPRINT)

    def test_rejects_invalid_or_missing_identity(self):
        for output in ("", "     0 valid identities found\n"):
            with self.subTest(output=output), self.assertRaisesRegex(
                ValueError, "No valid code-signing identities"
            ):
                resolve_identity(NAME, output)

    def test_rejects_local_certificate(self):
        with self.assertRaisesRegex(ValueError, "none is a Developer ID"):
            resolve_identity(NAME, identity("Devbox Local Development"))

    def test_does_not_select_another_developer_or_team(self):
        for different in (
            NAME.replace("Example", "Other"),
            NAME.replace("TEAM123456", "TEAM654321"),
            NAME.replace("Å", "A"),
            NAME + " ",
        ):
            with self.subTest(name=different), self.assertRaisesRegex(
                ValueError, "does not match"
            ):
                resolve_identity(NAME, identity(different))

    def test_rejects_ambiguous_name(self):
        output = identity() + identity(fingerprint=OTHER_FINGERPRINT)
        with self.assertRaisesRegex(ValueError, "Multiple valid certificates"):
            resolve_identity(NAME, output)

    def test_requires_developer_id(self):
        for name in ("", "-", "Devbox Local Development", "Apple Development: Example"):
            with self.subTest(name=name), self.assertRaisesRegex(
                ValueError, "Developer ID Application identity is required"
            ):
                resolve_identity(name, identity())

    @patch("signing_identity.subprocess.run")
    def test_inspects_only_the_supplied_keychain(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, identity(), "")
        environment = {
            "DEVBOX_SIGNING_IDENTITY": NAME,
            "DEVBOX_SIGNING_KEYCHAIN": "/temporary path/release.keychain-db",
        }
        output = io.StringIO()
        with patch.dict(os.environ, environment, clear=True), contextlib.redirect_stdout(output):
            main()
        run.assert_called_once_with(
            [
                "security", "find-identity", "-v", "-p", "codesigning",
                environment["DEVBOX_SIGNING_KEYCHAIN"],
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(output.getvalue(), FINGERPRINT + "\n")

    @patch("signing_identity.subprocess.run")
    def test_inspection_failure_does_not_log_raw_output(self, run):
        run.return_value = subprocess.CompletedProcess(
            [], 1, "untrusted stdout", "untrusted stderr"
        )
        with self.assertRaises(SystemExit) as raised:
            main()
        self.assertEqual(
            str(raised.exception),
            "Could not inspect the signing keychain with security find-identity.",
        )


class BuildSigningTests(unittest.TestCase):
    """Exercise the real build script with fake tools, never actual signing keys."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("build-app.sh", "signing_identity.py"):
            shutil.copyfile(Path(__file__).parent / name, scripts / name)
        resources = self.root / "Resources"
        resources.mkdir()
        (resources / "Info.plist").write_text("unused fixture")
        binary_directory = self.root / "binary"
        binary_directory.mkdir()
        (binary_directory / "DevBox").write_text("unused fixture")
        tools = self.root / "tools"
        tools.mkdir()
        self.log = self.root / "commands.log"
        self.identities = self.root / "identities.txt"
        self.identities.write_text(identity(), encoding="utf-8")
        commands = {
            "security": (
                'printf "%s\\n" security "$@" >> "$COMMAND_LOG"\n'
                'cat "$IDENTITIES_FILE"\n'
            ),
            "swift": (
                'printf "%s\\n" swift "$@" >> "$COMMAND_LOG"\n'
                'printf "%s\\n" "$FAKE_BINARY_DIRECTORY"\n'
            ),
            "codesign": 'printf "%s\\n" codesign "$@" >> "$COMMAND_LOG"\n',
        }
        for name, contents in commands.items():
            executable = tools / name
            executable.write_text("#!/bin/sh\nset -eu\n" + contents)
            executable.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "COMMAND_LOG": str(self.log),
            "IDENTITIES_FILE": str(self.identities),
            "FAKE_BINARY_DIRECTORY": str(binary_directory),
            "DEVBOX_SIGNING_IDENTITY": NAME,
            "DEVBOX_SIGNING_KEYCHAIN": str(self.root / "temporary keychain.keychain-db"),
            "BUILD_DIR": str(self.root / "app output"),
            "SWIFT_BUILD_PATH": str(self.root / "swift output"),
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def build(self):
        return subprocess.run(
            ["sh", str(self.root / "scripts" / "build-app.sh")],
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def test_signs_by_fingerprint_with_runtime_and_explicit_keychain(self):
        self.identities.write_text(identity(NAME.replace("Å", "A\u030a")), encoding="utf-8")
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.log.read_text().splitlines()
        self.assertEqual(commands[:6], [
            "security", "find-identity", "-v", "-p", "codesigning",
            self.environment["DEVBOX_SIGNING_KEYCHAIN"],
        ])
        signing = commands[commands.index("codesign"):]
        self.assertEqual(signing[:11], [
            "codesign", "--force", "--sign", FINGERPRINT,
            "--options", "runtime", "--timestamp",
            "--entitlements", "Resources/DevBox.entitlements",
            "--keychain", self.environment["DEVBOX_SIGNING_KEYCHAIN"],
        ])
        self.assertEqual(signing[12:15], ["codesign", "--verify", "--strict"])

    def test_wrong_import_fails_before_build_without_logging_names(self):
        self.identities.write_text(identity("Devbox Local Development"))
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("none is a Developer ID", result.stderr)
        commands = self.log.read_text().splitlines()
        self.assertNotIn("swift", commands)
        self.assertNotIn("codesign", commands)
        self.assertNotIn(NAME, result.stdout + result.stderr)
        self.assertNotIn("Devbox Local Development", result.stdout + result.stderr)

    def test_ad_hoc_and_local_builds_keep_existing_signing_behavior(self):
        for name in ("-", "Devbox Local Development"):
            with self.subTest(name=name):
                self.log.write_text("")
                self.environment["DEVBOX_SIGNING_IDENTITY"] = name
                result = self.build()
                self.assertEqual(result.returncode, 0, result.stderr)
                commands = self.log.read_text().splitlines()
                self.assertNotIn("security", commands)
                self.assertNotIn("--options", commands)
                signing = commands[commands.index("codesign"):]
                self.assertEqual(signing[:4], ["codesign", "--force", "--sign", name])


if __name__ == "__main__":
    unittest.main()
