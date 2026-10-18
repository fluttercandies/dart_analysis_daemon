import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dart_analysis_daemon/dart_analysis_daemon.dart';
import 'package:dart_analysis_daemon/src/analyzer_pool.dart';
import 'package:dart_analysis_daemon/src/session_server.dart';
import 'package:dart_analysis_daemon/src/session_idle_policy.dart';
import 'check_exit_code.dart';
import 'global_budget_service.dart';

Future<void> cliMain(List<String> arguments) async {
  final runner = _DanaRunner();
  try {
    final results = runner.parse(arguments);
    if (results['version'] as bool) {
      stdout.writeln(packageVersion);
      return;
    }
    await runner.runCommand(results);
  } on UsageException catch (error) {
    stderr.writeln(error);
    exitCode = 64;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  }
}

class _DanaRunner extends CommandRunner<void> {
  _DanaRunner() : super('dana', 'Persistent Dart analysis sessions.') {
    argParser.addFlag(
      'version',
      negatable: false,
      help: 'Print the package version.',
    );
    addCommand(
      _RootCommand(
        'serve',
        'Start a persistent root session.',
        _serveParser(),
        _serve,
      ),
    );
    addCommand(
      _RootCommand(
        'connect',
        'Send JSON commands to an existing session.',
        _connectParser(),
        (root, args, _) => _connect(
          root,
          autoStart: false,
          mode: args['mode'] as String?,
          files: args['files'] as List<String>,
          reuseIde: 'never',
          useStdin: true,
        ),
      ),
    );
    addCommand(
      _RootCommand(
        'check',
        'Check files or the full project; start a session if needed.',
        _checkParser(),
        _check,
      ),
    );
    addCommand(
      _RootCommand(
        'status',
        'Show the root session status.',
        _rootParser(),
        (root, _, _) => _singleCommand(root, {'op': 'status'}),
      ),
    );
    addCommand(
      _RootCommand(
        'stop',
        'Stop the root session and wait for cleanup.',
        _rootParser(),
        (root, _, _) => _singleCommand(root, {'op': 'shutdown'}),
      ),
    );
    addCommand(_BudgetCommand());
  }

  @override
  String get usageFooter => '''
Examples:
  dana check --root <project> --files lib/main.dart
  dana check --root <project> --mode full
Global worker budget (opt-in): dana budget serve|status|stop''';
}

/// Runs a root-scoped command and returns its exit code (null keeps the
/// current one). [usageError] reports an invalid option value as a usage error.
typedef _RootAction =
    Future<int?> Function(
      String root,
      ArgResults args,
      Never Function(String message) usageError,
    );

class _RootCommand extends Command<void> {
  _RootCommand(this.name, this.description, this.argParser, this._action);
  @override
  final String name;
  @override
  final String description;
  @override
  final ArgParser argParser;
  final _RootAction _action;
  @override
  bool get takesArguments => false;

  @override
  Future<void> run() async {
    final args = argResults!;
    // args only enforces `mandatory` when the value is read, as an
    // ArgumentError; report every missing one as a usage error instead.
    for (final option in argParser.options.values) {
      if (option.mandatory && !args.wasParsed(option.name)) {
        usageException('Option --${option.name} is required.');
      }
    }
    final value = args['root'] as String;
    if (value.isEmpty) usageException('--root must not be empty.');
    final String root;
    try {
      root = Directory(value).resolveSymbolicLinksSync();
    } on FileSystemException {
      usageException('--root directory does not exist: $value');
    }
    final code = await _action(root, args, usageException);
    if (code != null) exitCode = code;
  }
}

Future<int?> _serve(
  String root,
  ArgResults args,
  Never Function(String) usageError,
) async {
  final Duration idleTimeout;
  try {
    idleTimeout = parseSessionIdleTimeout(
      args['idle-timeout-seconds'] as String? ??
          Platform.environment['DANA_SESSION_IDLE_TIMEOUT_SECONDS'],
    );
  } on FormatException catch (error) {
    usageError(error.message);
  }
  await serveSession(
    root,
    startupToken: args['startup-token'] as String?,
    idleTimeout: idleTimeout,
  );
  return null;
}

Future<int?> _check(
  String root,
  ArgResults args,
  Never Function(String) usageError,
) {
  final int? settleTimeout;
  try {
    settleTimeout = parseBridgeSettleTimeout(
      args['bridge-settle-timeout'] as String?,
      Platform.environment['DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS'],
    );
  } on FormatException catch (error) {
    usageError(error.message);
  }
  return _connect(
    root,
    autoStart: true,
    mode: args['mode'] as String,
    files: args['files'] as List<String>,
    reuseIde: args['reuse-ide'] as String,
    useStdin: false,
    fatalWarnings: args['fatal-warnings'] as bool,
    fatalInfos: args['fatal-infos'] as bool,
    bridgeSettleTimeout: settleTimeout,
  );
}

class _BudgetCommand extends Command<void> {
  _BudgetCommand() {
    addSubcommand(
      _BudgetAction(
        'serve',
        'Start the global single-worker budget owner.',
        serveGlobalBudget,
      ),
    );
    for (final (op, description) in [
      ('status', 'Show global worker budget status.'),
      ('stop', 'Stop the global worker budget owner.'),
    ]) {
      addSubcommand(_BudgetAction(op, description, () => _budgetRequest(op)));
    }
  }
  @override
  String get name => 'budget';
  @override
  String get description => 'Manage the opt-in global single-worker budget.';
}

Future<void> _budgetRequest(String op) async {
  final result = await globalBudgetRequest({'op': op}, autoStart: false);
  stdout.writeln(jsonEncode(result));
  if (result['ok'] != true) exitCode = 1;
}

class _BudgetAction extends Command<void> {
  _BudgetAction(this.name, this.description, this._action);
  @override
  final String name;
  @override
  final String description;
  final Future<void> Function() _action;
  @override
  bool get takesArguments => false;

  @override
  Future<void> run() async {
    try {
      await _action();
    } on FormatException {
      rethrow;
    } catch (error) {
      stderr.writeln(error);
      exitCode = 1;
    }
  }
}

ArgParser _rootParser() =>
    ArgParser()
      ..addOption('root', mandatory: true, help: 'Project root directory.');

ArgParser _serveParser() =>
    _rootParser()
      ..addOption('startup-token', hide: true)
      ..addOption(
        'idle-timeout-seconds',
        help:
            'Reclaim after the last client and request leave; 0 disables. '
            'Defaults to DANA_SESSION_IDLE_TIMEOUT_SECONDS, or 0.',
      );

ArgParser _connectParser() =>
    _rootParser()
      ..addOption('mode', allowed: ['fast', 'full'])
      ..addMultiOption('files', help: 'Files for a fast check.');

ArgParser _checkParser() =>
    _rootParser()
      ..addOption('mode', allowed: ['fast', 'full'], defaultsTo: 'fast')
      ..addOption(
        'reuse-ide',
        allowed: ['auto', 'never', 'require'],
        defaultsTo: 'auto',
      )
      ..addMultiOption('files', help: 'Files for a fast check.')
      ..addFlag(
        'fatal-warnings',
        defaultsTo: true,
        help: 'Treat warning level issues as fatal (exit code 1).',
      )
      ..addFlag(
        'fatal-infos',
        help: 'Treat info level issues as fatal (exit code 1).',
      )
      ..addOption(
        'bridge-settle-timeout',
        valueHelp: 'seconds',
        help:
            'IDE bridge full check: once the IDE analyzer is idle, how long '
            'to wait for late plugin diagnostics before answering '
            '"settled": false (exit code 1). Defaults to '
            'DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS, or the bridge default '
            '(180).',
      );

Future<int> _connect(
  String root, {
  required bool autoStart,
  required String? mode,
  required List<String> files,
  required String reuseIde,
  required bool useStdin,
  bool fatalWarnings = true,
  bool fatalInfos = false,
  int? bridgeSettleTimeout,
}) async {
  // Resolve paths before choosing a session/bridge/pool. A shared pool runs
  // in its owner's directory, and Windows analyzer paths must use native
  // separators even when a caller supplies portable forward slashes.
  files = [
    for (final file in files)
      File.fromUri(
        Directory(
          root,
        ).uri.resolveUri(Uri.file(file, windows: Platform.isWindows)),
      ).path,
  ];
  int exitCodeFor(Object? response) => checkExitCode(
    response,
    fatalWarnings: fatalWarnings,
    fatalInfos: fatalInfos,
  );
  if (reuseIde != 'never' &&
      !useStdin &&
      ((mode ?? 'fast') == 'full' || files.isNotEmpty)) {
    final bridgeResult = await _tryIdeBridge(
      root,
      mode: mode ?? 'fast',
      files: files,
      required: reuseIde == 'require',
      exitCodeFor: exitCodeFor,
      settleTimeout: bridgeSettleTimeout,
    );
    if (bridgeResult != null) return bridgeResult;
  }
  // Auto-join a shared multi-root pool when enabled: if another project is
  // already running a pool, join it with addRoot and analyze inside that one
  // process instead of starting a second analyzer.
  if (multiRootEnabled &&
      !useStdin &&
      ((mode ?? 'fast') == 'full' || files.isNotEmpty)) {
    final poolResult = await _tryPool(
      root,
      mode: mode ?? 'fast',
      files: files,
      exitCodeFor: exitCodeFor,
    );
    if (poolResult != null) return poolResult;
  }
  (Socket, String)? connection;
  try {
    connection = await connectOrStartSession(
      root,
      endpointFile(root),
      autoStart: autoStart,
    );
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    return 64;
  }
  if (connection == null) return 69;
  final socket = connection.$1;
  final token = connection.$2;
  final lines = StreamIterator(
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  Future<Map<String, Object?>> send(Map<String, Object?> command) async {
    socket.writeln(jsonEncode({...command, 'token': token}));
    await socket.flush();
    if (!await lines.moveNext()) throw StateError('Session disconnected');
    final value = jsonDecode(lines.current);
    if (value is! Map) throw StateError('Invalid session response');
    return Map<String, Object?>.from(value);
  }

  try {
    final selectedMode = mode ?? 'fast';
    if (selectedMode == 'full') {
      final response = await send({'op': 'fullCheck'});
      stdout.writeln(jsonEncode(response));
      return exitCodeFor(response);
    }
    if (selectedMode != 'fast') {
      throw ArgumentError('Unknown --mode: $selectedMode');
    }
    if (files.isNotEmpty) {
      final response = await send({'op': 'check', 'files': files});
      stdout.writeln(jsonEncode(response));
      return exitCodeFor(response);
    }
    if (!useStdin) throw ArgumentError('Fast check requires --files');
    await for (final line in stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final command = jsonDecode(line);
      if (command is! Map) throw StateError('Command must be a JSON object');
      final response = await send(Map<String, Object?>.from(command));
      stdout.writeln(jsonEncode(response));
      stdout.flush();
      if (command['op'] == 'shutdown') break;
    }
    return 0;
  } finally {
    socket.destroy();
    await lines.cancel();
  }
}

/// Tries to run the check inside a shared multi-root pool.
///
/// Returns an exit code when a compatible pool was discovered and the check
/// ran there (after joining [root] with addRoot); returns null when no pool
/// applies, so the caller falls back to its own session.
Future<int?> _tryPool(
  String root, {
  required String mode,
  required List<String> files,
  required int Function(Object? response) exitCodeFor,
}) async {
  final registration = await discoverPool();
  if (registration == null) return null;
  // A pool whose own session is this root would mean "join myself"; the normal
  // session path already serves it, so skip to avoid a needless round-trip.
  final canonical = File(root).absolute.path;
  if (registration.roots.contains(canonical) &&
      registration.roots.length == 1) {
    return null;
  }
  PoolClient? client;
  try {
    client = await PoolClient.connect(registration);
    final joined = await client.addRoot(canonical);
    if (joined['ok'] != true) return null;
    final response =
        mode == 'full'
            ? await client.fullCheck(root: canonical)
            : await client.check(files);
    stdout.writeln(jsonEncode(response));
    return exitCodeFor(response);
  } catch (_) {
    // A pool that died between discovery and use must not fail the check; fall
    // back to the caller's own session.
    return null;
  } finally {
    await client?.close();
  }
}

Future<int?> _tryIdeBridge(
  String root, {
  required String mode,
  required List<String> files,
  required bool required,
  required int Function(Object? response) exitCodeFor,
  int? settleTimeout,
}) async {
  final endpoint = await IdeBridgeEndpoint.discover(root);
  if (endpoint == null) {
    if (required) {
      stderr.writeln('No compatible IDE analyzer bridge for $root.');
      return 69;
    }
    return null;
  }
  final capability = mode == 'full' ? 'fullCheck' : 'fastCheck';
  if (!endpoint.supports(capability)) {
    if (required) {
      stderr.writeln('IDE analyzer bridge does not support $capability.');
      return 69;
    }
    return null;
  }
  IdeBridgeClient? client;
  try {
    client = await IdeBridgeClient.connect(endpoint);
    final response =
        mode == 'full'
            ? await client.fullCheck(settleLimitSeconds: settleTimeout)
            : await client.check(files);
    stdout.writeln(jsonEncode(response));
    if (response['settled'] == false) {
      stderr.writeln(
        'IDE analyzer diagnostics were still arriving when the bridge '
        'stopped waiting; the result may be incomplete. Retry, raise '
        '--bridge-settle-timeout, or run `dart analyze`.',
      );
    }
    return exitCodeFor(response);
  } catch (error) {
    if (required) {
      stderr.writeln('IDE analyzer bridge unavailable: $error');
      return 69;
    }
    return null;
  } finally {
    await client?.close();
  }
}

Future<int> _singleCommand(String root, Map<String, Object?> command) async {
  final connection = await connectOrStartSession(
    root,
    endpointFile(root),
    autoStart: false,
    requireIdentity: command['op'] != 'shutdown',
  );
  if (connection == null) return 69;
  final socket = connection.$1;
  final token = connection.$2;
  try {
    socket.writeln(jsonEncode({...command, 'token': token}));
    await socket.flush();
    final lines = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final response = jsonDecode(line);
      stdout.writeln(jsonEncode(response));
      if (command['op'] == 'shutdown') {
        final endpoint = endpointFile(root);
        for (var attempt = 0; attempt < 60; attempt++) {
          if (!await endpoint.exists()) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      return response is Map && response['ok'] == false ? 1 : 0;
    }
    return 69;
  } finally {
    socket.destroy();
  }
}
