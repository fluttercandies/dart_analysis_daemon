// Research-only bounded target snapshot. This does not freeze dependencies.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'worktree_analyzer_client.dart';
import 'worktree_windows_disk_file.dart';

class ResearchDiskSnapshot {
  ResearchDiskSnapshot._(
    this.requested,
    this.path,
    this.content,
    this.digest,
    this.stamp,
    this.fileIdentity,
  );
  final String requested, path, content, digest, stamp, fileIdentity;
  static ResearchDiskSnapshot capture(String root, String requested) {
    final canonicalRoot = Directory(root).resolveSymbolicLinksSync();
    final file = File(requested);
    final path = file.resolveSymbolicLinksSync();
    if (!path.toLowerCase().startsWith(
          '$canonicalRoot${Platform.pathSeparator}'.toLowerCase(),
        ) ||
        !path.toLowerCase().endsWith('.dart')) {
      throw StateError('Target outside root or not Dart');
    }
    final before = file.statSync();
    final nativeRead = researchReadWindowsDisk(file.absolute.path);
    final bytes = nativeRead.bytes;
    if (bytes.length > 512 * 1024) throw StateError('Target exceeds 512 KiB');
    final after = file.statSync();
    String stamp(FileStat value) =>
        '${value.type}:${value.size}:${value.modified.microsecondsSinceEpoch}:${value.changed.microsecondsSinceEpoch}';
    if (before.type != FileSystemEntityType.file ||
        stamp(before) != stamp(after) ||
        file.resolveSymbolicLinksSync() != path) {
      throw StateError('Target changed during snapshot');
    }
    return ResearchDiskSnapshot._(
      file.absolute.path,
      path,
      utf8.decode(bytes),
      sha256.convert(bytes).toString(),
      stamp(after),
      nativeRead.identity,
    );
  }

  bool same(ResearchDiskSnapshot other) =>
      path == other.path &&
      digest == other.digest &&
      stamp == other.stamp &&
      fileIdentity == other.fileIdentity;
  void validate(String root) {
    if (!same(capture(root, requested))) {
      throw StateError('Target changed during analysis');
    }
  }
}

// Pin the exact disk text so analyzer file-watcher lag cannot produce a result
// for a previous target revision. Internal overlays are removed before reply.
Future<Map> researchBuiltinDiskQuery(
  ResearchAnalyzerClient client,
  ResearchDiskSnapshot target,
) async {
  client.record({'diskQuery': 'begin', 'targetDigest': target.digest});
  await client.request('analysis.updateContent', {
    'files': {
      target.path: {'type': 'add', 'content': target.content},
    },
  });
  late Map result;
  try {
    final value = await client.request('analysis.getErrors', {
      'file': target.path,
    });
    target.validate(client.root);
    result = {
      'errors': value['result']['errors'],
      'builtinOnly': true,
      'targetDigest': target.digest,
      'targetPinned': true,
    };
  } finally {
    // An uncertain cleanup poisons the client; its owner must discard the Job.
    await client.request('analysis.updateContent', {
      'files': {
        target.path: {'type': 'remove'},
      },
    });
    client.record({'diskQuery': 'cleanupAck', 'targetDigest': target.digest});
  }
  target.validate(client.root);
  return result;
}
