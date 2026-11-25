import 'remote_store.dart';

/// A [RemoteStore] kept in memory, for tests and examples.
///
/// It follows the same rules a real backend has to follow: compare-and-set on
/// the version, and operation ids remembered so retries are not applied twice.
/// It can also simulate a bad connection.
class InMemoryRemote implements RemoteStore {
  final _records = <String, VersionedRecord>{};
  final _appliedOps = <String, int>{}; // opId -> version it produced

  /// How many upcoming writes fail before reaching the server.
  int failNextWrites = 0;

  /// How many upcoming writes are applied but lose their answer on the way back.
  int loseNextResponses = 0;

  /// Number of writes actually applied (retries of the same operation excluded).
  int get appliedWrites => _appliedOps.length;

  @override
  Future<VersionedRecord?> fetch(String id) async => _records[id];

  @override
  Future<WriteResult> write(
    String id, {
    required Map<String, Object?>? data,
    required int baseVersion,
    required String opId,
  }) async {
    if (failNextWrites > 0) {
      failNextWrites--;
      throw const RemoteUnavailable('request failed');
    }
    final result = _apply(id, data, baseVersion, opId);
    if (loseNextResponses > 0) {
      loseNextResponses--;
      throw const RemoteUnavailable('response lost');
    }
    return result;
  }

  WriteResult _apply(
    String id,
    Map<String, Object?>? data,
    int baseVersion,
    String opId,
  ) {
    final already = _appliedOps[opId];
    if (already != null) return Accepted(already); // a retry, not a new write

    final current = _records[id] ?? VersionedRecord(id: id, version: 0);
    if (current.version != baseVersion) return Conflict(current);

    final next = VersionedRecord(
      id: id,
      version: current.version + 1,
      data: data == null ? null : Map.unmodifiable(data),
    );
    _records[id] = next;
    _appliedOps[opId] = next.version;
    return Accepted(next.version);
  }
}
