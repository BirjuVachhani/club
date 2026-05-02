/// Server-management tools: list logged-in servers, switch the active one,
/// and surface the authenticated identity.
///
/// In pinned mode (single `--server`), `switch_server` is still registered
/// but always returns an error — exposing it lets the AI discover that the
/// MCP server is pinned instead of guessing.
library;

import 'package:dart_mcp/server.dart';

import '../server_registry.dart';
import 'tool_helpers.dart';

void registerServerTools(ToolsSupport server, ServerRegistry registry) {
  server.registerTool(
    Tool(
      name: 'list_servers',
      description:
          'List the Club servers this MCP instance can access. The active '
          'server is the one used by tools that omit the `server` argument.',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) async => safeCall(() async {
      final entries = registry.servers
          .map(
            (s) => {
              'url': s.url,
              if (s.email != null) 'email': s.email,
              'isActive': s.url == registry.active.url,
            },
          )
          .toList();
      return jsonResult({
        'mode': registry.isPinned ? 'pinned' : 'discovered',
        'activeServer': registry.active.url,
        'servers': entries,
      });
    }),
  );

  server.registerTool(
    Tool(
      name: 'switch_server',
      description:
          'Set the active Club server for subsequent tool calls. Pass the '
          'server URL exactly as returned by `list_servers`. Errors when '
          '`club mcp` was started in pinned mode (--server flag).',
      inputSchema: Schema.object(
        properties: {
          'server': Schema.string(
            description: 'URL of a server returned by `list_servers`.',
          ),
        },
        required: ['server'],
      ),
    ),
    (request) async => safeCall(() async {
      final args = argsOf(request);
      final url = requiredString(args, 'server');
      registry.setActive(url);
      return jsonResult({'activeServer': registry.active.url});
    }),
  );

  server.registerTool(
    Tool(
      name: 'whoami',
      description:
          'Return the authenticated user (email, role, displayName) for a '
          'Club server. Useful as a connectivity / token-validity probe.',
      inputSchema: Schema.object(
        properties: {
          'server': Schema.string(
            description:
                'Optional server URL. Defaults to the active server when omitted.',
          ),
        },
      ),
    ),
    (request) async => safeCall(() async {
      final args = argsOf(request);
      final client = registry.clientFor(optString(args, 'server'));
      final me = await client.getMe();
      return jsonResult(me);
    }),
  );
}
