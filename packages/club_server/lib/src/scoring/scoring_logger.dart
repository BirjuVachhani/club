import 'dart:io';

/// A logger for the scoring system that writes to both stdout and a file.
///
/// Log lines are appended to [logFilePath]. The file is kept to a maximum
/// of [_maxLines] lines by periodic truncation.
class ScoringLogger {
  ScoringLogger({required this.logFilePath});

  final String logFilePath;

  static const _maxLines = 1000;

  IOSink? _sink;

  /// Open the log file for appending.
  Future<void> open() async {
    final file = File(logFilePath);
    await file.parent.create(recursive: true);
    _sink = file.openWrite(mode: FileMode.append);
  }

  /// Log a line to both stdout and the file.
  void log(String message) {
    final timestamp = DateTime.now().toUtc().toIso8601String().substring(0, 19);
    final line = '$timestamp | $message';
    // ignore: avoid_print
    print('[scoring] $message');
    _sink?.writeln(line);
  }

  /// Flush the file sink.
  Future<void> flush() async {
    await _sink?.flush();
  }

  /// Read the last [count] lines from the log file.
  Future<List<String>> readLastLines([int count = 300]) async {
    await flush();
    final file = File(logFilePath);
    if (!file.existsSync()) return [];
    final lines = await file.readAsLines();
    if (lines.length <= count) return lines;
    return lines.sublist(lines.length - count);
  }

  /// Truncate the file to the last [_maxLines] lines if it has grown
  /// beyond 2x that limit. Called periodically to prevent unbounded growth.
  Future<void> truncateIfNeeded() async {
    await flush();
    final file = File(logFilePath);
    if (!file.existsSync()) return;
    final lines = await file.readAsLines();
    if (lines.length <= _maxLines * 2) return;
    final trimmed = lines.sublist(lines.length - _maxLines);
    await _sink?.close();
    await file.writeAsString('${trimmed.join('\n')}\n');
    _sink = file.openWrite(mode: FileMode.append);
  }

  /// Clear the log file contents (keeps the file, just empties it).
  Future<void> clear() async {
    await _sink?.close();
    final file = File(logFilePath);
    if (file.existsSync()) {
      await file.writeAsString('');
    }
    _sink = file.openWrite(mode: FileMode.append);
  }

  /// Close the logger.
  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}
