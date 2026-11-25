import 'dart:math';

import 'outbox_store.dart';
import 'pending_op.dart';
import 'remote_store.dart';
import 'retry_policy.dart';

/// A change the server rejected because someone else changed the record first.
class ConflictReport {
  const ConflictReport({
    required this.recordId,
    required this.localData,
    required this.server,
  });

  final String recordId;

  /// What this device tried to write (`null` if it tried to delete it).
  final Map<String, Object?>? localData;

  /// What the server has now.
  final VersionedRecord server;
}

/// What happened during one [SyncEngine.flush].
class FlushReport {
  const FlushReport({
    required this.accepted,
    required this.conflicts,
    required this.parked,
    required this.stopped,
  });

  /// Records written, with their new server version.
  final Map<String, int> accepted;

  /// Changes rejected because the record changed on the server.
  final List<ConflictReport> conflicts;

  /// Operations that failed too many times and are waiting for a manual retry.
  final List<PendingOp> parked;

  /// `true` if the flush stopped early because of a failure or a backoff.
  final bool stopped;
}

/// Sends local changes to a [RemoteStore], in order, without losing them and
/// without silently overwriting changes made by other devices.
class SyncEngine {
  SyncEngine({
    required this.remote,
    required this.store,
    this.retry = const RetryPolicy(),
    DateTime Function()? now,
    Random? random,
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random();

  final RemoteStore remote;
  final OutboxStore store;
  final RetryPolicy retry;
  final DateTime Function() _now;
  final Random _random;
  final _ops = <PendingOp>[];
  final _idRandom = Random.secure();
  String? _inFlightOpId;
  Future<FlushReport>? _running;

  /// Loads the operations that were still pending when the app last closed.
  Future<void> init() async {
    _ops
      ..clear()
      ..addAll(await store.load());
  }

  List<PendingOp> get pending => List.unmodifiable(_ops);

  /// Queues a change made on top of [baseVersion], the version of the record
  /// this device last got from the server (0 for a new record).
  Future<void> enqueueWrite(
    String recordId,
    Map<String, Object?> data, {
    required int baseVersion,
  }) =>
      _enqueue(recordId, Map.of(data), baseVersion);

  /// Queues a deletion made on top of [baseVersion].
  Future<void> enqueueDelete(String recordId, {required int baseVersion}) =>
      _enqueue(recordId, null, baseVersion);

  /// Resolves a conflict by keeping this device's change: it is sent again on
  /// top of the server's current version. To keep the server's version
  /// instead, apply `conflict.server` locally; nothing needs to be sent.
  Future<void> keepLocal(ConflictReport conflict) =>
      _enqueue(conflict.recordId, conflict.localData, conflict.server.version);

  /// Gives parked operations a fresh set of attempts.
  Future<void> retryParked() async {
    for (final op in _ops.where((op) => op.parked)) {
      op
        ..parked = false
        ..attempts = 0
        ..notBefore = null;
    }
    await store.save(_ops);
  }

  Future<void> _enqueue(
    String recordId,
    Map<String, Object?>? data,
    int baseVersion,
  ) async {
    final last = _ops.lastWhereOrNull((op) => op.recordId == recordId);
    if (last != null &&
        last.attempts == 0 &&
        !last.parked &&
        last.opId != _inFlightOpId) {
      // Never sent: fold the new change into it. It keeps the version the
      // first change was based on, which is what the user actually saw.
      last.data = data;
    } else {
      _ops.add(PendingOp(
        opId: _newOpId(),
        recordId: recordId,
        data: data,
        // If an earlier change of this record may already be on the server,
        // this one builds on whatever version that change produces.
        baseVersion: last == null ? baseVersion : null,
      ));
    }
    await store.save(_ops);
  }

  /// Sends pending operations in order until one fails, is backing off, or
  /// the outbox is empty. Calls made while a flush is running get its result.
  Future<FlushReport> flush() =>
      _running ??= _flush().whenComplete(() => _running = null);

  Future<FlushReport> _flush() async {
    final accepted = <String, int>{};
    final conflicts = <ConflictReport>[];
    var stopped = false;

    var i = 0;
    while (i < _ops.length) {
      final op = _ops[i];
      // Parked, or waiting for the version an earlier operation will produce.
      if (op.parked || op.baseVersion == null) {
        i++;
        continue;
      }
      final notBefore = op.notBefore;
      if (notBefore != null && _now().isBefore(notBefore)) {
        stopped = true;
        break;
      }

      final WriteResult result;
      _inFlightOpId = op.opId; // a change arriving now must not be folded in
      try {
        result = await remote.write(
          op.recordId,
          data: op.data,
          baseVersion: op.baseVersion!,
          opId: op.opId,
        );
      } on RemoteUnavailable {
        op.attempts++;
        if (op.attempts >= retry.maxAttempts) {
          op.parked = true;
        } else {
          op.notBefore = _now().add(retry.delayAfter(op.attempts, _random));
        }
        await store.save(_ops);
        stopped = true;
        break;
      } finally {
        _inFlightOpId = null;
      }

      switch (result) {
        case Accepted(:final version):
          accepted[op.recordId] = version;
          _ops.removeAt(i);
          final next = _ops.skip(i).firstWhereOrNull(
                (other) => other.recordId == op.recordId,
              );
          next?.baseVersion = version;
        case Conflict(:final current):
          conflicts.add(ConflictReport(
            recordId: op.recordId,
            localData: _ops.lastWhere((o) => o.recordId == op.recordId).data,
            server: current,
          ));
          // A person (or the app) decides what to keep, so this record's
          // pending changes leave the outbox; see [keepLocal].
          _ops.removeWhere((o) => o.recordId == op.recordId);
      }
      await store.save(_ops);
    }

    return FlushReport(
      accepted: accepted,
      conflicts: conflicts,
      parked: [
        for (final op in _ops)
          if (op.parked) op
      ],
      stopped: stopped,
    );
  }

  String _newOpId() => List.generate(
        16,
        (_) => _idRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
}

extension<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }

  T? lastWhereOrNull(bool Function(T) test) {
    T? found;
    for (final item in this) {
      if (test(item)) found = item;
    }
    return found;
  }
}
