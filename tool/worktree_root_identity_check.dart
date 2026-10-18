import 'dart:convert';
import 'dart:io';
import 'worktree_root_identity.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp('dana-root-identity-');
  final root = await Directory('${fixture.path}/Original').create();
  final child = await Directory('${root.path}/child').create();
  final other = await Directory('${fixture.path}/Other').create();
  final file = await File('${fixture.path}/file').writeAsString('fixture');
  final first = researchRootIdentity(root.path);
  for (final alias in [
    root.path.toUpperCase(),
    '${child.path}/..',
    '${root.path}/',
    root.path.replaceAll('\\', '/'),
  ]) {
    check(
      researchRootIdentity(alias).key == first.key,
      'Alias did not identify the same root: $alias',
    );
  }
  check(
    researchRootIdentity(other.path).key != first.key,
    'Distinct directories merged',
  );
  for (final invalid in [
    'relative',
    file.path,
    '${fixture.path}/missing',
    'C:relative',
    '${root.path}\u0000tail',
  ]) {
    var rejected = false;
    try {
      researchRootIdentity(invalid);
    } catch (_) {
      rejected = true;
    }
    check(rejected, 'Invalid root accepted: $invalid');
  }
  // Junction creation needs no symlink privilege; create it only in this fixture.
  final shell =
      '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  final junction = '${fixture.path}/alias';
  final result = await Process.run(
    shell,
    [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'$ErrorActionPreference="Stop"; $null=New-Item -ItemType Junction -Path $env:DANA_ID_ALIAS -Target $env:DANA_ID_ROOT',
    ],
    environment: {'DANA_ID_ALIAS': junction, 'DANA_ID_ROOT': root.path},
  );
  check(result.exitCode == 0, 'Junction setup failed: ${result.stderr}');
  check(
    researchRootIdentity(junction).key == first.key,
    'Junction alias created a second identity',
  );
  final report = {
    'aliases': 5,
    'distinctDirectories': true,
    'invalidPathsRejected': 5,
    'fixture': fixture.path,
    'allPassed': true,
  };
  await File('${fixture.path}/results.json').writeAsString(jsonEncode(report));
  print(jsonEncode(report));
}
