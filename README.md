# dart_analysis_daemon

[![pub package](https://img.shields.io/pub/v/dart_analysis_daemon.svg)](https://pub.dev/packages/dart_analysis_daemon) [![GitHub stars](https://img.shields.io/github/stars/fluttercandies/dart_analysis_daemon)](https://github.com/fluttercandies/dart_analysis_daemon/stargazers) [![GitHub forks](https://img.shields.io/github/forks/fluttercandies/dart_analysis_daemon)](https://github.com/fluttercandies/dart_analysis_daemon/network) [![GitHub license](https://img.shields.io/github/license/fluttercandies/dart_analysis_daemon)](https://github.com/fluttercandies/dart_analysis_daemon/blob/main/LICENSE) [![GitHub issues](https://img.shields.io/github/issues/fluttercandies/dart_analysis_daemon)](https://github.com/fluttercandies/dart_analysis_daemon/issues) <a href="https://qm.qq.com/q/ZyJbSVjfSU">![FlutterCandies QQ 群](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffluttercandies%2F.github%2Frefs%2Fheads%2Fmain%2Fdata.yml&query=%24.qq_group_number&label=QQ%E7%BE%A4&logo=qq&color=1DACE8)</a>

English | [简体中文](README-CN.md)

`dana` keeps Dart's official analysis server warm, so repeated `dart analyze`
style checks take seconds instead of minutes. When your IDE already runs an
analyzer, `dana` asks that one instead of starting another.

It is built for AI agents, pre-push hooks, and scripts that analyze a large
project many times a day. The Dart SDK and the analysis server are not
modified; diagnostics come from the same server, plugins included.

Supported platforms: macOS and Windows.

## Why

Every `dart analyze` starts a fresh analysis server, loads the whole
workspace, and exits. On a large Flutter monorepo that is minutes and many
gigabytes each time, even for one file, while the IDE next to it already holds
the same analysis in memory.

`dana` replaces that with a long-lived session per project (or with the IDE's
own analyzer), and answers checks from it.

## Measured results

Environment: a Flutter monorepo with 15,000+ Dart files in about 70 packages
and two analyzer plugins; Apple Silicon, 24 GB RAM.

| Check | `dart analyze` | `dana`, IDE open | Faster | `dana`, no IDE (warm session) | Faster |
| ----- | -------------- | ---------------- | ------ | ----------------------------- | ------ |
| One file (`--files a.dart`) | ~3 min | < 1 s | ~300× | ~0.5 s | ~350× |
| One folder of ~1,200 files (`--files dir`) | ~8 s, plugin lints missing (see below) | < 1 s | ~13× | ~0.5 s | ~16× |
| Whole project (`--mode full`) | ~3.5 min | ~1 s | ~230× | ~0.5 s | ~400× |
| Whole project, right after changing a public API imported by ~5,000 files | ~3.5 min | ~30 s | ~6× | ~1 min | ~3× |
| Whole project, first check of a new session | ~3.5 min | n/a (uses the IDE's analyzer) | n/a | ~3.5 min | none |

| Resource | Without `dana` | With `dana` | Saved |
| -------- | -------------- | ----------- | ----- |
| Extra memory while the IDE is open | another analyzer, ~9 GB | none (proxy < 100 MB) | ~9 GB |

### Same-repository worktree comparison (Windows)

The memory test used lightweight synthetic projects with 20,003 files per
root. The latency test used the real Dart SDK `pkg/analyzer`, without plugins,
after warm-up and with serial requests.

| Measurement | Baseline | Shared multi-root | Difference |
| ----------- | -------- | ----------------- | ---------- |
| Analyzer Job private commit after checking two synthetic worktrees | 2,464.2 MiB (two workers) | 1,434.9 MiB (one worker) | 1,029.3 MiB saved (41.8%) |
| Hot single-file check, real SDK `pkg/analyzer` (p50 / p95, n=45) | 32.328 / 36.045 ms | 32.908 / 36.379 ms | +0.580 / +0.334 ms |
| Hot 40-file directory check, real SDK `pkg/analyzer` (p50 / p95, n=45) | 14.489 / 17.822 ms | 14.637 / 20.000 ms | +0.148 / +2.178 ms |

The memory test used lightweight synthetic source and measures analyzer Job
private commit, not Dart heap or working set; it is not an estimate for a large
Flutter project. The latency test does not cover cold starts, first-time root
joins, plugin analysis, or concurrent requests. The memory baseline uses one
independent analyzer per worktree; the latency baseline is a single-root worker.

- Results match `dart analyze` on the whole project, plugin lints included.
- `dart analyze <folder>` reports no plugin lints before Dart 3.14
  ([dart-lang/sdk#62710](https://github.com/dart-lang/sdk/issues/62710));
  `dana` folder checks include them.
- The first check starts the session and takes as long as `dart analyze`; the
  speed-up starts from the second one.

## How it works

For each `dana check`, the first source that is available answers:

1. **The IDE's analyzer**, through a bridge published by
   [`dart_analysis_server_proxy`](https://pub.dev/packages/dart_analysis_server_proxy).
   Costs no extra memory and reflects what the IDE sees.
2. **A shared multi-root pool** (opt-in, `DANA_MULTI_ROOT=1`): one analyzer for
   several worktrees, evicting the least recently used one when memory or the
   root cap runs out.
3. **A session for this project**, started on first use and reused afterwards.

An opt-in global budget (`DANA_GLOBAL_BUDGET=1`) instead
runs at most one analyzer for every project on the machine, rotating between
them.

## Install

```sh
dart pub global activate dart_analysis_daemon
```

This puts `dana` on your `PATH`. Three ways to run it, all sharing the same
sessions; they differ only in how fast the client itself starts:

| Way | Command | Client start-up | File | Folder | Whole project |
| --- | ------- | --------------- | ---- | ------ | ------------- |
| Global activation | `dana …` | ~0.4 s | ~0.6 s | ~0.6 s | ~0.9 s |
| Dart kernel (.dill) | `dart compile kernel bin/dart_analysis_daemon.dart -o dana.dill`, then `dart dana.dill …` | ~0.13 s | ~0.4 s | ~0.4 s | ~0.6 s |
| Native executable | `dart compile exe bin/dart_analysis_daemon.dart -o dana`, then `./dana …` | ~0.06 s | ~0.25 s | ~0.3 s | ~0.5 s |

Check times are through the IDE bridge. The difference is the client start-up
of a few hundred milliseconds, so it only matters when checks run very often.

The compile commands run in a source checkout. A compiled .dill file only runs on
the Dart SDK that compiled it. The measured results above use global
activation.

## Quick start

```sh
# Whole-project gate (what `dart analyze` reports).
dana check --root path/to/project --mode full

# Selected files or directories, for fast feedback after an edit.
dana check --root path/to/project --files lib/main.dart lib/xxx

# Inspect or stop the session.
dana status --root path/to/project
dana stop --root path/to/project
```

The first check starts a session and waits for the initial analysis (large
projects with plugins can take minutes); later checks reuse it. Run
`dana --help` or `dana help check` for every option.

Other commands: `dana serve --root <dir>` starts a session explicitly (for
example to warm it up ahead of time); `dana connect --root <dir>` sends
newline-delimited JSON commands from stdin to an existing session;
`dana budget serve|status|stop` manages the global budget.

## Checks and exit codes

- `--mode full` waits for the analyzer to finish its current pass and returns
  every diagnostic it has published. It does not trigger a re-analysis, so it
  stays fast on projects with tens of thousands of files.
- `--files` (the default `fast` mode) accepts files and directories, mixed.
  Directories are expanded recursively; hidden directories, `.dart_tool`,
  non-Dart files and files excluded by the analyzer are skipped.
- Exit codes follow `dart analyze`: `1` when an error or warning is reported,
  `0` for infos only or no diagnostics. `--[no-]fatal-warnings` (default on)
  and `--[no-]fatal-infos` (default off) behave as in `dart analyze`. `64` is a
  usage error, `69` means no session could be established. `75` means the shared
  pool refused admission; no separate analyzer was started. Retry memory-pressure
  denials after memory recovers (allow at least 10 s after an eviction). On
  For the shared multi-root pool on macOS, `warn` pressure is advisory; only
  `critical` pressure forces the pressure-denial path, subject to the
  physical-memory reserve. The global single-worker budget retains `warn` as a
  commit-pressure signal. For
  `root-limit`, free a root or adjust the limit; for `memory-sample-unavailable`,
  restore supported sampling before retrying. Do not busy-loop on `75`.
- Output is one JSON object with `ok`, `source` (`ide-bridge` or
  `daemon-session`), counts and `diagnostics` keyed by file.

## Reusing the IDE's analyzer

Set up [`dart_analysis_server_proxy`](https://pub.dev/packages/dart_analysis_server_proxy)
once; it sits in front of the IDE analyzer and publishes
`.dart_tool/dana-ide-bridge.json`. `--reuse-ide` picks the behaviour:

- `auto` (default): use the bridge when present, otherwise `dana`'s own session;
- `require`: fail (exit `69`) without a bridge;
- `never`: always use `dana`'s own session.

Things to know:

- The bridge answers from the IDE's current state, unsaved edits included.
  Save files first when you want results for what is on disk.
- A full check through the bridge waits until late plugin diagnostics stop
  arriving, up to `--bridge-settle-timeout` seconds (default 180). Reaching the
  cap answers `settled: false` and exits `1`.
- Right after the IDE starts or reloads, plugins may still be loading and
  publish nothing yet, so a settled result can lack plugin lints. If you rely
  on plugin lints, keep a file that always produces one plugin diagnostic and
  retry while it is missing.

## Several worktrees (multi-root pool)

With `DANA_MULTI_ROOT=1`, the first session registers as a shared pool and
checks for other compatible roots join it instead of starting another analyzer.

- `--mode full` reports only the requested root.
- `DANA_POOL_MAX_ROOTS` (1–64, default 3) controls how many roots the pool
  may retain. At the limit it evicts the least recently used eligible root;
  the pool's first root and the requested root are protected. If no root can
  be evicted, the join is rejected with a visible error instead of starting a
  second analyzer.
- On Windows and macOS, available physical/commit memory is checked before a
  new root joins. Admission does not wait for background analysis to finish.
  Under pressure the pool tries one LRU eviction, then resamples without
  sleeping in the request queue. Further pressure-driven eviction has a 10 s
  cooldown to allow memory release. If sampling is unavailable or pressure remains,
  the join is rejected. Other platforms currently lack a supported memory
  sampler, so additional roots are rejected while memory policy is enabled.
  On macOS, a kernel `warn` level alone does not reject a new shared-pool root;
  `critical` does. Background reclamation also ignores `warn` when deciding
  whether to reclaim an idle root; the global single-worker budget retains its
  `warn` pressure behavior. Only `critical` or insufficient physical headroom
  causes the multi-root pressure path.
  This is a best-effort admission guard, not a hard analyzer memory limit.
- While the pool is idle, it samples memory every 2 s. After two consecutive
  low-memory samples it may evict one non-primary root that has been unused
  for at least 10 s; subsequent evictions are at least 10 s apart to let the
  analyzer release the removed context.
  Active analysis is not interrupted; if memory pressure occurs during an
  active check, the OS can still begin paging or terminate a process first.
- An evicted root rejoins on its next check and pays its first analysis again.
  Re-checking a warmed file can be fast, but a newly joined root must rebuild
  analysis state and its first check can be much slower. The latency comparison
  here measures warmed targeted requests, not first joins or full-project checks.
- The pool shares the analyzer process and some global caches, but every root
  retains its own analysis context. Sharing can reduce total memory by avoiding
  a worker/runtime and some duplicate caches; the actual difference depends on
  the project, plugins, and analysis state. See [Measured results](#measured-results)
  for controlled comparisons.
- Memory monitoring is best-effort and observes system-wide headroom rather
  than a per-root allocation. A large active analysis can still exhaust memory
  before idle roots are safe to reclaim. Increasing `DANA_POOL_MAX_ROOTS` only
  allows more roots to remain resident; it does not merge analysis contexts
  or create a hard memory cap.

## Session lifecycle

- One session per canonical root. A session records the Dart executable and
  fingerprints of `pubspec.yaml`, `analysis_options.yaml` and the package
  config; when they change, `dana check` stops the old session and starts a
  new one.
- `DANA_SESSION_IDLE_TIMEOUT_SECONDS` (or `dana serve --idle-timeout-seconds`)
  reclaims a session after it has had no clients for that long. Off by default.
- `dana stop` returns once the analyzer has exited (`shutdownComplete: true`).
- A session killed without cleanup (for example with `SIGKILL`) is detected on
  the next check and replaced.
- A native `dana` build needs a Dart runtime for the analyzer. It looks at
  `DANA_DART_EXECUTABLE`, `DART_SDK`, `FLUTTER_ROOT` and `PATH`, in that order.
  Use the SDK your project uses.

## Windows and global budget

- `DANA_PROCESS_BACKEND=windows-ffi-job` (experimental) puts the analyzer
  process tree into a Job Object, so stopping a session also ends plugin
  processes. Pure Dart FFI, no helper binaries.
- `DANA_GLOBAL_BUDGET=1` (experimental) keeps at most one
  analyzer worker for all projects and rotates between them, admitting a new
  one only when enough memory is free. It accepts fast disk checks only (no
  full checks, no overlays). Manage it with `dana budget status|stop`.
  Defaults: keep 15% of RAM free (1–4 GiB), 512 MiB start-up allowance, 300 s
  idle reclaim; see the variables below. Stop existing sessions before turning
  it on or off.

## Dart API

```dart
import 'package:dart_analysis_daemon/dart_analysis_daemon.dart';

final session = await SessionClient.connect('/workspace/app');
try {
  final fast = await session.checkFiles(['/workspace/app/lib/main.dart']);
  final full = await session.fullCheck();
  print(full['diagnostics']);
} finally {
  await session.close(); // disconnects; the session keeps running
}
```

- `SessionClient.connect(root, {autoStart = true})` follows the same rules as
  the CLI and starts a session when needed; pass `autoStart: false` to only
  connect to an existing one.
- `checkFiles(files, {overlays})` can analyze in-memory content that is not on
  disk yet. Overlays are shared by every client of that session; remove them
  with `clearOverlays(files)` when done.
- `close()` disconnects this caller only. `shutdown()` stops the session for
  every caller.

To talk to an IDE bridge directly:

```dart
final endpoint = await IdeBridgeEndpoint.discover(projectRoot);
if (endpoint != null && endpoint.supports('fullCheck')) {
  final bridge = await IdeBridgeClient.connect(endpoint);
  try {
    print((await bridge.fullCheck())['diagnostics']);
  } finally {
    await bridge.close();
  }
}
```

`IdeBridgeClient` also offers `check(files)` and `status()`.

## Environment variables

| Variable | Default | Effect |
| -------- | ------- | ------ |
| `DANA_DART_EXECUTABLE` | discovered (see above) | Dart executable used to start the analyzer |
| `DANA_ANALYSIS_TIMEOUT_SECONDS` | 1800 | limit for start-up and analysis waits; `0` disables it |
| `DANA_SESSION_IDLE_TIMEOUT_SECONDS` | 0 (never) | reclaim a session idle for this many seconds |
| `DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS` | 180 | wait for late plugin diagnostics in a bridge full check (1–3600) |
| `DANA_MULTI_ROOT` | 0 | `1` enables the multi-root pool |
| `DANA_POOL_MAX_ROOTS` | 3 | strict root limit for the multi-root pool; LRU eviction or explicit admission rejection at the limit (1–64) |
| `DANA_GLOBAL_BUDGET` | 0 | `1` enables the global budget |
| `DANA_GLOBAL_RESERVE_MIB` | 15% of RAM, 1024–4096 | memory kept free for the budget and pool admission |
| `DANA_GLOBAL_STARTUP_MIB` / `DANA_GLOBAL_RECOVERY_MIB` | 512 / 256 | extra headroom to start or recover a worker |
| `DANA_GLOBAL_COOLDOWN_MS` / `DANA_GLOBAL_QUEUE_TIMEOUT_SECONDS` / `DANA_GLOBAL_IDLE_SECONDS` | 2000 / 120 / 300 | budget pacing, queue deadline, idle reclaim |
| `DANA_GLOBAL_STATE_DIR` | macOS `~/Library/Application Support/dart_analysis_daemon/global-v1`, Windows `%LOCALAPPDATA%\dart_analysis_daemon\global-v1` | state for the budget and the pool registry |
| `DANA_PROCESS_BACKEND` | direct | `windows-ffi-job` on Windows (see above) |
| `DANA_FULL_FALLBACK` | off | `1`: full checks also query files the analyzer never reported; for servers that skip empty results. Set it where the session starts |
| `DANA_IDENTITY_MAX_FILES` / `DANA_IDENTITY_MAX_ENTRIES` / `DANA_IDENTITY_MAX_BYTES_MIB` | 65536 / 131072 / 128 | limits on scanning project configuration for the session identity |

## Limitations

- The first check of a new session costs as much as `dart analyze`; a
  session for a large project holds about as much memory as one analyzer.
- Full checks report what the analyzer has observed. They rely on its file
  watcher to notice disk edits, which normally happens within a second or two.
- `dana` never attaches to an arbitrary analyzer process; IDE reuse goes only
  through the authenticated bridge.

## SDK changes and removal

Before changing SDK or session startup settings, stop the affected sessions
with `dana stop --root <project>` and, if running, the global budget owner
with `dana budget stop`. The next check starts them with the new settings.

To uninstall, stop those background processes first, then run
`dart pub global deactivate dart_analysis_daemon`.
