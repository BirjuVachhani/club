/// Process exit codes shared by `club` command runners.
///
/// Values match dart pub and traditional Unix conventions so CI integrations
/// that inspect `$?` behave the same regardless of which club command ran.
library;

class ExitCodes {
  static const int success = 0;
  static const int data = 65;
  static const int noInput = 66;
  static const int unavailable = 69;
  static const int software = 70;
  static const int config = 78;
}
