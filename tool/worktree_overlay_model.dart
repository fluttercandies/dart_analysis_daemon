// Research-only state model. Paths/scopes must already be validated by caller.
// An adapter must serialize updateContent calls, await successful responses,
// and independently establish that diagnostics correspond to the applied state.
import 'dart:convert';

class OverlayReplay {
  OverlayReplay(
    this.generation,
    this.revision,
    this.serial,
    Map<String, String> files,
    Set<String> removes,
  ) : files = Map.unmodifiable(files),
      removes = Set.unmodifiable(removes);
  final int generation;
  final int revision;
  final int serial;
  final Map<String, String> files;
  final Set<String> removes;
}

class OverlayTicket {
  OverlayTicket._(this.owner, this.generation, this.revision);
  final ResearchOverlayModel owner;
  final int generation;
  final int revision;
}

class _Overlay {
  _Overlay(this.owner, this.version, this.content, this.bytes);
  final String owner;
  final int version;
  final String? content;
  final int bytes;
}

class ResearchOverlayModel {
  ResearchOverlayModel(
    this.scope, {
    this.maxBytes = 4 * 1024 * 1024,
    this.maxFiles = 128,
  });
  final String scope;
  final int maxBytes;
  final int maxFiles;
  // Keep version tombstones until owner disconnects; bounded by maxFiles.
  final _files = <String, _Overlay>{};
  final _sentPaths = <String>{};
  int retainedBytes = 0;
  int revision = 0;
  int _generation = 0;
  int _serial = 0;
  int? _ackedRevision;
  OverlayReplay? _pending;
  bool _bound = false;

  void update(String owner, String path, int version, String? content) {
    final previous = _files[path];
    if (owner.isEmpty ||
        owner.length > 128 ||
        path.isEmpty ||
        path.length > 4096 ||
        version < 1 ||
        (previous != null &&
            (previous.owner != owner || version <= previous.version))) {
      throw StateError('Overlay ownership or version conflict');
    }
    if (!_files.containsKey(path) && _files.length >= maxFiles) {
      throw StateError('Overlay file limit');
    }
    if (content != null && content.length > maxBytes) {
      throw StateError('Overlay byte limit');
    }
    final bytes = content == null ? 0 : utf8.encode(content).length;
    final total = retainedBytes - (previous?.bytes ?? 0) + bytes;
    if (total > maxBytes) throw StateError('Overlay byte limit');
    _files[path] = _Overlay(owner, version, content, bytes);
    retainedBytes = total;
    revision++;
    _pending = null;
  }

  void disconnect(String owner) {
    final paths = _files.keys.where((p) => _files[p]!.owner == owner).toList();
    if (paths.isEmpty) return;
    for (final path in paths) {
      retainedBytes -= _files.remove(path)!.bytes;
    }
    revision++;
    _pending = null;
  }

  // Caller supplies a fresh, increasing generation after worker/root/env change.
  void bind(String workerScope, int generation) {
    if (workerScope != scope || generation <= _generation) {
      throw StateError('Invalid worker identity');
    }
    _bound = true;
    _generation = generation;
    _ackedRevision = null;
    _pending = null;
    _sentPaths.clear();
  }

  void unbind() {
    _bound = false;
    _ackedRevision = null;
    _pending = null;
    _sentPaths.clear();
  }

  OverlayReplay replay() {
    if (!_bound) throw StateError('No worker');
    final files = <String, String>{
      for (final entry in _files.entries)
        if (entry.value.content != null) entry.key: entry.value.content!,
    };
    // Include paths from stale/unacknowledged sends: they may have been applied.
    final removes = _sentPaths.difference(files.keys.toSet());
    final replay = OverlayReplay(
      _generation,
      revision,
      ++_serial,
      files,
      removes,
    );
    // Bound metadata even for repeated disconnect/update cycles before ack.
    if (_sentPaths.union(files.keys.toSet()).length > maxFiles) {
      throw StateError('Pending removal limit; drain replay or replace worker');
    }
    _sentPaths.addAll(files.keys);
    _pending = replay;
    return replay;
  }

  bool acknowledge(OverlayReplay replay) {
    if (!_bound ||
        !identical(replay, _pending) ||
        replay.generation != _generation ||
        replay.revision != revision) {
      return false;
    }
    _ackedRevision = revision;
    _sentPaths
      ..clear()
      ..addAll(replay.files.keys);
    _pending = null;
    return true;
  }

  OverlayTicket ticket() {
    if (!_bound || _pending != null || _ackedRevision != revision) {
      throw StateError('Replay not acknowledged');
    }
    return OverlayTicket._(this, _generation, revision);
  }

  bool accepts(OverlayTicket ticket) =>
      identical(ticket.owner, this) &&
      _bound &&
      _pending == null &&
      _ackedRevision == revision &&
      ticket.generation == _generation &&
      ticket.revision == revision;
}
