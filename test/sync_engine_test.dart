import 'dart:math';

import 'package:outbox_sync/outbox_sync.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryRemote remote;
  late MemoryOutboxStore store;
  late DateTime now;

  SyncEngine engine({RetryPolicy retry = const RetryPolicy()}) => SyncEngine(
        remote: remote,
        store: store,
        retry: retry,
        now: () => now,
        random: Random(1),
      );

  setUp(() {
    remote = InMemoryRemote();
    store = MemoryOutboxStore();
    now = DateTime(2026, 11, 24, 12);
  });

  test('sends a new record and empties the outbox', () async {
    final sync = engine();
    await sync.enqueueWrite('a', {'n': 1}, baseVersion: 0);

    final report = await sync.flush();

    expect(report.accepted, {'a': 1});
    expect(sync.pending, isEmpty);
    expect((await remote.fetch('a'))!.data, {'n': 1});
  });

  test('folds unsent changes of the same record into one operation', () async {
    final sync = engine();
    await sync.enqueueWrite('a', {'n': 1}, baseVersion: 0);
    await sync.enqueueWrite('a', {'n': 2}, baseVersion: 0);
    await sync.enqueueDelete('a', baseVersion: 0);

    expect(sync.pending, hasLength(1));
    expect(sync.pending.single.isDelete, isTrue);

    await sync.flush();
    expect(remote.appliedWrites, 1);
    expect((await remote.fetch('a'))!.isDeleted, isTrue);
  });

  test('a lost answer is retried without applying the write twice', () async {
    final sync = engine();
    await sync.enqueueWrite('a', {'n': 1}, baseVersion: 0);

    remote.loseNextResponses = 1; // applied on the server, answer lost
    final first = await sync.flush();
    expect(first.stopped, isTrue);
    expect(sync.pending.single.attempts, 1);

    now = now.add(const Duration(minutes: 10)); // past the backoff
    final second = await sync.flush();

    expect(second.accepted, {'a': 1});
    expect(remote.appliedWrites, 1);
    expect((await remote.fetch('a'))!.version, 1);
  });

  test('a change made after a failed attempt is chained, not folded in',
      () async {
    final sync = engine();
    await sync.enqueueWrite('a', {'n': 1}, baseVersion: 0);
    remote.loseNextResponses = 1;
    await sync.flush(); // first change may already be on the server

    await sync.enqueueWrite('a', {'n': 2}, baseVersion: 0);
    expect(sync.pending, hasLength(2));
    expect(sync.pending.last.baseVersion, isNull);

    now = now.add(const Duration(minutes: 10));
    final report = await sync.flush();

    expect(report.accepted, {'a': 2});
    expect((await remote.fetch('a'))!.data, {'n': 2});
  });

  test('waits for the backoff and keeps the order after a failure', () async {
    final sync = engine();
    await sync.enqueueWrite('a', {'n': 1}, baseVersion: 0);
    await sync.enqueueWrite('b', {'n': 1}, baseVersion: 0);

    remote.failNextWrites = 1;
    await sync.flush();
    final retryAt = sync.pending.first.notBefore!;
    expect(retryAt.isAfter(now), isTrue);

    final tooSoon = await sync.flush();
    expect(tooSoon.stopped, isTrue);
    expect(tooSoon.accepted, isEmpty, reason: '"b" does not jump the queue');

    now = retryAt;
    expect((await sync.flush()).accepted, {'a': 1, 'b': 1});
  });

  test('parks an operation after too many failures, then retries on demand',
      () async {
    final sync = engine(retry: const RetryPolicy(maxAttempts: 2));
    await sync.enqueueWrite('a', {'n': 1}, baseVersion: 0);

    remote.failNextWrites = 2;
    await sync.flush();
    now = now.add(const Duration(hours: 1));
    final report = await sync.flush();

    expect(report.parked.single.recordId, 'a');
    expect((await sync.flush()).accepted, isEmpty, reason: 'parked is skipped');

    await sync.retryParked();
    expect((await sync.flush()).accepted, {'a': 1});
  });

  test('a write on top of a deleted record is a conflict', () async {
    await remote.write('a', data: {'n': 1}, baseVersion: 0, opId: 'x');
    await remote.write('a', data: null, baseVersion: 1, opId: 'y'); // deleted

    final sync = engine();
    await sync.enqueueWrite('a', {'n': 2}, baseVersion: 1);
    final report = await sync.flush();

    expect(report.conflicts.single.server.isDeleted, isTrue);
    expect(sync.pending, isEmpty);
  });

  test('concurrent flush calls share one run', () async {
    final sync = engine();
    await sync.enqueueWrite('a', {'n': 1}, baseVersion: 0);

    final results = await Future.wait([sync.flush(), sync.flush()]);

    expect(identical(results[0], results[1]), isTrue);
    expect(remote.appliedWrites, 1);
  });
}
