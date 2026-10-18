// Research-only Windows bounded read tied to the same native file handle ID.
// ignore_for_file: depend_on_referenced_packages
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

final class _FileInformation extends Struct {
  @Array(13)
  external Array<Uint32> words;
}

class ResearchWindowsDiskRead {
  ResearchWindowsDiskRead(this.bytes, this.identity);
  final Uint8List bytes;
  final String identity;
}

class _Api {
  final library = DynamicLibrary.open('kernel32.dll');
  late final open = library.lookupFunction<
    Pointer<Void> Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Void>,
    ),
    Pointer<Void> Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
    )
  >('CreateFileW');
  late final information = library.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<_FileInformation>),
    int Function(Pointer<Void>, Pointer<_FileInformation>)
  >('GetFileInformationByHandle');
  late final read = library.lookupFunction<
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
  late final close = library.lookupFunction<
    Int32 Function(Pointer<Void>),
    int Function(Pointer<Void>)
  >('CloseHandle');
  late final error = library.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
}

final _api = _Api();

ResearchWindowsDiskRead researchReadWindowsDisk(String path) {
  if (!Platform.isWindows) {
    throw UnsupportedError('Research file identity currently requires Windows');
  }
  final name = path.toNativeUtf16();
  Pointer<Void> handle = nullptr;
  final info = calloc<_FileInformation>();
  const limit = 512 * 1024 + 1;
  final buffer = calloc<Uint8>(limit);
  final count = calloc<Uint32>();
  Never fail(String operation) =>
      throw FileSystemException(
        '$operation failed (Win32 ${_api.error()})',
        path,
      );
  List<int> metadata() {
    if (_api.information(handle, info) == 0) fail('File information');
    // FILETIME fields have DWORD alignment, not native uint64 alignment.
    return [for (var i = 0; i < 13; i++) info.ref.words[i]];
  }

  try {
    handle = _api.open(name, 0x80000000, 7, nullptr, 3, 0, nullptr);
    if (handle == nullptr ||
        handle.address == Pointer<Void>.fromAddress(-1).address) {
      handle = nullptr;
      fail('Open file');
    }
    final before = metadata();
    if ((before[0] & 0x10) != 0 || before[8] != 0 || before[9] >= limit) {
      throw StateError('Target is not a bounded disk file');
    }
    var length = 0;
    while (length < limit) {
      if (_api.read(
            handle,
            (buffer + length).cast(),
            limit - length,
            count,
            nullptr,
          ) ==
          0) {
        fail('Read file');
      }
      if (count.value == 0) break;
      length += count.value;
    }
    if (length >= limit) throw StateError('Target exceeds 512 KiB');
    final after = metadata();
    // Ignore last-access time, which reading can update. Identity, creation,
    // write time, size, attributes and link count must stay unchanged.
    for (final i in [0, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12]) {
      if (before[i] != after[i]) {
        throw StateError('File changed during native read');
      }
    }
    if (before[11] == 0 && before[12] == 0) {
      throw StateError('Filesystem did not provide a file ID');
    }
    return ResearchWindowsDiskRead(
      Uint8List.fromList(buffer.asTypedList(length)),
      '${before[7]}:${before[11]}:${before[12]}',
    );
  } finally {
    if (handle != nullptr) _api.close(handle);
    calloc.free(name);
    calloc.free(info);
    calloc.free(buffer);
    calloc.free(count);
  }
}
