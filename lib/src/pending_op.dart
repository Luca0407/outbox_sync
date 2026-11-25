/// A local change waiting to be sent to the server.
class PendingOp {
  PendingOp({
    required this.opId,
    required this.recordId,
    required this.data,
    required this.baseVersion,
    this.attempts = 0,
    this.notBefore,
    this.parked = false,
  });

  factory PendingOp.fromJson(Map<String, Object?> json) => PendingOp(
        opId: json['opId']! as String,
        recordId: json['recordId']! as String,
        data: (json['data'] as Map?)?.cast<String, Object?>(),
        baseVersion: json['baseVersion'] as int?,
        attempts: json['attempts']! as int,
        notBefore: json['notBefore'] == null
            ? null
            : DateTime.parse(json['notBefore']! as String),
        parked: json['parked']! as bool,
      );

  /// Sent with every attempt so the server can recognize a retry.
  final String opId;
  final String recordId;

  /// New content of the record, or `null` to delete it.
  Map<String, Object?>? data;

  /// Version of the record this change was made on.
  ///
  /// `null` means "the version produced by the previous operation on the same
  /// record", which is only known once that operation is accepted.
  int? baseVersion;

  /// Failed attempts so far.
  int attempts;

  /// Do not send before this time (backoff after a failure).
  DateTime? notBefore;

  /// Gave up after too many failed attempts; waits for [SyncEngine.retryParked].
  bool parked;

  bool get isDelete => data == null;

  Map<String, Object?> toJson() => {
        'opId': opId,
        'recordId': recordId,
        'data': data,
        'baseVersion': baseVersion,
        'attempts': attempts,
        'notBefore': notBefore?.toIso8601String(),
        'parked': parked,
      };
}
