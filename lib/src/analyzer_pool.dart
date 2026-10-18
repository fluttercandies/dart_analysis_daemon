import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/global_budget_service.dart';
import 'package:dart_analysis_daemon/src/runtime.dart';

/// Opt-in auto-join across projects (`DANA_MULTI_ROOT=1`).
///
/// When enabled, the first `dana` session also registers itself as a shared
/// multi-root pool. A later `dana check` for a different project discovers the
/// pool, joins it with `addRoot`, and analyzes inside the one process, so
/// opening several projects no longer spawns an analyzer each.
bool get multiRootEnabled {
  final value = Platform.environment['DANA_MULTI_ROOT'];
  if (value == null || value == '0') return false;
  if (value != '1') throw FormatException('DANA_MULTI_ROOT must be 0 or 1');
  return true;
}

/// Identity that must match for two projects to share one pool.
///
/// Intentionally SDK/runtime-scoped, NOT per-root: different projects have
/// different pubspecs and analysis_options by design, and that is exactly the
/// multi-root case the pool exists for. What must agree is the Dart executable,
/// the VM version, and the global-budget flag — anything that would make one
/// analysis server give wrong answers for the other root. Per-root config is
/// the analyzer's own concern once the root is added via `setAnalysisRoots`.
Future<Map<String, Object?>> poolIdentity() async => {
  'protocol': 1,
  'dartExecutable': await identityDartExecutable(),
  'dartVersion': Platform.version,
  'globalBudget': globalBudgetEnabled,
};

/// The cross-root discovery point. Independent of any one root so a second
/// project can find a live pool. Lives inside the platform state directory the
/// global budget already resolves, under a dedicated `pool-v1` subtree. Kept
/// inside that directory (not a sibling) so an explicit `DANA_GLOBAL_STATE_DIR`
/// — which is itself the final state directory — is honoured exactly.
/// Default cap on roots in a shared pool. Measured on a large Flutter
/// monorepo, each root costs ~10 GiB of analyzer footprint; on a 24 GiB
/// machine a fourth root drives swap to its limit.
const defaultPoolMaxRoots = 3;

/// `DANA_POOL_MAX_ROOTS` (1..64), else [defaultPoolMaxRoots].
int get poolMaxRoots =>
    parsePoolMaxRoots(Platform.environment['DANA_POOL_MAX_ROOTS']);

int parsePoolMaxRoots(String? value) {
  if (value == null || value.isEmpty) return defaultPoolMaxRoots;
  final parsed = RegExp(r'^\d+$').hasMatch(value) ? int.tryParse(value) : null;
  if (parsed == null || parsed < 1 || parsed > 64) {
    throw FormatException('DANA_POOL_MAX_ROOTS must be 1..64, got "$value"');
  }
  return parsed;
}

File poolRegistryFile() {
  final base = globalBudgetDirectory();
  return File(
    '${base.path}${Platform.pathSeparator}pool-v1'
    '${Platform.pathSeparator}pool.json',
  );
}

/// A validated, reachable pool endpoint plus the roots it currently serves.
class PoolRegistration {
  PoolRegistration({
    required this.address,
    required this.port,
    required this.token,
    required this.pid,
    required this.roots,
    required this.identity,
  });

  final String address;
  final int port;
  final String token;
  final int pid;
  final List<String> roots;
  final Map<String, Object?> identity;

  Map<String, Object?> toJson() => {
    'protocol': 1,
    'address': address,
    'port': port,
    'token': token,
    'pid': pid,
    'owner': 'dart_analysis_daemon-pool',
    'roots': roots,
    'identity': identity,
  };

  static PoolRegistration? tryParse(Object? value) {
    if (value is! Map) return null;
    final address = value['address'];
    final port = value['port'];
    final token = value['token'];
    final pid = value['pid'];
    final roots = value['roots'];
    final identity = value['identity'];
    if (value['protocol'] != 1) return null;
    if (address is! String || (address != '127.0.0.1' && address != '::1')) {
      return null;
    }
    if (port is! int || port < 1 || port > 65535) return null;
    if (token is! String || token.isEmpty) return null;
    if (pid is! int) return null;
    if (identity is! Map) return null;
    return PoolRegistration(
      address: address,
      port: port,
      token: token,
      pid: pid,
      roots: roots is List ? roots.whereType<String>().toList() : const [],
      identity: Map<String, Object?>.from(identity),
    );
  }
}

/// Writes (or overwrites) the pool registry for the session that owns [port].
///
/// Called by a session acting as the pool. Atomic rename so a discovering
/// process never reads a half-written file.
Future<void> writePoolRegistry(
  PoolRegistration registration, {
  File? registry,
}) async {
  final file = registry ?? poolRegistryFile();
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.$pid.tmp');
  await temporary.writeAsString(jsonEncode(registration.toJson()));
  await temporary.rename(file.path);
}

/// Whether a handled [command] changed the pool's root set, so the owning
/// session must republish the registry for later discoverers.
bool poolRootsChanged(
  Map<String, Object?> command,
  Map<String, Object?> response,
) =>
    (command['op'] == 'addRoot' || command['op'] == 'removeRoot') &&
    response['ok'] == true &&
    (response['changed'] == true ||
        (response['evicted'] is List &&
            (response['evicted'] as List).isNotEmpty));

/// Removes the pool registry if it still points at this process.
///
/// A session only clears the registry it published, so a concurrently started
/// pool is never clobbered on shutdown.
Future<void> deletePoolRegistryIfOwned({File? registry}) async {
  final file = registry ?? poolRegistryFile();
  if (!await file.exists()) return;
  try {
    final current = PoolRegistration.tryParse(
      jsonDecode(await file.readAsString()),
    );
    if (current != null && current.pid == pid) await file.delete();
  } on Object {
    // A malformed or racing registry is left for the next writer to replace.
  }
}

/// Discovers a live pool compatible with the current SDK, or null.
///
/// A pool is only returned when it is reachable and its recorded identity
/// matches the current SDK/runtime identity ([poolIdentity]), so projects on
/// different SDKs never share one analysis server. Per-root config does not
/// gate joining — that is the whole point of a multi-root pool.
Future<PoolRegistration?> discoverPool({File? registry}) async {
  final file = registry ?? poolRegistryFile();
  if (!await file.exists()) return null;
  PoolRegistration? registration;
  try {
    registration = PoolRegistration.tryParse(
      jsonDecode(await file.readAsString()),
    );
  } on Object {
    return null;
  }
  if (registration == null) return null;
  if (!_sameIdentity(registration.identity, await poolIdentity())) {
    return null;
  }
  try {
    final socket = await Socket.connect(
      registration.address,
      registration.port,
      timeout: const Duration(milliseconds: 500),
    );
    // destroy, not close: close() only shuts the write side, and the unread
    // input keeps the caller's isolate alive until the pool hangs up, so a
    // `dana check` that probed a live pool would never exit.
    socket.destroy();
  } on Object {
    // Registry points at a dead pool; let the caller start its own session.
    return null;
  }
  return registration;
}

bool _sameIdentity(
  Map<Object?, Object?> actual,
  Map<String, Object?> expected,
) => jsonEncode(actual) == jsonEncode(expected);

/// A client for a shared pool: joins [root] then runs one check in the pool.
class PoolClient {
  PoolClient._(this._socket, this._token)
    : _lines = StreamIterator(
        _socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

  final Socket _socket;
  final String _token;
  final StreamIterator<String> _lines;
  bool _closed = false;

  static Future<PoolClient> connect(PoolRegistration registration) async {
    final socket = await Socket.connect(
      registration.address,
      registration.port,
      timeout: const Duration(milliseconds: 500),
    );
    return PoolClient._(socket, registration.token);
  }

  /// Adds [root] to the pool's analyzed set. Idempotent on the server.
  Future<Map<String, Object?>> addRoot(String root) =>
      _send({'op': 'addRoot', 'root': root});

  Future<Map<String, Object?>> check(List<String> files) =>
      _send({'op': 'check', 'files': files});

  /// Full check scoped to [root], so the pool answers only for that worktree.
  Future<Map<String, Object?>> fullCheck({String? root}) =>
      _send({'op': 'fullCheck', if (root != null) 'root': root});

  Future<Map<String, Object?>> _send(Map<String, Object?> command) async {
    if (_closed) throw StateError('Pool client is closed');
    _socket.writeln(jsonEncode({...command, 'token': _token}));
    await _socket.flush();
    if (!await _lines.moveNext()) throw StateError('Pool disconnected');
    final decoded = jsonDecode(_lines.current);
    if (decoded is! Map) throw StateError('Invalid pool response');
    return Map<String, Object?>.from(decoded);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _lines.cancel();
    _socket.destroy();
  }
}
