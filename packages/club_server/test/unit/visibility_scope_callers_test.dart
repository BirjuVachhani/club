import 'dart:io';

import 'package:test/test.dart';

/// Pins the set of files allowed to say `VisibilityScope.trustedInternal`.
///
/// The required-parameter design makes "forgot to decide" a compile error
/// exactly once. After that, a contributor facing a red squiggle can type
/// `trustedInternal` and be back to an unfiltered read, and nothing would
/// notice. This test is what makes that a deliberate act: widening the
/// list is a visible line in a diff, next to a comment saying why.
///
/// When this fails, the question to answer is not "how do I make the test
/// pass" but "should this call site really see private packages?". For a
/// request handler the answer is almost always no; use
/// `visibilityScopeFor(request)` instead.
void main() {
  /// Each entry records *why* the file is allowed to read unfiltered.
  const allowed = <String, String>{
    // The declaration itself.
    'packages/club_core/lib/src/repositories/visibility_scope.dart':
        'defines the constant',

    // Write paths recomputing derived state. They must consider every
    // version, including ones no anonymous caller may list, or the
    // recomputed `latest` pointer would be wrong for signed-in users.
    'packages/club_core/lib/src/services/package_service.dart':
        'retract/publish recompute of latest_version',
    'packages/club_core/lib/src/services/publish_service.dart':
        'publish-time recompute of latest_version',

    // Computes what *would* become visible, so by definition it has to
    // read what currently is not.
    'packages/club_core/lib/src/services/visibility_service.dart':
        'closure analysis over private packages',

    // Publisher package listing; the request scope is applied at the API
    // boundary in publisher_api.dart instead.
    'packages/club_core/lib/src/services/publisher_service.dart':
        'internal publisher package listing',

    // Recomputes latest pointers after a version delete.
    'packages/club_db/lib/src/sqlite_metadata_store.dart':
        'deleteVersion recompute',

    // Admin surfaces exist to show the operator everything, and are
    // role-gated with requireRole(admin).
    'packages/club_server/lib/src/api/admin_api.dart':
        'admin moderation views, role-gated',
    'packages/club_server/lib/src/api/package_admin_api.dart':
        'package admin views, ownership-gated',

    // Liveness probe: counts rows, returns no package data.
    'packages/club_server/lib/src/api/health_api.dart':
        'health probe row count',

    // Background job with no request context.
    'packages/club_server/lib/src/dependency_index_backfill.dart':
        'boot-time dependency indexing',

    // Tests.
    'packages/club_db/test/search_order_test.dart': 'test',
    'packages/club_db/test/visibility_service_test.dart': 'test',
    'packages/club_db/test/discovery_filter_test.dart':
        'test: asserts what each scope sees, so it names both of them',
    'packages/club_server/test/unit/visibility_scope_callers_test.dart':
        'this test',
  };

  test('only pinned files reference VisibilityScope.trustedInternal', () {
    // Tests run from the package directory; walk up to the workspace root.
    final root = _workspaceRoot();

    final offenders = <String>[];
    for (final entity in Directory(
      '${root.path}/packages',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final relative = entity.path
          .substring(root.path.length + 1)
          .replaceAll(r'\', '/');
      // Generated code and build artefacts are not hand-written policy.
      if (relative.contains('/.dart_tool/')) continue;
      if (relative.endsWith('.g.dart')) continue;

      if (!entity.readAsStringSync().contains('trustedInternal')) continue;
      if (allowed.containsKey(relative)) continue;
      offenders.add(relative);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files read package data without filtering by visibility:\n'
          '  ${offenders.join('\n  ')}\n\n'
          'If the call site serves a request, use '
          '`visibilityScopeFor(request)` so anonymous callers see only '
          'public packages. If it is genuinely internal (a write path, a '
          'background job, or a role-gated admin view), add it to the '
          '`allowed` map in this test with a one-line reason.',
    );
  });

  test('the pinned list has no stale entries', () {
    // A file that stopped needing the exemption should lose it, otherwise
    // the list slowly becomes a blanket permission.
    final root = _workspaceRoot();
    final stale = <String>[];
    for (final path in allowed.keys) {
      if (path.endsWith('visibility_scope_callers_test.dart')) continue;
      final file = File('${root.path}/$path');
      if (!file.existsSync() ||
          !file.readAsStringSync().contains('trustedInternal')) {
        stale.add(path);
      }
    }
    expect(
      stale,
      isEmpty,
      reason:
          'These files no longer use trustedInternal; remove them from the '
          'allowed map:\n  ${stale.join('\n  ')}',
    );
  });
}

Directory _workspaceRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/packages').existsSync() &&
        File('${dir.path}/pubspec.yaml').existsSync()) {
      return dir;
    }
    dir = dir.parent;
  }
  throw StateError('Could not locate the workspace root from ${Directory.current.path}');
}
