import 'dart:io';

const _maxSearchDepth = 8;
const _maxSearchEntries = 32768;
const _ignoredDirectories = {
  '.git',
  '.dart_tool',
  '.idea',
  '.pub-cache',
  '.vscode',
  'build',
  'coverage',
  'dist',
  'node_modules',
  'vendor',
};

/// Returns whether [path] is a Dart project, package, or workspace root.
///
/// The bounded search recognizes packages with `pubspec.yaml`, including
/// nested packages in monorepos, without traversing generated or vendored
/// directories. Generated metadata and loose Dart files alone do not qualify
/// a workspace for the IDE bridge.
Future<bool> isDartProjectRoot(String path) async {
  final root = Directory(path);
  try {
    if (!await root.exists()) return false;
    if (await _hasDartMarker(root)) return true;

    final pending = <({Directory directory, int depth})>[
      (directory: root, depth: 0),
    ];
    var entries = 0;
    var pendingIndex = 0;
    while (pendingIndex < pending.length) {
      final current = pending[pendingIndex++];
      if (current.depth >= _maxSearchDepth) continue;
      if (await _hasDartMarker(current.directory)) return true;
      await for (final entity in current.directory.list(followLinks: false)) {
        if (++entries > _maxSearchEntries) return false;
        if (entity is Directory) {
          final name =
              entity.uri.pathSegments
                  .where((segment) => segment.isNotEmpty)
                  .last
                  .toLowerCase();
          if (!_ignoredDirectories.contains(name)) {
            pending.add((directory: entity, depth: current.depth + 1));
          }
        }
      }
    }
    return false;
  } on FileSystemException {
    return false;
  }
}

Future<bool> _hasDartMarker(Directory directory) =>
    File.fromUri(directory.uri.resolve('pubspec.yaml')).exists();
