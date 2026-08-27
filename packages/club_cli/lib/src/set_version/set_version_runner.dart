/// End-to-end orchestration for `club set-version`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../prepare/package_discovery.dart';
import '../util/exit_codes.dart';
import '../util/log.dart';
import '../util/prompt.dart';
import 'set_version_planner.dart';
import 'set_version_writer.dart';

class SetVersionOptions {
  const SetVersionOptions({required this.version, this.directory = ''});

  final String version;
  final String directory;
}

typedef PackageSelector =
    Future<List<String>> Function(
      Map<String, DiscoveredPackage> packages,
      String version,
    );

class SetVersionRunner {
  SetVersionRunner(this.options, {PackageSelector? selector})
    : _selector = selector ?? _selectPackages;

  final SetVersionOptions options;
  final PackageSelector _selector;

  Future<int> run() async {
    final rootDir = p.absolute(
      options.directory.isEmpty ? Directory.current.path : options.directory,
    );
    info('🔖  ${bold('club set-version')}');
    detail('root: $rootDir');

    final packages = discoverPackages(rootDir);
    if (packages.isEmpty) {
      error('No Dart packages found under $rootDir.');
      return ExitCodes.noInput;
    }
    detail(
      'discovered ${bold('${packages.length}')} '
      '${packages.length == 1 ? 'package' : 'packages'}',
    );

    final List<String> selected;
    try {
      selected = await _selector(packages, options.version);
    } on NonInteractiveError catch (exception) {
      error(exception.message);
      return ExitCodes.config;
    }
    if (selected.isEmpty) {
      info('Nothing selected. No files were changed.');
      return ExitCodes.success;
    }

    final plan = planSetVersion(
      packages: packages,
      selectedPackageNames: selected.toSet(),
      newVersion: options.version,
    );
    final result = applySetVersionPlan(plan);

    if (result.filesWritten == 0) {
      success('No changes needed.');
      return ExitCodes.success;
    }

    success(
      'Updated ${plan.versionChanges} package '
      '${plan.versionChanges == 1 ? 'version' : 'versions'} and '
      '${plan.dependencyChanges} hosted dependency '
      '${plan.dependencyChanges == 1 ? 'constraint' : 'constraints'} '
      'across ${result.filesWritten} '
      '${result.filesWritten == 1 ? 'file' : 'files'}.',
    );
    if (plan.skippedNonHostedReferences > 0) {
      detail(
        'Skipped ${plan.skippedNonHostedReferences} matching non-hosted '
        '${plan.skippedNonHostedReferences == 1 ? 'dependency' : 'dependencies'}.',
      );
    }
    return ExitCodes.success;
  }

  static Future<List<String>> _selectPackages(
    Map<String, DiscoveredPackage> packages,
    String version,
  ) {
    final names = packages.keys.toList()..sort();
    return pickMulti<String>(
      'Select packages to set to $version:',
      [
        for (final name in names)
          PickOption(
            label: name,
            value: name,
            detail: packages[name]!.version ?? '(no version)',
          ),
      ],
      nonInteractiveMessage:
          'Package selection requires an interactive terminal.',
    );
  }
}
