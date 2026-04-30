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
///
/// The arrow-key picker uses **synchronous** stdin reads
/// (`stdin.readByteSync`) rather than `stdin.listen`. Subscribing to
/// `stdin` consumes its single-subscription stream — once cancelled, the
/// underlying file descriptor lands in a half-closed state where
/// `stdin.hasTerminal` reports `false`, breaking every subsequent
/// `confirm()` call. Sync reads dodge that entirely.
library;

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

  return _runMenu<T>(
    prompt: prompt,
    optionCount: options.length,
    nonInteractiveMessage:
        'Multiple options available, but cannot prompt in a non-interactive '
        'shell. Specify --server <url> explicitly to choose.',
    footer: 'Use ↑/↓ to move, Enter to select, q to cancel.',
    lineFor: (i, cursor) {
      final opt = options[i];
      final marker = i == cursor ? cyan('❯ ') : '  ';
      final label = i == cursor ? bold(opt.label) : opt.label;
      final detailText = opt.detail != null ? gray('  ${opt.detail}') : '';
      return '$marker$label$detailText';
    },
    onEnter: (cursor) => _EnterAction.complete(options[cursor].value),
  );
}

/// Show an arrow-key driven menu allowing multiple selections.
///
/// Like [pick], but Space toggles the current item and Enter confirms the
/// current set. Returns the values of all toggled-on options.
///
/// When fewer than [minSelected] items are toggled and the user presses
/// Enter, a status hint is displayed and the prompt stays open.
///
/// Throws [NonInteractiveError] in non-TTY environments — callers should
/// require explicit positional args / flags in that case.
Future<List<T>> pickMulti<T>(
  String prompt,
  List<PickOption<T>> options, {
  int minSelected = 1,
}) async {
  if (options.isEmpty) {
    throw ArgumentError('pickMulti() called with no options.');
  }

  final toggled = List<bool>.filled(options.length, false);

  return _runMenu<List<T>>(
    prompt: prompt,
    optionCount: options.length,
    nonInteractiveMessage:
        'Multiple options available, but cannot prompt in a non-interactive '
        'shell. Pass package names as positional arguments to bypass the '
        'interactive picker.',
    footer:
        '↑/↓ to move, Space to toggle, Enter to confirm, q to cancel.',
    lineFor: (i, cursor) {
      final opt = options[i];
      final pointer = i == cursor ? cyan('❯ ') : '  ';
      final box = toggled[i] ? green('[x] ') : '[ ] ';
      final label = i == cursor ? bold(opt.label) : opt.label;
      final detailText = opt.detail != null ? gray('  ${opt.detail}') : '';
      return '$pointer$box$label$detailText';
    },
    onSpace: (cursor) {
      toggled[cursor] = !toggled[cursor];
    },
    onEnter: (cursor) {
      final picked = <T>[
        for (var j = 0; j < options.length; j++)
          if (toggled[j]) options[j].value,
      ];
      if (picked.length < minSelected) {
        return _EnterAction.refuse(
          'Select at least $minSelected '
          '${minSelected == 1 ? 'item' : 'items'}.',
        );
      }
      return _EnterAction.complete(picked);
    },
  );
}

// ── Shared menu loop ────────────────────────────────────────────────────────

/// Outcome of an Enter press, returned from [_runMenu]'s `onEnter` callback.
class _EnterAction<R> {
  _EnterAction.complete(R this.value)
    : refuse = false,
      refusalMessage = null;
  _EnterAction.refuse(String message)
    : value = null,
      refuse = true,
      refusalMessage = message;
  final R? value;
  final bool refuse;
  final String? refusalMessage;
}

/// Renders a live menu and dispatches keyboard events. Shared by [pick] and
/// [pickMulti].
///
/// The menu state (which row is highlighted, which rows are toggled, etc.)
/// lives in the caller's closures — this function is intentionally state-
/// less so a single render loop can host any selector built on top of it.
///
/// Wraps the synchronous [_menuLoop] in raw-mode setup/teardown. Restoration
/// runs in `finally` so the tty is always returned to its prior state, even
/// when [_menuLoop] throws (cancellation, stdin EOF).
Future<R> _runMenu<R>({
  required String prompt,
  required int optionCount,
  required String nonInteractiveMessage,
  required String footer,
  required String Function(int i, int cursor) lineFor,
  required _EnterAction<R> Function(int cursor) onEnter,
  void Function(int cursor)? onSpace,
}) async {
  if (!isInteractive) {
    throw NonInteractiveError(nonInteractiveMessage);
  }

  final wasEchoMode = stdin.echoMode;
  final wasLineMode = stdin.lineMode;
  stdin.echoMode = false;
  stdin.lineMode = false;

  try {
    return _menuLoop<R>(
      prompt: prompt,
      optionCount: optionCount,
      footer: footer,
      lineFor: lineFor,
      onEnter: onEnter,
      onSpace: onSpace,
    );
  } finally {
    // Best-effort restore. A closed-stdin StdinException doesn't matter —
    // the parent shell resets the tty when it regains control.
    try {
      stdin.echoMode = wasEchoMode;
    } on StdinException {/* ignore */}
    try {
      stdin.lineMode = wasLineMode;
    } on StdinException {/* ignore */}
    try {
      stdout.writeln();
    } on StdoutException {/* ignore */}
  }
}

/// Body of [_runMenu], factored out so terminal-state restoration runs in
/// a single `finally` regardless of how the loop exits (return, throw).
///
/// All input is read synchronously via [Stdin.readByteSync]. Synchronous
/// reads block the event loop while the user types, which is exactly what
/// we want for an interactive picker — there is nothing else for the CLI
/// to do until they hit Enter.
R _menuLoop<R>({
  required String prompt,
  required int optionCount,
  required String footer,
  required String Function(int i, int cursor) lineFor,
  required _EnterAction<R> Function(int cursor) onEnter,
  void Function(int cursor)? onSpace,
}) {
  var cursor = 0;
  String? statusMessage;
  var lastLineCount = 0;

  void render({bool first = false}) {
    if (!first) {
      stdout.write('\x1b[${lastLineCount}A');
    }
    stdout.writeln('\x1b[2K$prompt');
    for (var i = 0; i < optionCount; i++) {
      stdout.writeln('\x1b[2K${lineFor(i, cursor)}');
    }
    stdout.writeln('\x1b[2K${gray('  $footer')}');
    if (statusMessage != null) {
      stdout.writeln('\x1b[2K${yellow('  $statusMessage')}');
      lastLineCount = optionCount + 3;
    } else {
      lastLineCount = optionCount + 2;
    }
  }

  render(first: true);

  while (true) {
    final b = stdin.readByteSync();
    if (b == -1) {
      throw NonInteractiveError('stdin closed before a selection was made.');
    }

    // Arrow keys: most terminals deliver `ESC [ A/B` as 3 bytes back-to-
    // back when the user presses an arrow. Read the next two synchronously
    // — they are already in the kernel buffer when we get here.
    //
    // Lone ESC: the user's `readByteSync` after the lone 0x1b will block
    // waiting for the next key. That is acceptable; the documented cancel
    // key is `q`, so lone ESC is a degenerate case.
    if (b == 0x1b) {
      final b2 = stdin.readByteSync();
      if (b2 == 0x5b) {
        final b3 = stdin.readByteSync();
        if (b3 == 0x41) {
          cursor = (cursor - 1 + optionCount) % optionCount;
          statusMessage = null;
          render();
          continue;
        }
        if (b3 == 0x42) {
          cursor = (cursor + 1) % optionCount;
          statusMessage = null;
          render();
          continue;
        }
        // Some other CSI sequence (Home/End/etc.) — ignore.
        continue;
      }
      // ESC followed by anything else: treat the ESC as a cancel and
      // discard the trailing byte rather than mis-interpreting it.
      throw NonInteractiveError('Selection cancelled by user.');
    }

    // 'q' → cancel.
    if (b == 0x71) {
      throw NonInteractiveError('Selection cancelled by user.');
    }

    // Space → caller-defined toggle. No-op for single-select pick().
    if (b == 0x20) {
      if (onSpace != null) {
        onSpace(cursor);
        statusMessage = null;
        render();
      }
      continue;
    }

    // Enter (LF or CR) → confirm.
    if (b == 0x0a || b == 0x0d) {
      final action = onEnter(cursor);
      if (action.refuse) {
        statusMessage = action.refusalMessage;
        render();
        continue;
      }
      return action.value as R;
    }

    // Vim-style: 'k' / 'j'.
    if (b == 0x6b) {
      cursor = (cursor - 1 + optionCount) % optionCount;
      statusMessage = null;
      render();
    } else if (b == 0x6a) {
      cursor = (cursor + 1) % optionCount;
      statusMessage = null;
      render();
    }
  }
}
