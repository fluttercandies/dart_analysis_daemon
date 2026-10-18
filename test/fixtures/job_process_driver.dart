import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.first == 'leaf') {
    // Existence is the readiness signal: publish only after all PID bytes exist.
    final marker = await File('${args[1]}.tmp').writeAsString('$pid');
    await marker.rename(args[1]);
    Timer.periodic(const Duration(seconds: 1), (_) {});
    return;
  }
  final leafFile = File(args[1]);
  final child = await Process.start(Platform.resolvedExecutable, [
    File.fromUri(Platform.script).path,
    'leaf',
    leafFile.path,
  ]);
  child.stdout.drain<void>().ignore();
  child.stderr.drain<void>().ignore();
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await leafFile.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Leaf did not start');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  stdout.writeln(
    jsonEncode({
      'pid': pid,
      'childPid': child.pid,
      'leafPid': int.parse(await leafFile.readAsString()),
      'cwd': Directory.current.path,
      'arguments': args.skip(2).toList(),
    }),
  );
  await stdout.flush();
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (line == 'exit-root') exit(0);
    stdout.writeln(jsonEncode({'echo': line}));
    await stdout.flush();
  }
}
