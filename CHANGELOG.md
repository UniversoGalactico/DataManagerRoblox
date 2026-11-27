# Changelog

## 3.0.0 — 2026-11-27

- Generic profile API and explicit v3 storage envelope (breaking change; use a fresh store or explicit offline migration).
- Per-acquisition ownership, atomic writes, release acknowledgement recovery, validated snapshots and bounded background saves.
- 25 regression suites at O0/O1/O2, finite external adversarial audit on rc.3, and maintainer-reported Studio smoke test 9/9 on real DataStore.
- Final module changes only the version string relative to rc.3. No guarantees of crash-proof persistence, cross-server load performance or production certification.
