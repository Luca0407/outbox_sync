/// A record as the server stores it.
///
/// [version] is 0 while the record does not exist, becomes 1 on the first
/// accepted write and grows by one on every accepted write after that. The
/// server assigns it, so it does not depend on any device's clock.
class VersionedRecord {
  const VersionedRecord({required this.id, required this.version, this.data});

  final String id;
  final int version;

  /// The record's fields, or `null` when the record was deleted (a tombstone)
  /// or never existed.
  final Map<String, Object?>? data;

  bool get isDeleted => data == null;

  @override
  String toString() =>
      'VersionedRecord($id, v$version, ${isDeleted ? 'deleted' : data})';
}

/// Outcome of a version-checked write.
sealed class WriteResult {
  const WriteResult();
}

/// The write was applied and the record now has [version].
final class Accepted extends WriteResult {
  const Accepted(this.version);

  final int version;
}

/// The write was rejected: the server has a version the writer never saw.
final class Conflict extends WriteResult {
  const Conflict(this.current);

  /// What the server has now.
  final VersionedRecord current;
}

/// Thrown by a [RemoteStore] when the request failed or its answer was lost.
///
/// The write may or may not have been applied, which is why every write
/// carries an operation id: sending it again is safe.
class RemoteUnavailable implements Exception {
  const RemoteUnavailable([this.message = 'remote unavailable']);

  final String message;

  @override
  String toString() => 'RemoteUnavailable: $message';
}

/// A server-side store that only accepts a write when the writer saw the
/// latest version of the record (compare-and-set).
///
/// It can be implemented on top of a Firestore transaction, a REST API with
/// `If-Match`, or SQL with `UPDATE ... WHERE version = ?`. See the README.
abstract interface class RemoteStore {
  Future<VersionedRecord?> fetch(String id);

  /// Writes [data], or a tombstone when [data] is `null`, only if the record's
  /// current version equals [baseVersion].
  ///
  /// [opId] identifies the operation: if it was already applied (for example,
  /// the answer was lost and the client retries), the store must return the
  /// same [Accepted] instead of applying it twice.
  Future<WriteResult> write(
    String id, {
    required Map<String, Object?>? data,
    required int baseVersion,
    required String opId,
  });
}
