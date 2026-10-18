import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map;
    final method = request['method'];
    if (method == 'server.shutdown') {
      stdout.writeln(jsonEncode({'id': request['id'], 'result': {}}));
      await stdout.flush();
      return;
    }
    if (method ==
        (args.first == 'startup'
            ? 'analysis.setAnalysisRoots'
            : 'analysis.getErrors')) {
      if (args.last == 'malformed') {
        stdout.writeln('not valid json');
      } else {
        stdout.writeln(
          jsonEncode({
            'event': args.last,
            'params': {'message': 'injected plugin failure'},
          }),
        );
      }
      // Even a valid response after the error must not turn this into success.
      stdout.writeln(
        jsonEncode({
          'id': request['id'],
          'result': {'errors': []},
        }),
      );
    } else {
      stdout.writeln(jsonEncode({'id': request['id'], 'result': {}}));
    }
    await stdout.flush();
  }
}
