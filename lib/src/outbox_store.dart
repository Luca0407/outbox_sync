import 'dart:convert';
import 'dart:io';

import 'pending_op.dart';

/// Where the outbox is persisted, so pending changes survive a restart.
abstract interface class OutboxStore {
  Future<List<PendingOp>> load();

  Future<void> save(List<PendingOp> ops);
}

/// Keeps the outbox in memory. It still round-trips through JSON, so tests
/// catch anything that would not survive a real store.
class MemoryOutboxStore implements OutboxStore {
  String _json = '[]';

  @override
  Future<List<PendingOp>> load() async => _decode(_json);

  @override
  Future<void> save(List<PendingOp> ops) async => _json = _encode(ops);
}

/// Keeps the outbox in a JSON file.
///
/// Each save writes a temporary file and then renames it over the real one, so
/// a crash in the middle of a save leaves the previous outbox intact instead of
/// a half-written file.
class JsonFileOutboxStore implements OutboxStore {
  JsonFileOutboxStore(this.file);

  final File file;

  @override
  Future<List<PendingOp>> load() async {
    if (!await file.exists()) return [];
    return _decode(await file.readAsString());
  }

  @override
  Future<void> save(List<PendingOp> ops) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(_encode(ops), flush: true);
    await tmp.rename(file.path);
  }
}

String _encode(List<PendingOp> ops) =>
    jsonEncode([for (final op in ops) op.toJson()]);

List<PendingOp> _decode(String json) => [
      for (final item in jsonDecode(json) as List)
        PendingOp.fromJson((item as Map).cast<String, Object?>()),
    ];
