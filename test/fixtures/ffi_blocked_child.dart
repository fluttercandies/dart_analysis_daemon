import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  Timer.periodic(const Duration(seconds: 1), (_) {});
  if (args.contains('--emit')) {
    stdout.add(
      Uint8List.fromList(List.generate(4 * 1024 * 1024, (i) => i % 251)),
    );
    await stdout.flush();
  }
}
