#!/usr/bin/env python3
"""Check a distribution ZIP for accidental credentials, home paths, and local data.

This is a release guard, not a guarantee that arbitrary secrets can be detected.
Print categories and filenames only, never matching values.
"""
import re
import sys
import zipfile
from pathlib import PurePosixPath

patterns = {
    "credential pattern": rb"(?:sk-or-v1-[A-Za-z0-9_-]{20,}|gsk_[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})",
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "builder home path": rb"/Users/[^/\s\x00]+/|/home/[^/\s\x00]+/",
}
failed = False
with zipfile.ZipFile(sys.argv[1]) as archive:
    for entry in archive.infolist():
        path = PurePosixPath(entry.filename)
        if path.is_absolute() or ".." in path.parts:
            print("Unsafe archive path"); failed = True
        if path.name in {"history.json", "usage.json", ".env", ".DS_Store"} or path.suffix in {".m4a", ".wav"}:
            print(f"Local data file: {path.name}"); failed = True
        for label, pattern in patterns.items():
            if re.search(pattern, archive.read(entry)):
                print(f"{label}: {entry.filename}"); failed = True
if failed:
    sys.exit(1)
print("Release checks passed: no recognized credentials, home paths, or local data files.")
