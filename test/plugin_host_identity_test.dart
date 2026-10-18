import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/managed_plugin_cache.dart';
import 'package:dart_analysis_daemon/src/plugin_host_identity.dart';
import 'package:test/test.dart';

String escaped(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll(' ', '\\ ');

Future<File> createHost(Directory state) async {
  final host = await Directory(
    '${state.path}/.plugin_manager/host/bin',
  ).create(recursive: true);
  await Directory('${host.parent.path}/.dart_tool').create();
  final package = await Directory(
    '${state.path}/resolved package/lib',
  ).create(recursive: true);
  await File(
    '${package.parent.path}/pubspec.yaml',
  ).writeAsString('name: resolved\n');
  final dependency = await File(
    '${package.path}/rule.dart',
  ).writeAsString('void a() {}');
  await File('${host.parent.path}/pubspec.yaml').writeAsString('name: host\n');
  await File(
    '${host.parent.path}/pubspec.lock',
  ).writeAsString('packages: {}\n');
  await File(
    '${host.parent.path}/.dart_tool/package_config.json',
  ).writeAsString(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {'name': 'resolved', 'rootUri': package.parent.uri.toString()},
      ],
    }),
  );
  await File('${host.path}/plugin.dart').writeAsString('void main() {}');
  await File('${host.path}/plugin.aot').writeAsBytes([1, 2, 3]);
  await File('${host.path}/depfile.txt').writeAsString(
    '${escaped('${host.path}/plugin.aot')}: ${escaped(dependency.path)}\n',
  );
  return dependency;
}

void main() {
  test('compiler dependency escaping and malformed depfiles', () {
    expect(
      PluginHostIdentity.parseDependencies(
        r'C:\\out.aot: C:\\path\ with\ space\\lib.dart C:\\other.dart',
      ),
      [r'C:\path with space\lib.dart', r'C:\other.dart'],
    );
    expect(
      () => PluginHostIdentity.parseDependencies('invalid'),
      throwsFormatException,
    );
    expect(
      () => PluginHostIdentity.parseDependencies('out: broken\\'),
      throwsFormatException,
    );
  });
  if (!Platform.isWindows) return;
  test(
    'actual host resolved source content and package metadata are observed',
    () async {
      final state = await Directory.systemTemp.createTemp('dana-host-observe-');
      try {
        expect(
          await PluginHostIdentity().capture(state.path),
          'no-generated-hosts',
        );
        final dependency = await createHost(state);
        final before = await PluginHostIdentity().capture(state.path);
        final time = await dependency.lastModified();
        await dependency.writeAsString('void b() {}');
        await dependency.setLastModified(time);
        final changed = await PluginHostIdentity().capture(state.path);
        expect(changed, isNot(before));
        await File(
          '${dependency.parent.parent.path}/pubspec.yaml',
        ).writeAsString('name: resolved\nversion: 0.0.2\n');
        expect(await PluginHostIdentity().capture(state.path), isNot(changed));
        await dependency.delete();
        await expectLater(
          PluginHostIdentity().capture(state.path),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await state.delete(recursive: true);
      }
    },
  );
  test(
    'changed actual execution inputs reject hot reuse and invalidate cached AOT',
    () async {
      final state = await Directory.systemTemp.createTemp('dana-host-cache-');
      final cache = ManagedPluginCache(state, 'sdk-cache-${'a' * 16}');
      try {
        final entry = await cache.prepare('root', 'v1');
        final source = await createHost(entry);
        await cache.recordExecution('root', 'v1');
        await cache.validateExecution('root', 'v1');
        await source.writeAsString('void changed() {}');
        await expectLater(
          cache.validateExecution('root', 'v1'),
          throwsStateError,
        );
        final fresh = await cache.prepare('root', 'v1');
        expect(fresh.path, entry.path);
        expect(await source.exists(), false);
      } finally {
        await state.delete(recursive: true);
      }
    },
  );
}
