import 'dart:io';

import 'package:dart_analysis_daemon/src/managed_plugin_cache.dart';
import 'package:test/test.dart';

void main() {
  test(
    'private cache reuses identity, bounds LRU and cleans only its directory',
    () async {
      final state = await Directory.systemTemp.createTemp('dana-cache-policy-');
      final name = 'sdk-cache-${'a' * 16}';
      final cache = ManagedPluginCache(state, name);
      try {
        final unrelated = await File(
          '${state.path}/keep.txt',
        ).writeAsString('user');
        final a = await cache.prepare('root', 'a');
        final b = await cache.prepare('root', 'b');
        final c = await cache.prepare('root', 'c');
        expect((await cache.prepare('root', 'a')).path, a.path);
        await cache.prepare('other-root', 'a');
        expect(await a.exists(), true);
        expect(await b.exists(), false);
        expect(await c.exists(), true);
        await cache.invalidate('root', 'c');
        expect(await c.exists(), false);
        await cache.prepare('root', 'c');
        expect(await c.exists(), true);
        expect(await cache.directory.list().length, 3);
        await expectLater(
          ManagedPluginCache.removeOwned(state, '../'),
          throwsStateError,
        );
        expect(await unrelated.exists(), true);
        await ManagedPluginCache.removeOwned(state, name);
        expect(await cache.directory.exists(), false);
        expect(await unrelated.readAsString(), 'user');
        await ManagedPluginCache.removeOwned(state, name);
        final longCache = ManagedPluginCache(
          Directory('${state.path}/${'x' * 170}'),
          name,
        );
        await expectLater(
          longCache.prepare('root', 'identity'),
          throwsStateError,
        );
      } finally {
        await state.delete(recursive: true);
      }
    },
  );
}
