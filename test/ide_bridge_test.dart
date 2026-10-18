import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/dart_analysis_daemon.dart';
import 'package:test/test.dart';

void main() {
  late Directory project;
  ServerSocket? server;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('dana-bridge-test-');
  });

  tearDown(() async {
    await server?.close();
    if (await project.exists()) await project.delete(recursive: true);
  });

  test('discovers only a matching loopback endpoint', () async {
    final endpointFile = File(
      '${project.path}${Platform.pathSeparator}.dart_tool'
      '${Platform.pathSeparator}dana-ide-bridge.json',
    )..parent.createSync(recursive: true);
    await endpointFile.writeAsString(
      jsonEncode({
        'protocol': 1,
        'transport': 'loopback',
        'root': project.resolveSymbolicLinksSync(),
        'address': '127.0.0.1',
        'port': 1234,
        'token': 'secret',
        'capabilities': {'fastCheck': true, 'fullCheck': false},
      }),
    );

    final endpoint = await IdeBridgeEndpoint.discover(project.path);
    expect(endpoint, isNotNull);
    expect(endpoint!.supports('fastCheck'), isTrue);
    expect(endpoint.supports('fullCheck'), isFalse);

    await endpointFile.writeAsString(
      jsonEncode({
        'protocol': 1,
        'transport': 'loopback',
        'root': project.resolveSymbolicLinksSync(),
        'address': '0.0.0.0',
        'port': 1234,
        'token': 'secret',
      }),
    );
    expect(await IdeBridgeEndpoint.discover(project.path), isNull);
  });

  test('sends authenticated JSON-lines requests', () async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((socket) {
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final request = jsonDecode(line) as Map;
            socket.writeln(
              jsonEncode({
                'ok': true,
                'tokenSeen': request['token'] == 'secret',
                'op': request['op'],
              }),
            );
          });
    });
    final endpoint = IdeBridgeEndpoint(
      root: project.path,
      address: InternetAddress.loopbackIPv4.address,
      port: server!.port,
      token: 'secret',
      capabilities: {'fastCheck': true},
    );
    final client = await IdeBridgeClient.connect(endpoint);
    addTearDown(client.close);

    final response = await client.check(['lib/main.dart']);
    expect(response['ok'], isTrue);
    expect(response['tokenSeen'], isTrue);
    expect(response['op'], 'check');
  });
}
