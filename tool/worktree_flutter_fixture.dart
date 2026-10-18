// Prepare detached worktrees in a temporary clone. Original checkout untouched.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Supply clean aopd repository path');
  }
  final source = Directory(args.single).resolveSymbolicLinksSync();
  Future<String> git(List<String> arguments, String cwd) async {
    final result = await Process.run('git', arguments, workingDirectory: cwd);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
    return '${result.stdout}'.trim();
  }

  if ((await git(['status', '--porcelain'], source)).isNotEmpty) {
    throw StateError(
      'Source must be clean; never copy uncommitted user changes',
    );
  }
  final commit = await git(['rev-parse', 'HEAD'], source);
  final fixture = await Directory.systemTemp.createTemp(
    'dana-flutter-worktrees-',
  );
  final clone = '${fixture.path}/repository';
  await git([
    'clone',
    '--shared',
    '--no-checkout',
    source,
    clone,
  ], fixture.path);
  final plugin = Directory.fromUri(
    Platform.script.resolve(
      '../../benchmarks/minimal-plugin/plugin-dynamic-probe',
    ),
  ).resolveSymbolicLinksSync().replaceAll('\\', '/');
  final configFile = File('$source/example/.dart_tool/package_config.json');
  final config = jsonDecode(await configFile.readAsString()) as Map;
  final flutterRoot = Directory.fromUri(
    Uri.parse(config['flutterRoot'] as String),
  );
  final runtime = '${flutterRoot.path}/bin/cache/dart-sdk/bin/dart.exe';
  if (!File(runtime).existsSync()) throw StateError('Actual runtime absent');
  final roots = <Map>[];
  for (var i = 0; i < 3; i++) {
    final root = '${fixture.path}/root$i';
    await git(['worktree', 'add', '--detach', root, commit], clone);
    final project = '$root/example';
    for (final name in [
      'pubspec.lock',
      '.dart_tool/package_config.json',
      '.dart_tool/package_graph.json',
    ]) {
      final destination = File('$project/$name');
      await destination.parent.create(recursive: true);
      await File('$source/example/$name').copy(destination.path);
    }
    final clonedConfig = File('$project/.dart_tool/package_config.json');
    final missing = <String>[];
    for (final package in config['packages'] as List) {
      final uri = clonedConfig.uri.resolve(package['rootUri'] as String);
      if (uri.scheme != 'file' || !Directory.fromUri(uri).existsSync()) {
        missing.add('${package['name']}: $uri');
      }
    }
    if (missing.isNotEmpty) throw StateError('Missing package roots: $missing');
    final options = File('$project/analysis_options.yaml');
    await options.writeAsString(
      '${await options.readAsString()}\nplugins:\n  minimal_plugin:\n    path: $plugin\n',
    );
    // Explicit benchmark files only, added to temporary detached worktrees.
    // All real application source and original lint configuration are retained.
    await File('$project/lib/probe.dart').writeAsString(
      "import 'dependency.dart';\nclass SyntaxProbeDisk {}\nclass SemanticProbeDisk extends SelectedBase {}\nint value = missingDisk;\n",
    );
    await File('$project/lib/dependency.dart').writeAsString(
      'class ForbiddenBase {}\nclass AllowedBase {}\ntypedef SelectedBase = ForbiddenBase;\n',
    );
    roots.add({
      'root': Directory(project).resolveSymbolicLinksSync(),
      'commit': await git(['rev-parse', 'HEAD'], root),
      'dartFiles':
          Directory('$project/lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .length,
      'workingChanges': await git(['status', '--porcelain'], root),
    });
  }
  final report = {
    'fixture': fixture.path,
    'source': source,
    'commit': commit,
    'runtime': runtime,
    'plugin': plugin,
    'roots': roots,
    'originalStatus': await git(['status', '--porcelain'], source),
    'scope':
        'detached worktrees in temporary shared clone; original checkout unchanged; no pub get',
  };
  await File(
    '${fixture.path}/fixture.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  print(const JsonEncoder.withIndent('  ').convert(report));
}
