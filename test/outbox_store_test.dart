import 'dart:io';
import 'dart:math';

import 'package:outbox_sync/outbox_sync.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('outbox_'));
  tearDown(() async => dir.delete(recursive: true));

  test('pending changes survive a restart', () async {
    final file = File('${dir.path}/outbox.json');
    final remote = InMemoryRemote()..failNextWrites = 1;

    final before = SyncEngine(remote: remote, store: JsonFileOutboxStore(file));
    await before.enqueueWrite('a', {'n': 1}, baseVersion: 0);
    await before.flush(); // fails: the change stays in the outbox

    // The app is closed and opened again.
    final after = SyncEngine(
      remote: remote,
      store: JsonFileOutboxStore(file),
      now: () => DateTime.now().add(const Duration(hours: 1)),
    );
    await after.init();

    expect(after.pending.single.attempts, 1);
    expect((await after.flush()).accepted, {'a': 1});
    expect(await JsonFileOutboxStore(file).load(), isEmpty);
  });

  test('a save replaces the file in one step and leaves no temp file',
      () async {
    final file = File('${dir.path}/outbox.json');
    final store = JsonFileOutboxStore(file);
    final op =
        PendingOp(opId: '1', recordId: 'a', data: {'n': 1}, baseVersion: 0);

    await store.save([op]);
    await store.save([op, op]);

    expect(await store.load(), hasLength(2));
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('retry delays double, stay under the cap and include jitter', () {
    const policy = RetryPolicy(
      baseDelay: Duration(seconds: 2),
      maxDelay: Duration(seconds: 60),
    );
    final random = Random(7);
    for (var attempt = 1; attempt <= 10; attempt++) {
      final full = Duration(seconds: min(2 * pow(2, attempt - 1).toInt(), 60));
      final delay = policy.delayAfter(attempt, random);
      expect(delay, greaterThanOrEqualTo(full ~/ 2));
      expect(delay, lessThanOrEqualTo(full));
    }
  });
}
