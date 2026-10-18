import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/environment_identity.dart';
import 'package:test/test.dart';

void main() {
  if (!Platform.isWindows) return;
  late Directory fixture;
  late Directory root;
  Future<File> write(String relative, String content) async {
    final file = File('${fixture.path}/$relative');
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  Future<String> identity() => EnvironmentIdentity().capture(root.path);
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('dana-environment-');
    root = await Directory('${fixture.path}/project').create();
  });
  tearDown(() => fixture.delete(recursive: true));

  test(
    'ancestor and nested options invalidate, ordinary source edits do not',
    () async {
      final first = await identity();
      await write('project/lib/main.dart', 'int a = 1;');
      // The new directory adds missing config observations; warm after creation.
      final withDirectory = await identity();
      await write('project/lib/main.dart', 'int a = 2;');
      expect(await identity(), withDirectory);
      await write('analysis_options.yaml', 'analyzer: {}');
      final parent = await identity();
      expect(parent, isNot(first));
      expect(parent, isNot(withDirectory));
      await write(
        'project/lib/analysis_options.yaml',
        'linter: {rules: [avoid_print]}',
      );
      expect(await identity(), isNot(parent));
    },
  );

  test(
    'relative/list/package includes use contents and correct package context',
    () async {
      await write(
        'project/analysis_options.yaml',
        'include: [../shared.yaml, "package:rules/base.yaml"]',
      );
      final shared = await write('shared.yaml', 'analyzer: {}');
      await write('rules/lib/base.yaml', 'linter: {rules: [avoid_print]}');
      await write(
        'project/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'rules', 'rootUri': '../../rules/', 'packageUri': 'lib/'},
          ],
        }),
      );
      final first = await identity();
      await shared.writeAsString('analyzer: {errors: {unused_import: ignore}}');
      expect(await identity(), isNot(first));
      final second = await identity();
      await write(
        'rules/lib/base.yaml',
        'linter: {rules: [prefer_final_locals]}',
      );
      expect(await identity(), isNot(second));
    },
  );

  test('nested packages resolve their own package includes', () async {
    await write(
      'project/lib/analysis_options.yaml',
      'include: package:rules/base.yaml',
    );
    await write('local_rules/lib/base.yaml', 'analyzer: {}');
    await write(
      'project/lib/.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'rules',
            'rootUri': '../../../local_rules/',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
    final first = await identity();
    await write('local_rules/lib/base.yaml', 'linter: {}');
    expect(await identity(), isNot(first));
  });

  test('same-content config replacement changes file identity', () async {
    final options = await write(
      'project/analysis_options.yaml',
      'analyzer: {}',
    );
    final replacement = await write('replacement.yaml', 'analyzer: {}');
    final first = await identity();
    await options.rename('${fixture.path}/old.yaml');
    await replacement.rename(options.path);
    expect(await identity(), isNot(first));
  });

  test('external package includes retain requesting package context', () async {
    await write(
      'project/analysis_options.yaml',
      'include: package:first/base.yaml',
    );
    await write('first/lib/base.yaml', 'include: package:second/base.yaml');
    final second = await write('second/lib/base.yaml', 'analyzer: {}');
    await write(
      'project/.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'first', 'rootUri': '../../first', 'packageUri': 'lib/'},
          {'name': 'second', 'rootUri': '../../second/', 'packageUri': 'lib/'},
        ],
      }),
    );
    final first = await identity();
    await second.writeAsString('linter: {}');
    expect(await identity(), isNot(first));
  });

  test(
    'include cycles, missing files, invalid schemes and malformed YAML reject',
    () async {
      await write('project/analysis_options.yaml', 'include: ../shared.yaml');
      await write('shared.yaml', 'include: project/analysis_options.yaml');
      await expectLater(identity(), throwsFormatException);
      await write('project/analysis_options.yaml', 'include: missing.yaml');
      await expectLater(identity(), throwsA(isA<FileSystemException>()));
      await write(
        'project/analysis_options.yaml',
        'include: https://example.com/x.yaml',
      );
      await expectLater(identity(), throwsFormatException);
      await write('project/analysis_options.yaml', 'include: [');
      await expectLater(identity(), throwsA(isA<Exception>()));
    },
  );

  test('per-file size and include-depth limits fail explicitly', () async {
    await write('project/analysis_options.yaml', 'x' * (4 * 1024 * 1024 + 1));
    await expectLater(identity(), throwsStateError);
    for (var i = 0; i < 34; i++) {
      await write('project/options$i.yaml', 'include: options${i + 1}.yaml');
    }
    await write('project/analysis_options.yaml', 'include: options0.yaml');
    await expectLater(identity(), throwsStateError);
  });

  test(
    'generated directory contents do not change bounded configuration identity',
    () async {
      await write(
        'project/build/analysis_options.yaml',
        'include: missing.yaml',
      );
      await write(
        'project/.dart_tool/tool/analysis_options.yaml',
        'include: missing.yaml',
      );
      final first = await identity();
      await write(
        'project/build/analysis_options.yaml',
        'include: still_missing.yaml',
      );
      expect(await identity(), first);
    },
  );

  test(
    'duplicate and missing include packages reject instead of guessing',
    () async {
      await write(
        'project/analysis_options.yaml',
        'include: package:rules/base.yaml',
      );
      await write('rules/lib/base.yaml', 'analyzer: {}');
      final config = await write(
        'project/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'rules', 'rootUri': '../../rules/', 'packageUri': 'lib/'},
            {'name': 'rules', 'rootUri': '../../rules/', 'packageUri': 'lib/'},
          ],
        }),
      );
      await expectLater(identity(), throwsFormatException);
      await config.writeAsString(
        jsonEncode({'configVersion': 2, 'packages': []}),
      );
      await expectLater(identity(), throwsFormatException);
    },
  );
}
