import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/check_exit_code.dart';
import 'package:test/test.dart';

/// A check response shaped like Dana's: diagnostics grouped by file path.
Map<String, Object?> _response(Object severity, {bool ok = true}) => {
  'ok': ok,
  'source': 'session',
  'mode': 'full',
  'diagnostics': {
    '/project/lib/a.dart': [
      {'severity': severity, 'code': 'sample', 'message': 'm'},
    ],
  },
};

void main() {
  // (level, legacy encoding, LSP encoding)
  const levels = [
    ('error', 'ERROR', 1),
    ('warning', 'WARNING', 2),
    ('info', 'INFO', 3),
    ('hint', null, 4),
  ];

  int expected(
    String level, {
    required bool fatalWarnings,
    required bool fatalInfos,
  }) => switch (level) {
    'error' => 1,
    'warning' => fatalWarnings ? 1 : 0,
    'info' => fatalInfos ? 1 : 0,
    _ => 0,
  };

  group('checkExitCode matrix', () {
    for (final (level, legacy, lsp) in levels) {
      for (final (encoding, severity) in [
        if (legacy != null) ('legacy', legacy as Object),
        ('lsp', lsp as Object),
      ]) {
        for (final fatalWarnings in [true, false]) {
          for (final fatalInfos in [true, false]) {
            final want = expected(
              level,
              fatalWarnings: fatalWarnings,
              fatalInfos: fatalInfos,
            );
            test(
              'only $level ($encoding $severity), '
              'fatalWarnings=$fatalWarnings fatalInfos=$fatalInfos -> $want',
              () {
                expect(
                  checkExitCode(
                    _response(severity),
                    fatalWarnings: fatalWarnings,
                    fatalInfos: fatalInfos,
                  ),
                  want,
                );
              },
            );
          }
        }
      }
    }
  });

  test('defaults match dart analyze (warnings fatal, infos not)', () {
    expect(checkExitCode(_response('ERROR')), 1);
    expect(checkExitCode(_response(1)), 1);
    expect(checkExitCode(_response('WARNING')), 1);
    expect(checkExitCode(_response(2)), 1);
    expect(checkExitCode(_response('INFO')), 0);
    expect(checkExitCode(_response(3)), 0);
    expect(checkExitCode(_response(4)), 0);
  });

  test('clean response is 0', () {
    expect(checkExitCode({'ok': true, 'diagnostics': <String, Object?>{}}), 0);
    expect(checkExitCode({'ok': true}), 0);
    expect(checkExitCode(null), 0);
  });

  test('ok == false is always 1, regardless of diagnostics and flags', () {
    for (final fatalWarnings in [true, false]) {
      for (final fatalInfos in [true, false]) {
        expect(
          checkExitCode(
            {'ok': false, 'error': 'analysis server crashed'},
            fatalWarnings: fatalWarnings,
            fatalInfos: fatalInfos,
          ),
          1,
        );
        expect(
          checkExitCode(
            _response(4, ok: false),
            fatalWarnings: fatalWarnings,
            fatalInfos: fatalInfos,
          ),
          1,
        );
      }
    }
  });

  test('finds a fatal diagnostic among non-fatal ones in other files', () {
    final response = {
      'ok': true,
      'diagnostics': {
        '/project/lib/a.dart': [
          {'severity': 'INFO', 'code': 'i'},
          {'severity': 4, 'code': 'h'},
        ],
        '/project/lib/b.dart': [
          {'severity': 3, 'code': 'i'},
          {'severity': 2, 'code': 'w'},
        ],
      },
    };
    expect(checkExitCode(response), 1);
    expect(checkExitCode(response, fatalWarnings: false), 0);
    expect(checkExitCode(response, fatalWarnings: false, fatalInfos: true), 1);
  });

  test('finds diagnostics nested deeper inside the diagnostics map', () {
    final response = {
      'ok': true,
      'diagnostics': {
        '/project': {
          'files': {
            '/project/lib/a.dart': {
              'items': [
                {'severity': 'WARNING', 'code': 'w'},
              ],
            },
          },
        },
      },
    };
    expect(checkExitCode(response), 1);
    expect(checkExitCode(response, fatalWarnings: false), 0);
  });

  test('unknown severity values are not fatal', () {
    for (final severity in ['error', 'Warning', 'HINT', 0, 5, '1']) {
      expect(
        checkExitCode(
          _response(severity),
          fatalWarnings: true,
          fatalInfos: true,
        ),
        0,
        reason: 'severity $severity',
      );
    }
  });

  group('settled', () {
    test('settled == false is 1 even for a clean response', () {
      expect(checkExitCode({..._response('INFO'), 'settled': false}), 1);
      expect(
        checkExitCode({
          'ok': true,
          'settled': false,
          'diagnostics': <String, Object?>{},
        }, fatalWarnings: false),
        1,
      );
    });

    test('settled == true or absent follows the diagnostics', () {
      expect(checkExitCode({..._response('INFO'), 'settled': true}), 0);
      expect(checkExitCode(_response('INFO')), 0);
      expect(checkExitCode({..._response(2), 'settled': true}), 1);
    });
  });

  group('parseBridgeSettleTimeout', () {
    test('returns null when neither source is set', () {
      expect(parseBridgeSettleTimeout(null, null), isNull);
      expect(parseBridgeSettleTimeout(null, ''), isNull);
    });

    test('reads the flag, else the environment; the flag wins', () {
      expect(parseBridgeSettleTimeout('30', null), 30);
      expect(parseBridgeSettleTimeout(null, '45'), 45);
      expect(parseBridgeSettleTimeout('30', '45'), 30);
      expect(parseBridgeSettleTimeout('1', null), 1);
      expect(parseBridgeSettleTimeout('3600', null), 3600);
    });

    for (final bad in ['0', '-5', '3601', '1.5', ' 30', 'abc', '', '+30']) {
      test('rejects flag "$bad"', () {
        expect(
          () => parseBridgeSettleTimeout(bad, null),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('--bridge-settle-timeout'),
            ),
          ),
        );
      });
    }

    test('names the environment variable when it is the bad source', () {
      expect(
        () => parseBridgeSettleTimeout(null, 'soon'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS'),
          ),
        ),
      );
    });
  });

  group('dana check flags (via a fake IDE bridge)', () {
    late Directory project;
    late ServerSocket server;
    final packageRoot = Directory.current.path;
    final config = '$packageRoot/.dart_tool/package_config.json';

    setUp(() async {
      project = await Directory.systemTemp.createTemp('dana-exit-code-test-');
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              final request = jsonDecode(line) as Map;
              // A fullCheck that carries settleLimitSeconds is answered as an
              // unsettled, otherwise clean result echoing the value it got.
              final limit = request['settleLimitSeconds'];
              if (request['op'] == 'fullCheck' && limit != null) {
                socket.writeln(
                  jsonEncode({
                    ..._response('INFO'),
                    'settled': false,
                    'echoSettleLimit': limit,
                  }),
                );
                return;
              }
              final severity = switch (request['op']) {
                'fullCheck' => 2,
                _ => 'INFO',
              };
              socket.writeln(jsonEncode(_response(severity)));
            });
      });
      final endpoint = File(
        '${project.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}dana-ide-bridge.json',
      )..parent.createSync(recursive: true);
      await endpoint.writeAsString(
        jsonEncode({
          'protocol': 1,
          'transport': 'loopback',
          'root': project.resolveSymbolicLinksSync(),
          'address': '127.0.0.1',
          'port': server.port,
          'token': 'secret',
          'capabilities': {'fastCheck': true, 'fullCheck': true},
        }),
      );
    });

    tearDown(() async {
      await server.close();
      if (await project.exists()) await project.delete(recursive: true);
    });

    Future<ProcessResult> check(
      List<String> arguments, {
      Map<String, String>? environment,
    }) => Process.run(Platform.resolvedExecutable, [
      '--packages=$config',
      '$packageRoot/bin/dart_analysis_daemon.dart',
      'check',
      '--root',
      project.path,
      '--reuse-ide',
      'require',
      ...arguments,
    ], environment: environment).timeout(const Duration(seconds: 60));

    Map<String, Object?> lastJson(ProcessResult result) =>
        jsonDecode('${result.stdout}'.trim().split('\n').last)
            as Map<String, Object?>;

    test(
      '--bridge-settle-timeout reaches the bridge; unsettled exits 1',
      () async {
        final result = await check([
          '--mode',
          'full',
          '--bridge-settle-timeout',
          '7',
        ]);
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(lastJson(result)['echoSettleLimit'], 7);
        expect('${result.stderr}', contains('may be incomplete'));
      },
    );

    test(
      'DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS is used when the flag is absent',
      () async {
        final result = await check(
          ['--mode', 'full'],
          environment: {'DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS': '9'},
        );
        expect(lastJson(result)['echoSettleLimit'], 9);
      },
    );

    test('the flag wins over the environment variable', () async {
      final result = await check(
        ['--mode', 'full', '--bridge-settle-timeout', '11'],
        environment: {'DANA_BRIDGE_SETTLE_TIMEOUT_SECONDS': '9'},
      );
      expect(lastJson(result)['echoSettleLimit'], 11);
    });

    test(
      'an invalid --bridge-settle-timeout exits 64 before connecting',
      () async {
        final result = await check([
          '--mode',
          'full',
          '--bridge-settle-timeout',
          '0',
        ]);
        expect(result.exitCode, 64);
        expect('${result.stderr}', contains('--bridge-settle-timeout'));
        expect('${result.stdout}', isEmpty);
      },
    );

    // The fake bridge answers fullCheck with an LSP warning and fast check
    // with a legacy INFO, so each flag is observable through the exit code.
    final cases = <(List<String>, int)>[
      (['--mode', 'full'], 1),
      (['--mode', 'full', '--no-fatal-warnings'], 0),
      (['--mode', 'fast', '--files', 'lib/a.dart'], 0),
      (['--mode', 'fast', '--files', 'lib/a.dart', '--fatal-infos'], 1),
    ];
    for (final (arguments, want) in cases) {
      test('${arguments.join(' ')} -> $want', () async {
        final result = await check(arguments);
        expect(
          result.exitCode,
          want,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          (jsonDecode('${result.stdout}'.trim().split('\n').last) as Map)['ok'],
          true,
        );
      });
    }
  });
}
