# Testing and audit

Run python3 tests/run.py --luau /path/to/luau --optimization 2. CI runs the same suites at O0, O1 and O2 using a checksum-pinned official Luau executable.

The test adapter simulates optimistic transform replay, errors before commit, errors after commit, conflicting owners, metadata, detached snapshots, invalid inputs, migration failures, local expiry and coroutine scheduling. It includes a fixed-seed 1,000-scenario two-owner campaign. The fake store is not Roblox DataStore; the simulated scheduler is not Studio's scheduler.

Audit decisions: each acquisition has a unique GUID; only atomic ownership comparison can authorize writes; release retries use a marker; snapshots remain stable during retries; local expiration freezes handles; unknown record formats fail closed. Invalid close arguments do not permanently disable the manager.

Studio smoke test: the maintainer reported 9/9 passing on rc.3 in an empty published test experience with real Roblox API access (2026-11-27). This is a user-reported result, not independently recorded telemetry. Both managers ran in one Studio server. Remaining integration gates: actual joins/rejoins across live servers, DataStore budgets, prolonged outages and shutdown under load. No production certification claimed.

The candidate also tests differing lease policies, loss of ownership during shutdown, and misspelled configuration keys. A Studio smoke script is included for a fresh, published test experience with API access. It writes only to a dedicated test store with a random key, not to a player profile. It is not executed by CI.

## Optional external LuauProof audit

The rc.3 audit uses the original LuauProof 3.20 numeric grammar, operand generator, rational binary64 oracle and bundled Luau VM. The private toolkit is not included or required for CI.

Run `python3 tests/luauproof_attack.py --luauproof /path/to/luauproof --seed 32027 --out audit.json` from the repository root. Repeat with seed 32028. The script verifies the pinned external tool hashes. [Evidence](../tests/evidence/rc3/) binds results to source hashes. The matched rc.2 campaign identified one malformed configuration case (false timeout was silently defaulted), repeated in three optimization modes. rc.3 rejects explicitly false numeric options and invalid store adapters. The two rc.3 campaigns recorded 324,810 checks with zero observed differences, including 73,728 arithmetic-oracle checks and repeated inputs across VM optimizations. These are finite simulated-store observations, not unique attacks, real DataStore tests or a formal proof.

The v3.0.0 module differs from the audited rc.3 module only in the VERSION string. The historical audit hashes intentionally identify rc.3. CI reruns the regression suite for the final release.
