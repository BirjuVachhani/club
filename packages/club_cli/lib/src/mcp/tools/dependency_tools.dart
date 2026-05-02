/// Dependency management tools — produce pubspec.yaml snippets the AI can
/// then apply with its own filesystem tools.
///
/// We deliberately do NOT write to disk here. The MCP layer is intentionally
/// transport-agnostic and side-effect-free; once a future HTTP transport
/// lands, the same tools still make sense without any local filesystem
/// access.
library;

import 'package:dart_mcp/server.dart';

import '../server_registry.dart';
import 'tool_helpers.dart';

void registerDependencyTools(ToolsSupport server, ServerRegistry registry) {
  server.registerTool(
    Tool(
      name: 'add_dependency_snippet',
      description:
          'Resolve a package on a Club server and return a YAML snippet the '
          'caller can paste under `dependencies:` (or `dev_dependencies:` / '
          '`dependency_overrides:`) in pubspec.yaml. Validates that the '
          'package exists on the server and includes the required `hosted` '
          'block so the snippet works in a polyglot pubspec with mixed '
          'registries.',
      inputSchema: Schema.object(
        properties: {
          'name': Schema.string(description: 'Package name to add.'),
          'version': Schema.string(
            description:
                'Optional version constraint (e.g. "^1.2.3"). Defaults to '
                '"^<latest-stable>" when omitted.',
          ),
          'section': Schema.string(
            description:
                'Which pubspec section to target. One of: dependencies, '
                'dev_dependencies, dependency_overrides. Defaults to '
                '"dependencies".',
            enumValues: const [
              'dependencies',
              'dev_dependencies',
              'dependency_overrides',
            ],
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
      final section = optString(args, 'section') ?? 'dependencies';
      final explicitConstraint = optString(args, 'version');
      final client = registry.clientFor(optString(args, 'server'));
      final serverUrl = client.serverUrl.toString();

      final pkg = await client.listVersions(name);
      final latestStable = pkg.latest.version;
      final constraint = explicitConstraint ?? '^$latestStable';

      final snippet =
          '$name:\n'
          '  hosted: $serverUrl\n'
          '  version: "$constraint"\n';

      final instruction =
          'Add the snippet under `$section:` in your pubspec.yaml '
          '(create the section if it does not exist), then run '
          '`dart pub get`. Or run: '
          '`club add $name${explicitConstraint != null ? ':$explicitConstraint' : ''} '
          '--server ${client.serverUrl.host}`.';

      return jsonResult({
        'name': name,
        'section': section,
        'server': serverUrl,
        'resolvedVersion': latestStable,
        'constraint': constraint,
        'snippet': snippet,
        'instruction': instruction,
      });
    }),
  );
}
