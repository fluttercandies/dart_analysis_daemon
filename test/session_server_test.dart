import 'dart:io';

import 'package:dart_analysis_daemon/src/session_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory project;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('dana-session-test-');
  });

  tearDown(() async {
    if (await project.exists()) await project.delete(recursive: true);
  });

  test('stores the endpoint below the project .dart_tool directory', () {
    expect(
      endpointFile(project.path).path,
      endsWith(
        '${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}'
        'ai-analyzer-session.json',
      ),
    );
  });

  test('identity changes when analyzer configuration changes', () async {
    final before = await sessionIdentity(project.path);
    await File(
      '${project.path}${Platform.pathSeparator}pubspec.yaml',
    ).writeAsString('name: sample\n');
    final after = await sessionIdentity(project.path);

    final beforeConfig = (before['config'] as Map)['pubspec.yaml'];
    final afterConfig = (after['config'] as Map)['pubspec.yaml'];
    expect(beforeConfig, 'missing');
    expect(afterConfig, isNot(beforeConfig));
  });
}
