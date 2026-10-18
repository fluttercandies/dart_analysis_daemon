import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'plugin_host_identity.dart';

/// Owner-private SDK state. Call only after the previous worker Job is empty.
/// Identity covers the bounded observation graph, not every runtime dependency.
class ManagedPluginCache {
  ManagedPluginCache(this.state, this.name) {
    _validateName(name);
  }
  final Directory state;
  final String name;
  final _entries = <String, Directory>{};
  final _executionIdentities = <String, String>{};
  Directory get directory => Directory('${state.path}/$name');

  String _key(String root, String identity) => sha256
      .convert(utf8.encode(jsonEncode([root.toLowerCase(), identity])))
      .toString()
      .substring(0, 32);

  Future<void> invalidate(String root, String identity) async {
    final key = _key(root, identity);
    final entry = _entries[key];
    if (entry == null) return;
    final path = entry.path;
    await Isolate.run(() {
      if (Directory(path).existsSync()) {
        Directory(path).deleteSync(recursive: true);
      }
    });
    _entries.remove(key);
    _executionIdentities.remove(key);
  }

  Future<String> _observe(Directory entry) =>
      Isolate.run(() => PluginHostIdentity().capture(entry.path));

  Future<void> recordExecution(String root, String identity) async {
    final key = _key(root, identity);
    final entry = _entries[key];
    if (entry == null) throw StateError('Missing managed plugin state');
    _executionIdentities[key] = await _observe(entry);
  }

  Future<void> validateExecution(String root, String identity) async {
    final key = _key(root, identity);
    final expected = _executionIdentities[key];
    final entry = _entries[key];
    if (expected == null ||
        entry == null ||
        await _observe(entry) != expected) {
      throw StateError('Plugin execution inputs changed; result discarded');
    }
  }

  Future<Directory> prepare(String root, String identity) async {
    final key = _key(root, identity);
    // The SDK appends its own host/hash/bin paths, and some AOT loading paths
    // still fail beyond MAX_PATH even when file creation succeeds.
    if ('${directory.absolute.path}/$key'.length > 160) {
      throw StateError(
        'Managed SDK state path is too long; use a shorter DANA_GLOBAL_STATE_DIR',
      );
    }
    var existing = _entries[key];
    if (existing != null) {
      final expected = _executionIdentities[key];
      if (expected != null && await _observe(existing) != expected) {
        await invalidate(root, identity);
        existing = null;
      }
    }
    if (existing != null) {
      _entries.remove(key);
      _entries[key] = existing;
      return existing;
    }
    if (_entries.length >= 3) {
      final oldest = _entries.keys.first;
      final path = _entries[oldest]!.path;
      await Isolate.run(() => Directory(path).deleteSync(recursive: true));
      _entries.remove(oldest);
      _executionIdentities.remove(oldest);
    }
    final result = await Directory(
      '${directory.path}/$key',
    ).create(recursive: true);
    _entries[key] = result;
    return result;
  }

  /// The journal stores a basename, never an arbitrary deletion path.
  static Future<void> removeOwned(Directory state, Object? name) async {
    if (name == null) return; // Older implementations did not own SDK state.
    if (name is! String) throw StateError('Invalid managed cache name');
    _validateName(name);
    final path = '${state.path}/$name';
    await Isolate.run(() {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type != FileSystemEntityType.directory) {
        throw StateError('Managed cache is not an owned directory');
      }
      Directory(path).deleteSync(recursive: true);
    });
  }

  static void _validateName(String name) {
    if (!RegExp(r'^sdk-cache-[a-f0-9]{16}$').hasMatch(name)) {
      throw StateError('Invalid managed cache basename');
    }
  }
}
