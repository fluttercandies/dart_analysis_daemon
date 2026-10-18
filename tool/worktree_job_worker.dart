// Research-only process tree, deliberately including an uncooperative leaf.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_overlay_transport.dart';

Future<void> main(List<String> args) async {
  final mode = args[0];
  final log = File(args[1]);
  final token = args[2];
  void record(String event) => log.writeAsStringSync(
    '${jsonEncode({'event': event, 'pid': pid, 'token': token})}\n',
    mode: FileMode.append,
  );
  record(mode);
  if (mode == 'leaf') {
    stdout.writeln(jsonEncode({'event': 'leaf-ready', 'pid': pid}));
    Timer.periodic(const Duration(seconds: 1), (_) {});
    await Completer<void>().future;
    return;
  }
  stdout.writeln(jsonEncode({'event': 'gated', 'pid': pid}));
  // The owner assigns this process to its Job before permitting descendants.
  final commands = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  if (!await commands.moveNext() || commands.current != token) return;
  final child = await Process.start(Platform.resolvedExecutable, [
    File.fromUri(Platform.script).path,
    'leaf',
    log.path,
    token,
  ]);
  child.stderr.drain<void>();
  final ready =
      await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
  final overlayServer = await startOverlayWorker(token);
  stdout.writeln(
    jsonEncode({
      'event': 'tree-ready',
      'pid': pid,
      'leaf': jsonDecode(ready)['pid'],
      'runtimeVersion': Platform.version,
      'overlayPort': overlayServer.port,
    }),
  );
  while (await commands.moveNext()) {
    if (commands.current == 'crash:$token') exit(41);
  }
  record('owner-eof');
  // The leaf intentionally ignores this loss. Only Job ownership contains it.
}
