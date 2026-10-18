import 'dart:io';

import 'package:dart_analysis_daemon/src/environment_identity.dart';
import 'package:test/test.dart';

void main() {
  if (!Platform.isWindows) return;
  late Directory fixture;
  Future<File> write(String path, String text) async {
    final file = File('${fixture.path}/$path');
    await file.parent.create(recursive: true);
    return file.writeAsString(text);
  }

  Future<String> capture() =>
      EnvironmentIdentity().capture('${fixture.path}/root');
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('dana-plugin-identity-');
    await write(
      'root/analysis_options.yaml',
      'plugins:\n  sample:\n    path: ../plugin\n',
    );
    await write('plugin/pubspec.yaml', 'name: sample\n');
    await write('plugin/lib/plugin.dart', 'void f() {}');
  });
  tearDown(() => fixture.delete(recursive: true));

  test(
    'linked lib source roots reject rather than following a junction',
    () async {
      final source = Directory('${fixture.path}/plugin/lib');
      final moved = await source.rename('${fixture.path}/linked-sources');
      final junction = await Process.run('cmd.exe', [
        '/d',
        '/c',
        'mklink',
        '/J',
        source.path.replaceAll('/', '\\'),
        moved.path.replaceAll('/', '\\'),
      ]);
      expect(junction.exitCode, 0, reason: '${junction.stderr}');
      expect(
        FileSystemEntity.typeSync(source.path, followLinks: false),
        FileSystemEntityType.link,
      );
      await expectLater(capture(), throwsStateError);
    },
  );

  test('content changes with preserved modification time invalidate', () async {
    final source = File('${fixture.path}/plugin/lib/plugin.dart');
    final originalTime = await source.lastModified();
    final first = await capture();
    await source.writeAsString('void g() {}');
    await source.setLastModified(originalTime);
    expect(await source.lastModified(), originalTime);
    expect(await capture(), isNot(first));
  });

  test(
    'path plugin content, added sources and same-content replacement invalidate',
    () async {
      var previous = await capture();
      await write('plugin/lib/plugin.dart', 'void changed() {}');
      expect(await capture(), isNot(previous));
      previous = await capture();
      final extra = await write('plugin/lib/new.dart', 'int value = 1;');
      expect(await capture(), isNot(previous));
      previous = await capture();
      final replacement = await write('replacement.dart', 'int value = 1;');
      await extra.rename('${fixture.path}/old.dart');
      await replacement.rename(extra.path);
      expect(await capture(), isNot(previous));
      previous = await capture();
      await extra.delete();
      expect(await capture(), isNot(previous));
    },
  );

  test(
    'transitive path dependencies, cycles and overrides are observed',
    () async {
      await write(
        'plugin/pubspec.yaml',
        'name: sample\ndependencies:\n  middle:\n    path: ../middle\n',
      );
      await write(
        'middle/pubspec.yaml',
        'name: middle\ndependencies:\n  leaf:\n    path: ../leaf\n',
      );
      await write(
        'leaf/pubspec.yaml',
        'name: leaf\ndependencies:\n  sample:\n    path: ../plugin\n',
      );
      await write('leaf/lib/leaf.dart', 'int value = 1;');
      final first = await capture();
      await write('leaf/lib/leaf.dart', 'int value = 2;');
      expect(await capture(), isNot(first));
      await write(
        'plugin/pubspec_overrides.yaml',
        'dependency_overrides:\n  middle:\n    path: ../replacement\n',
      );
      await write('replacement/pubspec.yaml', 'name: middle\n');
      await write('replacement/lib/middle.dart', 'int value = 1;');
      final overridden = await capture();
      await write('leaf/lib/leaf.dart', 'int value = 3;');
      expect(await capture(), overridden);
      await write('replacement/lib/middle.dart', 'int value = 2;');
      expect(await capture(), isNot(overridden));
    },
  );

  test('entrypoint and local package resolution changes invalidate', () async {
    var previous = await capture();
    await write('plugin/bin/plugin.dart', 'void main() {}');
    expect(await capture(), isNot(previous));
    previous = await capture();
    await write(
      'plugin/.dart_tool/package_config.json',
      '{"configVersion":2,"packages":[]}',
    );
    expect(await capture(), isNot(previous));
    previous = await capture();
    await write('plugin/pubspec.lock', 'packages: {}');
    expect(await capture(), isNot(previous));
  });

  test('missing path dependencies and excessive source counts fail', () async {
    await write(
      'plugin/pubspec.yaml',
      'name: sample\ndependencies:\n  missing:\n    path: ../missing\n',
    );
    await expectLater(capture(), throwsA(isA<FileSystemException>()));
    await write('plugin/pubspec.yaml', 'name: sample\n');
    for (var i = 0; i < 512; i++) {
      await write('plugin/lib/file$i.dart', 'int v$i = $i;');
    }
    await expectLater(capture(), throwsStateError);
  });
}
