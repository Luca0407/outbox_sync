import 'package:outbox_sync/outbox_sync.dart';
import 'package:test/test.dart';

import 'support/clock_based_server.dart';

/// Two devices share a repair job. Device A is online and marks the job as
/// delivered at 10:00. Device B was offline with the 9:00 copy and, at 10:30
/// by its own clock, adds a note. Then B reconnects.
void main() {
  final nine = DateTime(2026, 11, 24, 9);
  final ten = DateTime(2026, 11, 24, 10);
  final tenThirty = DateTime(2026, 11, 24, 10, 30);

  test('comparing device clocks silently loses the other device\'s edit', () {
    final server = ClockBasedServer()
      ..write('job-1', {'status': 'pending'}, modifiedAt: nine);

    // A, online, delivers the job.
    server.write('job-1', {'status': 'delivered'}, modifiedAt: ten);

    // B's edit was made on the 9:00 copy, but its timestamp is later.
    final applied = server.write(
      'job-1',
      {'status': 'pending', 'note': 'call the customer'},
      modifiedAt: tenThirty,
    );

    expect(applied, isTrue, reason: 'no conflict is flagged');
    expect(server.read('job-1')!['status'], 'pending',
        reason: '"delivered" is gone and nobody was told');
  });

  test('version-checked writes turn the same story into a conflict', () async {
    final remote = InMemoryRemote();
    await remote.write('job-1',
        data: {'status': 'pending'}, baseVersion: 0, opId: 'seed');

    final deviceA = SyncEngine(remote: remote, store: MemoryOutboxStore());
    final deviceB = SyncEngine(remote: remote, store: MemoryOutboxStore());

    // Both edits are made on version 1, the copy both devices had.
    await deviceB.enqueueWrite(
      'job-1',
      {'status': 'pending', 'note': 'call the customer'},
      baseVersion: 1,
    );
    await deviceA.enqueueWrite('job-1', {'status': 'delivered'},
        baseVersion: 1);

    final a = await deviceA.flush();
    expect(a.accepted, {'job-1': 2});

    final b = await deviceB.flush();
    expect(b.accepted, isEmpty);
    expect(b.conflicts.single.server.data, {'status': 'delivered'});
    expect(b.conflicts.single.localData!['note'], 'call the customer');
    expect((await remote.fetch('job-1'))!.data, {'status': 'delivered'},
        reason: 'nothing was overwritten');

    // Someone decides to keep B's note on top of the delivered job.
    await deviceB.keepLocal(ConflictReport(
      recordId: 'job-1',
      localData: {'status': 'delivered', 'note': 'call the customer'},
      server: b.conflicts.single.server,
    ));
    expect((await deviceB.flush()).accepted, {'job-1': 3});
  });
}
