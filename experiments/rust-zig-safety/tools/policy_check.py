#!/usr/bin/env python3
"""Deliberately restrictive text policy for Zig application files.

This is a gate over source patterns, NOT a borrow checker or a proof of safety.
Only app.zig is checked; core.zig is explicitly an audited trust boundary.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re

RULES: dict[str, str] = {
    "raw_heap": r"\b(?:alloc|free|create|destroy|resize|realloc|dupe)\s*\(",
    "raw_pointer_ops": r"@(?:ptrCast|ptrFromInt|intFromPtr|alignCast)\s*\(|\[\*c?\]|\.ptr\b",
    "direct_threading": r"\bstd\.Thread\b|\.spawn\s*\(",
    "unchecked_index": r"\b[a-zA-Z_]\w*\s*\[[^\]\n]+\]",
    "unsafe_control": r"\b(?:undefined|unreachable)\b|@setRuntimeSafety\s*\(",
    "manual_copy": r"@memcpy\s*\(|@memset\s*\(",
}
ALLOWED_IMPORTS = {"std", "core.zig"}


def check_text(source: str) -> list[str]:
    # Remove Zig line comments to avoid false positives in instructions.
    body = "\n".join(line.split("//", 1)[0] for line in source.splitlines())
    issues: list[str] = []
    for number, line in enumerate(body.splitlines(), start=1):
        for rule, regex in RULES.items():
            if re.search(regex, line):
                issues.append(f"L{number}: {rule}")
        for value in re.findall(r'@import\s*\(\s*"([^"]+)"\s*\)', line):
            if value not in ALLOWED_IMPORTS:
                issues.append(f"L{number}: unauthorized_import({value})")
    return issues


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("file", type=Path)
    args = p.parse_args()
    issues = check_text(args.file.read_text(encoding="utf-8"))
    if issues:
        print(f"DENIED: {args.file}")
        print("\n".join(f"  {x}" for x in issues))
        return 1
    print(f"ALLOWED: {args.file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
