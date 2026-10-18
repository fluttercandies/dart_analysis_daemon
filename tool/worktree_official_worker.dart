// Dedicated research child: control ready precedes official root configuration.
// Must be launched suspended inside the native owner's Job, never directly.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_analyzer_client.dart';
import 'worktree_disk_snapshot.dart';
import 'worktree_disk_observation.dart';
import 'worktree_overlay_transport.dart' show readOverlayFrame;

Future<void> main(List<String> args) async {
  if (args.length != 4 || args[0] != 'gated') {
    throw ArgumentError('Native gated launch required');
  }
  final token = args[2];
  final root = Directory(args[3]).resolveSymbolicLinksSync();
  final gateDirectory =
      Platform.environment['DANA_RESEARCH_OFFICIAL_GATES'] ?? '';
  late final ResearchAnalyzerClient client;
  client = ResearchAnalyzerClient(
    root,
    File('${args[1]}.protocol'),
    maxLogBytes: 8 * 1024 * 1024,
    maxRequestTimings: 128,
    afterBuiltinWrite:
        gateDirectory.isEmpty
            ? null
            : (id) async {
              final hold = File('$gateDirectory/official-query.hold');
              if (!hold.existsSync()) return;
              client.record({'faultGate': 'held', 'id': id});
              await File('$gateDirectory/official-query.reached').writeAsString(
                jsonEncode({
                  'id': id,
                  'worker': pid,
                  'protocolLog': client.log.path,
                }),
                flush: true,
              );
              final watch = Stopwatch()..start();
              while (hold.existsSync()) {
                if (watch.elapsed > const Duration(seconds: 6)) {
                  throw TimeoutException('Official research response gate');
                }
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
              client.record({'faultGate': 'released', 'id': id});
            },
  );
  stdout.writeln(jsonEncode({'event': 'gated', 'pid': pid}));
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  if (!await input.moveNext() || input.current != token) return;
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  var active = 0;
  var queued = 0;
  var closing = false;
  // A poisoned official stream cannot serve another lease. Exiting makes the
  // native owner reclaim descendants and report failure to the scheduler.
  client.failures.stream.listen((error) {
    if (!closing) {
      try {
        client.record({'officialStreamFailure': '$error'});
      } catch (_) {}
      exit(1);
    }
  });
  var highestId = 0;
  var operations = Future<void>.value();
  final done = Completer<void>();
  server.listen((socket) async {
    if (++active > 8 || closing) {
      active--;
      socket.destroy();
      return;
    }
    Object? id;
    try {
      final request = await readOverlayFrame(
        socket,
      ).timeout(const Duration(seconds: 5));
      id = request['id'];
      if (request['protocol'] != 1 ||
          request['token'] != token ||
          request['root'] != root ||
          id is! int ||
          id <= highestId) {
        throw StateError('Control authentication or identity mismatch');
      }
      final op = request['op'];
      if (![
            'status',
            'initialize',
            'builtin-errors',
            'observe-disk',
            'observe-overlay',
            'shutdown',
          ].contains(op) ||
          (request.containsKey('overlays') && op != 'observe-overlay') ||
          request.containsKey('content')) {
        throw StateError('Unsupported operation or overlays');
      }
      if (queued >= 8) throw StateError('Control queue full');
      highestId = id;
      queued++;
      final queueWatch = Stopwatch()..start();
      final result = Completer<Map>();
      operations = operations.then((_) async {
        final queuedMs = queueWatch.elapsedMilliseconds;
        final operationWatch = Stopwatch()..start();
        try {
          if (closing) throw StateError('Worker closing');
          Map response;
          switch (op) {
            case 'initialize':
              if (!client.rootConfigured) {
                try {
                  await client.start().timeout(const Duration(seconds: 150));
                } catch (error) {
                  try {
                    client.record({'initializationFailure': '$error'});
                  } catch (_) {}
                  // A timeout cannot cancel the underlying protocol. Discard
                  // the entire stream and let the owner confirm Job zero.
                  exit(1);
                }
              }
              response = {'rootConfigured': client.rootConfigured};
            case 'builtin-errors':
            case 'observe-disk':
            case 'observe-overlay':
              if (!client.rootConfigured || client.failure != null) {
                throw StateError('Root unavailable');
              }
              final target = ResearchDiskSnapshot.capture(
                root,
                request['file'] as String,
              );
              if (request['targetDigest'] != null &&
                  request['targetDigest'] != target.digest) {
                throw StateError('Target changed while queued');
              }
              final bundle =
                  op == 'observe-disk' || op == 'observe-overlay'
                      ? ResearchDiskBundle.capture(
                        root,
                        target.path,
                        request['dependencies'],
                      )
                      : null;
              if (bundle != null &&
                  request['inputDigests'] is Map &&
                  (bundle.digests.length !=
                          (request['inputDigests'] as Map).length ||
                      bundle.digests.entries.any(
                        (e) => request['inputDigests'][e.key] != e.value,
                      ))) {
                throw StateError('Declared disk inputs changed while queued');
              }
              final overlay =
                  op == 'observe-overlay'
                      ? ResearchRequestOverlay.capture(
                        bundle!,
                        request['overlays'],
                      )
                      : null;
              if (overlay != null &&
                  request['overlaySnapshotDigest'] != overlay.digest) {
                throw StateError('Overlay snapshot digest mismatch');
              }
              response = await (bundle == null
                      ? researchBuiltinDiskQuery(client, target)
                      : researchObserveDisk(
                        client,
                        bundle,
                        researchExpectedCodes(request['expectedCodes']),
                        overlay: overlay,
                      ))
                  .timeout(
                    const Duration(seconds: 45),
                    onTimeout: () {
                      exit(1);
                    },
                  );
            case 'shutdown':
              closing = true;
              await client.close();
              response = {'gracefulAnalyzerExit': true};
            default:
              response = {
                'rootConfigured': client.rootConfigured,
                'failure': client.failure?.toString(),
                'analyzerPid': client.process?.pid,
                'queued': queued,
              };
          }
          result.complete({
            'id': id,
            'ok': true,
            'controlReady': true,
            'diagnosticComplete': false,
            'queueMs': queuedMs,
            'executionMs': operationWatch.elapsedMilliseconds,
            'runtimeVersion': Platform.version,
            ...response,
          });
        } catch (error) {
          result.complete({'id': id, 'ok': false, 'error': '$error'});
        } finally {
          queued--;
        }
      });
      final encoded = jsonEncode(await result.future);
      if (utf8.encode(encoded).length > 512 * 1024) {
        throw StateError('Official response exceeds 512 KiB');
      }
      socket.writeln(encoded);
      await socket.flush().timeout(const Duration(seconds: 2));
    } catch (error) {
      try {
        socket.writeln(jsonEncode({'id': id, 'ok': false, 'error': '$error'}));
        await socket.flush().timeout(const Duration(seconds: 2));
      } catch (_) {}
    } finally {
      socket.destroy();
      active--;
      if (closing && queued == 0 && !done.isCompleted) done.complete();
    }
  });
  stdout.writeln(
    jsonEncode({
      'event': 'tree-ready',
      'pid': pid,
      'leaf': 0,
      'overlayPort': server.port,
      'runtimeVersion': Platform.version,
    }),
  );
  await done.future;
  await server.close();
  // Native owner still confirms whole Job zero after this process exits.
  exit(0);
}
