#!/usr/bin/env python3
"""Resolve the expected Developer ID name to a valid certificate fingerprint."""

import os
import re
import subprocess
import sys
import unicodedata


DEVELOPER_ID_PREFIX = "Developer ID Application:"


def resolve_identity(expected, identities_output):
    if not expected.startswith(DEVELOPER_ID_PREFIX):
        raise ValueError("A Developer ID Application identity is required.")

    identities = re.findall(
        r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^\r\n]+)"\s*$',
        identities_output,
        re.MULTILINE,
    )
    if not identities:
        raise ValueError(
            "No valid code-signing identities were found in the signing keychain. "
            "Check that the .p12 contains the certificate and its private key, "
            "and that the certificate is valid and its Apple chain is trusted."
        )

    developer_ids = [
        (fingerprint, name)
        for fingerprint, name in identities
        if name.startswith(DEVELOPER_ID_PREFIX)
    ]
    if not developer_ids:
        raise ValueError(
            "The signing keychain contains valid identities, but none is a "
            "Developer ID Application identity. Export the Apple-issued certificate "
            "with its private key, not the local development identity."
        )

    # Equivalent Unicode spellings (e.g. composed/decomposed Å) identify the same
    # name. Do not silently choose a different developer or team.
    expected = unicodedata.normalize("NFC", expected)
    matches = {
        fingerprint.upper()
        for fingerprint, name in developer_ids
        if unicodedata.normalize("NFC", name) == expected
    }
    if not matches:
        raise ValueError(
            "A valid Developer ID Application identity is present, but its name "
            "does not match DEVBOX_SIGNING_IDENTITY. Check the exact certificate "
            "name and team ID, or export the matching identity into the .p12."
        )
    if len(matches) != 1:
        raise ValueError(
            "Multiple valid certificates match DEVBOX_SIGNING_IDENTITY. "
            "Export only the intended signing identity into the .p12."
        )
    return matches.pop()


def main():
    command = ["security", "find-identity", "-v", "-p", "codesigning"]
    if keychain := os.environ.get("DEVBOX_SIGNING_KEYCHAIN"):
        command.append(keychain)
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        # Do not dump keychain contents or credential-derived output into CI logs.
        sys.exit("Could not inspect the signing keychain with security find-identity.")
    try:
        fingerprint = resolve_identity(
            os.environ.get("DEVBOX_SIGNING_IDENTITY", ""), result.stdout
        )
    except ValueError as error:
        sys.exit(str(error))
    print(fingerprint)


if __name__ == "__main__":
    main()
