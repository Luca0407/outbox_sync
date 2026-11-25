import 'package:outbox_sync/outbox_sync.dart';

/// Two devices edit the same record; the second one gets a conflict instead of
/// overwriting the first.
Future<void> main() async {
  final remote = InMemoryRemote();
  final phone = SyncEngine(remote: remote, store: MemoryOutboxStore());
  final desktop = SyncEngine(remote: remote, store: MemoryOutboxStore());

  await phone.enqueueWrite('job-1', {'status': 'pending'}, baseVersion: 0);
  print('phone: ${(await phone.flush()).accepted}'); // {job-1: 1}

  // Both devices now edit version 1.
  await phone.enqueueWrite('job-1', {'status': 'delivered'}, baseVersion: 1);
  await desktop.enqueueWrite('job-1', {'status': 'cancelled'}, baseVersion: 1);

  print('phone: ${(await phone.flush()).accepted}'); // {job-1: 2}
  final report = await desktop.flush();
  print('desktop conflict, server has: ${report.conflicts.single.server}');
}
