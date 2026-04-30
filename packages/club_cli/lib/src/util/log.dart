/// Logging primitives used by the publish flow.
///
/// Mirrors the role of dart pub's `log` library
/// (https://github.com/dart-lang/pub/blob/master/lib/src/log.dart) but
/// scaled down to what the club CLI needs.
///
/// All output goes through these helpers so we can:
/// - Disable colors when the terminal does not support them or when running
///   under CI (`NO_COLOR` env var, non-TTY stdout).
/// - Route warnings/errors to stderr while keeping informational output on
///   stdout.
library;

import 'dart:io';

import 'package:ansicolor/ansicolor.dart';

/// Whether ANSI color codes should be emitted.
///
/// Disabled automatically when stdout is not a terminal (typical for CI),
/// or when the `NO_COLOR` env var is set
/// (https://no-color.org/), or when `TERM=dumb`.
bool get colorsEnabled {
  if (Platform.environment.containsKey('NO_COLOR')) return false;
  if (Platform.environment['TERM'] == 'dumb') return false;
  if (!stdout.hasTerminal) return false;
  if (!stderr.hasTerminal) return false;
  return true;
}

/// Configure ansicolor based on the current environment.
///
/// Must be called once at startup (typically from `club.dart`).
void configureColors() {
  ansiColorDisabled = !colorsEnabled;
}

// ── Color pens ──────────────────────────────────────────────────────────────

final _red = AnsiPen()..red(bold: true);
final _yellow = AnsiPen()..yellow(bold: true);
final _green = AnsiPen()..green(bold: true);
final _cyan = AnsiPen()..cyan();
final _gray = AnsiPen()..gray(level: 0.6);
final _bold = AnsiPen()..white(bold: true);

String red(String s) => _red(s);
String yellow(String s) => _yellow(s);
String green(String s) => _green(s);
String cyan(String s) => _cyan(s);
String gray(String s) => _gray(s);
String bold(String s) => _bold(s);

// ── Output helpers ──────────────────────────────────────────────────────────

/// Print an informational message to stdout.
void info(String message) => stdout.writeln(message);

/// Print an indented detail line to stdout.
void detail(String message) => stdout.writeln('   $message');

/// Print a success message to stdout.
void success(String message) => stdout.writeln(green('✓ ') + message);

/// Print a warning to stderr.
void warning(String message) => stderr.writeln(yellow('⚠ ') + message);

/// Print an error to stderr.
void error(String message) => stderr.writeln(red('✗ ') + message);

/// Print a hint to stdout.
void hint(String message) => stdout.writeln(cyan('● ') + message);

/// Print a section heading with a horizontal rule.
void heading(String message) {
  stdout.writeln();
  final rule = '─' * (60 - message.length).clamp(4, 60);
  stdout.writeln('${bold(message)} ${gray(rule)}');
}

/// Print a bordered box around [lines].
///
/// Each line is padded to produce a uniform width. The box uses Unicode
/// box-drawing characters and is safe for CI logs (no ANSI escapes inside
/// the border itself — only content is colored).
void box(List<String> lines) {
  // Strip ANSI codes to measure visible width.
  final visible = lines.map(_visibleLength).toList();
  final maxLen = visible.fold<int>(0, (m, l) => l > m ? l : m);
  final width = maxLen + 4; // 2 padding + 2 border chars

  stdout.writeln();
  stdout.writeln('  ${gray('┌${'─' * width}┐')}');
  for (var i = 0; i < lines.length; i++) {
    final pad = ' ' * (maxLen - visible[i]);
    stdout.writeln('  ${gray('│')}  ${lines[i]}$pad  ${gray('│')}');
  }
  stdout.writeln('  ${gray('└${'─' * width}┘')}');
}

/// Print a bordered table with a header row and data rows.
///
/// Column widths adapt to the widest cell in each column (ANSI codes are
/// stripped when measuring). Header cells are bolded automatically.
void table(List<String> header, List<List<String>> rows) {
  final all = [header, ...rows];
  final cols = header.length;
  final widths = List<int>.filled(cols, 0);
  for (final row in all) {
    for (var c = 0; c < cols; c++) {
      final w = _visibleLength(row[c]);
      if (w > widths[c]) widths[c] = w;
    }
  }

  String pad(String cell, int width) =>
      cell + ' ' * (width - _visibleLength(cell));

  final top = '┌${widths.map((w) => '─' * (w + 2)).join('┬')}┐';
  final sep = '├${widths.map((w) => '─' * (w + 2)).join('┼')}┤';
  final bot = '└${widths.map((w) => '─' * (w + 2)).join('┴')}┘';

  stdout.writeln();
  stdout.writeln('  ${gray(top)}');
  final headerCells = [
    for (var c = 0; c < cols; c++) pad(bold(header[c]), widths[c]),
  ];
  stdout.writeln(
    '  ${gray('│')} ${headerCells.join(' ${gray('│')} ')} ${gray('│')}',
  );
  stdout.writeln('  ${gray(sep)}');
  for (final row in rows) {
    final cells = [
      for (var c = 0; c < cols; c++) pad(row[c], widths[c]),
    ];
    stdout.writeln(
      '  ${gray('│')} ${cells.join(' ${gray('│')} ')} ${gray('│')}',
    );
  }
  stdout.writeln('  ${gray(bot)}');
}

int _visibleLength(String s) =>
    s.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '').length;

/// Format a [Duration] as a short human-readable string.
String formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
  if (d.inSeconds < 60) {
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  final mins = d.inMinutes;
  final secs = d.inSeconds % 60;
  return '${mins}m ${secs}s';
}
