/// Validates Dart package names.
///
/// Rules (from pub.dev):
/// - Lowercase letters, digits, and underscores only
/// - Must start with a letter
/// - 1-64 characters
/// - Cannot be a Dart reserved word
abstract final class PackageNameValidator {
  static final _validPattern = RegExp(r'^[a-z][a-z0-9_]*$');

  static const _maxLength = 64;

  static const _reservedWords = {
    'assert', 'break', 'case', 'catch', 'class', 'const', 'continue',
    'default', 'do', 'else', 'enum', 'extends', 'false', 'final',
    'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow',
    'return', 'super', 'switch', 'this', 'throw', 'true', 'try',
    'var', 'void', 'while', 'with',
    // Built-in identifiers
    'abstract', 'as', 'covariant', 'deferred', 'dynamic', 'export',
    'extension', 'external', 'factory', 'function', 'get', 'implements',
    'import', 'interface', 'late', 'library', 'mixin', 'operator',
    'part', 'required', 'set', 'static', 'typedef',
  };

  /// Returns null if valid, or an error message if invalid.
  static String? validate(String name) {
    if (name.isEmpty) {
      return 'Package name cannot be empty.';
    }
    if (name.length > _maxLength) {
      return 'Package name cannot exceed $_maxLength characters.';
    }
    if (!_validPattern.hasMatch(name)) {
      return 'Package name must start with a lowercase letter and '
          'contain only lowercase letters, digits, and underscores.';
    }
    if (_reservedWords.contains(name)) {
      return '\'$name\' is a reserved word and cannot be used as a package name.';
    }
    return null;
  }

  /// Returns true if the name is valid.
  static bool isValid(String name) => validate(name) == null;
}
