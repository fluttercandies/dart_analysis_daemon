// Windows research root identity. Only opens directories for metadata reads.
import 'dart:ffi';
import 'dart:io';

final class _FileInfo extends Struct {
  @Uint32()
  external int attributes;
  @Uint32()
  external int creationLow;
  @Uint32()
  external int creationHigh;
  @Uint32()
  external int accessLow;
  @Uint32()
  external int accessHigh;
  @Uint32()
  external int writeLow;
  @Uint32()
  external int writeHigh;
  @Uint32()
  external int volume;
  @Uint32()
  external int sizeHigh;
  @Uint32()
  external int sizeLow;
  @Uint32()
  external int links;
  @Uint32()
  external int indexHigh;
  @Uint32()
  external int indexLow;
}

class ResearchRootIdentity {
  ResearchRootIdentity(this.key, this.path);
  final String key;
  final String path;
}

final _kernel = DynamicLibrary.open('kernel32.dll');
final _getHeap = _kernel
    .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
      'GetProcessHeap',
    );
final _allocate = _kernel.lookupFunction<
  Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
  Pointer<Void> Function(Pointer<Void>, int, int)
>('HeapAlloc');
final _free = _kernel.lookupFunction<
  Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
  int Function(Pointer<Void>, int, Pointer<Void>)
>('HeapFree');
final _open = _kernel.lookupFunction<
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
final _info = _kernel.lookupFunction<
  Int32 Function(Pointer<Void>, Pointer<_FileInfo>),
  int Function(Pointer<Void>, Pointer<_FileInfo>)
>('GetFileInformationByHandle');
final _finalPath = _kernel.lookupFunction<
  Uint32 Function(Pointer<Void>, Pointer<Uint16>, Uint32, Uint32),
  int Function(Pointer<Void>, Pointer<Uint16>, int, int)
>('GetFinalPathNameByHandleW');
final _close = _kernel
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'CloseHandle',
    );

ResearchRootIdentity researchRootIdentity(String input) {
  if (!Platform.isWindows) {
    throw UnsupportedError('Windows root identity research');
  }
  if (input.length > 32760 ||
      input.contains('\u0000') ||
      !(RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(input) ||
          input.startsWith(r'\\')) ||
      input.startsWith('\\\\?\\') ||
      input.startsWith('\\\\.\\')) {
    throw ArgumentError(
      'Use an absolute directory path without device prefixes',
    );
  }
  final heap = _getHeap();
  Pointer<Void> memory(int length) {
    final pointer = _allocate(heap, 8, length); // zero initialized
    if (pointer == nullptr) throw StateError('Root identity allocation failed');
    return pointer;
  }

  final allocations = <Pointer<Void>>[];
  Pointer<Void>? handle;
  try {
    final name = memory((input.length + 1) * 2);
    allocations.add(name);
    name
        .cast<Uint16>()
        .asTypedList(input.length + 1)
        .setAll(0, input.codeUnits);
    handle = _open(name.cast(), 0, 7, nullptr, 3, 0x02000000, nullptr);
    if (handle.address == -1 ||
        handle.address == 0xffffffffffffffff ||
        handle == nullptr) {
      throw FileSystemException('Cannot open root directory', input);
    }
    final data = memory(sizeOf<_FileInfo>());
    allocations.add(data);
    if (_info(handle, data.cast()) == 0) {
      throw FileSystemException('Cannot read root identity', input);
    }
    final value = data.cast<_FileInfo>().ref;
    if (value.attributes & 0x10 == 0) {
      throw FileSystemException('Root is not a directory', input);
    }
    final buffer = memory(32768 * 2);
    allocations.add(buffer);
    final length = _finalPath(handle, buffer.cast(), 32768, 0);
    if (length == 0 || length >= 32768) {
      throw FileSystemException('Cannot resolve root path', input);
    }
    var path = String.fromCharCodes(buffer.cast<Uint16>().asTypedList(length));
    if (path.startsWith('\\\\?\\UNC\\')) {
      path = '\\\\${path.substring(8)}';
    } else if (path.startsWith('\\\\?\\')) {
      path = path.substring(4);
    }
    return ResearchRootIdentity(
      '${value.volume}:${value.indexHigh}:${value.indexLow}',
      path,
    );
  } finally {
    if (handle != null &&
        handle.address != -1 &&
        handle.address != 0xffffffffffffffff &&
        handle != nullptr) {
      _close(handle);
    }
    for (final allocation in allocations) {
      _free(heap, 0, allocation);
    }
  }
}
