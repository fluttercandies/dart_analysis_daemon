import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'windows_disk_snapshot.dart';

/// Bounded observations of compilation inputs inside an owner-private state.
/// A compiler depfile is not a complete runtime dependency or version barrier.
class PluginHostIdentity {
  final _records = <String, Object?>{};
  var _bytes = 0;

  String _read(String path) {
    final canonical = File(path).resolveSymbolicLinksSync();
    final key = canonical.toLowerCase();
    if (_records.containsKey(key)) return '';
    if (_records.length >= 4096) {
      throw StateError('Plugin host identity exceeds 4096 inputs');
    }
    final snapshot = WindowsDiskSnapshot.read(
      canonical,
      limit: 4 * 1024 * 1024,
    );
    _bytes += snapshot.bytes.length;
    if (_bytes > 128 * 1024 * 1024) {
      throw StateError('Plugin host identity exceeds 128MiB read budget');
    }
    _records[key] = {
      'id': snapshot.identity,
      'time': snapshot.writeTime,
      'sha256': sha256.convert(snapshot.bytes).toString(),
    };
    return utf8.decode(snapshot.bytes);
  }

  Future<String> capture(String statePath) async {
    final manager = Directory('$statePath/.plugin_manager');
    if (!manager.existsSync()) return 'no-generated-hosts';
    var hosts = 0;
    await for (final entry in manager.list(followLinks: false)) {
      if (entry is! Directory) {
        throw StateError('Unknown plugin host state entry');
      }
      if (++hosts > 32) {
        throw StateError('Plugin host identity exceeds 32 contexts');
      }
      final root = entry.path;
      final configFile = File('$root/.dart_tool/package_config.json');
      final config = jsonDecode(_read(configFile.path));
      if (config is! Map ||
          config['configVersion'] != 2 ||
          config['packages'] is! List) {
        throw FormatException('Unsupported plugin host package configuration');
      }
      _read('$root/pubspec.yaml');
      _read('$root/pubspec.lock');
      _read('$root/bin/plugin.dart');
      final dependencies = parseDependencies(_read('$root/bin/depfile.txt'));
      if (dependencies.isEmpty) {
        throw FormatException('Empty plugin compiler dependency graph');
      }
      for (final path in dependencies) {
        if (!File(path).isAbsolute) {
          throw FormatException('Relative plugin compiler dependency');
        }
        _read(path);
      }
      final snapshot = File('$root/bin/plugin.aot').statSync();
      if (snapshot.type != FileSystemEntityType.file || snapshot.size == 0) {
        throw StateError('Plugin AOT is missing');
      }
      _records['aot:$root'] = {
        'size': snapshot.size,
        'modified': snapshot.modified.toUtc().toIso8601String(),
      };
      for (final package in config['packages'] as List) {
        if (package is! Map || package['rootUri'] is! String) {
          throw FormatException('Invalid plugin resolved package');
        }
        final location = configFile.uri.resolve(package['rootUri'] as String);
        if (location.scheme != 'file') {
          throw FormatException('Non-file plugin package root');
        }
        _read('${Directory.fromUri(location).path}/pubspec.yaml');
      }
    }
    final sorted = Map.fromEntries(
      _records.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return sha256.convert(utf8.encode(jsonEncode(sorted))).toString();
  }

  static List<String> parseDependencies(String text) {
    final separator = text.indexOf(': ');
    if (separator < 0) throw FormatException('Invalid plugin compiler depfile');
    final input = text
        .substring(separator + 2)
        .trim()
        .replaceAll(RegExp(r'[\r\n]'), '');
    final paths = <String>[];
    final token = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final char = input[i];
      if (char == r'\') {
        if (++i >= input.length) {
          throw FormatException('Truncated depfile escape');
        }
        token.write(input[i]);
      } else if (char == ' ') {
        if (token.isNotEmpty) {
          paths.add(token.toString());
          token.clear();
        }
      } else {
        token.write(char);
      }
    }
    if (token.isNotEmpty) paths.add(token.toString());
    return paths.toSet().toList();
  }
}
