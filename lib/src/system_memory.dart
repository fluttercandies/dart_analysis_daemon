import 'dart:ffi';
import 'dart:io';

const bytesPerMiB = 1024 * 1024;

class SystemMemorySnapshot {
  SystemMemorySnapshot({
    required this.totalPhysicalBytes,
    required this.availablePhysicalBytes,
    required this.commitLimitBytes,
    required this.availableCommitBytes,
    DateTime? sampledAt,
  }) : sampledAt = sampledAt ?? DateTime.now().toUtc();

  final int totalPhysicalBytes;
  final int availablePhysicalBytes;
  final int commitLimitBytes;
  final int availableCommitBytes;
  final DateTime sampledAt;

  bool freshAt(DateTime now) {
    final age = now.difference(sampledAt);
    return !age.isNegative &&
        age <= const Duration(seconds: 2) &&
        totalPhysicalBytes > 0 &&
        availablePhysicalBytes >= 0 &&
        availablePhysicalBytes <= totalPhysicalBytes &&
        commitLimitBytes > 0 &&
        availableCommitBytes >= 0 &&
        availableCommitBytes <= commitLimitBytes;
  }

  Map<String, Object?> toJson() => {
    'sampledAt': sampledAt.toIso8601String(),
    'totalPhysicalMiB': totalPhysicalBytes / bytesPerMiB,
    'availablePhysicalMiB': availablePhysicalBytes / bytesPerMiB,
    'commitLimitMiB': commitLimitBytes / bytesPerMiB,
    'availableCommitMiB': availableCommitBytes / bytesPerMiB,
  };
}

/// Read-only Windows system counters. Unknown samples stay null, never zero.
class WindowsSystemMemorySampler {
  WindowsSystemMemorySampler() {
    if (!Platform.isWindows) throw UnsupportedError('Windows memory sampler');
  }
  final _kernel = DynamicLibrary.open('kernel32.dll');
  final _psapi = DynamicLibrary.open('psapi.dll');
  final _crt = DynamicLibrary.open('msvcrt.dll');
  late final _alloc = _crt.lookupFunction<
    Pointer<Void> Function(IntPtr, IntPtr),
    Pointer<Void> Function(int, int)
  >('calloc');
  late final _free = _crt.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)
  >('free');
  late final _physical = _kernel.lookupFunction<
    Int32 Function(Pointer<_MemoryStatus>),
    int Function(Pointer<_MemoryStatus>)
  >('GlobalMemoryStatusEx');
  late final _commit = _psapi.lookupFunction<
    Int32 Function(Pointer<_PerformanceInfo>, Uint32),
    int Function(Pointer<_PerformanceInfo>, int)
  >('GetPerformanceInfo');

  SystemMemorySnapshot? sample() {
    final physical = _alloc(1, sizeOf<_MemoryStatus>()).cast<_MemoryStatus>();
    final commit =
        _alloc(1, sizeOf<_PerformanceInfo>()).cast<_PerformanceInfo>();
    try {
      if (physical == nullptr || commit == nullptr) return null;
      physical.ref.length = sizeOf<_MemoryStatus>();
      commit.ref.cb = sizeOf<_PerformanceInfo>();
      if (_physical(physical) == 0 ||
          _commit(commit, sizeOf<_PerformanceInfo>()) == 0) {
        return null;
      }
      final info = commit.ref;
      if (info.pageSize <= 0 || info.commitTotal > info.commitLimit) {
        return null;
      }
      final result = SystemMemorySnapshot(
        totalPhysicalBytes: physical.ref.totalPhysical,
        availablePhysicalBytes: physical.ref.availablePhysical,
        commitLimitBytes: info.commitLimit * info.pageSize,
        availableCommitBytes:
            (info.commitLimit - info.commitTotal) * info.pageSize,
      );
      return result.freshAt(DateTime.now().toUtc()) ? result : null;
    } finally {
      if (physical != nullptr) _free(physical.cast());
      if (commit != nullptr) _free(commit.cast());
    }
  }
}

final class _MemoryStatus extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int load;
  @Uint64()
  external int totalPhysical;
  @Uint64()
  external int availablePhysical;
  @Uint64()
  external int totalPageFile;
  @Uint64()
  external int availablePageFile;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availableVirtual;
  @Uint64()
  external int availableExtendedVirtual;
}

final class _PerformanceInfo extends Struct {
  @Uint32()
  external int cb;
  @UintPtr()
  external int commitTotal;
  @UintPtr()
  external int commitLimit;
  @UintPtr()
  external int commitPeak;
  @UintPtr()
  external int physicalTotal;
  @UintPtr()
  external int physicalAvailable;
  @UintPtr()
  external int systemCache;
  @UintPtr()
  external int kernelTotal;
  @UintPtr()
  external int kernelPaged;
  @UintPtr()
  external int kernelNonpaged;
  @UintPtr()
  external int pageSize;
  @Uint32()
  external int handleCount;
  @Uint32()
  external int processCount;
  @Uint32()
  external int threadCount;
}

/// Read-only macOS system counters via libSystem FFI. Unknown samples stay
/// null, never zero.
///
/// macOS has no fixed commit limit (swap grows dynamically), so the commit
/// fields mirror the physical values. That keeps `SystemMemorySnapshot.freshAt`
/// valid and makes the policy's commit check never stricter than its physical
/// check, matching the "soft reserve" intent on this platform.
class MacSystemMemorySampler {
  MacSystemMemorySampler() {
    if (!Platform.isMacOS) throw UnsupportedError('macOS memory sampler');
  }

  final _lib = DynamicLibrary.process();

  late final _calloc = _lib.lookupFunction<
    Pointer<Void> Function(IntPtr, IntPtr),
    Pointer<Void> Function(int, int)
  >('calloc');
  late final _free = _lib.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)
  >('free');
  late final _sysctlByName = _lib.lookupFunction<
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Void>,
      Pointer<IntPtr>,
      Pointer<Void>,
      IntPtr,
    ),
    int Function(
      Pointer<Uint8>,
      Pointer<Void>,
      Pointer<IntPtr>,
      Pointer<Void>,
      int,
    )
  >('sysctlbyname');
  late final _machHostSelf = _lib
      .lookupFunction<Uint32 Function(), int Function()>('mach_host_self');
  late final _hostStatistics64 = _lib.lookupFunction<
    Int32 Function(Uint32, Int32, Pointer<Uint32>, Pointer<Uint32>),
    int Function(int, int, Pointer<Uint32>, Pointer<Uint32>)
  >('host_statistics64');
  late final _hostPageSize = _lib.lookupFunction<
    Int32 Function(Uint32, Pointer<IntPtr>),
    int Function(int, Pointer<IntPtr>)
  >('host_page_size');

  // HOST_VM_INFO64 flavor and its documented natural_t field count.
  static const _hostVmInfo64 = 4;
  static const _hostVmInfo64Count = 38;

  // vm_statistics64 field indices (natural_t units). The leading four counts
  // are 32-bit; purgeable/speculative sit after the 64-bit event counters.
  static const _freeIndex = 0;
  static const _inactiveIndex = 2;
  static const _purgeableIndex = 22;
  static const _speculativeIndex = 23;

  SystemMemorySnapshot? sample() {
    final total = _totalPhysicalBytes();
    if (total == null || total <= 0) return null;
    final available = _availablePhysicalBytes();
    if (available == null || available < 0 || available > total) return null;

    final result = macSnapshot(
      totalPhysicalBytes: total,
      availablePhysicalBytes: available,
      pressureLevel: _pressureLevel(),
    );
    return result.freshAt(DateTime.now().toUtc()) ? result : null;
  }

  /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical.
  int? _pressureLevel() {
    const name = 'kern.memorystatus_vm_pressure_level';
    final nameBytes = name.codeUnits;
    final namePtr = _calloc(nameBytes.length + 1, 1).cast<Uint8>();
    final out = _calloc(1, sizeOf<Int32>()).cast<Int32>();
    final lenPtr = _calloc(1, sizeOf<IntPtr>()).cast<IntPtr>();
    try {
      if (namePtr == nullptr || out == nullptr || lenPtr == nullptr) {
        return null;
      }
      for (var i = 0; i < nameBytes.length; i++) {
        namePtr[i] = nameBytes[i];
      }
      lenPtr.value = sizeOf<Int32>();
      final rc = _sysctlByName(namePtr, out.cast(), lenPtr, nullptr, 0);
      if (rc != 0) return null;
      return out.value;
    } finally {
      if (namePtr != nullptr) _free(namePtr.cast());
      if (out != nullptr) _free(out.cast());
      if (lenPtr != nullptr) _free(lenPtr.cast());
    }
  }

  int? _totalPhysicalBytes() {
    const name = 'hw.memsize';
    final nameBytes = name.codeUnits;
    final namePtr = _calloc(nameBytes.length + 1, 1).cast<Uint8>();
    final out = _calloc(1, sizeOf<Uint64>()).cast<Uint64>();
    final lenPtr = _calloc(1, sizeOf<IntPtr>()).cast<IntPtr>();
    try {
      if (namePtr == nullptr || out == nullptr || lenPtr == nullptr) {
        return null;
      }
      for (var i = 0; i < nameBytes.length; i++) {
        namePtr[i] = nameBytes[i];
      }
      lenPtr.value = sizeOf<Uint64>();
      final rc = _sysctlByName(namePtr, out.cast(), lenPtr, nullptr, 0);
      if (rc != 0) return null;
      return out.value;
    } finally {
      if (namePtr != nullptr) _free(namePtr.cast());
      if (out != nullptr) _free(out.cast());
      if (lenPtr != nullptr) _free(lenPtr.cast());
    }
  }

  int? _availablePhysicalBytes() {
    final pagePtr = _calloc(1, sizeOf<IntPtr>()).cast<IntPtr>();
    final vm = _calloc(_hostVmInfo64Count, sizeOf<Uint32>()).cast<Uint32>();
    final countPtr = _calloc(1, sizeOf<Uint32>()).cast<Uint32>();
    try {
      if (pagePtr == nullptr || vm == nullptr || countPtr == nullptr) {
        return null;
      }
      final host = _machHostSelf();
      if (_hostPageSize(host, pagePtr) != 0) return null;
      final pageSize = pagePtr.value;
      if (pageSize <= 0) return null;

      countPtr.value = _hostVmInfo64Count;
      if (_hostStatistics64(host, _hostVmInfo64, vm, countPtr) != 0) {
        return null;
      }
      // Reclaimable memory: free pages plus the inactive, speculative and
      // purgeable pages the kernel can hand back under pressure. This mirrors
      // the "available" figure shown by Activity Monitor more closely than
      // free pages alone.
      final pages =
          vm[_freeIndex] +
          vm[_inactiveIndex] +
          vm[_speculativeIndex] +
          vm[_purgeableIndex];
      if (pages < 0) return null;
      return pages * pageSize;
    } finally {
      if (pagePtr != nullptr) _free(pagePtr.cast());
      if (vm != nullptr) _free(vm.cast());
      if (countPtr != nullptr) _free(countPtr.cast());
    }
  }
}

/// The system memory sampler for this platform, or null where none exists
/// (callers then skip memory-driven decisions).
SystemMemorySnapshot? Function()? platformMemorySampler() {
  if (Platform.isMacOS) return MacSystemMemorySampler().sample;
  if (Platform.isWindows) return WindowsSystemMemorySampler().sample;
  return null;
}

/// Builds a macOS snapshot. macOS has no fixed commit limit, so commit mirrors
/// physical memory, except that a kernel memory-pressure level of warn (2) or
/// worse reports no available commit. "Available" pages alone stay near the
/// reserve under compression and swap even while the system is thrashing; the
/// pressure level is the kernel's own verdict on that state. An unknown level
/// (null) leaves the physical figure unchanged.
SystemMemorySnapshot macSnapshot({
  required int totalPhysicalBytes,
  required int availablePhysicalBytes,
  required int? pressureLevel,
  DateTime? sampledAt,
}) {
  final underPressure = pressureLevel != null && pressureLevel >= 2;
  return SystemMemorySnapshot(
    totalPhysicalBytes: totalPhysicalBytes,
    availablePhysicalBytes: availablePhysicalBytes,
    commitLimitBytes: totalPhysicalBytes,
    availableCommitBytes: underPressure ? 0 : availablePhysicalBytes,
    sampledAt: sampledAt,
  );
}
