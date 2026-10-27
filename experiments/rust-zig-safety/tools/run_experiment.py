#!/usr/bin/env python3
"""Reproducible tests. Runs only installed compilers; NEVER fabricates results."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"


def run_case(name: str, argv: list[str], expected: str = "zero", seconds: int = 35) -> dict:
    tool = argv[0]
    if ("/" not in tool and shutil.which(tool) is None) or ("/" in tool and not Path(tool).exists()):
        return {"name": name, "status": "NOT_RUN", "reason": f"tool/executable unavailable: {tool}", "command": argv}
    start = time.monotonic()
    try:
        proc = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True, timeout=seconds)
        rc = proc.returncode
        captured = ((proc.stdout or "") + "\n" + (proc.stderr or ""))[-30000:]
        if expected == "observation":
            status = "OBSERVED_ONLY"  # UB passing or failing proves nothing in absence of sanitizer
        elif (rc == 0) == (expected == "zero"):
            status = "PASS_EXPECTED"
        else:
            status = "UNEXPECTED"
        classification = ("compiler-diagnostic" if "error:" in captured and "panic:" not in captured else
                          "runtime-panic" if "panic:" in captured else
                          "leak-report" if "leaked" in captured.lower() else
                          "nonzero-other" if rc != 0 else "success")
        return {"name": name, "status": status, "expected": expected,
                "exit_code": rc, "classification_heuristic": classification,
                "duration_sec": round(time.monotonic() - start, 3), "command": argv,
                "output_tail": captured}
    except subprocess.TimeoutExpired as exc:
        return {"name": name, "status": "TIMEOUT", "command": argv, "reason": str(exc)}


def source_metrics() -> dict:
    data = {}
    files = {
        "zig_plain": [ROOT / "zig_plain/app.zig"],
        "zig_restricted": [ROOT / "zig_restricted/app.zig", ROOT / "zig_restricted/core.zig"],
        "rust_safe": [ROOT / "rust_safe/src/lib.rs"],
    }
    for name, paths in files.items():
        texts = [p.read_text() for p in paths]
        data[name] = {
            "nonblank_noncomment_loc": sum(sum(bool(line.strip()) and not line.lstrip().startswith(("//", "//!")) for line in text.splitlines()) for text in texts),
            "file_count": len(paths),
            "alloc_site_mentions": sum(len(re.findall(r"(?:\.alloc\(|\.to_vec\()", text)) for text in texts),
        }
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dangerous", action="store_true", help="Run UB fault cases in separate subprocesses; results are observations only")
    args = parser.parse_args()
    RESULTS.mkdir(exist_ok=True)
    cases: list[dict] = []
    def add(name: str, argv: list[str], expected="zero", seconds=35):
        result = run_case(name, argv, expected, seconds)
        cases.append(result)
        print(f"{name}: {result['status']}" + (f" (exit={result.get('exit_code')})" if 'exit_code' in result else ''), flush=True)

    add("policy-positive", [sys.executable, "tools/policy_check.py", "zig_restricted/app.zig"])
    add("policy-negative-selftests", [sys.executable, "tools/test_policy.py"])
    add("zig-plain-Debug", ["zig", "test", "zig_plain/app.zig", "-O", "debug"])
    add("zig-restricted-Debug", ["zig", "test", "zig_restricted/app.zig", "-O", "debug"])
    add("zig-plain-ReleaseSafe", ["zig", "test", "zig_plain/app.zig", "-O", "safe"])
    add("zig-restricted-ReleaseSafe", ["zig", "test", "zig_restricted/app.zig", "-O", "safe"])
    add("rust-safe", ["cargo", "test", "--manifest-path", "rust_safe/Cargo.toml", "--offline", "--quiet"])
    add("zig-out-of-bounds-Debug", ["zig", "test", "fixtures/zig_oob.zig", "-O", "debug"], "nonzero")
    add("zig-leak-Debug", ["zig", "test", "fixtures/zig_leak.zig", "-O", "debug"], "nonzero")
    add("rust-use-after-free-compile", ["rustc", "--edition=2021", "fixtures/rust_uaf.rs", "-o", "/tmp/rust_uaf_probe"], "nonzero")
    add("rust-shared-mut-race-compile", ["rustc", "--edition=2021", "fixtures/rust_race.rs", "-o", "/tmp/rust_race_probe"], "nonzero")
    add("rust-out-of-bounds-compile", ["rustc", "--edition=2021", "fixtures/rust_oob.rs", "-o", "/tmp/rust_oob_probe"])
    if Path("/tmp/rust_oob_probe").exists():
        add("rust-out-of-bounds-runtime", ["/tmp/rust_oob_probe", "8"], "nonzero")
    else:
        cases.append({"name": "rust-out-of-bounds-runtime", "status": "NOT_RUN", "reason": "compiled binary unavailable"})

    if args.dangerous:
        add("zig-UAF-UB-observation", ["zig", "test", "fixtures/zig_uaf.zig", "-O", "debug"], "observation", seconds=12)
        add("zig-race-UB-observation", ["zig", "test", "fixtures/zig_race.zig", "-O", "debug"], "observation", seconds=12)

    report = {"created_utc": datetime.now(timezone.utc).isoformat(),
              "platform": platform.platform(),
              "version": {k: shutil.which(k) for k in ("zig", "rustc", "cargo")},
              "cases": cases, "source_metrics": source_metrics(),
              "methodology_warning": "Restricted Zig is policy + trusted core, not Rust-like static lifetime proof. UB test passing means nothing."}
    (RESULTS / "results.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    rows = ["# Experimental results", "", "| Case | Outcome | Exit |", "|---|---|---:|"]
    for case in cases:
        rows.append(f"| {case['name']} | {case['status']} | {case.get('exit_code', '—')} |")
    rows += ["", "UNEXPECTED = actual result contradicted expected compiler/runtime response.",
             "OBSERVED_ONLY = UB test outcome is not a reliable safety determination.",
             "NOT_RUN = no native execution; do not report as pass or fail.", ""]
    (RESULTS / "results.md").write_text("\n".join(rows))
    print(f"Saved {RESULTS / 'results.json'}")
    # Missing compilers is not a failing build for local packaging, but is distinct in results.
    return 1 if any(c["status"] in ("UNEXPECTED", "TIMEOUT") for c in cases) else 0


if __name__ == "__main__":
    raise SystemExit(main())
