import 'dart:convert';
import 'worktree_analyzer_overlay_probe.dart' show ProbeDiagnosticCache;

void main() {
  final cache = ProbeDiagnosticCache();
  final results = <Map>[];
  void check(bool value) {
    if (!value) throw StateError('Diagnostic invariant');
  }

  void push(String file, List errors, int sequence) => cache.receive({
    'event': 'analysis.errors',
    'params': {'file': file, 'errors': errors},
  }, sequence);
  void run(String name, void Function() body) {
    body();
    results.add({'name': name, 'passed': true});
    print('PASS $name');
  }

  run(
    'flush during stability observation invalidates even a previously clean result',
    () {
      push('a', [], 10);
      push('b', ['error'], 11);
      check(cache.matches('a', 9, (e) => e.isEmpty));
      cache.receive({
        'event': 'analysis.flushResults',
        'params': {
          'files': ['a'],
        },
      }, 12);
      check(
        !cache.matches('a', 9, (e) => e.isEmpty) &&
            !cache.errorSequence.containsKey('a'),
      );
      check(cache.matches('b', 10, (e) => e.single == 'error'));
    },
  );
  run('republished diagnostics must cross the request sequence threshold', () {
    push('a', [], 13);
    check(!cache.matches('a', 13, (e) => e.isEmpty));
    push('a', ['new'], 14);
    check(!cache.matches('a', 13, (e) => e.isEmpty));
    check(cache.matches('a', 13, (e) => e.single == 'new'));
    cache.receive({
      'event': 'analysis.flushResults',
      'params': {
        'files': ['a', 'b', 'unknown'],
      },
    }, 15);
    check(cache.errors.isEmpty && cache.errorSequence.isEmpty);
  });
  print(jsonEncode({'allPassed': true, 'results': results, 'cacheOnly': true}));
}
