import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import 'runtime.dart';
import 'windows_disk_snapshot.dart';

/// Bounded configuration observation, not a snapshot of all dependencies.
/// Runs in a separate isolate; Windows reads retain file identity and content.
class EnvironmentIdentity {
  Directory? _captureRoot;
  final _records = <String, Object?>{};
  final _options = <String>{};
  final _active = <String>{};
  final _contents = <String, Uint8List?>{};
  final _pathPlugins = <String>{};
  final _sourcePackages = <String>{};
  var _sourceFiles = 0;
  var _bytes = 0;
  var _entries = 0;

  /// Observability for capacity tuning (not part of the identity output).
  int get recordCount => _records.length;
  int get entryCount => _entries;
  int get byteCount => _bytes;

  Future<String> capture(String requestedRoot) async {
    final root = Directory(requestedRoot).resolveSymbolicLinksSync();
    _captureRoot = Directory(root);
    for (final name in [
      'pubspec.yaml',
      'pubspec.lock',
      'pubspec_overrides.yaml',
      '.dart_tool/package_config.json',
      '.dart_tool/extension_discovery/vs_code.json',
    ]) {
      _read(File('$root/$name'));
    }
    // Record missing ancestor files too: adding one invalidates the identity.
    var parent = Directory(root);
    final rootConfig = _nearestPackageConfig(parent);
    for (var depth = 0; ; depth++) {
      if (depth > 64) {
        throw StateError('Configuration ancestor depth exceeds 64');
      }
      _visitOptions(
        File('${parent.path}/analysis_options.yaml'),
        packageConfig: rootConfig,
      );
      final next = parent.parent;
      if (next.path == parent.path) break;
      parent = next;
    }
    // A streamed walk includes nested context configuration and its presence.
    // Generated/tool directories are outside this bounded observation scope.
    await _walk(Directory(root), 0);
    for (final path in _pathPlugins) {
      await _scanSourcePackage(Directory(path), 0);
    }
    final sorted = Map.fromEntries(
      _records.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return sha256.convert(utf8.encode(jsonEncode(sorted))).toString();
  }

  Future<void> _walk(Directory directory, int depth) async {
    if (depth > 32) {
      throw StateError('Configuration directory depth exceeds 32');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (++_entries > identityMaxEntries) {
        throw StateError('Configuration scan exceeds  entries');
      }
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entry is Directory) {
        if (const {'.git', '.dart_tool', 'build'}.contains(name)) continue;
        // A missing marker detects a new config without retaining directory IDs
        // (ordinary source-file edits should not invalidate a warm worker).
        _visitOptions(File('${entry.path}/analysis_options.yaml'));
        _read(File('${entry.path}/pubspec.yaml'));
        _read(File('${entry.path}/pubspec.lock'));
        _read(File('${entry.path}/pubspec_overrides.yaml'));
        _read(File('${entry.path}/.dart_tool/package_config.json'));
        await _walk(entry, depth + 1);
      } else if (entry is Link) {
        // Do not follow arbitrary source links; config links are read explicitly.
        if (name == 'analysis_options.yaml') _visitOptions(File(entry.path));
      }
    }
  }

  Uint8List? _read(File file, {bool required = false}) {
    final requested = file.absolute.path;
    if (_contents.containsKey(requested)) {
      final bytes = _contents[requested];
      if (required && bytes == null) {
        throw FileSystemException('Missing configuration', requested);
      }
      return bytes;
    }
    final maxFiles = identityMaxFiles;
    if (_records.length >= maxFiles && !_records.containsKey(requested)) {
      throw StateError('Configuration identity exceeds $maxFiles files');
    }
    if (!file.existsSync()) {
      _records[requested] = 'missing';
      _contents[requested] = null;
      if (required) {
        throw FileSystemException('Missing configuration', requested);
      }
      return null;
    }
    final snapshot = WindowsDiskSnapshot.read(
      requested,
      limit: 4 * 1024 * 1024,
    );
    _bytes += snapshot.bytes.length;
    final maxBytes = identityMaxBytes;
    if (_bytes > maxBytes) {
      throw StateError(
        'Configuration identity exceeds ${maxBytes ~/ (1024 * 1024)}MiB '
        'read budget',
      );
    }
    _records[requested] = {
      'path': snapshot.path,
      'identity': snapshot.identity,
      'writeTime': snapshot.writeTime,
      'length': snapshot.bytes.length,
      'sha256': sha256.convert(snapshot.bytes).toString(),
    };
    _contents[requested] = snapshot.bytes;
    return snapshot.bytes;
  }

  void _visitOptions(
    File file, {
    bool required = false,
    int depth = 0,
    File? packageConfig,
  }) {
    if (depth > 32) throw StateError('Options include depth exceeds 32');
    final canonical =
        file.existsSync()
            ? file.resolveSymbolicLinksSync().toLowerCase()
            : file.absolute.path.toLowerCase();
    final context = packageConfig ?? _nearestPackageConfig(file.parent);
    final key = '$canonical|${context?.absolute.path.toLowerCase()}';
    if (_active.contains(key)) throw FormatException('Options include cycle');
    if (!_options.add(key)) {
      if (required && !file.existsSync()) {
        throw FileSystemException('Missing included options', file.path);
      }
      return;
    }
    final bytes = _read(file, required: required);
    if (bytes == null) return;
    final value = loadYaml(utf8.decode(bytes));
    if (value == null) return;
    if (value is! Map) throw FormatException('Options must be a mapping');
    _active.add(key);
    try {
      final plugins = value['plugins'];
      if (plugins is Map) {
        for (final entry in plugins.entries) {
          final spec = entry.value;
          if (spec is Map && spec['path'] is String) {
            final declared = spec['path'] as String;
            final path =
                Directory(declared).isAbsolute
                    ? declared
                    : Directory.fromUri(file.parent.uri.resolve(declared)).path;
            _pathPlugins.add(path);
          }
        }
      }
      final include = value['include'];
      final targets =
          include == null
              ? const <Object?>[]
              : include is String
              ? [include]
              : include is List
              ? include
              : throw FormatException(
                'Options include must be a string or list',
              );
      for (final target in targets) {
        if (target is! String || target.isEmpty) {
          throw FormatException('Options include must name a file');
        }
        _visitOptions(
          _resolveInclude(file, target, context),
          required: true,
          depth: depth + 1,
          packageConfig: context,
        );
      }
    } finally {
      _active.remove(key);
    }
  }

  File? _nearestPackageConfig(Directory directory) {
    for (var depth = 0; depth <= 64; depth++) {
      final file = File('${directory.path}/.dart_tool/package_config.json');
      if (_read(file) != null) return file;
      final root = _captureRoot;
      if (root != null && directory.path == root.path) return null;
      final next = directory.parent;
      if (next.path == directory.path) return null;
      directory = next;
    }
    throw StateError('Package configuration ancestor depth exceeds 64');
  }

  Future<void> _scanSourcePackage(Directory directory, int depth) async {
    if (depth > 32) throw StateError('Plugin path dependency depth exceeds 32');
    final canonical = directory.resolveSymbolicLinksSync();
    if (!_sourcePackages.add(canonical.toLowerCase())) return;
    if (_sourcePackages.length > 128) {
      throw StateError('Plugin path dependency scan exceeds 128 packages');
    }
    final specFile = File('$canonical/pubspec.yaml');
    final spec = loadYaml(utf8.decode(_read(specFile, required: true)!));
    if (spec is! Map) throw FormatException('Plugin pubspec must be a mapping');
    _read(File('$canonical/pubspec.lock'));
    _read(File('$canonical/.dart_tool/package_config.json'));
    final overridesFile = File('$canonical/pubspec_overrides.yaml');
    final overridesBytes = _read(overridesFile);
    final overrides =
        overridesBytes == null ? null : loadYaml(utf8.decode(overridesBytes));
    if (overrides != null && overrides is! Map) {
      throw FormatException('Plugin overrides must be a mapping');
    }
    for (final name in ['lib', 'bin']) {
      final source = Directory('$canonical/$name');
      if (FileSystemEntity.typeSync(source.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError(
          'Plugin source roots require verified link resolution',
        );
      }
      // Track missing source roots: adding a lib/bin invalidates the identity.
      _records['source-directory:${source.path}'] = source.existsSync();
      if (source.existsSync()) await _scanDartSources(source, 0);
    }
    final dependencies = spec['dependencies'];
    if (dependencies != null && dependencies is! Map) {
      throw FormatException('Plugin dependencies must be a mapping');
    }
    final replacements = <Object?, Object?>{};
    for (final mapping in [
      spec['dependency_overrides'],
      if (overrides is Map) overrides['dependency_overrides'],
    ]) {
      if (mapping != null && mapping is! Map) {
        throw FormatException('Plugin dependency overrides must be a mapping');
      }
      if (mapping is Map) replacements.addAll(mapping);
    }
    final names = <Object?>{
      if (dependencies is Map) ...dependencies.keys,
      ...replacements.keys,
    };
    for (final name in names) {
      final source =
          replacements.containsKey(name)
              ? replacements[name]
              : (dependencies as Map)[name];
      if (source is! Map || source['path'] is! String) continue;
      final declared = source['path'] as String;
      final dependency =
          Directory(declared).isAbsolute
              ? Directory(declared)
              : Directory.fromUri(Directory(canonical).uri.resolve(declared));
      await _scanSourcePackage(dependency, depth + 1);
    }
  }

  Future<void> _scanDartSources(Directory directory, int depth) async {
    if (depth > 32) {
      throw StateError('Plugin source directory depth exceeds 32');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (++_entries > identityMaxEntries) {
        throw StateError('Configuration scan exceeds  entries');
      }
      if (entry is Link) {
        throw StateError(
          'Plugin source links require verified resolution: ${entry.path}',
        );
      } else if (entry is Directory) {
        await _scanDartSources(entry, depth + 1);
      } else if (entry is File && entry.path.endsWith('.dart')) {
        if (++_sourceFiles > 512) {
          throw StateError('Plugin source scan exceeds 512 Dart files');
        }
        _read(entry, required: true);
      }
    }
  }

  File _resolveInclude(File owner, String target, File? context) {
    if (File(target).isAbsolute) return File(target);
    final uri = Uri.parse(target);
    if (uri.scheme == 'package') {
      final segments = uri.pathSegments;
      if (segments.length < 2 || segments.any((s) => s == '..' || s.isEmpty)) {
        throw FormatException('Invalid package options include: $target');
      }
      final config = context;
      if (config != null) {
        final bytes = _read(config, required: true)!;
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map ||
            value['configVersion'] != 2 ||
            value['packages'] is! List) {
          throw FormatException('Unsupported package config: ${config.path}');
        }
        final packages =
            (value['packages'] as List)
                .whereType<Map>()
                .where((p) => p['name'] == segments.first)
                .toList();
        if (packages.length != 1) {
          throw FormatException(
            'Unresolved or duplicate include package: $target',
          );
        }
        final package = packages.single;
        final root = config.uri.resolve(package['rootUri'] as String);
        if (root.scheme != 'file') {
          throw FormatException('Non-file package root');
        }
        final base = Directory.fromUri(
          root,
        ).uri.resolve(package['packageUri'] as String? ?? 'lib/');
        if (base.scheme != 'file') {
          throw FormatException('Non-file package root');
        }
        return File.fromUri(base.resolve(segments.skip(1).join('/')));
      }
      throw FormatException('No package config for include: $target');
    }
    if (uri.hasScheme && uri.scheme != 'file') {
      throw FormatException('Unsupported options include scheme: $target');
    }
    return File.fromUri(owner.uri.resolveUri(uri));
  }
}
