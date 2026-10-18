import 'dart:convert';
import 'worktree_overlay_model.dart';

void main() {
  final results = <Map>[];
  void check(bool value) {
    if (!value) throw StateError('Invariant failed');
  }

  void rejects(void Function() action) {
    var rejected = false;
    try {
      action();
    } on StateError {
      rejected = true;
    }
    check(rejected);
  }

  void run(String name, void Function() body) {
    body();
    results.add({'name': name, 'passed': true});
    print('PASS $name');
  }

  run(
    'full replay acknowledgement gates tickets and worker replacement requires replay',
    () {
      final model = ResearchOverlayModel('root:env');
      model.update('a', 'x.dart', 1, 'unsaved');
      model.bind('root:env', 1);
      rejects(model.ticket);
      final replay = model.replay();
      check(replay.files['x.dart'] == 'unsaved');
      check(model.acknowledge(replay));
      final old = model.ticket();
      model.bind('root:env', 2);
      check(!model.accepts(old) && !model.acknowledge(replay));
      rejects(model.ticket);
      check(model.acknowledge(model.replay()));
      check(model.accepts(model.ticket()));
      rejects(() => model.bind('other-root:env', 3));
      rejects(() => model.bind('root:env', 1));
    },
  );
  run('versions owner conflicts and root scopes stay isolated', () {
    final a = ResearchOverlayModel('a');
    final b = ResearchOverlayModel('b');
    a.update('client', 'x', 2, 'one');
    b.update('client', 'x', 1, 'two');
    rejects(() => a.update('client', 'x', 2, 'stale'));
    rejects(() => a.update('other', 'x', 3, 'conflict'));
    a.bind('a', 1);
    b.bind('b', 1);
    check(a.replay().files['x'] == 'one' && b.replay().files['x'] == 'two');
    check(a.acknowledge(a.replay()) && b.acknowledge(b.replay()));
    check(!b.accepts(a.ticket()) && !a.accepts(b.ticket()));
  });
  run('edits discard late ack and invalidate earlier diagnostic ticket', () {
    final model = ResearchOverlayModel('a')..bind('a', 1);
    model.update('client', 'x', 1, 'old');
    check(model.acknowledge(model.replay()));
    final ticket = model.ticket();
    final late = model.replay();
    model.update('client', 'x', 2, 'new');
    check(!model.acknowledge(late) && !model.accepts(ticket));
    final latest = model.replay();
    check(latest.files['x'] == 'new' && model.acknowledge(latest));
  });
  run(
    'clear and disconnect remove even unacknowledged content and release bytes',
    () {
      final model = ResearchOverlayModel('a')..bind('a', 1);
      model.update('c', 'x', 1, 'hello');
      final unacked = model.replay();
      model.update('c', 'x', 2, null);
      rejects(() => model.update('c', 'x', 1, 'stale'));
      final cleared = model.replay();
      check(
        cleared.removes.contains('x') &&
            cleared.files.isEmpty &&
            model.retainedBytes == 0,
      );
      check(!model.acknowledge(unacked) && model.acknowledge(cleared));
      model.update('c', 'y', 1, 'content');
      model.replay();
      model.disconnect('c');
      final removed = model.replay();
      check(removed.removes.contains('y') && model.retainedBytes == 0);
      check(model.acknowledge(removed));
      model.unbind();
      rejects(model.ticket);
      rejects(model.replay);
    },
  );
  run(
    'byte file and unacknowledged removal limits reject without losing current state',
    () {
      final model = ResearchOverlayModel('a', maxBytes: 4, maxFiles: 1)
        ..bind('a', 1);
      model.update('c', 'x', 1, '中');
      rejects(() => model.update('c', 'x', 2, '中文'));
      rejects(() => model.update('c', 'y', 1, 'a'));
      check(model.retainedBytes == 3 && model.replay().files['x'] == '中');
      model.disconnect('c');
      model.update('d', 'y', 1, 'a');
      rejects(model.replay);
      model.bind('a', 2);
      check(model.acknowledge(model.replay()));
    },
  );
  print(
    jsonEncode({
      'results': results,
      'allPassed': true,
      'syntheticModelOnly': true,
    }),
  );
}
