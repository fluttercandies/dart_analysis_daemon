import 'dart:io';

import 'package:dart_analysis_daemon/src/runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory fixture;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('dana-runtime-identity-');
  });

  tearDown(() => fixture.delete(recursive: true));

  test('a symlinked executable has the same identity as its target', () async {
    if (Platform.isWindows) {
      // Creating symlinks on Windows needs developer mode or elevation.
      markTestSkipped('symlinks need privileges on Windows');
      return;
    }
    final target = await File('${fixture.path}/dart').create();
    final link = await Link('${fixture.path}/sdk_link').create(fixture.path);

    expect(
      canonicalExecutablePath('${link.path}/dart'),
      canonicalExecutablePath(target.path),
    );
  });

  test('a missing path is kept as given, case folded', () {
    expect(canonicalExecutablePath('/No/Such/Dart'), '/no/such/dart');
  });
}
