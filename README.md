# outbox_sync

A small, dependency-free outbox for offline-first Dart and Flutter apps. It keeps
local changes until the server confirms them, sends them in order, retries safely
after a bad connection, and turns concurrent edits into **conflicts** instead of
silent overwrites.

## Why this exists

I build Flutter apps for people who work with a poor connection: municipal
inspectors, drivers, shop counters. A common way to sync them is to write through
Firestore and decide who wins a concurrent edit by comparing each change's
modification time, taken from the device clock. That rule has a hole:

1. Device A and device B both have version 9:00 of a repair job.
2. A, online, marks the job as *delivered* at 10:00.
3. B, offline, adds a note at 10:30 (by its own clock) on its 9:00 copy.
4. B reconnects. Its timestamp is later, so the write goes through and
   *delivered* is gone. Nobody is told.

`test/lost_update_test.dart` reproduces exactly that, and then shows the same story
with this package, where B's write comes back as a conflict.

## How it works

```
 local change ──► outbox (persisted) ──► write(id, data, baseVersion, opId) ──► server
                     ▲                                │
                     └──── backoff + retry ◄── failure│
                                                      ├─► Accepted(version)
                                                      └─► Conflict(current)
```

- **The server owns the version.** Every record has a version that the server
  increments on each accepted write. A change says which version it was made on
  (`baseVersion`), and the server applies it only if that is still the current
  version (compare-and-set). Device clocks are never compared.
- **Retries are idempotent.** Every operation carries an `opId`. If the server
  applied a write but the answer was lost, the retry gets the same `Accepted`
  instead of creating a second write.
- **The outbox is durable and ordered.** Pending changes are saved after every step
  (`JsonFileOutboxStore` writes a temp file and renames it, so a crash never leaves
  a half-written outbox). Changes are sent in the order they were made.
- **Unsent changes are folded.** Editing a record twice before it is sent produces
  one write, based on the version the first edit saw. A change made after a record
  was already (maybe) sent is chained: it waits for the version the earlier write
  produces.
- **Failures back off.** Delays double up to a cap, with jitter so many devices do
  not retry at the same instant. After `maxAttempts` the operation is parked and
  reported; `retryParked()` gives it another set of attempts.

## Usage

```dart
final sync = SyncEngine(
  remote: myRemote, // your RemoteStore
  store: JsonFileOutboxStore(File('outbox.json')),
);
await sync.init(); // reload what was pending when the app closed

// The user edits a job that was at version 4 on this device.
await sync.enqueueWrite('job-17', {'status': 'delivered'}, baseVersion: 4);

final report = await sync.flush(); // call it on reconnect or on a timer
for (final conflict in report.conflicts) {
  // Show both versions. To keep this device's change:
  await sync.keepLocal(conflict);
  // To keep the server's, apply conflict.server locally instead.
}
```

## Implementing `RemoteStore`

The server side has to do two things inside one atomic step: check the version and
remember the `opId`. With Firestore, for example:

```dart
await firestore.runTransaction((tx) async {
  final applied = await tx.get(opsRef.doc(opId));
  if (applied.exists) return Accepted(applied['version']); // a retry

  final snap = await tx.get(recordsRef.doc(id));
  final current = snap.exists ? snap['version'] as int : 0;
  if (current != baseVersion) return Conflict(/* current record */);

  tx.set(recordsRef.doc(id), {...?data, 'version': current + 1, 'deleted': data == null});
  tx.set(opsRef.doc(opId), {'version': current + 1});
  return Accepted(current + 1);
});
```

Security rules (or the API) should also reject any write whose `version` is not
exactly the previous one plus one, so a client cannot skip the check.

## Known limits

- One record per operation. There are no multi-record transactions.
- One queue for everything: a failing operation holds back the ones after it,
  even for other records. That keeps the order simple to reason about.
- No automatic merge. A conflict goes back to the app; merging fields or asking a
  person is the app's decision.
- The server has to keep applied `opId`s for as long as a client might retry.
- `InMemoryRemote` and the JSON file store are for tests and small apps. A Flutter
  app would usually keep the outbox in SQLite next to its data.

## Running the tests

```bash
dart pub get
dart test
```
