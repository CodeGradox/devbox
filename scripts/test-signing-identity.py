#!/usr/bin/env python3
"""Credential-free regression tests for Developer ID selection."""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
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


class NotarizeKeychainTests(unittest.TestCase):
    """Run a copied release script with an isolated, entirely fake toolchain."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="notarize Å 'quoted' ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(Path(__file__).parent / "notarize-app.sh", scripts / "notarize-app.sh")
        (scripts / "build-app.sh").write_text('exec mock-build\n')
        tools = self.root / "tools"
        tools.mkdir()
        # No inherited PATH: an omitted signing/notary mock must never fall
        # through to the host's security, codesign, or Apple command-line tools.
        for name in ("sh", "dirname", "mktemp", "rm", "grep"):
            executable = shutil.which(name)
            self.assertIsNotNone(executable, name)
            (tools / name).symlink_to(executable)
        (tools / "python3").symlink_to(sys.executable)
        mock = tools / "mock-tool"
        mock.write_text("#!" + sys.executable + "\n" + textwrap.dedent(r'''
            import json
            import os
            from pathlib import Path
            import shlex
            import sys

            tool = Path(sys.argv[0]).name
            args = sys.argv[1:]
            state_file = Path(os.environ["MOCK_STATE"])
            state = json.loads(state_file.read_text())
            credentials = os.environ.get("DEVBOX_CREDENTIALS_DIRECTORY")
            event = {
                "tool": tool, "args": args, "search": state,
                "keychain": os.environ.get("DEVBOX_SIGNING_KEYCHAIN"),
                "credentials": credentials,
                "credentials_exist": bool(credentials and Path(credentials).is_dir()),
            }
            with open(os.environ["MOCK_LOG"], "a") as log:
                log.write(json.dumps(event) + "\n")
            failure = os.environ["MOCK_FAILURE"]
            if tool == "security":
                operation = args[0]
                if operation == "default-keychain":
                    sys.exit("The release must not change the default keychain")
                if operation == "list-keychains":
                    assert args[1:3] == ["-d", "user"], args
                    if args[3:] == []:
                        if failure == "capture":
                            sys.exit(41)
                        # Shell-quoted output exercises spaces, Unicode and both
                        # kinds of quotes without splitting paths into words.
                        for path in state:
                            print("    " + shlex.quote(path))
                    else:
                        assert args[3] == "-s", args
                        state_file.write_text(json.dumps(args[4:]))
                elif operation == "create-keychain":
                    # Model create-keychain changing the list: capturing after
                    # this command would silently restore the wrong state.
                    state_file.write_text(json.dumps(state + [args[-1]]))
                elif operation == "import":
                    if failure == "import":
                        sys.exit(42)
                elif operation not in (
                    "set-keychain-settings", "unlock-keychain",
                    "set-key-partition-list", "delete-keychain",
                ):
                    sys.exit("Unexpected security command: " + repr(args))
            elif tool == "mock-build":
                if failure == "build":
                    sys.exit(43)
            elif tool == "openssl":
                print("0" * 64)
            elif tool == "codesign":
                if "-dv" in args:
                    print("Authority=Developer ID Application: Fixture")
                    print("flags=runtime")
                    print("Timestamp=fixture")
            elif tool == "xcrun":
                if args[:2] == ["notarytool", "submit"]:
                    print(json.dumps({"id": "fixture", "status": "Accepted"}))
            elif tool not in ("ditto", "spctl"):
                sys.exit("Unexpected tool: " + tool)
        '''))
        mock.chmod(0o755)
        for name in ("security", "mock-build", "openssl", "codesign", "ditto", "xcrun", "spctl"):
            (tools / name).symlink_to(mock)
        self.original = [
            '/Users/Fixture Å/Library/Keychains/login "work".keychain-db',
            "/Users/Fixture Å/Library/Keychains/team's keys.keychain-db",
            "/Library/Keychains/System.keychain",
        ]
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps(self.original))
        self.log = self.root / "events.jsonl"
        runner = self.root / "runner"
        runner.mkdir()
        self.environment = {
            "PATH": str(tools),
            "HOME": str(self.root),
            "RUNNER_TEMP": str(runner),
            "BUILD_DIR": str(self.root / "build"),
            "DEVBOX_CERTIFICATE_BASE64": "ZmFrZQ==",
            "DEVBOX_CERTIFICATE_PASSWORD": "fixture-only",
            "DEVBOX_SIGNING_IDENTITY": NAME,
            "DEVBOX_NOTARY_KEY_BASE64": "ZmFrZQ==",
            "DEVBOX_NOTARY_KEY_ID": "fixture",
            "DEVBOX_NOTARY_ISSUER_ID": "fixture",
            "MOCK_STATE": str(self.state),
            "MOCK_LOG": str(self.log),
            "MOCK_FAILURE": "",
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def notarize(self, failure=""):
        self.environment["MOCK_FAILURE"] = failure
        result = subprocess.run(
            [str(self.root / "tools" / "sh"), str(self.root / "scripts" / "notarize-app.sh")],
            env=self.environment, capture_output=True, text=True, timeout=20,
        )
        self.events = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result

    def security_calls(self, operation):
        return [
            event for event in self.events
            if event["tool"] == "security" and event["args"][0] == operation
        ]

    def assert_restored(self):
        self.assertEqual(json.loads(self.state.read_text()), self.original)
        updates = [
            event for event in self.security_calls("list-keychains")
            if event["args"][3:4] == ["-s"]
        ]
        self.assertTrue(updates, "cleanup must explicitly restore the captured search list")
        self.assertEqual(updates[-1]["args"], ["list-keychains", "-d", "user", "-s", *self.original])
        deletion, = self.security_calls("delete-keychain")
        self.assertLess(self.events.index(updates[-1]), self.events.index(deletion))
        self.assertEqual(deletion["search"], self.original)
        self.assertTrue(deletion["credentials_exist"])
        self.assertFalse(Path(deletion["credentials"]).exists())
        self.assertEqual(list(Path(self.environment["RUNNER_TEMP"]).iterdir()), [])
        self.assertEqual(self.security_calls("default-keychain"), [])

    def assert_registered_before_build(self):
        calls = self.security_calls("list-keychains")
        self.assertTrue(calls, "capture the original search list before creating a keychain")
        capture = calls[0]
        self.assertEqual(capture["args"], ["list-keychains", "-d", "user"])
        creation, = self.security_calls("create-keychain")
        self.assertLess(self.events.index(capture), self.events.index(creation))
        build, = [event for event in self.events if event["tool"] == "mock-build"]
        registration = next(
            event for event in self.security_calls("list-keychains")
            if event["args"][3:4] == ["-s"]
        )
        self.assertEqual(registration["args"], [
            "list-keychains", "-d", "user", "-s", build["keychain"], *self.original,
        ])
        self.assertEqual(build["search"], [build["keychain"], *self.original])
        for operation in ("import", "set-key-partition-list"):
            call, = self.security_calls(operation)
            self.assertLess(self.events.index(call), self.events.index(registration))
        self.assertLess(self.events.index(registration), self.events.index(build))

    def test_restores_search_list_after_success(self):
        result = self.notarize()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_registered_before_build()
        self.assert_restored()
        self.assertTrue(any(
            event["tool"] == "xcrun" and event["args"][:2] == ["notarytool", "submit"]
            for event in self.events
        ))

    def test_restores_search_list_after_import_failure(self):
        result = self.notarize("import")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(event["tool"] == "mock-build" for event in self.events))
        self.assert_restored()

    def test_restores_search_list_after_build_failure(self):
        result = self.notarize("build")
        self.assertNotEqual(result.returncode, 0)
        self.assert_registered_before_build()
        self.assert_restored()
        self.assertFalse(any(event["tool"] == "xcrun" for event in self.events))

    def test_failed_capture_does_not_restore_an_empty_search_list(self):
        result = self.notarize("capture")
        self.assertNotEqual(result.returncode, 0)
        calls = self.security_calls("list-keychains")
        self.assertEqual([event["args"] for event in calls], [["list-keychains", "-d", "user"]])
        self.assertEqual(self.security_calls("create-keychain"), [])
        self.assertFalse(any(event["tool"] == "mock-build" for event in self.events))
        self.assertEqual(json.loads(self.state.read_text()), self.original)
        self.assertEqual(list(Path(self.environment["RUNNER_TEMP"]).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
