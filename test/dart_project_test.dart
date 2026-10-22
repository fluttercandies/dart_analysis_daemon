import 'dart:io';

import 'package:dart_analysis_daemon/src/dart_project.dart';
import 'package:test/test.dart';

void main() {
  test('recognizes Dart packages nested in a monorepo', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'dana-dart-workspace-',
    );
    try {
      final package = Directory('${workspace.path}/packages/example');
      await package.create(recursive: true);
      await File(
        '${package.path}/pubspec.yaml',
      ).writeAsString('name: example\n');
      expect(await isDartProjectRoot(workspace.path), isTrue);
    } finally {
      await workspace.delete(recursive: true);
    }
  });

  test('does not treat a vendored package as the workspace project', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'dana-non-dart-workspace-',
    );
    try {
      final vendored = Directory('${workspace.path}/vendor/example');
      await vendored.create(recursive: true);
      await File(
        '${vendored.path}/pubspec.yaml',
      ).writeAsString('name: vendored_example\n');
      expect(await isDartProjectRoot(workspace.path), isFalse);
    } finally {
      await workspace.delete(recursive: true);
    }
  });

  test('requires pubspec.yaml for a standalone Dart source tree', () async {
    final workspace = await Directory.systemTemp.createTemp('dana-loose-dart-');
    try {
      await File('${workspace.path}/main.dart').writeAsString('void main() {}');
      expect(await isDartProjectRoot(workspace.path), isFalse);
    } finally {
      await workspace.delete(recursive: true);
    }
  });

  test(
    'does not use a parent package configuration for the selected root',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'dana-parent-config-',
      );
      try {
        await Directory('${workspace.path}/.dart_tool').create();
        await File(
          '${workspace.path}/.dart_tool/package_config.json',
        ).writeAsString('{}');
        final child = Directory('${workspace.path}/project');
        await child.create();
        expect(await isDartProjectRoot(child.path), isFalse);
      } finally {
        await workspace.delete(recursive: true);
      }
    },
  );
}
