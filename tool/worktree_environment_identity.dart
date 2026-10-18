// Research-only: use versions already present in this package's test graph.
// No product dependencies or package manifest are changed.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';
import 'worktree_root_identity.dart';

class ResearchEnvironment {
  ResearchEnvironment(
    this.rootKey,
    this.root,
    this.runtime,
    this.version,
    this.files,
    this.key,
  );
  final String rootKey, root, runtime, version, key;
  final Map<String, String> files;
}

class ResearchEnvironmentCollector {
  final _versions = <String, String>{};
  Future<ResearchEnvironment> capture(String root, String executable) async {
    final directory = researchRootIdentity(root);
    final runtime = File(executable).resolveSymbolicLinksSync();
    if (!runtime.toLowerCase().endsWith('dart.exe')) {
      throw ArgumentError('Select an actual dart.exe');
    }
    final bin = File(runtime).parent;
    final runtimeFiles = [
      File(runtime),
      File('${bin.path}/dartvm.exe'),
      File('${bin.parent.path}/version'),
      File('${bin.path}/snapshots/analysis_server.dart.snapshot'),
    ];
    final runtimeMetadata = <String, String>{};
    for (final file in runtimeFiles) {
      if (!file.existsSync()) {
        runtimeMetadata[file.path] = 'missing';
        continue;
      }
      final stat = file.statSync();
      runtimeMetadata[file.resolveSymbolicLinksSync()] =
          '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    }
    final runtimeStamp = jsonEncode(runtimeMetadata);
    var version = _versions[runtimeStamp];
    if (version == null) {
      final process = await Process.start(runtime, ['--version']);
      final output = process.stdout.transform(utf8.decoder).join();
      final error = process.stderr.transform(utf8.decoder).join();
      try {
        final code = await process.exitCode.timeout(const Duration(seconds: 5));
        version = '${await output}${await error}'.trim();
        if (code != 0 || !version.startsWith('Dart SDK version:')) {
          throw StateError('Selected runtime failed version probe');
        }
        if (_versions.length >= 8) _versions.clear();
        _versions[runtimeStamp] = version;
      } catch (_) {
        process.kill();
        await process.exitCode;
        rethrow;
      }
    }
    final files = <String, String>{};
    var total = 0;
    List<int>? read(File file, {bool required = false}) {
      if (files.length >= 1024) throw StateError('Too many environment inputs');
      final path = file.absolute.path;
      if (!file.existsSync()) {
        if (required) {
          throw FileSystemException('Missing environment input', path);
        }
        files[path] = 'missing';
        return null;
      }
      final handle = file.openSync();
      late List<int> bytes;
      try {
        bytes = handle.readSync(4 * 1024 * 1024 + 1);
      } finally {
        handle.closeSync();
      }
      total += bytes.length;
      if (bytes.length > 4 * 1024 * 1024 || total > 32 * 1024 * 1024) {
        throw StateError('Environment input budget exceeded');
      }
      files[file.resolveSymbolicLinksSync()] = sha256.convert(bytes).toString();
      return bytes;
    }

    final rootDirectory = Directory(directory.path);
    final packages = <String, Uri>{};
    final packageConfig = File(
      '${rootDirectory.path}/.dart_tool/package_config.json',
    );
    final packageBytes = read(packageConfig);
    if (packageBytes != null) {
      final config = jsonDecode(utf8.decode(packageBytes)) as Map;
      if (config['configVersion'] != 2 || config['packages'] is! List) {
        throw FormatException('Unsupported package config');
      }
      for (final item in config['packages'] as List) {
        final name = item['name'] as String;
        if (packages.containsKey(name)) {
          throw FormatException('Duplicate package: $name');
        }
        final base = packageConfig.uri.resolve(item['rootUri'] as String);
        if (base.scheme != 'file') {
          throw FormatException('Only file package roots supported');
        }
        final packageUri = item['packageUri'] as String? ?? 'lib/';
        packages[name] = Uri.directory(
          Directory.fromUri(base).path,
        ).resolve(packageUri);
      }
    }
    for (final name in [
      'pubspec.yaml',
      'pubspec.lock',
      '.dart_tool/extension_discovery/vs_code.json',
    ]) {
      read(File('${rootDirectory.path}/$name'));
    }
    final activeOptions = <String>{};
    final visitedOptions = <String>{};
    final scannedPlugins = <String>{};
    void plugin(Directory source) {
      final canonical = source.resolveSymbolicLinksSync();
      if (!scannedPlugins.add(canonical)) return;
      read(File('$canonical/pubspec.yaml'), required: true);
      read(File('$canonical/pubspec.lock'));
      read(File('$canonical/.dart_tool/package_config.json'));
      final lib = Directory('$canonical/lib');
      if (!lib.existsSync()) {
        throw FileSystemException('Missing plugin lib', canonical);
      }
      final sourceFiles =
          lib
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (sourceFiles.length > 512) {
        throw StateError('Plugin source scan exceeds 512 Dart files');
      }
      for (final file in sourceFiles) {
        read(file, required: true);
      }
    }

    File resolveInclude(File owner, String target) {
      if (File(target).isAbsolute) return File(target);
      final uri = Uri.parse(target);
      if (uri.scheme == 'package') {
        final segments = uri.pathSegments;
        final base = packages[segments.first];
        if (base == null) {
          throw FormatException('Unresolved options package: $target');
        }
        return File.fromUri(base.resolve(segments.skip(1).join('/')));
      }
      if (uri.hasScheme && uri.scheme != 'file') {
        throw FormatException('Unsupported options include: $target');
      }
      return File.fromUri(owner.uri.resolveUri(uri));
    }

    void options(File file, {bool required = false, int depth = 0}) {
      if (depth > 32) throw StateError('Options include depth exceeded');
      final path =
          file.existsSync()
              ? file.resolveSymbolicLinksSync()
              : file.absolute.path;
      if (activeOptions.contains(path)) {
        throw FormatException('Options include cycle');
      }
      if (!visitedOptions.add(path)) return;
      final bytes = read(file, required: required);
      if (bytes == null) return;
      final yaml = loadYaml(utf8.decode(bytes));
      if (yaml == null) return;
      if (yaml is! Map) throw FormatException('Options must be a mapping');
      activeOptions.add(path);
      final include = yaml['include'];
      if (include != null) {
        final targets =
            include is String
                ? [include]
                : include is List
                ? include
                : throw FormatException('Invalid include');
        for (final target in targets) {
          if (target is! String) {
            throw FormatException('Include must name a file');
          }
          options(
            resolveInclude(file, target),
            required: true,
            depth: depth + 1,
          );
        }
      }
      final plugins = yaml['plugins'];
      if (plugins != null) {
        if (plugins is! Map) {
          throw FormatException('Research supports plugins mapping only');
        }
        for (final entry in plugins.entries) {
          final spec = entry.value;
          if (spec is Map && spec['path'] is String) {
            final pluginPath = spec['path'] as String;
            plugin(
              Directory(pluginPath).isAbsolute
                  ? Directory(pluginPath)
                  : Directory.fromUri(file.parent.uri.resolve(pluginPath)),
            );
          } else {
            // Hosted/git resolution cannot be inferred from a name/version alone.
            // Explicitly fail rather than claiming unobserved source is covered.
            throw FormatException(
              'Research requires resolved path plugin sources: ${entry.key}',
            );
          }
        }
      }
      if ((yaml['analyzer'] is Map) &&
          (yaml['analyzer'] as Map)['plugins'] != null) {
        throw FormatException(
          'Legacy analyzer plugins require a separate resolver',
        );
      }
      activeOptions.remove(path);
    }

    options(File('${rootDirectory.path}/analysis_options.yaml'));
    final sorted = Map.fromEntries(
      files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final key =
        sha256
            .convert(
              utf8.encode(
                jsonEncode({
                  'root': directory.key,
                  'runtime': runtimeMetadata,
                  'version': version,
                  'files': sorted,
                }),
              ),
            )
            .toString();
    return ResearchEnvironment(
      directory.key,
      directory.path,
      runtime,
      version,
      Map.unmodifiable(sorted),
      key,
    );
  }
}
