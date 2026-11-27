# Testing and audit

Run python3 tests/run.py --luau /path/to/luau --optimization 2. CI runs the same suites at O0, O1 and O2 using a checksum-pinned official Luau executable.

The test adapter simulates optimistic transform replay, errors before commit, errors after commit, conflicting owners, metadata, detached snapshots, invalid inputs, migration failures, local expiry and coroutine scheduling. It includes a fixed-seed 1,000-scenario two-owner campaign. The fake store is not Roblox DataStore; the simulated scheduler is not Studio's scheduler.

Audit decisions: each acquisition has a unique GUID; only atomic ownership comparison can authorize writes; release retries use a marker; snapshots remain stable during retries; local expiration freezes handles; unknown record formats fail closed. Invalid close arguments do not permanently disable the manager.

Remaining integration gates: run in a separate published test experience with API access and a fresh store, exercise actual joins/rejoins and two live servers, verify DataStore budgets and shutdown under load. No real-service measurements or production certification claimed.
