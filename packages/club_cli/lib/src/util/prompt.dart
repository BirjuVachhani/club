/// Interactive prompts (confirmation + arrow-key picker) with CI-safe
/// fallbacks.
///
/// Mirrors the role of dart pub's `confirm`/`select` utilities
/// (https://github.com/dart-lang/pub/blob/master/lib/src/log.dart#L286 —
/// `confirm`).
///
/// All prompts gracefully degrade when stdin is not a terminal: instead of
/// blocking forever in CI, they throw [NonInteractiveError] so callers can
/// surface a clear "use --force or --server" message.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log.dart';

/// Thrown when an interactive prompt is requested but stdin is not a TTY.
class NonInteractiveError implements Exception {
  NonInteractiveError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Returns true if stdin is connected to an interactive terminal.
bool get isInteractive => stdin.hasTerminal && stdout.hasTerminal;

/// Returns true when the process is running inside a continuous-integration
/// environment. Checked against the conventions that Dart tooling, GitHub
/// Actions, Travis, CircleCI, and Buildkite all set — a shell variable
/// named `CI` / `CONTINUOUS_INTEGRATION` / `BUILD_NUMBER` being present
/// (non-empty) is the common signal. Matches `dart pub`'s `runningFromCI`.
///
/// When true, confirmation prompts are silently skipped (the automated job
/// already opted in by passing `--force` semantics through env detection).
bool get isCI {
  bool present(String k) {
    final v = Platform.environment[k];
    return v != null && v.isNotEmpty && v.toLowerCase() != 'false';
  }

  return present('CI') ||
      present('CONTINUOUS_INTEGRATION') ||
      present('BUILD_NUMBER');
}

// ── Confirmation prompt ─────────────────────────────────────────────────────

/// Ask the user a yes/no question. Returns true if confirmed.
///
/// In non-interactive environments throws [NonInteractiveError] so the
/// caller can decide whether to abort or proceed (e.g. when `--force` is
/// passed elsewhere).
Future<bool> confirm(String question, {bool defaultAnswer = false}) async {
  if (!isInteractive) {
    throw NonInteractiveError(
      'Cannot prompt for confirmation in a non-interactive shell. '
      'Pass --force to skip this prompt.',
    );
  }

  final hint = defaultAnswer ? '[Y/n]' : '[y/N]';
  stdout.write('$question $hint ');
  final line = stdin.readLineSync(encoding: utf8)?.trim().toLowerCase() ?? '';
  if (line.isEmpty) return defaultAnswer;
  return line == 'y' || line == 'yes';
}

// ── Arrow-key picker ────────────────────────────────────────────────────────

/// A single option in a [pick] menu.
class PickOption<T> {
  PickOption({required this.label, required this.value, this.detail});
  final String label;
  final T value;
  final String? detail;
}

/// Show an arrow-key driven menu and return the chosen option's value.
///
/// Behaviour:
/// - If stdin is a TTY: render a live menu using ANSI escapes; use
///   ↑/↓ (or k/j) to move, Enter to select, q/Esc to cancel.
/// - If stdin is NOT a TTY: throw [NonInteractiveError] so the caller can
///   show a CI-friendly error.
///
/// Hand-rolled to avoid a dependency that pulls in `dart:ffi` or fails in
/// CI environments. The implementation deliberately mirrors the small
/// "select" helper used by some shipped Dart tools.
Future<T> pick<T>(String prompt, List<PickOption<T>> options) async {
  if (options.isEmpty) {
    throw ArgumentError('pick() called with no options.');
  }
  if (options.length == 1) return options.first.value;

  if (!isInteractive) {
    throw NonInteractiveError(
      'Multiple options available, but cannot prompt in a non-interactive '
      'shell. Specify --server <url> explicitly to choose.',
    );
  }

  var selected = 0;

  // Save terminal state
  final wasEchoMode = stdin.echoMode;
  final wasLineMode = stdin.lineMode;
  stdin.echoMode = false;
  stdin.lineMode = false;

  void render({bool first = false}) {
    if (!first) {
      // Move cursor up over previous render (prompt + options + footer)
      stdout.write('\x1b[${options.length + 2}A');
    }
    stdout.writeln('\x1b[2K$prompt');
    for (var i = 0; i < options.length; i++) {
      final opt = options[i];
      final marker = i == selected ? cyan('❯ ') : '  ';
      final label = i == selected ? bold(opt.label) : opt.label;
      final detail = opt.detail != null ? gray('  ${opt.detail}') : '';
      stdout.writeln('\x1b[2K$marker$label$detail');
    }
    stdout.writeln(
      '\x1b[2K${gray('  Use ↑/↓ to move, Enter to select, q to cancel.')}',
    );
  }

  render(first: true);

  final completer = Completer<T>();
  late StreamSubscription<List<int>> sub;

  void cleanup() {
    sub.cancel();
    stdin.echoMode = wasEchoMode;
    stdin.lineMode = wasLineMode;
    // Hide cursor restoration noise — just drop a blank line.
    stdout.writeln();
  }

  sub = stdin.listen((bytes) {
    // Handle multi-byte sequences (arrow keys = ESC [ A/B)
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      // ESC sequence
      if (b == 0x1b && i + 2 < bytes.length && bytes[i + 1] == 0x5b) {
        final code = bytes[i + 2];
        if (code == 0x41) {
          // Up
          selected = (selected - 1 + options.length) % options.length;
        } else if (code == 0x42) {
          // Down
          selected = (selected + 1) % options.length;
        }
        i += 2;
        render();
        continue;
      }
      // ESC alone or 'q' → cancel
      if (b == 0x1b || b == 0x71) {
        cleanup();
        completer.completeError(
          NonInteractiveError('Selection cancelled by user.'),
        );
        return;
      }
      // Enter (LF or CR)
      if (b == 0x0a || b == 0x0d) {
        cleanup();
        completer.complete(options[selected].value);
        return;
      }
      // Vim-style: 'k' (up), 'j' (down)
      if (b == 0x6b) {
        selected = (selected - 1 + options.length) % options.length;
        render();
      } else if (b == 0x6a) {
        selected = (selected + 1) % options.length;
        render();
      }
    }
  });

  return completer.future;
}
