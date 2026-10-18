import 'dart:io';

import 'package:dart_analysis_daemon/src/windows_disk_snapshot.dart';
import 'package:test/test.dart';

void main() {
  if (!Platform.isWindows) return;
  test('snapshot detects edits and same-content file replacement', () async {
    final directory = await Directory.systemTemp.createTemp(
      'dana-disk-version-',
    );
    try {
      final file = await File(
        '${directory.path}/target.dart',
      ).writeAsString('one');
      final original = WindowsDiskSnapshot.read(file.path);
      expect(original.same(WindowsDiskSnapshot.read(file.path)), true);
      await file.writeAsString('two');
      expect(original.same(WindowsDiskSnapshot.read(file.path)), false);
      final replacement = await File(
        '${directory.path}/replacement.dart',
      ).writeAsString('one');
      // Preserve the old file so its ID cannot be reused for the replacement.
      await file.rename('${directory.path}/old.dart');
      await replacement.rename(file.path);
      final replaced = WindowsDiskSnapshot.read(file.path);
      expect(replaced.bytes, original.bytes);
      expect(replaced.identity, isNot(original.identity));
      expect(original.same(replaced), false);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'snapshot rejects oversized and missing targets and releases handles',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dana-disk-limits-',
      );
      try {
        final file = await File(
          '${directory.path}/target.dart',
        ).writeAsString('12345');
        expect(
          () => WindowsDiskSnapshot.read(file.path, limit: 4),
          throwsStateError,
        );
        expect(
          () => WindowsDiskSnapshot.read('${directory.path}/missing.dart'),
          throwsA(isA<FileSystemException>()),
        );
        await file.delete();
        expect(await file.exists(), false);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
