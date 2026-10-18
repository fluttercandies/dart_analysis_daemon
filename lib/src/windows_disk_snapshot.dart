import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Content and identity come from the same handle, with no delete/write sharing.
/// The handle is held only for the bounded read, never across an analyzer query.
class WindowsDiskSnapshot {
  WindowsDiskSnapshot(this.path, this.identity, this.writeTime, this.bytes);
  final String path;
  final String identity;
  final String writeTime;
  final Uint8List bytes;

  static WindowsDiskSnapshot read(String requested, {int limit = 1024 * 1024}) {
    if (limit < 0 || limit > 4 * 1024 * 1024) {
      throw RangeError.range(limit, 0, 4 * 1024 * 1024, 'limit');
    }
    if (!Platform.isWindows) return _readPortable(requested, limit);
    final api = _DiskApi();
    final canonical = File(requested).resolveSymbolicLinksSync();
    final units = canonical.codeUnits;
    Pointer<Uint16> name = nullptr;
    Pointer<Uint32> info = nullptr;
    Pointer<Uint32> count = nullptr;
    Pointer<Uint8> buffer = nullptr;
    Pointer<Void> handle = nullptr;
    try {
      name = api.allocate((units.length + 1) * 2).cast<Uint16>();
      name.asTypedList(units.length).setAll(0, units);
      info = api.allocate(52).cast<Uint32>();
      count = api.allocate(4).cast<Uint32>();
      buffer = api.allocate(limit + 1).cast<Uint8>();
      // Sharing reads only makes a concurrently writing/replacing file fail
      // explicitly; it cannot silently produce a mixed snapshot.
      handle = api.open(name, 0x80000000, 1, nullptr, 3, 0, nullptr);
      if (handle == nullptr ||
          handle.address == Pointer<Void>.fromAddress(-1).address) {
        handle = nullptr;
        throw FileSystemException(
          'Unable to open a stable target snapshot',
          canonical,
        );
      }
      if (api.information(handle, info.cast()) == 0) {
        throw FileSystemException('File identity unavailable', canonical);
      }
      final before = [for (var i = 0; i < 13; i++) info[i]];
      if ((before[0] & 0x10) != 0 ||
          before[8] != 0 ||
          before[9] > limit ||
          (before[11] == 0 && before[12] == 0)) {
        throw StateError('Target exceeds snapshot limit or has no file ID');
      }
      var offset = 0;
      while (offset <= limit) {
        if (api.read(
              handle,
              (buffer + offset).cast(),
              limit + 1 - offset,
              count,
              nullptr,
            ) ==
            0) {
          throw FileSystemException('Snapshot read failed', canonical);
        }
        if (count.value == 0) break;
        offset += count.value;
      }
      if (offset > limit) throw StateError('Target exceeds snapshot limit');
      if (api.information(handle, info.cast()) == 0) {
        throw StateError('File metadata lost during snapshot');
      }
      for (final i in [0, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12]) {
        if (before[i] != info[i]) {
          throw StateError('Target changed during snapshot');
        }
      }
      if (File(requested).resolveSymbolicLinksSync() != canonical) {
        throw StateError('Target path changed during snapshot');
      }
      return WindowsDiskSnapshot(
        canonical,
        '${before[7]}:${before[11]}:${before[12]}',
        '${before[5]}:${before[6]}',
        Uint8List.fromList(buffer.asTypedList(offset)),
      );
    } finally {
      if (handle != nullptr) api.close(handle);
      api.free(name.cast());
      api.free(info.cast());
      api.free(count.cast());
      api.free(buffer.cast());
    }
  }

  /// Portable snapshot for non-Windows platforms. Dart's `dart:io` gives a
  /// stable-enough read on macOS/Linux: read bytes, then confirm the file's
  /// size, modification time and resolved path did not change across the read.
  /// A concurrent writer is detected and rejected rather than silently
  /// producing a mixed snapshot, matching the Windows handle-sharing intent.
  static WindowsDiskSnapshot _readPortable(String requested, int limit) {
    final file = File(requested);
    final canonical = file.resolveSymbolicLinksSync();
    final target = File(canonical);
    final before = target.statSync();
    if (before.type != FileSystemEntityType.file) {
      throw FileSystemException('Snapshot target is not a file', canonical);
    }
    if (before.size > limit) {
      throw StateError('Target exceeds snapshot limit');
    }
    final bytes = target.readAsBytesSync();
    final after = target.statSync();
    if (bytes.length != before.size ||
        after.size != before.size ||
        after.modified != before.modified ||
        File(requested).resolveSymbolicLinksSync() != canonical) {
      throw StateError('Target changed during snapshot');
    }
    final identity =
        '${before.size}:'
        '${before.modified.microsecondsSinceEpoch}:'
        '${before.mode}';
    final writeTime = '${before.modified.microsecondsSinceEpoch}';
    return WindowsDiskSnapshot(canonical, identity, writeTime, bytes);
  }

  bool same(WindowsDiskSnapshot other) {
    if (path != other.path ||
        identity != other.identity ||
        writeTime != other.writeTime ||
        bytes.length != other.bytes.length) {
      return false;
    }
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }
}

class _DiskApi {
  final _dll = DynamicLibrary.open('kernel32.dll');
  final _crt = DynamicLibrary.open('msvcrt.dll');
  late final _calloc = _crt.lookupFunction<
    Pointer<Void> Function(IntPtr, IntPtr),
    Pointer<Void> Function(int, int)
  >('calloc');
  late final free = _crt.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)
  >('free');
  late final open = _dll.lookupFunction<
    Pointer<Void> Function(
      Pointer<Uint16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Void>,
    ),
    Pointer<Void> Function(
      Pointer<Uint16>,
      int,
      int,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
    )
  >('CreateFileW');
  late final information = _dll.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Void>),
    int Function(Pointer<Void>, Pointer<Void>)
  >('GetFileInformationByHandle');
  late final read = _dll.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<Uint32>,
      Pointer<Void>,
    )
  >('ReadFile');
  late final close = _dll.lookupFunction<
    Int32 Function(Pointer<Void>),
    int Function(Pointer<Void>)
  >('CloseHandle');
  Pointer<Void> allocate(int bytes) {
    final result = _calloc(1, bytes);
    if (result == nullptr) throw StateError('Snapshot allocation failed');
    return result;
  }
}
