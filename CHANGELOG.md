## 0.2.0

- Make multi-root admission non-blocking: do not wait for an active analysis
  or a memory timeout before deciding whether a root can be evicted.
- Reject immediately when the pool has no eligible root, and add a short
  post-eviction cooldown so stale memory samples cannot evict several roots in
  one request sequence.
- Treat macOS `warn` pressure as advisory for shared-pool new-root admission;
  reserve that admission rejection for `critical` pressure or insufficient
  physical headroom, and share one cooldown between admission and background
  eviction.
- Keep macOS `warn` as a pressure signal for the global single-worker budget,
  while shared-pool admission and background reclamation use the same advisory
  warn rule and wait for `critical` or insufficient physical headroom.
- Isolate integration and idle-session tests from caller-provided multi-root
  environment variables.

- Protect the opt-in multi-root pool with bounded root admission and system
  memory checks. When the pool cannot safely admit a root, `dana` reports the
  reason and does not silently start a separate analyzer.
- Reclaim eligible idle non-primary roots under sustained memory pressure;
  active analysis is not interrupted, and this best-effort policy is not a
  hard memory limit.
- Keep the shared-pool registry synchronized after runtime eviction and report
  measured Windows worktree memory and latency comparisons in the README.

## 0.1.2

- Require `pubspec.yaml` within the workspace for IDE bridge reuse;
  `.dart_tool`, legacy package metadata and loose Dart files do not qualify.
- Keep parent `.dart_tool` package configurations out of project identity checks.

## 0.1.1

- Reuse the IDE analyzer only for detected Dart project roots, including
  monorepos with nested Dart packages.

## 0.1.0

- Resolve CLI file and folder arguments against the requested root before
  session, IDE bridge or shared-pool routing; use native Windows separators.
- Fix Windows test fixtures and cover stale endpoint recovery on Windows.
- Recover dead Windows endpoints when connection failure is reported through
  Win32 refusal or the short connection deadline; retain live-owner endpoints.
- Add README development checks and bilingual troubleshooting/removal steps.
- Resolve symlinks in the Dart executable recorded in session, pool and budget
  identities, so a symlinked SDK (for example FVM) and its target match.
- `dana stop` no longer refuses a session whose identity differs; shutdown is
  authenticated by the endpoint token.

- Multi-root pool: the pool registry now follows joins, leaves and LRU
  evictions, so a later project discovers the pool's real root set.
- Multi-root pool: memory-driven eviction waits (up to 10 s) for a removed
  root's memory to be released before deciding to evict another, instead of
  evicting every idle root on a stale sample.
- Retire the PowerShell/C# windows-job backend and native helper sidecars;
  select windows-ffi-job for Windows process-tree ownership.
- Add generated CLI help and release validation/publishing workflows.

- Added a root-scoped persistent analyzer session.
- Added `dana check` fast and full modes.
- Added automatic session startup, `dana status`, and `dana stop`.
- Added analyzer idle waiting and file fingerprint validation.
- Added SDK and project configuration identity validation for endpoints.
- Added concurrent session startup protection and atomic endpoint publication.
- Added Windows analyzer process-tree cleanup during shutdown.
- Added `SessionClient` with disk-backed checks and explicit overlays.
- Added integration coverage for reuse, overlays, errors, shutdown, and
  concurrent startup.
- Added authenticated IDE bridge discovery and reuse with `--reuse-ide
  auto|never|require`; the companion-free proxy implementation lives in
  `analysis_server_proxy`.
- Extended automatic session startup waiting to five minutes so slow analyzer
  plugin initialization does not cause a false `69` connection failure.

