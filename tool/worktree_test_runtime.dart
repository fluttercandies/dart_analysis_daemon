import 'dart:io';

/// Research checks select additional SDKs explicitly, never from a developer's
/// machine-specific installation directory.
String requireTestRuntime(String variable) {
  final value = Platform.environment[variable];
  if (value == null || value.isEmpty || !File(value).existsSync()) {
    throw ArgumentError('Set $variable to an existing Dart executable.');
  }
  return File(value).absolute.path;
}

Future<String> testRuntimeVersion(String executable) async {
  final result = await Process.run(executable, ['--version']);
  final match = RegExp(
    r'Dart SDK version: (\S+)',
  ).firstMatch('${result.stdout}${result.stderr}');
  if (result.exitCode != 0 || match == null) {
    throw StateError('Could not read the selected test SDK version.');
  }
  return match.group(1)!;
}
