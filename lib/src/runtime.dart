import 'dart:io';

/// Maximum time to wait for a large-project analysis operation.
///
/// Set `DANA_ANALYSIS_TIMEOUT_SECONDS=0` to wait without a wall-clock limit.
/// A process exit still fails pending requests immediately.
Duration? get analysisTimeout {
  final value = Platform.environment['DANA_ANALYSIS_TIMEOUT_SECONDS'];
  if (value == '0') return null;
  final seconds = int.tryParse(value ?? '') ?? 1800;
  return Duration(seconds: seconds > 0 ? seconds : 1800);
}

/// Maximum number of configuration files the environment-identity fingerprint
/// will read before refusing to continue.
///
/// This is a resource guard on `EnvironmentIdentity.capture`, which runs on the
/// hot path of every managed check. The original 1024 default suits small
/// single-package projects but is too low for large monorepos: a 59-package
/// Flutter workspace reads far more pubspec/options/package-config files (plus
/// a "missing" record per probed-but-absent file). The default is raised to a
/// level that covers real monorepos while still bounding a runaway or hostile
/// tree; override with `DANA_IDENTITY_MAX_FILES`.
int get identityMaxFiles {
  final value = Platform.environment['DANA_IDENTITY_MAX_FILES'];
  final parsed = int.tryParse(value ?? '');
  // A ~60-package monorepo worktree records ~21k config entries (most are
  // "missing" markers probed per directory). Default leaves ~3x headroom.
  if (parsed == null || parsed <= 0) return 65536;
  return parsed;
}

/// Maximum total bytes the environment-identity fingerprint will read.
///
/// Companion guard to [identityMaxFiles]: bounds the hashing/IO cost of
/// `capture`. Raised from the original 16 MiB for the same monorepo reason;
/// override with `DANA_IDENTITY_MAX_BYTES_MIB` (value in MiB).
int get identityMaxBytes {
  final value = Platform.environment['DANA_IDENTITY_MAX_BYTES_MIB'];
  final parsed = int.tryParse(value ?? '');
  if (parsed == null || parsed <= 0) return 128 * 1024 * 1024;
  return parsed * 1024 * 1024;
}

/// Maximum number of filesystem entries the identity walk will visit.
///
/// `EnvironmentIdentity._walk` streams the whole project tree (skipping
/// .git/.dart_tool/build) to notice new or moved config files. A 15k-file
/// monorepo easily exceeds the original 8192-entry guard. Raised to cover real
/// trees while still stopping a runaway walk; override with
/// `DANA_IDENTITY_MAX_ENTRIES`.
int get identityMaxEntries {
  final value = Platform.environment['DANA_IDENTITY_MAX_ENTRIES'];
  final parsed = int.tryParse(value ?? '');
  // A large monorepo worktree walks ~25k entries; default leaves ~5x headroom.
  if (parsed == null || parsed <= 0) return 131072;
  return parsed;
}

/// Whether `full` should fall back to per-file `analysis.getErrors` for files
/// the analyzer reported as analyzed but for which no `analysis.errors`
/// notification was cached.
///
/// Default is off. On a protocol-conformant analysis server every included
/// file receives an `analysis.errors` push (empty when clean), so the cache is
/// already complete and the only files missing from it are the ones the
/// analyzer excludes (generated code, etc.). Querying those with
/// `analysis.getErrors` ignores the exclude rules and reintroduces excluded
/// files as false positives, so the fallback is opt-in via
/// `DANA_FULL_FALLBACK=1` for the rare analyzer that does not emit empty
/// notifications.
///
/// This is read inside the long-lived session (the `serve` process that owns
/// the [AnalyzerDaemon]), so set the variable in the environment that starts
/// `dana serve`, not on an individual `dana check` client invocation.
bool get fullCheckFallbackEnabled {
  final value = Platform.environment['DANA_FULL_FALLBACK'];
  return value == '1' || value == 'true';
}

/// Resolves the Dart executable used to launch an analysis server.
///
/// In a JIT process [Platform.resolvedExecutable] is normally `dart`. In an
/// AOT process it can be `dartaotruntime` or the compiled application itself,
/// neither of which accepts `language-server` as a command. Prefer explicit
/// configuration, then derive the sibling Dart executable, and finally use
/// the user's PATH.
Future<String> resolveDartExecutable() async {
  final configured = Platform.environment['DANA_DART_EXECUTABLE'];
  if (configured != null && configured.isNotEmpty) {
    return _requireExecutable(configured, 'DANA_DART_EXECUTABLE');
  }
  final sdk = Platform.environment['DART_SDK'];
  if (sdk != null && sdk.isNotEmpty) {
    final candidate = _dartInSdk(sdk);
    if (candidate.existsSync()) return candidate.path;
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final candidate = _dartInFlutterRoot(flutterRoot);
    if (candidate.existsSync()) return candidate.path;
  }

  final resolved = File(Platform.resolvedExecutable).absolute;
  final name = resolved.uri.pathSegments.last.toLowerCase();
  if (name == 'dart' || name == 'dart.exe') return resolved.path;
  final sibling = File(
    '${resolved.parent.path}${Platform.pathSeparator}dart'
    '${Platform.isWindows ? '.exe' : ''}',
  );
  if (sibling.existsSync()) return sibling.path;

  final command = Platform.isWindows ? 'where.exe' : 'which';
  final result = await Process.run(command, ['dart'], runInShell: false);
  if (result.exitCode == 0) {
    final candidates = <String>[];
    for (final line in '${result.stdout}'.split(RegExp(r'[\r\n]+'))) {
      final candidate = line.trim();
      if (candidate.isNotEmpty && File(candidate).existsSync()) {
        candidates.add(candidate);
      }
    }
    for (final candidate in candidates) {
      final lower = candidate.toLowerCase();
      if ((!Platform.isWindows &&
              !lower.endsWith('.bat') &&
              !lower.endsWith('.cmd')) ||
          (Platform.isWindows && lower.endsWith('dart.exe'))) {
        return candidate;
      }
    }
  }
  if (Platform.isWindows) {
    final flutter = await Process.run('where.exe', ['flutter']);
    if (flutter.exitCode == 0) {
      for (final line in '${flutter.stdout}'.split(RegExp(r'[\r\n]+'))) {
        final candidate = line.trim();
        if (candidate.isEmpty) continue;
        final flutterPath = File(candidate).absolute.path;
        final flutterBin = Directory(flutterPath).parent;
        final dart = _dartInFlutterRoot(flutterBin.parent.path);
        if (dart.existsSync()) return dart.path;
      }
    }
  }
  throw StateError(
    'Could not locate a Dart executable for the analyzer. Set '
    'DANA_DART_EXECUTABLE or DART_SDK.',
  );
}

/// The Dart executable as it appears in session, pool and budget identities.
///
/// Symlinks are resolved so that an FVM link and the SDK path it points to
/// produce the same identity. Only identities use this form; the analyzer is
/// still launched through [resolveDartExecutable].
Future<String> identityDartExecutable() async =>
    canonicalExecutablePath(await resolveDartExecutable());

/// [path] with symlinks resolved and case folded; [path] itself when it
/// cannot be resolved.
String canonicalExecutablePath(String path) {
  String resolved;
  try {
    resolved = File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    resolved = path;
  }
  return resolved.toLowerCase();
}

File _dartInSdk(String sdk) => File(
  '${Directory(sdk).absolute.path}${Platform.pathSeparator}bin'
  '${Platform.pathSeparator}dart${Platform.isWindows ? '.exe' : ''}',
);

File _dartInFlutterRoot(String root) => File(
  '${Directory(root).absolute.path}${Platform.pathSeparator}bin'
  '${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk'
  '${Platform.pathSeparator}bin${Platform.pathSeparator}dart'
  '${Platform.isWindows ? '.exe' : ''}',
);

String _requireExecutable(String path, String variable) {
  final file = File(path).absolute;
  if (!file.existsSync()) {
    throw StateError('$variable does not point to an executable: ${file.path}');
  }
  return file.path;
}

/// Returns arguments for restarting this CLI in either JIT or AOT mode.
List<String> selfProcessArguments(Iterable<String> arguments) {
  final script = File.fromUri(Platform.script).absolute.path;
  final executable = File(Platform.resolvedExecutable).absolute.path;
  if (_samePath(script, executable)) return arguments.toList();
  return [script, ...arguments];
}

bool _samePath(String first, String second) {
  return first.toLowerCase() == second.toLowerCase();
}
