import 'dart:async';

/// Safety watchdog that monitors incoming UDP packet timestamps and automatically
/// triggers [onTimeout] (which releases all gamepad buttons and sticks) if no
/// valid packet arrives within [timeout].
class InputWatchdog {
  final Duration timeout;
  final void Function() onTimeout;

  Timer? _timer;
  bool _isTimedOut = false;

  InputWatchdog({
    this.timeout = const Duration(milliseconds: 200),
    required this.onTimeout,
  });

  bool get isTimedOut => _isTimedOut;

  /// Feeds the watchdog on every valid `INPUT` or `HEARTBEAT` packet.
  void feed() {
    _isTimedOut = false;
    _timer?.cancel();
    _timer = Timer(timeout, () {
      _isTimedOut = true;
      onTimeout();
    });
  }

  /// Stops the watchdog timer cleanly.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _isTimedOut = false;
  }
}
