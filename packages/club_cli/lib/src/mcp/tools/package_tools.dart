/// Package read tools: versions, version detail, content (readme/changelog),
/// scoring, and dartdoc summary.
library;

import 'package:dart_mcp/server.dart';

import '../dartdoc_proxy.dart';
import '../server_registry.dart';
import 'tool_helpers.dart';

void registerPackageTools(ToolsSupport server, ServerRegistry registry) {
  server.registerTool(
    Tool(
      name: 'get_package',
      description:
          'List every version of a package on a Club server, plus the '
          'latest stable, latest prerelease, and discontinued/unlisted '
          'state.',
      inputSchema: Schema.object(
        properties: {
          'name': Schema.string(description: 'Package name.'),
          'server': Schema.string(
            description:
                'Optional server URL. Defaults to the active server when omitted.',
          ),
        },
        required: ['name'],
      ),
    ),
    (request) async => safeCall(() async {
      final args = argsOf(request);
      final name = requiredString(args, 'name');
      final client = registry.clientFor(optString(args, 'server'));
      final pkg = await client.listVersions(name);
      return jsonResult(pkg.toJson());
    }),
  );

  server.registerTool(
    Tool(
      name: 'get_package_version',
      description:
          'Get a specific version of a package. Returns the parsed pubspec '
          '(name, description, dependencies, environment, homepage, '
          'repository), archive URL + sha256, and published timestamp.',
      inputSchema: Schema.object(
        properties: {
          'name': Schema.string(description: 'Package name.'),
          'version': Schema.string(description: 'Semver version string.'),
          'server': Schema.string(
            description:
                'Optional server URL. Defaults to the active server when omitted.',
          ),
        },
        required: ['name', 'version'],
      ),
    ),
    (request) async => safeCall(() async {
      final args = argsOf(request);
      final name = requiredString(args, 'name');
      final version = requiredString(args, 'version');
      final client = registry.clientFor(optString(args, 'server'));
      final info = await client.getVersion(name, version);
      return jsonResult(info.toJson());
    }),
  );

  server.registerTool(
    Tool(
      name: 'get_package_content',
      description:
          'Fetch a version\'s README, CHANGELOG, and example content as '
          'markdown strings. When `version` is omitted the latest version '
          'is used. Output also includes screenshot URLs and bin '
          'executables declared in pubspec.',
      inputSchema: Schema.object(
        properties: {
          'name': Schema.string(description: 'Package name.'),
          'version': Schema.string(
            description:
                'Optional semver version. Defaults to the latest when omitted.',
          ),
          'server': Schema.string(
            description:
                'Optional server URL. Defaults to the active server when omitted.',
          ),
        },
        required: ['name'],
      ),
    ),
    (request) async => safeCall(() async {
      final args = argsOf(request);
      final name = requiredString(args, 'name');
      final version = optString(args, 'version');
      final client = registry.clientFor(optString(args, 'server'));
      final content = await client.getVersionContent(name, version: version);
      return jsonResult(content.toJson());
    }),
  );

  server.registerTool(
    Tool(
      name: 'get_package_score',
      description:
          'Get the pana points + tags + likes + 30-day download count for '
          'a package or a specific version. When `version` is omitted, the '
          'package-level score is returned.',
      inputSchema: Schema.object(
        properties: {
          'name': Schema.string(description: 'Package name.'),
          'version': Schema.string(
            description: 'Optional semver version.',
          ),
          'server': Schema.string(
            description:
                'Optional server URL. Defaults to the active server when omitted.',
          ),
        },
        required: ['name'],
      ),
    ),
    (request) async => safeCall(() async {
      final args = argsOf(request);
      final name = requiredString(args, 'name');
      final version = optString(args, 'version');
      final client = registry.clientFor(optString(args, 'server'));
      final score = await client.getScore(name, version: version);
      return jsonResult(score.toJson());
    }),
  );

  server.registerTool(
    Tool(
      name: 'get_package_scoring_report',
      description:
          'Get the detailed pana scoring report for a specific version: '
          'per-section points, status, and markdown summaries explaining '
          'why points were granted or withheld. Returns a status string '
          '(`completed`, `pending`, `running`, `failed`, `disabled`, '
          '`not_analyzed`); only `completed` carries section data.',
      inputSchema: Schema.object(
        properties: {
          'name': Schema.string(description: 'Package name.'),
          'version': Schema.string(description: 'Semver version string.'),
          'server': Schema.string(
            description:
                'Optional server URL. Defaults to the active server when omitted.',
          ),
        },
        required: ['name', 'version'],
      ),
    ),
    (request) async => safeCall(() async {
      final args = argsOf(request);
      final name = requiredString(args, 'name');
      final version = requiredString(args, 'version');
      final client = registry.clientFor(optString(args, 'server'));
      final report = await client.getScoringReport(name, version);
      return jsonResult({
        'status': report.status,
        'grantedPoints': report.grantedPoints,
        'maxPoints': report.maxPoints,
        'panaVersion': report.panaVersion,
        'dartVersion': report.dartVersion,
        'flutterVersion': report.flutterVersion,
        'analyzedAt': report.analyzedAt?.toIso8601String(),
        'errorMessage': report.errorMessage,
        'sections': report.sections
            .map(
              (s) => {
                'id': s.id,
                'title': s.title,
                'grantedPoints': s.grantedPoints,
                'maxPoints': s.maxPoints,
                'status': s.status,
                'summary': s.summary,
              },
            )
            .toList(),
      });
    }),
  );

  server.registerTool(
    Tool(
      name: 'get_package_api_docs',
      description:
          'Return a structured summary of a package\'s generated API '
          'reference (dartdoc): generation status, the absolute documentation '
          'URL, the package description, and the list of exported libraries '
          'with short summaries. The docs URL points at the Club server\'s '
          'private dartdoc viewer — the AI itself usually cannot fetch it, '
          'but a human user with network access to the server can.',
      inputSchema: Schema.object(
        properties: {
          'name': Schema.string(description: 'Package name.'),
          'server': Schema.string(
            description:
                'Optional server URL. Defaults to the active server when omitted.',
          ),
        },
        required: ['name'],
      ),
    ),
    (request) async => safeCall(() async {
      final args = argsOf(request);
      final name = requiredString(args, 'name');
      final client = registry.clientFor(optString(args, 'server'));

      final status = await client.getDartdocStatus(name);
      final result = <String, Object?>{
        'status': status.status,
        if (status.version != null) 'version': status.version,
        if (status.generatedAt != null)
          'generatedAt': status.generatedAt!.toIso8601String(),
        if (status.docsUrl != null)
          'docsUrl': client.serverUrl.resolve(status.docsUrl!).toString(),
        if (status.errorMessage != null) 'errorMessage': status.errorMessage,
      };

      if (status.isReady) {
        final summary = await fetchDartdocSummary(client, name);
        if (summary != null) {
          result['description'] = summary.description;
          result['libraries'] =
              summary.libraries.map((l) => l.toJson()).toList();
        }
      }

      return jsonResult(result);
    }),
  );
}
