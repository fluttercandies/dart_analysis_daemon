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
| Five worktrees checked one after another | ~10 GB each, ~50 GB for five | ~21 GB peak in total (pool keeps 2 roots) | ~29 GB (~60%) |

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
  usage error, `69` means no session could be established.
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
checks for other roots join it instead of starting another analyzer.

- `--mode full` reports only the requested root.
- `DANA_POOL_MAX_ROOTS` (1–64, default 3) caps the roots analyzed at once.
  Beyond it the least recently used root is evicted; the first root of the
  pool and the requested root are never evicted.
- Joining also evicts under memory pressure (on macOS: a kernel
  memory-pressure level of warn or worse). After each eviction the pool
  waits up to 10 s for that memory to be released before deciding on another.
- An evicted root rejoins on its next check and pays its first analysis again.
  Re-checking an analyzed file takes tens of milliseconds; the first check of a
  freshly joined large root takes from tens of seconds to over a minute.
- The pool saves one analyzer process and its startup, not analysis memory.
  Each root still needs about the memory of its own analyzer: on a 15,000+
  file project one root takes about 10 GB and two roots about 18 GB. Memory
  is checked when a root joins, so growth of roots already in the pool does
  not trigger eviction.

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
| `DANA_POOL_MAX_ROOTS` | 3 | roots one pool analyzes at once (1–64) |
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
