// A small persistent client for Dart's legacy analysis-server protocol.
//
// The public input/output protocol is newline-delimited JSON:
//   {"op":"check","files":["absolute/path/to/file.dart"]}
//   {"op":"check","files":[{"path":"...","content":"..."}]}
//   {"op":"shutdown"}
//
// The server is started once and analysis roots are configured once. This is
// intentionally a client/wrapper, not a fork of analysis_server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/runtime.dart';
import 'package:dart_analysis_daemon/src/analyzer_process.dart';
import 'package:dart_analysis_daemon/src/analyzer_process_start.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:dart_analysis_daemon/src/global_budget_policy.dart';

class AnalyzerDaemon {
  AnalyzerDaemon(
    this.root, {
    Future<Process> Function()? processStarter,
    Future<AnalyzerProcess> Function()? ownedProcessStarter,
    SystemMemorySnapshot? Function()? memorySampler,
    GlobalBudgetPolicy? budgetPolicy,
    this.maxRoots,
    DateTime Function()? now,
    this.evictionSettleLimit = const Duration(seconds: 10),
    this.runtimeIdleGrace = const Duration(seconds: 10),
    bool Function()? analysisInProgress,
  }) : _processStarter = processStarter,
       _ownedProcessStarter = ownedProcessStarter,
       _memorySampler = memorySampler,
       _budgetPolicy = budgetPolicy,
       _analysisInProgressOverride = analysisInProgress,
       _now = now ?? (() => DateTime.now().toUtc()) {
    if (processStarter != null && ownedProcessStarter != null) {
      throw ArgumentError('Choose one process starter');
    }
    if ((maxRoots != null && maxRoots! < 1) ||
        evictionSettleLimit.isNegative ||
        runtimeIdleGrace.isNegative) {
      throw ArgumentError('Invalid multi-root memory policy');
    }
  }

  /// The primary root. Used as the process working directory and the initial
  /// member of [_activeRoots]. Additional roots can be added with [addRoot]
  /// so one analysis server serves several worktrees at once.
  final String root;
  // Insertion-ordered set of currently-analyzed roots (LRU order is managed by
  // the pool above; this class just tracks membership). Always contains [root]
  // unless it was explicitly removed.
  final _activeRoots = <String>{};
  // Per-root last-use time (canonical path -> timestamp) for LRU eviction.
  final _rootLastUsed = <String, DateTime>{};

  /// Strict upper bound on concurrently analyzed roots; null means unbounded.
  final int? maxRoots;
  final SystemMemorySnapshot? Function()? _memorySampler;
  final GlobalBudgetPolicy? _budgetPolicy;
  final bool Function()? _analysisInProgressOverride;
  final DateTime Function() _now;

  /// How long a memory-driven eviction allows memory to come back before
  /// deciding whether another root must go. Releasing a large root takes
  /// seconds (measured ~5 s for ~7 GiB on macOS), and the kernel pressure level
  /// lags further; resampling immediately reads the pre-eviction state and
  /// evicts every idle root.
  final Duration evictionSettleLimit;

  /// A root must have been unused for this long before runtime reclamation.
  final Duration runtimeIdleGrace;
  DateTime? _lastEvictionAt;
  static const _runtimeMonitorCooldown = Duration(seconds: 10);
  final Future<Process> Function()? _processStarter;
  final Future<AnalyzerProcess> Function()? _ownedProcessStarter;
  late final AnalyzerProcess _process;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final Map<String, List<Object?>> _errors = {};
  final StreamController<Map<String, Object?>> _notifications =
      StreamController.broadcast();
  Future<void> _writeQueue = Future<void>.value();
  bool _isAnalyzing = false;
  bool get _analysisInProgress =>
      _isAnalyzing || (_analysisInProgressOverride?.call() ?? false);
  int _lowMemorySamples = 0;
  bool _runtimeRecoveryPending = false;
  int _nextId = 0;
  bool _started = false;
  bool _closed = false;
  Future<void>? _closeFuture;
  Future<void>? _startFuture;
  final _creationDone = Completer<void>();
  bool _processCreated = false;
  Object? _failure;

  void _throwIfFailed() {
    if (_failure != null) throw StateError('Analyzer unavailable: $_failure');
  }

  void _recordFailure(Object error) {
    _failure ??= error;
    _errors.clear();
    _failPending(_failure!);
  }

  Map<String, Object?>? sampleOwnedResources() {
    if (!_started || _closed) return null;
    final process = _process;
    return process is OwnedProcessMetrics
        ? (process as OwnedProcessMetrics).sampleResources()
        : null;
  }

  SystemMemorySnapshot? _sampleMemory() {
    try {
      return _memorySampler?.call();
    } on Object {
      return null;
    }
  }

  Future<void> start() => _startFuture ??= _start();

  /// Roots this server is currently analyzing, in insertion order.
  List<String> get activeRoots => List.unmodifiable(_activeRoots);

  /// Adds [newRoot] to the analyzed set, so this one server also analyzes that
  /// worktree, subject to configured admission policy. Returns true only when
  /// the root was newly admitted.
  Future<bool> addRoot(String newRoot) async {
    final result = await ensureRoot(newRoot);
    return result.added;
  }

  Future<bool> _applyAddRoot(String newRoot) async {
    _throwIfFailed();
    final canonical = File(newRoot).absolute.path;
    if (_activeRoots.contains(canonical)) return false;
    _activeRoots.add(canonical);
    _rootLastUsed[canonical] = _now();
    await _applyRoots();
    return true;
  }

  /// Removes [oldRoot] from the analyzed set, releasing its analysis context
  /// (the main memory-reclamation lever under pressure). No-op if absent or if
  /// it is the last remaining root. Returns true if the set changed.
  Future<bool> removeRoot(String oldRoot) async {
    _throwIfFailed();
    final canonical = File(oldRoot).absolute.path;
    if (!_activeRoots.contains(canonical) || _activeRoots.length <= 1) {
      return false;
    }
    _activeRoots.remove(canonical);
    _rootLastUsed.remove(canonical);
    // Drop cached diagnostics that belonged to the removed root so they can
    // never leak into a later full/directory result.
    _errors.removeWhere((path, _) => _isUnderRoot(path, canonical));
    await _applyRoots();
    return true;
  }

  Future<void> _applyRoots() async {
    await _request('analysis.setAnalysisRoots', {
      'included': _activeRoots.toList(),
      'excluded': [],
    });
    _throwIfFailed();
  }

  /// Ensures [requestedRoot] is active, evicting least-recently-used idle roots
  /// first when memory is tight. This is the IDE-style behaviour: keep several
  /// worktrees warm for instant re-review, but drop the stalest one under
  /// pressure rather than OOM. Configured root and memory limits fail closed:
  /// the result reports a denial rather than exceeding a limit. [pinned] roots
  /// and the primary root are never evicted automatically.
  Future<({bool added, List<String> evicted, String? deniedReason})> ensureRoot(
    String requestedRoot, {
    Set<String> pinned = const {},
  }) async {
    _throwIfFailed();
    final canonical = File(requestedRoot).absolute.path;
    final evicted = <String>[];
    if (_activeRoots.contains(canonical)) {
      _rootLastUsed[canonical] = _now();
      return (added: false, evicted: evicted, deniedReason: null);
    }

    // Never evict the primary root, the requested root, pinned roots, or the
    // last remaining root.
    final pinnedCanonical = {
      for (final p in pinned) File(p).absolute.path,
      File(root).absolute.path,
      canonical,
    };
    final sampler = _memorySampler;
    final policy = _budgetPolicy;
    if (policy == null) {
      while (maxRoots != null && _activeRoots.length >= maxRoots!) {
        final victim = _lruEvictable(pinnedCanonical);
        if (victim == null || !await removeRoot(victim)) {
          return (added: false, evicted: evicted, deniedReason: 'root-limit');
        }
        evicted.add(victim);
      }
    }
    if (policy != null && sampler == null) {
      return (
        added: false,
        evicted: evicted,
        deniedReason: 'memory-sample-unavailable',
      );
    }
    if (policy != null) {
      // Evict LRU idle roots while admitting a new one would be refused for
      // memory.
      final activePolicy = policy;
      String? tight() => activePolicy.waitingReason(
        _sampleMemory(),
        starting: true,
        recovering: false,
        now: _now(),
      );
      while (true) {
        final pressure = tight();
        if (pressure == 'memory-sample-unavailable') {
          return (added: false, evicted: evicted, deniedReason: pressure);
        }
        final atRootLimit =
            maxRoots != null && _activeRoots.length >= maxRoots!;
        if (!atRootLimit && pressure == null) break;
        // Do not evict every context on a stale post-eviction sample. Return
        // promptly so the session queue can serve other roots during recovery.
        if (pressure != null &&
            (evicted.isNotEmpty ||
                (_lastEvictionAt != null &&
                    _now().difference(_lastEvictionAt!) <
                        evictionSettleLimit))) {
          return (
            added: false,
            evicted: evicted,
            deniedReason: 'memory-pressure',
          );
        }
        final victim = _lruEvictable(pinnedCanonical);
        if (victim == null && atRootLimit) {
          return (added: false, evicted: evicted, deniedReason: 'root-limit');
        }
        if (victim == null) {
          return (
            added: false,
            evicted: evicted,
            deniedReason: 'memory-pressure',
          );
        }
        if (!await removeRoot(victim)) {
          return (
            added: false,
            evicted: evicted,
            deniedReason: pressure != null ? 'memory-pressure' : 'root-limit',
          );
        }
        evicted.add(victim);
        _lastEvictionAt = _now();
      }
    }
    final added = await _applyAddRoot(canonical);
    if (added) _rootLastUsed[canonical] = _now();
    return (added: added, evicted: evicted, deniedReason: null);
  }

  String? _lruEvictable(Set<String> pinned, {bool requireRuntimeIdle = false}) {
    String? oldest;
    DateTime? oldestAt;
    for (final r in _activeRoots) {
      if (pinned.contains(r)) continue;
      final at = _rootLastUsed[r] ?? DateTime.fromMillisecondsSinceEpoch(0);
      final unusedFor = _now().difference(at);
      if (requireRuntimeIdle &&
          (unusedFor.isNegative || unusedFor < runtimeIdleGrace)) {
        continue;
      }
      if (oldestAt == null || at.isBefore(oldestAt)) {
        oldest = r;
        oldestAt = at;
      }
    }
    return oldest;
  }

  /// Samples memory and reclaims one sufficiently idle non-primary root.
  /// The caller must serialize this with client requests and publish registry
  /// changes when a root is removed.
  Future<List<String>> monitorMemoryPressureOnce() async {
    final sampler = _memorySampler;
    final policy = _budgetPolicy;
    if (!_started ||
        _closed ||
        _analysisInProgress ||
        sampler == null ||
        policy == null) {
      return const [];
    }
    final SystemMemorySnapshot? sample;
    try {
      sample = sampler();
    } on Object {
      _lowMemorySamples = 0;
      _runtimeRecoveryPending = false;
      return const [];
    }
    if (sample == null || !sample.freshAt(_now())) {
      _lowMemorySamples = 0;
      _runtimeRecoveryPending = false;
      return const [];
    }

    final recoveryReason = policy.waitingReason(
      sample,
      starting: false,
      recovering: true,
      now: _now(),
    );
    if (_runtimeRecoveryPending) {
      if (recoveryReason == null) {
        _runtimeRecoveryPending = false;
        _lowMemorySamples = 0;
        return const [];
      }
    } else {
      final pressureReason = policy.waitingReason(
        sample,
        starting: false,
        recovering: false,
        now: _now(),
      );
      if (pressureReason == null) {
        _lowMemorySamples = 0;
        return const [];
      }
      _lowMemorySamples++;
      if (_lowMemorySamples < 2) return const [];
      _runtimeRecoveryPending = true;
    }

    final lastEviction = _lastEvictionAt;
    if (lastEviction != null &&
        _now().difference(lastEviction) < _runtimeMonitorCooldown) {
      return const [];
    }
    final pinned = {File(root).absolute.path};
    final victim = _lruEvictable(pinned, requireRuntimeIdle: true);
    if (victim == null || _analysisInProgress) return const [];
    if (await removeRoot(victim)) {
      _lastEvictionAt = _now();
      _lowMemorySamples = 0;
      return [victim];
    }
    return const [];
  }

  Future<void> _start() async {
    final primaryRoot = File(root).absolute.path;
    _activeRoots.add(primaryRoot);
    _rootLastUsed[primaryRoot] = _now();
    try {
      final dartExecutable = await resolveDartExecutable();
      if (_ownedProcessStarter != null) {
        _process = await _ownedProcessStarter();
      } else if (_processStarter != null) {
        _process = DirectAnalyzerProcess(await _processStarter());
      } else {
        _process = await startAnalyzerProcess(dartExecutable, [
          'language-server',
          '--protocol=analyzer',
          '--client-id=ai-analyzer',
        ], workingDirectory: root);
      }

      _processCreated = true;
      _creationDone.complete();
      if (_closed) throw StateError('Analyzer startup cancelled');
      _process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              try {
                _receive(line);
              } catch (error) {
                _recordFailure(error);
              }
            },
            onError: (Object error, StackTrace stack) {
              stderr.writeln('[analysis-server stdout] $error');
              _recordFailure(error);
            },
            onDone: () {
              if (!_closed) {
                _recordFailure(StateError('Analyzer stdout closed'));
              }
            },
          );
      _process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => stderr.writeln('[analysis-server] $line'));
      unawaited(
        _process.exitCode.then((code) {
          final error = StateError('Analysis server exited with code $code.');
          if (!_closed) _recordFailure(error);
        }),
      );

      await _request('server.getVersion', {});
      await _request('server.setSubscriptions', {
        'subscriptions': ['STATUS'],
      });
      await _request('analysis.setAnalysisRoots', {
        'included': _activeRoots.toList(),
        'excluded': [],
      });
      _throwIfFailed();
      _started = true;
    } catch (_) {
      if (!_creationDone.isCompleted) _creationDone.complete();
      await close();
      rethrow;
    }
  }

  Future<Map<String, Object?>> handle(Map<String, Object?> command) async {
    if (command['op'] != 'shutdown' && command['op'] != 'status') {
      _throwIfFailed();
    }
    switch (command['op']) {
      case 'check':
        return _check(command['files']);
      case 'fullCheck':
        final scope = command['root'];
        if (scope != null && (scope is! String || scope.isEmpty)) {
          return {'ok': false, 'error': 'fullCheck.root must be a path'};
        }
        return _fullCheck(root: scope as String?);
      case 'clearContent':
        return _clearContent(command['files']);
      case 'addRoot':
        final target = command['root'];
        if (target is! String || target.isEmpty) {
          return {'ok': false, 'error': 'addRoot.root must be a path'};
        }
        // Pool joins go through ensureRoot so a memory-short pool evicts its
        // least-recently-used idle roots instead of growing without bound.
        final admitted = await ensureRoot(target);
        if (admitted.deniedReason != null) {
          final reason = admitted.deniedReason!;
          final message = switch (reason) {
            'root-limit' =>
              'The shared analyzer pool is at its root limit and has no '
                  'eligible root to evict.',
            'memory-pressure' =>
              'The shared analyzer pool cannot confirm enough memory. '
                  'Retry after memory recovery.',
            'memory-sample-unavailable' =>
              'System memory could not be sampled; the pool refused to add '
                  'another root.',
            _ => 'The shared analyzer pool refused the root.',
          };
          return {
            'ok': false,
            'code': 'pool-admission-denied',
            'reason': reason,
            'error': message,
            'fallbackStarted': false,
            'changed': false,
            'evicted': admitted.evicted,
          };
        }
        return {
          'ok': true,
          'changed': admitted.added,
          'evicted': admitted.evicted,
        };
      case 'removeRoot':
        final target = command['root'];
        if (target is! String || target.isEmpty) {
          return {'ok': false, 'error': 'removeRoot.root must be a path'};
        }
        return {'ok': true, 'changed': await removeRoot(target)};
      case 'status':
        return {
          'ok': true,
          'source': 'daemon-session',
          'started': _started,
          'root': root,
          'roots': _activeRoots.toList(),
          'isAnalyzing': _isAnalyzing,
          'processBackend': _process.backend,
          'healthy': _failure == null,
          'failure': _failure?.toString(),
        };
      case 'shutdown':
        await close();
        return {'ok': true};
      default:
        return {'ok': false, 'error': 'Unknown op: ${command['op']}'};
    }
  }

  Future<Map<String, Object?>> _check(Object? value) async {
    if (value is! List || value.isEmpty) {
      return {'ok': false, 'error': 'check.files must be a non-empty list'};
    }
    final files = <String, String>{};
    final paths = <String>[];
    final directoryPaths = <String>{};
    for (final item in value) {
      if (item is String) {
        final path = File(item).absolute.path;
        if (Directory(path).existsSync()) {
          final expanded = await _expandDirectory(path);
          paths.addAll(expanded);
          directoryPaths.addAll(expanded);
        } else {
          paths.add(path);
        }
      } else if (item is Map && item['path'] is String) {
        final path = File(item['path'] as String).absolute.path;
        if (Directory(path).existsSync()) {
          return {
            'ok': false,
            'error': 'check.files content overlays must be files: $path',
          };
        }
        paths.add(path);
        if (item['content'] is String) {
          files[path] = item['content'] as String;
        }
      } else {
        return {'ok': false, 'error': 'Invalid check.files item: $item'};
      }
    }

    final uniquePaths = paths.toSet().toList(growable: false);
    if (uniquePaths.isEmpty) {
      return {'ok': false, 'error': 'check.files contains no Dart files'};
    }
    // Refresh LRU last-use for the roots these files belong to.
    for (final path in uniquePaths) {
      for (final r in _activeRoots) {
        if (_isUnderRoot(path, r)) {
          _rootLastUsed[r] = _now();
          break;
        }
      }
    }
    final selectedFiles =
        files.isEmpty
            ? const <String, String>{}
            : {
              for (final entry in files.entries)
                if (uniquePaths.contains(entry.key)) entry.key: entry.value,
            };

    await _request('analysis.setPriorityFiles', {'files': uniquePaths});

    final stopwatch = Stopwatch()..start();
    if (selectedFiles.isNotEmpty) {
      await _request('analysis.updateContent', {
        'files': {
          for (final entry in selectedFiles.entries)
            entry.key: {'type': 'add', 'content': entry.value},
        },
      });
    }
    if (directoryPaths.isNotEmpty) {
      await _waitForDirectoryAnalysis(directoryPaths);
    }
    final resultPaths = [
      for (final path in uniquePaths)
        if (!directoryPaths.contains(path) || _errors.containsKey(path)) path,
    ];
    final responses = await Future.wait([
      for (final path in resultPaths)
        directoryPaths.contains(path)
            ? Future<List<Object?>>.value(_errors[path] ?? const [])
            : _getStableErrors(path),
    ]);
    stopwatch.stop();
    final counts = _diagnosticCounts(responses);
    _throwIfFailed();

    return {
      'ok': true,
      'source': 'daemon-session',
      'elapsedMs': stopwatch.elapsedMilliseconds,
      'contentUpdated': selectedFiles.isNotEmpty,
      ...counts,
      'diagnostics': {
        for (var index = 0; index < resultPaths.length; index++)
          resultPaths[index]: responses[index],
      },
    };
  }

  /// Expands a directory from disk into one priority-file batch. The analyzer
  /// diagnostics cache is applied after the batch has settled, so a cold
  /// session can discover newly-created files while excluded files are still
  /// removed by their missing cache keys.
  Future<List<String>> _expandDirectory(String directory) async {
    // Resolve symlinks so scanned file paths share the same prefix as `root`,
    // which `_resolveRoot` already canonicalizes. Without this, a directory
    // under a symlinked location (e.g. macOS temp dirs where `/var` ->
    // `/private/var`) yields `/var/...` file paths that fail the
    // `_isProjectFile` prefix check against a `/private/var/...` root, so the
    // expansion comes back empty.
    final directoryHandle = Directory(directory);
    final normalizedDirectory =
        directoryHandle.existsSync()
            ? directoryHandle.resolveSymbolicLinksSync()
            : directoryHandle.absolute.path;
    final result = <String>[];
    final pending = <Directory>[Directory(normalizedDirectory)];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      await for (final entity in current.list(followLinks: false)) {
        final name =
            entity.uri.pathSegments.isEmpty
                ? entity.path
                : entity.uri.pathSegments.last;
        if (name.startsWith('.')) continue;
        if (entity is Directory) {
          pending.add(entity);
        } else if (entity is File &&
            entity.path.toLowerCase().endsWith('.dart') &&
            _isProjectFile(entity.path)) {
          result.add(entity.absolute.path);
        }
      }
    }
    result.sort();
    return result;
  }

  Future<void> _waitForDirectoryAnalysis(Set<String> paths) async {
    if (paths.every(_errors.containsKey)) return;
    var sawWorking = _isAnalyzing;
    final deadline = Stopwatch()..start();
    Stopwatch? idleSince = _isAnalyzing ? null : (Stopwatch()..start());
    while (true) {
      _throwIfFailed();
      if (paths.every(_errors.containsKey)) return;
      if (sawWorking && !_isAnalyzing) return;
      if (!sawWorking &&
          !_isAnalyzing &&
          idleSince != null &&
          idleSince.elapsed >= const Duration(milliseconds: 250)) {
        // setPriorityFiles can be a no-op for an already-idle analyzer. Do
        // not wait forever for excluded files or a status cycle that will
        // never happen; the cache-key filter below is authoritative.
        return;
      }
      if (analysisTimeout != null && deadline.elapsed >= analysisTimeout!) {
        throw TimeoutException(
          'Analyzer did not publish directory diagnostics',
        );
      }
      if (_isAnalyzing) {
        sawWorking = true;
        idleSince = null;
      } else if (!sawWorking && idleSince == null) {
        idleSince = Stopwatch()..start();
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<List<Object?>> _getStableErrors(String path) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final before = await _fileFingerprint(path);
      final errors = await _getErrors(path);
      final after = await _fileFingerprint(path);
      if (before == after) return errors;
    }
    // The caller is actively changing this file. Return the latest result
    // after bounded retries rather than blocking the AI indefinitely.
    return _errors[path] ?? const [];
  }

  Future<List<Object?>> _getErrors(String path) async {
    final response = await _request('analysis.getErrors', {'file': path});
    final result = response['result'];
    if (result is Map && result['errors'] is List) {
      final errors = List<Object?>.from(result['errors'] as List);
      _errors[path] = errors;
      return errors;
    }
    return _errors[path] ?? const [];
  }

  Future<Map<String, Object?>> _clearContent(Object? value) async {
    if (value is! List ||
        value.isEmpty ||
        value.any((item) => item is! String)) {
      return {
        'ok': false,
        'error': 'clearContent.files must be a non-empty list',
      };
    }
    final files = value.cast<String>();
    for (final path in files) {
      for (final r in _activeRoots) {
        if (_isUnderRoot(path, r)) {
          _rootLastUsed[r] = _now();
          break;
        }
      }
    }
    await _request('analysis.updateContent', {
      'files': {
        for (final path in files) path: {'type': 'remove'},
      },
    });
    return {'ok': true, 'files': files.length};
  }

  /// [root], when given, restricts the result to files under that root. In a
  /// shared pool one check must answer for its own worktree only; otherwise
  /// another worktree's errors would fail it.
  Future<Map<String, Object?>> _fullCheck({String? root}) async {
    final scope = root == null ? null : File(root).absolute.path;
    if (scope != null && !_activeRoots.any((r) => _isUnderRoot(scope, r))) {
      return {'ok': false, 'error': 'fullCheck.root is not analyzed: $root'};
    }
    for (final r in _activeRoots) {
      if (scope == null || _isUnderRoot(scope, r) || _isUnderRoot(r, scope)) {
        _rootLastUsed[r] = _now();
      }
    }
    final stopwatch = Stopwatch()..start();
    // The shared session's analysis server already watches the file system and
    // keeps `_errors` current: during every analysis pass it pushes an
    // `analysis.errors` notification per analyzed file, cached by `_receive`.
    // On the legacy protocol a `server.status` with `isAnalyzing:false` is sent
    // only after all `analysis.errors` for that pass, on the same stream, so
    // once the server is idle the cache holds the authoritative,
    // exclude-respecting diagnostics for the whole root.
    //
    // So `full` just reuses that cache instead of issuing one
    // `analysis.getErrors` round-trip per file (slow on large workspaces and
    // blind to the analyzer's own exclude rules, which surfaces excluded
    // generated files as false positives). It also does not force a
    // `reanalyze`: that recomputes the entire workspace from scratch on every
    // gate run even when nothing changed. Instead it waits for any in-flight
    // pass to settle so disk edits made just before the gate are reflected,
    // matching the trust model `fast` already uses.
    await _waitForIdle();
    _throwIfFailed();

    final libraries = _errors.keys
        .where(_isProjectFile)
        .where((path) => scope == null || _isUnderRoot(path, scope))
        .where((path) => path.toLowerCase().endsWith('.dart'))
        .where((path) => !_isUnderHiddenSegment(path))
        .toList(growable: false);
    final diagnostics = <String, List<Object?>>{
      for (final path in libraries)
        if (_errors.containsKey(path)) path: _errors[path]!,
    };
    if (fullCheckFallbackEnabled) {
      for (final path in libraries) {
        if (diagnostics.containsKey(path)) continue;
        diagnostics[path] = await _getStableErrors(path);
      }
    }
    stopwatch.stop();
    final counts = _diagnosticCounts(diagnostics.values);
    return {
      'ok': true,
      'source': 'daemon-session',
      'mode': 'full',
      'elapsedMs': stopwatch.elapsedMilliseconds,
      'files': libraries.length,
      ...counts,
      'diagnostics': diagnostics,
    };
  }

  Map<String, int> _diagnosticCounts(Iterable<List<Object?>> diagnostics) {
    var errors = 0;
    var warnings = 0;
    var infos = 0;
    for (final fileDiagnostics in diagnostics) {
      for (final diagnostic in fileDiagnostics) {
        if (diagnostic is! Map) continue;
        switch (diagnostic['severity']) {
          case 'ERROR':
            errors++;
          case 'WARNING':
            warnings++;
          default:
            infos++;
        }
      }
    }
    return {'errors': errors, 'warnings': warnings, 'infos': infos};
  }

  /// Waits until the analysis server is idle so the cached diagnostics reflect
  /// a settled analysis pass. If a pass is already in flight (e.g. the server
  /// is still reacting to a recent disk edit) this blocks until it finishes;
  /// if the server is already idle it returns immediately and the caller reads
  /// the up-to-date cache. Unlike a forced `analysis.reanalyze`, this does not
  /// recompute an unchanged workspace from scratch.
  Future<void> _waitForIdle() async {
    if (!_isAnalyzing) return;
    await _waitForStatus(false);
  }

  Future<void> _waitForStatus(bool analyzing) async {
    _throwIfFailed();
    if (_isAnalyzing == analyzing) return;
    await _notifications.stream
        .firstWhere((message) {
          _throwIfFailed();
          if (message['event'] != 'server.status') return false;
          final params = message['params'];
          final analysis = params is Map ? params['analysis'] : null;
          return analysis is Map && analysis['isAnalyzing'] == analyzing;
        })
        .timeout(analysisTimeout ?? const Duration(days: 3650));
    _throwIfFailed();
  }

  Future<String> _fileFingerprint(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      // A stable in-process FNV-1a fingerprint avoids adding a package just
      // for the before/after change check. It is not used as a cache key.
      var hash = 0xcbf29ce484222325;
      for (final byte in bytes) {
        hash ^= byte;
        hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
      }
      return '${bytes.length}:$hash';
    } on FileSystemException {
      return 'missing';
    }
  }

  bool _isProjectFile(String path) =>
      _activeRoots.any((r) => _isUnderRoot(path, r));

  // Hidden-segment check relative to whichever active root contains the path,
  // so a dot-directory under one worktree is judged against that worktree.
  bool _isUnderHiddenSegment(String path) {
    for (final r in _activeRoots) {
      if (_isUnderRoot(path, r)) return _containsHiddenSegment(path, r);
    }
    return true;
  }

  bool _isUnderRoot(String path, String rootPath) {
    final normalizedPath = path.toLowerCase();
    final normalizedRoot = rootPath.toLowerCase();
    return normalizedPath == normalizedRoot ||
        normalizedPath.startsWith('$normalizedRoot${Platform.pathSeparator}');
  }

  bool _containsHiddenSegment(String path, String base) {
    final normalizedPath = File(path).absolute.path;
    final normalizedBase = Directory(base).absolute.path;
    if (normalizedPath == normalizedBase) return false;
    final separator =
        normalizedBase.endsWith(Platform.pathSeparator)
            ? ''
            : Platform.pathSeparator;
    final relative = normalizedPath.substring(
      normalizedBase.length + separator.length,
    );
    return relative
        .split(Platform.pathSeparator)
        .any((segment) => segment.startsWith('.'));
  }

  void _receive(String line) {
    if (line.trim().isEmpty) return;
    final decoded = jsonDecode(line);
    if (decoded is! Map) return;
    final message = Map<String, Object?>.from(decoded);
    if (const {
      'server.pluginError',
      'server.error',
      'plugin.error',
    }.contains(message['event'])) {
      _recordFailure(
        StateError(
          'Analyzer protocol failure: ${message['event']}: ${message['params']}',
        ),
      );
      if (!_notifications.isClosed) _notifications.add(message);
      return;
    }
    if (message['event'] == 'analysis.flushResults') {
      final params = message['params'];
      if (params is Map && params['files'] is List) {
        for (final file in params['files'] as List) {
          if (file is String) _errors.remove(file);
        }
      }
    }
    final id = message['id'];
    if (id != null && message['method'] == null) {
      _pending.remove('$id')?.complete(message);
      return;
    }
    if (message['event'] == 'analysis.errors') {
      final params = message['params'] as Map<String, Object?>?;
      final file = params?['file'];
      final errors = params?['errors'];
      if (file is String && errors is List) _errors[file] = errors;
    }
    if (message['event'] == 'server.status') {
      final params = message['params'];
      final analysis = params is Map ? params['analysis'] : null;
      if (analysis is Map && analysis['isAnalyzing'] is bool) {
        final isAnalyzing = analysis['isAnalyzing'] as bool;
        _isAnalyzing = isAnalyzing;
      }
    }
    if (!_notifications.isClosed) _notifications.add(message);
  }

  Future<Map<String, Object?>> _request(String method, Object? params) {
    if (method != 'server.shutdown') _throwIfFailed();
    final id = '${++_nextId}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    final write = _writeQueue.then<void>((_) async {
      _process.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'params': params}),
      );
      await _process.stdin.flush();
    });
    // A closed pipe must fail this request immediately, even if the process
    // exit was observed before the request entered the pending map.
    _writeQueue = write.catchError((Object error) {
      if (identical(_pending[id], completer) && !completer.isCompleted) {
        completer.completeError(error);
      }
    });
    final responseFuture =
        analysisTimeout == null
            ? completer.future
            : completer.future.timeout(analysisTimeout!);
    return responseFuture
        .then((response) {
          if (method != 'server.shutdown') _throwIfFailed();
          if (response['error'] != null) {
            throw StateError('$method failed: ${response['error']}');
          }
          return response;
        })
        .whenComplete(() => _pending.remove(id));
  }

  void _failPending(Object error) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      if (!request.isCompleted) request.completeError(error);
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    if (_startFuture == null && !_processCreated) return;
    // Creation may be in flight. Join it before reclaiming the slot, and make
    // every handshake waiter fail so silent startup cannot block shutdown.
    _failPending(StateError('Analysis session closed.'));
    await _creationDone.future;
    try {
      if (!_processCreated) return;
      try {
        if (_started && _failure == null) {
          await _request(
            'server.shutdown',
            {},
          ).timeout(const Duration(seconds: 5));
        }
      } catch (_) {
        // A missing shutdown response is handled by bounded termination below.
      }
      await _terminateProcessTree();
    } finally {
      // Complete pending responses even when termination failed. The caller
      // still receives that failure; request timers must not retain the host.
      _failPending(StateError('Analysis session closed.'));
      await _notifications.close();
    }
  }

  Future<void> _terminateProcessTree() async {
    await _process.terminate();
  }
}
