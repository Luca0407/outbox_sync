/// A server that resolves concurrent writes by comparing the device clocks,
/// the way many offline-first apps start out: a write is rejected only if the
/// server's copy has a later modification time.
///
/// It is not part of the package. It exists so the tests can show the
/// problem the package solves.
class ClockBasedServer {
  final _records =
      <String, ({Map<String, Object?> data, DateTime modifiedAt})>{};

  Map<String, Object?>? read(String id) => _records[id]?.data;

  /// Returns `true` if the write was applied, `false` if it was flagged as a
  /// conflict because the server's copy is newer.
  bool write(String id, Map<String, Object?> data,
      {required DateTime modifiedAt}) {
    final current = _records[id];
    if (current != null && current.modifiedAt.isAfter(modifiedAt)) return false;
    _records[id] = (data: data, modifiedAt: modifiedAt);
    return true;
  }
}
