# Rust vs Plain Zig vs Restricted Zig — reproducible safety probe

**Stage:** prototype; no published compiler outcome until the actual CI logs exist.
**Language targets:** Zig 0.17.0, Rust stable (version recorded by CI).

This is NOT a benchmark proving one language is intrinsically safer or easier for AI; it
makes specific failure modes and a low-cost Zig safe-subset gate testable.

## Arms and identical task

* `zig_plain/app.zig`: direct allocation, copy, bounded checksum, two OS threads,
  one output slot per worker.
* `zig_restricted/app.zig`: same behavior through a small trusted
  `zig_restricted/core.zig`. Source policy prohibits direct allocator calls,
  pointer reinterpretation, direct indexing and raw thread spawning **in app.zig**.
* `rust_safe/src/lib.rs`: same behavior using `Vec`, immutable slices, and scoped threads.

Each arm tests empty, normal, length=64, length=65, and two parallel workers.
The Zig plain and restricted **trusted core** intentionally share the same algorithm;
this isolates the policy/API cost and avoids attributing architecture differences to Zig.
Count trusted code LOC separately; just counting application LOC would flatter the subset.

## Faults

| Fault | Zig plain | Zig restricted | Rust safe |
|---|---|---|---|
| Runtime out-of-bounds indexing | Debug `zig test fixtures/zig_oob.zig` should stop | gate forbids direct indexing in app | runtime bounds panic; not always compile error |
| Leaked allocation | `std.testing.allocator` should report leak | gate forbids allocator in app; trusted core must be audited | RAII cleans normal owned Vec case |
| Use after free | Zig can compile it; runtime outcome of UB NOT reliable | app gate forbids direct free and pointer casts | compile error E0382 |
| Unsynchronized shared write | Zig can compile; data race is UB | no direct spawn in app; core uses disjoint outputs | sample with simultaneous `&mut` fails borrow check |

### Important caveats

* `policy_check.py` uses text patterns, not AST or formal ownership analysis.
  It can produce false negatives and positives (aliases, FFI, metaprogramming).
* Direct allocator use in restricted application code is denied, but this does
  **not** ensure safe lifetime semantics in the trusted core. The core is a trusted
  computing base requiring audit and separate adversarial tests.
* Zig release-fast safety checks are intentionally out of scope; use Debug and
  ReleaseSafe. The `zig test` allocator reports leaks in Zig test mode.
* Fault detection is scored **by stage**, not averaged blindly. Passing a racy
  test or a use-after-free test is NOT proof that an implementation is safe.
* AI-generated-code error rate requires repeated generated tasks with a fixed
  prompt, a fixed model snapshot, blind scoring, and many trials. This prototype
  tests language/toolchain mechanisms only, not AI productivity.

## Run locally (if compilers installed)

```sh
python3 tools/run_experiment.py --dangerous
```

`--dangerous` additionally runs isolated intentionally-undefined-behavior cases;
their exit codes are observations only. Without this flag the deterministic
compiler-checked and runtime panic/leak checks still run.

Outputs: `results/results.json` and `results/results.md`; never interpret
`NOT_RUN` as passing.

## GitHub Actions

The workflow `.github/workflows/safety-compare.yml` is designed to be copied
into the **repository root** (not underneath this folder). Its push trigger is
restricted to the disposable experimental branch so that the unrelated main
project is not affected. It uses `mlugg/setup-zig@v2` for Zig 0.17.0 and the
GitHub-hosted Rust toolchain. Inspect the Actions run log before drawing conclusions.

## Independent references

* Zig 0.17 reference: https://ziglang.org/documentation/0.17.0/
* Zig 0.17 release: https://ziglang.org/download/
* Setup action: https://github.com/mlugg/setup-zig