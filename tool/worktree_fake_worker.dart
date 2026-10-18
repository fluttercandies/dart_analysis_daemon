// Dedicated lightweight child for research process tests. Never runs analyzer.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final mode = args[0];
  final token = args[1];
  final generation = int.parse(args[2]);
  if (mode == 'exit-before-ready') exit(23);
  if (mode == 'slow-ready') {
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  stdout.writeln(
    jsonEncode({
      'event': 'ready',
      'token': mode == 'bad-token' ? 'wrong' : token,
      'generation': mode == 'bad-generation' ? generation + 1 : generation,
      'pid': pid,
    }),
  );
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final command = jsonDecode(line) as Map;
    if (command['token'] != token || command['generation'] != generation) {
      continue;
    }
    if (command['op'] == 'crash') exit(31);
    if (command['op'] == 'shutdown' && mode != 'ignore-shutdown') return;
  }
}
