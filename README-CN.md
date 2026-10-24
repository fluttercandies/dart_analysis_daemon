# dart_analysis_daemon

[![pub package](https://img.shields.io/pub/v/dart_analysis_daemon.svg)](https://pub.dev/packages/dart_analysis_daemon) [![GitHub stars](https://img.shields.io/github/stars/fluttercandies/dart_analysis_daemon)](https://github.com/fluttercandies/dart_analysis_daemon/stargazers) [![GitHub forks](https://img.shields.io/github/forks/fluttercandies/dart_analysis_daemon)](https://github.com/fluttercandies/dart_analysis_daemon/network) [![GitHub license](https://img.shields.io/github/license/fluttercandies/dart_analysis_daemon)](https://github.com/fluttercandies/dart_analysis_daemon/blob/main/LICENSE) [![GitHub issues](https://img.shields.io/github/issues/fluttercandies/dart_analysis_daemon)](https://github.com/fluttercandies/dart_analysis_daemon/issues) <a href="https://qm.qq.com/q/ZyJbSVjfSU">![FlutterCandies QQ 群](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffluttercandies%2F.github%2Frefs%2Fheads%2Fmain%2Fdata.yml&query=%24.qq_group_number&label=QQ%E7%BE%A4&logo=qq&color=1DACE8)</a>

[English](README.md) | 简体中文

`dana` 让 Dart 官方 analysis server 保持常驻，原本要几分钟的 `dart analyze` 式检查，
重复执行时只要几秒。IDE 已经开着 analyzer 时，`dana` 直接向它要结果，不再另起一个。

它面向需要一天内多次分析大型项目的场景：AI Agent、pre-push 钩子、各类脚本。不修改
Dart SDK 和 analysis server，诊断来自同一个 server，插件 lint 也包含在内。

支持平台：macOS、Windows。

## 为什么需要

每次 `dart analyze` 都会启动一个新的 analysis server、加载整个 workspace，然后退出。
在大型 Flutter 单体仓库上，即使只查一个文件，每次也要几分钟、占用好几 GB 内存；而旁边
的 IDE 内存里已经有一份同样的分析结果。

`dana` 为每个项目维护一个常驻 session（或者直接用 IDE 的 analyzer），检查都从这里回答。

## 实测效果

测试环境：Flutter 单体仓库，15,000+ 个 Dart 文件、约 70 个包、2 个 analyzer 插件；
Apple Silicon，24 GB 内存。

| 检查 | `dart analyze` | `dana`，IDE 开着 | 提升 | `dana`，未开 IDE（session 已预热） | 提升 |
| ---- | -------------- | ---------------- | ---- | ---------------------------------- | ---- |
| 单个文件（`--files a.dart`） | 约 3 分钟 | 不到 1 秒 | 约 300 倍 | 约 0.5 秒 | 约 350 倍 |
| 一个约 1,200 个文件的目录（`--files dir`） | 约 8 秒，缺少插件 lint（见下） | 不到 1 秒 | 约 13 倍 | 约 0.5 秒 | 约 16 倍 |
| 全项目（`--mode full`） | 约 3.5 分钟 | 约 1 秒 | 约 230 倍 | 约 0.5 秒 | 约 400 倍 |
| 全项目，刚改完一个被约 5,000 个文件引用的公开 API | 约 3.5 分钟 | 约 30 秒 | 约 6 倍 | 约 1 分钟 | 约 3 倍 |
| 全项目，新 session 的第一次检查 | 约 3.5 分钟 | 不适用（用的是 IDE 的 analyzer） | 不适用 | 约 3.5 分钟 | 无 |

| 资源 | 不用 `dana` | 用 `dana` | 节省 |
| ---- | ----------- | --------- | ---- |
| 开着 IDE 时额外占用的内存 | 再起一个 analyzer，约 9 GB | 无（proxy 不到 100 MB） | 约 9 GB |

### 同仓多 worktree 对照（Windows）

内存测试为每个 root 20,003 个文件的轻量合成项目；延迟测试使用真实 Dart SDK
`pkg/analyzer`，不启用插件，热身后串行请求。

| 测量项 | 基线 | 共享多根池 | 差值 |
| ------ | ---- | -------- | ---- |
| 两个合成 worktree 检查后的 analyzer Job 私有提交 | 2,464.2 MiB（两个 worker） | 1,434.9 MiB（一个 worker） | 节省 1,029.3 MiB（41.8%） |
| 真实 SDK `pkg/analyzer` 热态单文件（p50 / p95，n=45） | 32.328 / 36.045 ms | 32.908 / 36.379 ms | +0.580 / +0.334 ms |
| 真实 SDK `pkg/analyzer` 热态 40 文件目录（p50 / p95，n=45） | 14.489 / 17.822 ms | 14.637 / 20.000 ms | +0.148 / +2.178 ms |

内存测试使用轻量合成源码，指标是 analyzer Job 私有提交，不是 Dart heap 或工作集，不能
作为大型 Flutter 项目的节省估算。延迟测试不涵盖冷启动、首次加入 root、插件分析或并发
请求；内存基线为每个 worktree 各自运行 analyzer，延迟基线为单 root worker。

- 结果与 `dart analyze` 全项目检查一致，包括插件 lint。
- Dart 3.14 之前，`dart analyze <目录>` 不报插件 lint
  （[dart-lang/sdk#62710](https://github.com/dart-lang/sdk/issues/62710)）；`dana` 检查目录时会报。
- 第一次检查要先启动 session，耗时与 `dart analyze` 相当，从第二次开始才快。

## 工作方式

每次 `dana check`，按顺序取第一个可用的来源：

1. **IDE 的 analyzer**，经
   [`dart_analysis_server_proxy`](https://pub.dev/packages/dart_analysis_server_proxy)
   发布的 bridge。不额外占内存，结果与 IDE 看到的一致。
2. **共享的多根池**（需开启 `DANA_MULTI_ROOT=1`）：多个 worktree 共用一个 analyzer，
   内存或 root 数到上限时淘汰最久未用的那个。
3. **本项目的 session**，第一次使用时启动，之后复用。

另有可选的全局预算（`DANA_GLOBAL_BUDGET=1`）：整台机器上所有
项目最多只跑一个 analyzer，在项目之间轮换。

## 安装

```sh
dart pub global activate dart_analysis_daemon
```

`dana` 会出现在 `PATH` 中。有 3 种运行方式，共用同样的 session，区别只在客户端本身的启动速度：

| 方式 | 命令 | 客户端启动 | 文件 | 目录 | 全项目 |
| ---- | ---- | ---------- | ---- | ---- | ------ |
| 全局激活 | `dana …` | 约 0.4 秒 | 约 0.6 秒 | 约 0.6 秒 | 约 0.9 秒 |
| kernel 快照 | `dart compile kernel bin/dart_analysis_daemon.dart -o dana.dill`，然后 `dart dana.dill …` | 约 0.13 秒 | 约 0.4 秒 | 约 0.4 秒 | 约 0.6 秒 |
| 原生可执行文件 | `dart compile exe bin/dart_analysis_daemon.dart -o dana`，然后 `./dana …` | 约 0.06 秒 | 约 0.25 秒 | 约 0.3 秒 | 约 0.5 秒 |

检查耗时都是经 IDE bridge 测的。差别就是客户端启动的几百毫秒，只有检查非常频繁时才值得在意。
编译命令在源码目录下执行；kernel 快照只能在编译它的 Dart SDK 上运行。上面「实测效果」用的是全局激活。

## 快速开始

```sh
# 全项目门禁（与 dart analyze 报告的内容一致）。
dana check --root path/to/project --mode full

# 指定文件或目录，改完代码后快速反馈。
dana check --root path/to/project --files lib/main.dart lib/xxx

# 查看或停止 session。
dana status --root path/to/project
dana stop --root path/to/project
```

第一次检查会启动 session 并等初次分析完成（带插件的大项目可能要几分钟），之后的检查
复用它。全部参数见 `dana --help` 或 `dana help check`。

其他命令：`dana serve --root <目录>` 显式启动 session（例如提前预热）；`dana connect --root <目录>`
从标准输入逐行读取 JSON 命令，发给已有的 session；`dana budget serve|status|stop` 管理全局预算。

## 检查与退出码

- `--mode full` 等 analyzer 完成当前这轮分析，返回它已发布的全部诊断。不会触发重新分析，
  所以在几万个文件的项目上也很快。
- `--files`（默认的 `fast` 模式）接受文件和目录，可以混用。目录会递归展开；隐藏目录、
  `.dart_tool`、非 Dart 文件和被 analyzer 排除的文件会跳过。
- 退出码与 `dart analyze` 一致：有 error 或 warning 时为 `1`，只有 info 或没有诊断时为
  `0`。`--[no-]fatal-warnings`（默认开）和 `--[no-]fatal-infos`（默认关）的含义同
  `dart analyze`。`64` 表示参数错误，`69` 表示无法建立 session。`75` 表示多根池拒绝
  准入，不会另起 analyzer。`memory-pressure` 可在内存恢复后重试（淘汰后至少间隔 10 秒）。
  对 macOS 多根池，`warn` 压力级别只作提示，只有 `critical` 才会强制走准入拒绝路径，同时仍检查物理余量；
  全局单 worker 预算仍把 `warn` 视为提交压力；多根池后台回收忽略 `warn`，只有 `critical`
  或物理余量不足才会进入多根池压力回收路径。
  `root-limit` 需释放 root 或调整上限；`memory-sample-unavailable` 需恢复受支持的采样。
  不要对 `75` 进行无间隔重试。
- 输出是一个 JSON 对象，包含 `ok`、`source`（`ide-bridge` 或 `daemon-session`）、各级别
  计数，以及按文件归组的 `diagnostics`。

## 复用 IDE 的 analyzer

配置一次 [`dart_analysis_server_proxy`](https://pub.dev/packages/dart_analysis_server_proxy)：
它挡在 IDE 的 analyzer 前面，并发布 `.dart_tool/dana-ide-bridge.json`。`--reuse-ide`
决定行为：

- `auto`（默认）：有 bridge 就用，没有就用 `dana` 自己的 session；
- `require`：没有 bridge 时失败（退出码 `69`）；
- `never`：始终用 `dana` 自己的 session。

需要注意：

- bridge 返回的是 IDE 当前的状态，包括未保存的编辑。需要以磁盘内容为准时，先保存文件。
- 经 bridge 的 full 检查会等晚到的插件诊断停止推送，最多等 `--bridge-settle-timeout`
  秒（默认 180）。超时返回 `settled: false`，退出码 `1`。
- IDE 刚启动或 reload 时插件可能还在加载，暂时不推送任何诊断，此时即使 settled 也可能
  缺少插件 lint。如果依赖插件 lint，可以放一个必定产生一条插件诊断的文件，缺失时重试。

## 多个 worktree（多根池）

设置 `DANA_MULTI_ROOT=1` 后，第一个 session 会登记为共享池，之后其他 root 的检查加入
这个池，不再各自启动 analyzer；只有 Dart runtime 和相关配置兼容时才会加入。

- `--mode full` 只返回请求的那个 root。
- `DANA_POOL_MAX_ROOTS`（1–64，默认 3）控制池最多保留的 root 数。达到上限时会淘汰
  最久未用且可淘汰的 root；池的第一个 root 和本次请求的 root 不会被淘汰。没有可淘汰的
  root 时会明确拒绝加入，不会另起一个 analyzer。
- Windows 和 macOS 会在新 root 加入前检查当前可用物理/提交内存；内存不足时按 LRU
  尝试淘汰一个 LRU root 并立即重新采样，不等待后台分析完成，也不在请求队列中睡眠。
  后续压力淘汰有 10 秒冷却期，让内存有时间释放。采样不可用或仍无法确认余量时会拒绝加入，
  CLI 会在 stderr 和 JSON 结果中提示。其他平台当前没有受支持的内存采样器；启用内存策略时，
  会拒绝加入额外 root。macOS 多根池的 `warn` 单独不会拒绝新 root，也不会回收 root，`critical`
  或物理余量不足才会处理。这是尽力而为的保护，不是 analyzer 的硬内存上限。
- 池空闲时每 2 秒采样；连续 2 次低于基础保留值后，可能淘汰一个至少 10 秒未使用的非主
  root；两次回收至少间隔 10 秒，让系统有时间释放已移除的分析上下文。正在进行的分析不会
  被强制打断；若压力发生在活跃检查期间，系统仍可能先换页或终止进程。
- 被淘汰的 root 下次检查时需要重新加入并重新建立分析状态；刚加入后的首次检查通常比热态
  定向检查慢得多。本文延迟对照只测已热身的单文件/目录请求，不代表首次加入或全项目检查耗时。
- 池不会把每个 root 的分析上下文合并成一份；它主要省下一份 analyzer 进程、运行时和
  部分共享缓存，因此总内存可能下降，但每个 root 仍保留自己的分析状态。实际差异取决于
  项目、插件和分析上下文；具体对照见[实测效果](#实测效果)。
- 内存监控只能观察系统级可用余量，无法估算每个 root 的安全内存，也无法抢占活跃分析。
  大型分析仍可能先耗尽内存。调大 `DANA_POOL_MAX_ROOTS` 只会允许池保留更多 root，不会合并
  分析上下文或形成硬上限。

## Session 生命周期

- 一个 canonical root 对应一个 session。session 记录 Dart 可执行文件以及 `pubspec.yaml`、
  `analysis_options.yaml`、package config 的指纹；它们变化后，`dana check` 会停止旧
  session 并启动新的。
- `DANA_SESSION_IDLE_TIMEOUT_SECONDS`（或 `dana serve --idle-timeout-seconds`）在没有客户端
  连接这么久之后回收 session。默认不回收。
- `dana stop` 在 analyzer 退出后才返回（`shutdownComplete: true`）。
- session 没有正常清理就退出（例如被 `SIGKILL`）时，下一次检查会发现并替换它。
- 原生编译的 `dana` 需要一个 Dart 运行时来启动 analyzer，依次查找
  `DANA_DART_EXECUTABLE`、`DART_SDK`、`FLUTTER_ROOT` 和 `PATH`。请使用项目所用的 SDK。

## Windows 与全局预算

- `DANA_PROCESS_BACKEND=windows-ffi-job`（实验性）把 analyzer 进程树放进 Job Object，
  停止 session 时插件进程也会一起结束。纯 Dart FFI 实现，不需要额外的辅助程序。
- `DANA_GLOBAL_BUDGET=1`（实验性）让所有项目最多共用一个 analyzer
  worker 并轮换，只在空闲内存足够时才启动新的。只接受基于磁盘的 fast 检查（不支持 full
  检查和 overlay）。用 `dana budget status|stop` 管理。默认保留 15% 内存（1–4 GiB）、
  启动额外预留 512 MiB、空闲 300 秒回收；可通过下表的变量调整。开启或关闭前先停止已有
  session。

## Dart API

```dart
import 'package:dart_analysis_daemon/dart_analysis_daemon.dart';

final session = await SessionClient.connect('/workspace/app');
try {
  final fast = await session.checkFiles(['/workspace/app/lib/main.dart']);
  final full = await session.fullCheck();
  print(full['diagnostics']);
} finally {
  await session.close(); // 只断开连接，session 继续运行
}
```

- `SessionClient.connect(root, {autoStart = true})` 与 CLI 规则一致，需要时启动 session；
  只想连接已有 session 时传 `autoStart: false`。
- `checkFiles(files, {overlays})` 可以分析尚未写盘的内存内容。overlay 由同一 session 的
  所有客户端共享，用完后用 `clearOverlays(files)` 清除。
- `close()` 只断开当前调用方；`shutdown()` 会为所有调用方停止 session。

直接与 IDE bridge 通信：

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

`IdeBridgeClient` 还提供 `check(files)` 和 `status()`。

## 环境变量

| 变量 | 默认值 | 作用 |
| ---- | ------ | ---- |
| `DANA_DART_EXECUTABLE` | 自动发现（见上文） | 启动 analyzer 用的 Dart 可执行文件 |
| `DANA_ANALYSIS_TIMEOUT_SECONDS` | 1800 | 启动和分析等待的上限；`0` 表示不限 |
| `DANA_SESSION_IDLE_TIMEOUT_SECONDS` | 0（不回收） | session 空闲多少秒后回收 |
| `DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS` | 180 | bridge full 检查等待晚到插件诊断的上限（1–3600） |
| `DANA_MULTI_ROOT` | 0 | `1` 开启多根池 |
| `DANA_POOL_MAX_ROOTS` | 3 | 多根池严格 root 上限；达到后按 LRU 淘汰或明确拒绝加入（1–64） |
| `DANA_GLOBAL_BUDGET` | 0 | `1` 开启全局预算 |
| `DANA_GLOBAL_RESERVE_MIB` | 内存的 15%，1024–4096 | 全局预算和多根池准入时保留的空闲内存 |
| `DANA_GLOBAL_STARTUP_MIB` / `DANA_GLOBAL_RECOVERY_MIB` | 512 / 256 | 启动或恢复 worker 时额外预留的内存 |
| `DANA_GLOBAL_COOLDOWN_MS` / `DANA_GLOBAL_QUEUE_TIMEOUT_SECONDS` / `DANA_GLOBAL_IDLE_SECONDS` | 2000 / 120 / 300 | 全局预算的间隔、排队超时、空闲回收 |
| `DANA_GLOBAL_STATE_DIR` | macOS `~/Library/Application Support/dart_analysis_daemon/global-v1`，Windows `%LOCALAPPDATA%\dart_analysis_daemon\global-v1` | 全局预算与池注册表的状态目录 |
| `DANA_PROCESS_BACKEND` | direct | Windows 上可设为 `windows-ffi-job`（见上文） |
| `DANA_FULL_FALLBACK` | 关 | `1`：full 检查会补查 analyzer 从未上报的文件，用于不推送空结果的 server。要设在启动 session 的环境里 |
| `DANA_IDENTITY_MAX_FILES` / `DANA_IDENTITY_MAX_ENTRIES` / `DANA_IDENTITY_MAX_BYTES_MIB` | 65536 / 131072 / 128 | 计算 session 身份时扫描项目配置的上限 |

## 限制

- 新 session 的第一次检查与 `dart analyze` 耗时相当；大项目的一个 session 占用的内存与
  一个 analyzer 相当。
- full 检查返回的是 analyzer 已观察到的结果，依赖它的文件监听发现磁盘改动，通常在一两秒内。
- `dana` 从不接管任意 analyzer 进程；复用 IDE 只通过带鉴权的 bridge。

## 切换 SDK 与卸载

切换 SDK 或 session 启动设置前，执行 `dana stop --root <项目>` 停止相关会话；
有全局预算 owner 时也执行 `dana budget stop`。下次检查会按新设置重新启动。

卸载前同样先停止这些后台进程，再执行
`dart pub global deactivate dart_analysis_daemon`。
