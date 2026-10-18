import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The metadata file written by an IDE companion bridge.
File ideBridgeEndpointFile(String root) => File(
  '${Directory(root).path}${Platform.pathSeparator}.dart_tool'
  '${Platform.pathSeparator}dana-ide-bridge.json',
);

/// A validated, root-scoped IDE bridge endpoint.
class IdeBridgeEndpoint {
  IdeBridgeEndpoint({
    required this.root,
    required this.address,
    required this.port,
    required this.token,
    required this.capabilities,
    this.pid,
    this.owner,
  });

  final String root;
  final String address;
  final int port;
  final String token;
  final Map<String, bool> capabilities;
  final int? pid;
  final String? owner;

  bool supports(String capability) => capabilities[capability] == true;

  static Future<IdeBridgeEndpoint?> discover(String root) async {
    final canonicalRoot = Directory(root).resolveSymbolicLinksSync();
    final file = ideBridgeEndpointFile(root);
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return null;
      final metadata = Map<Object?, Object?>.from(value);
      if (metadata['protocol'] != 1 || metadata['transport'] != 'loopback') {
        return null;
      }
      final declaredRoot = metadata['root'];
      if (declaredRoot is! String ||
          Directory(declaredRoot).resolveSymbolicLinksSync() != canonicalRoot) {
        return null;
      }
      final address = metadata['address'];
      final port = metadata['port'];
      final token = metadata['token'];
      if (address != '127.0.0.1' && address != '::1') return null;
      if (port is! int || port < 1 || port > 65535) return null;
      if (token is! String || token.isEmpty) return null;
      final rawCapabilities = metadata['capabilities'];
      final capabilities = <String, bool>{};
      if (rawCapabilities is Map) {
        for (final entry in rawCapabilities.entries) {
          if (entry.key is String && entry.value is bool) {
            capabilities[entry.key as String] = entry.value as bool;
          }
        }
      }
      return IdeBridgeEndpoint(
        root: canonicalRoot,
        address: address as String,
        port: port,
        token: token,
        capabilities: capabilities,
        pid: metadata['pid'] is int ? metadata['pid'] as int : null,
        owner: metadata['owner'] as String?,
      );
    } on Object {
      // An endpoint may be being atomically replaced by the IDE.
      return null;
    }
  }
}

/// Client for the small JSON-lines protocol exposed by an IDE companion.
class IdeBridgeClient {
  IdeBridgeClient._(this.endpoint, this._socket)
    : _lines = StreamIterator(
        _socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

  final IdeBridgeEndpoint endpoint;
  final Socket _socket;
  final StreamIterator<String> _lines;
  bool _closed = false;

  static Future<IdeBridgeClient> connect(IdeBridgeEndpoint endpoint) async {
    final socket = await Socket.connect(
      endpoint.address,
      endpoint.port,
      timeout: const Duration(milliseconds: 500),
    );
    return IdeBridgeClient._(endpoint, socket);
  }

  Future<Map<String, Object?>> check(
    List<String> files, {
    Map<String, String> overlays = const {},
  }) => _send({
    'op': 'check',
    'files': [
      for (final file in files)
        overlays.containsKey(file)
            ? {'path': file, 'content': overlays[file]}
            : file,
    ],
  });

  /// [settleLimitSeconds] bounds how long the bridge waits, once the IDE
  /// analyzer is idle, for late diagnostics (analyzer plugins) to stop
  /// arriving. Null uses the bridge's default.
  Future<Map<String, Object?>> fullCheck({int? settleLimitSeconds}) => _send({
    'op': 'fullCheck',
    if (settleLimitSeconds != null) 'settleLimitSeconds': settleLimitSeconds,
  });

  Future<Map<String, Object?>> status() => _send({'op': 'status'});

  Future<Map<String, Object?>> _send(Map<String, Object?> command) async {
    if (_closed) throw StateError('IDE bridge client is closed');
    _socket.writeln(jsonEncode({...command, 'token': endpoint.token}));
    await _socket.flush();
    if (!await _lines.moveNext()) throw StateError('IDE bridge disconnected');
    final value = jsonDecode(_lines.current);
    if (value is! Map) throw StateError('Invalid IDE bridge response');
    return Map<String, Object?>.from(value);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _lines.cancel();
    _socket.destroy();
  }
}
