import 'dart:math';

/// How long to wait between failed attempts, and when to give up.
class RetryPolicy {
  const RetryPolicy({
    this.baseDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(minutes: 5),
    this.maxAttempts = 8,
  });

  final Duration baseDelay;
  final Duration maxDelay;

  /// After this many failed attempts the operation is parked.
  final int maxAttempts;

  /// Delay after the [attempt]-th failure (1-based).
  ///
  /// It doubles with each failure up to [maxDelay]. Half of it is fixed and
  /// half random ("equal jitter"), so many devices coming back online at once
  /// do not retry in lockstep.
  Duration delayAfter(int attempt, Random random) {
    final exponential = baseDelay * pow(2, (attempt - 1).clamp(0, 20)).toInt();
    final capped = exponential > maxDelay ? maxDelay : exponential;
    final half = capped.inMilliseconds ~/ 2;
    return Duration(milliseconds: half + random.nextInt(half + 1));
  }
}
