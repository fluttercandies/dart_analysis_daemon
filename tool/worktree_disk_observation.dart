// Experimental merged diagnostic observation, never a universal plugin barrier.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_analyzer_client.dart';
import 'worktree_disk_snapshot.dart';
import 'worktree_overlay_transport.dart' show overlayDigest;

// Full snapshot scoped to one serialized official request. Existing files only;
// no retained owner state or promise that a revision is analyzed by a plugin.
class ResearchRequestOverlay {
  ResearchRequestOverlay._(this.overrides, this.effectiveFiles);
  final Map<String, String> overrides, effectiveFiles;
  String get digest => overlayDigest(overrides);
  String get effectiveDigest => overlayDigest(effectiveFiles);
  static ResearchRequestOverlay capture(
    ResearchDiskBundle bundle,
    Object? value,
  ) {
    if (value is! Map || value.length > bundle.inputs.length) {
      throw ArgumentError('Supply an overlay map of declared existing inputs');
    }
    final permitted = {
      for (final input in bundle.inputs) input.path.toLowerCase(): input.path,
    };
    final overrides = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          (entry.value as String).length > 512 * 1024) {
        throw ArgumentError('Invalid request overlay');
      }
      final key =
          permitted[File(
            entry.key as String,
          ).resolveSymbolicLinksSync().toLowerCase()];
      if (key == null || overrides.containsKey(key)) {
        throw ArgumentError('Overlay path undeclared or duplicated');
      }
      final text = entry.value as String;
      final encoded = utf8.encode(text);
      if (encoded.length > 512 * 1024 || utf8.decode(encoded) != text) {
        throw ArgumentError(
          'Overlay exceeds 512 KiB or contains invalid Unicode',
        );
      }
      overrides[key] = text;
    }
    final effective = {
      for (final input in bundle.inputs)
        input.path: overrides[input.path] ?? input.content,
    };
    if (effective.values.fold<int>(
          0,
          (n, text) => n + utf8.encode(text).length,
        ) >
        1024 * 1024) {
      throw ArgumentError('Effective request snapshot exceeds 1 MiB');
    }
    return ResearchRequestOverlay._(
      Map.unmodifiable(overrides),
      Map.unmodifiable(effective),
    );
  }
}

class ResearchDiskBundle {
  ResearchDiskBundle._(this.target, this.inputs);
  final ResearchDiskSnapshot target;
  final List<ResearchDiskSnapshot> inputs;
  static ResearchDiskBundle capture(
    String root,
    String file,
    Object? dependencies,
  ) {
    if (dependencies != null &&
        (dependencies is! List || dependencies.length > 7)) {
      throw ArgumentError('Declare at most seven dependency files');
    }
    final paths = [file, ...?dependencies as List?];
    final inputs = <ResearchDiskSnapshot>[];
    final seen = <String>{};
    var bytes = 0;
    for (final path in paths) {
      if (path is! String) throw ArgumentError('Dependency must be a path');
      final snapshot = ResearchDiskSnapshot.capture(root, path);
      if (!seen.add(snapshot.path.toLowerCase())) {
        throw ArgumentError('Duplicate disk input');
      }
      bytes += snapshot.content.length * 3; // Conservative UTF-8 upper bound.
      if (bytes > 1024 * 1024) {
        throw StateError('Disk bundle exceeds 1 MiB budget');
      }
      inputs.add(snapshot);
    }
    return ResearchDiskBundle._(inputs.first, inputs);
  }

  Map<String, String> get digests => {
    for (final input in inputs) input.path: input.digest,
  };
  void validate(String root) {
    for (final input in inputs) {
      input.validate(root);
    }
  }
}

List<String> researchExpectedCodes(Object? value) {
  if (value is! List ||
      value.length > 16 ||
      value.any(
        (v) => v is! String || !RegExp(r'^[a-z0-9_]{1,80}$').hasMatch(v),
      )) {
    throw ArgumentError(
      'Expected codes must be at most sixteen diagnostic codes',
    );
  }
  return value.cast<String>().toList()..sort();
}

Future<Map> researchObserveDisk(
  ResearchAnalyzerClient client,
  ResearchDiskBundle bundle,
  List<String> expected, {
  Duration observationTimeout = const Duration(seconds: 20),
  ResearchRequestOverlay? overlay,
}) async {
  bundle.validate(client.root);
  final since = client.eventSequence;
  final watch = Stopwatch()..start();
  client.record({
    overlay == null ? 'diskObservation' : 'requestOverlayObservation': 'begin',
    'inputDigests': bundle.digests,
    if (overlay != null) 'overlaySnapshotDigest': overlay.digest,
    if (overlay != null) 'effectiveInputDigest': overlay.effectiveDigest,
    'since': since,
  });
  late Map result;
  try {
    await client.request('analysis.updateContent', {
      'files': {
        for (final input in bundle.inputs)
          input.path: {
            'type': 'add',
            'content': overlay?.effectiveFiles[input.path] ?? input.content,
          },
      },
    });
    final direct = await client.request('analysis.getErrors', {
      'file': bundle.target.path,
    });
    int? stableSequence;
    int? stableSince;
    while (true) {
      if (client.failure != null) {
        throw StateError('Official stream failed: ${client.failure}');
      }
      final errors = client.errors[bundle.target.path];
      final sequence = client.errorSequence[bundle.target.path];
      final codes = errors?.map((e) => '${e['code']}').toList();
      codes?.sort();
      final matches =
          errors != null &&
          sequence != null &&
          sequence > since &&
          !client.busy &&
          codes!.length == expected.length &&
          List.generate(
            codes.length,
            (i) => codes[i] == expected[i],
          ).every((v) => v);
      if (matches) {
        if (stableSequence != sequence) {
          stableSequence = sequence;
          stableSince = watch.elapsedMilliseconds;
        }
        if (watch.elapsedMilliseconds - stableSince! >= 250) {
          bundle.validate(client.root);
          result = {
            'errors': List.of(errors),
            'directErrors': direct['result']['errors'],
            'builtinOnly': false,
            'observationOnly': true,
            'completionBasis': 'expected-codes-fresh-push-idle-250ms',
            'targetDigest': bundle.target.digest,
            'targetPinned': true,
            'inputDigests': bundle.digests,
            'sinceSequence': since,
            'pushSequence': sequence,
            'observationMs': watch.elapsedMilliseconds,
            if (overlay != null) 'overlaySnapshotDigest': overlay.digest,
            if (overlay != null)
              'effectiveInputDigest': overlay.effectiveDigest,
            if (overlay != null) 'overlayScope': 'request-only',
            if (overlay != null)
              'targetContentSource':
                  overlay.overrides.containsKey(bundle.target.path)
                      ? 'overlay'
                      : 'disk',
          };
          break;
        }
      } else {
        stableSequence = null;
        stableSince = null;
      }
      if (watch.elapsed > observationTimeout) {
        throw StateError(
          'Expected diagnostic observation not reached: $expected; current=$codes; sequence=$sequence; since=$since',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  } finally {
    await client.request('analysis.updateContent', {
      'files': {
        for (final input in bundle.inputs) input.path: {'type': 'remove'},
      },
    });
    client.record({
      overlay == null ? 'diskObservation' : 'requestOverlayObservation':
          'cleanupAck',
      'inputDigests': bundle.digests,
    });
  }
  bundle.validate(client.root);
  return result;
}
