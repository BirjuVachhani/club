import 'package:cron/cron.dart';
import 'package:logging/logging.dart';

/// A single scheduled job.
///
/// `schedule` is a standard 5-field cron expression (minute hour day
/// month weekday). `run` is the work to perform on each firing. The
/// scheduler wraps the call in a try/catch so one task failing never
/// starves the others.
class ScheduledTask {
  const ScheduledTask({
    required this.name,
    required this.schedule,
    required this.run,
  });

  /// Human-readable task name, shown in log lines
  /// (e.g. `publisher-verifications:sweep`).
  final String name;

  /// Standard 5-field cron expression.
  final String schedule;

  /// The work to perform. Must be re-entrant-safe — if a previous
  /// firing is still running when the next one is due, both will
  /// execute concurrently.
  final Future<void> Function() run;
}

/// In-process cron scheduler.
///
/// Owns a single [Cron] instance and runs every registered [ScheduledTask]
/// against it on [start]. Runs in the same isolate as the HTTP server —
/// no external systemd / k8s cron required; when the server dies, so do
/// the schedules.
///
/// The scheduler intentionally doesn't depend on any domain services. It
/// takes opaque callbacks so services stay unaware of *when* they run —
/// they just expose the right operations (`sweep()`,
/// `deleteExpiredX()`, etc.) and the caller wires one into a schedule.
class Scheduler {
  Scheduler(this._tasks, {Logger? logger})
    : _logger = logger ?? Logger('Scheduler');

  final List<ScheduledTask> _tasks;
  final Logger _logger;
  final Cron _cron = Cron();
  bool _started = false;

  /// Parse all cron expressions and register callbacks. Safe to call
  /// more than once; subsequent calls are a no-op.
  void start() {
    if (_started) return;
    _started = true;

    for (final task in _tasks) {
      _cron.schedule(Schedule.parse(task.schedule), () async {
        try {
          await task.run();
        } catch (e, st) {
          // Scheduled work is "fire and forget" — failures in one task
          // must not prevent the next firing or other tasks from running.
          _logger.warning(
            'Scheduled task "${task.name}" failed',
            e,
            st,
          );
        }
      });
      _logger.fine(
        'Registered scheduled task "${task.name}" (${task.schedule})',
      );
    }
  }

  /// Stop the scheduler. Any in-flight task invocations complete; no
  /// new firings will occur. Idempotent.
  Future<void> close() async {
    if (!_started) return;
    await _cron.close();
  }
}
