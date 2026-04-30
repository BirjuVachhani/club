/// Mirrors dart pub's
/// [`Validator.runAll`](https://github.com/dart-lang/pub/blob/master/lib/src/validator.dart):
/// run every validator concurrently and aggregate findings.
library;

import 'analyze.dart';
import 'changelog.dart';
import 'compiled_dartdoc.dart';
import 'dependency.dart';
import 'dependency_override.dart';
import 'deprecated_fields.dart';
import 'devtools_extension.dart';
import 'directory.dart';
import 'executable.dart';
import 'file_case.dart';
import 'flutter_constraint.dart';
import 'flutter_plugin_format.dart';
import 'gitignore.dart';
import 'git_status.dart';
import 'leak_detection.dart';
import 'license.dart';
import 'name.dart';
import 'pubspec.dart';
import 'pubspec_field.dart';
import 'pubspec_typo.dart';
import 'readme.dart';
import 'relative_version.dart';
import 'sdk_constraint.dart';
import 'size.dart';
import 'strict_dependencies.dart';
import 'validator.dart';

/// Aggregated outcome of running every validator.
class ValidationReport {
  ValidationReport({
    required this.errors,
    required this.warnings,
    required this.hints,
  });

  final List<ValidationFinding> errors;
  final List<ValidationFinding> warnings;
  final List<ValidationFinding> hints;

  bool get hasErrors => errors.isNotEmpty;
  bool get hasWarnings => warnings.isNotEmpty;
  int get total => errors.length + warnings.length + hints.length;
}

/// Build the list of all validators for the given [context].
///
/// New validators should be appended here.
List<Validator> buildValidators(ValidationContext context) => [
  AnalyzeValidator(context),
  ChangelogValidator(context),
  CompiledDartdocValidator(context),
  DependencyValidator(context),
  DependencyOverrideValidator(context),
  DeprecatedFieldsValidator(context),
  DevtoolsExtensionValidator(context),
  DirectoryValidator(context),
  ExecutableValidator(context),
  FileCaseValidator(context),
  FlutterConstraintValidator(context),
  FlutterPluginFormatValidator(context),
  GitignoreValidator(context),
  GitStatusValidator(context),
  LeakDetectionValidator(context),
  LicenseValidator(context),
  NameValidator(context),
  PubspecPresentValidator(context),
  PubspecFieldValidator(context),
  PubspecTypoValidator(context),
  ReadmeValidator(context),
  RelativeVersionValidator(context),
  SdkConstraintValidator(context),
  SizeValidator(context),
  StrictDependenciesValidator(context),
];

/// Run every validator (concurrently) and collect their findings.
///
/// The list mirrors dart pub publish's `_allValidators`.
Future<ValidationReport> runAllValidators(ValidationContext context) async {
  final validators = buildValidators(context);

  await Future.wait(validators.map((v) => v.validate()));

  final errors = <ValidationFinding>[];
  final warnings = <ValidationFinding>[];
  final hints = <ValidationFinding>[];
  for (final v in validators) {
    for (final f in v.findings) {
      switch (f.severity) {
        case Severity.error:
          errors.add(f);
        case Severity.warning:
          warnings.add(f);
        case Severity.hint:
          hints.add(f);
      }
    }
  }
  return ValidationReport(
    errors: errors,
    warnings: warnings,
    hints: hints,
  );
}
