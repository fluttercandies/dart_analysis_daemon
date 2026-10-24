import 'package:dart_analysis_daemon/dart_analysis_daemon.dart';
import 'package:test/test.dart';

void main() {
  test('exposes the package version', () {
    expect(packageVersion, '0.2.0');
  });
}
