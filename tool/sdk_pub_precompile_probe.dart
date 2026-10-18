// Isolate SDK/Pub compilation from dana: no imports, dependencies, or FFI.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'dana-sdk-pub-probe-',
  );
  final package = await Directory(
    '${directory.path}/package/bin',
  ).create(recursive: true);
  await File('${package.parent.path}/pubspec.yaml').writeAsString(
    'name: dana_sdk_probe\nversion: 0.0.1\n'
    'environment:\n  sdk: ^3.7.0\n',
  );
  await File(
    '${package.path}/dana_sdk_probe.dart',
  ).writeAsString("void main() { print('probe-ok'); }\n");
  final records = <Map<String, Object?>>[];
  final environment = {'PUB_CACHE': '${directory.path}/cache'};
  Future<bool> run(String label, List<String> args) async {
    final clock = Stopwatch()..start();
    final process = await Process.start(
      Platform.resolvedExecutable,
      args,
      workingDirectory: directory.path,
      environment: environment,
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    int code;
    try {
      code = await process.exitCode.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      timedOut = true;
      // Exact tree launched above, never other Dart/IDE processes.
      if (Platform.isWindows) {
        await Process.run('taskkill', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 5));
      } else {
        process.kill();
      }
      code = await process.exitCode.timeout(const Duration(seconds: 5));
    }
    records.add({
      'label': label,
      'arguments': args,
      'exitCode': code,
      'timedOut': timedOut,
      'milliseconds': clock.elapsedMilliseconds,
      'stdout': await output,
      'stderr': await errors,
    });
    stdout.writeln('$label: code=$code timedOut=$timedOut');
    return code == 0 && !timedOut;
  }

  try {
    if (await run('activate', [
      'pub',
      'global',
      'activate',
      '--source',
      'path',
      package.parent.path,
    ])) {
      await run('pub-global-run', [
        'pub',
        '--verbose',
        'global',
        'run',
        'dana_sdk_probe',
      ]);
      await run('direct-source', ['${package.path}/dana_sdk_probe.dart']);
    }
  } finally {
    final result = File('${directory.path}/results.json');
    await result.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'sdk': Platform.version, 'records': records}),
    );
    stdout.writeln('results: ${result.path}');
  }
}
