/// Discovery tools: search and full-name listing.
library;

import 'package:dart_mcp/server.dart';

import '../server_registry.dart';
import 'tool_helpers.dart';

const _allowedSorts = ['relevance', 'updated', 'created', 'likes'];

void registerSearchTools(ToolsSupport server, ServerRegistry registry) {
  server.registerTool(
    Tool(
      name: 'search_packages',
      description:
          'Search packages on a Club server. Returns a paginated list of '
          'package names with relevance scores. Page size is fixed at 20.',
      inputSchema: Schema.object(
        properties: {
          'query': Schema.string(
            description:
                'Search text. Empty/omitted returns the most popular packages '
                'for the chosen sort order.',
          ),
          'page': Schema.int(
            description: '1-indexed page number. Defaults to 1.',
          ),
          'sort': Schema.string(
            description:
                'Sort order. One of: relevance, updated, created, likes.',
            enumValues: _allowedSorts,
          ),
          'server': Schema.string(
            description:
                'Optional server URL. Defaults to the active server when omitted.',
          ),
        },
      ),
    ),
    (request) async => safeCall(() async {
      final args = argsOf(request);
      final query = optString(args, 'query') ?? '';
      final page = optInt(args, 'page') ?? 1;
      final sort = optString(args, 'sort') ?? 'relevance';
      // Defensive guard in addition to schema enforcement: some clients
      // skip schema validation, and an out-of-spec sort would otherwise
      // surface as a server-side 400 with a less actionable message.
      if (!_allowedSorts.contains(sort)) {
        throw ArgumentError(
          'Unknown sort "$sort". Allowed: ${_allowedSorts.join(", ")}.',
        );
      }
      final client = registry.clientFor(optString(args, 'server'));
      final res = await client.search(query, page: page, sort: sort);
      return jsonResult(res);
    }),
  );

  server.registerTool(
    Tool(
      name: 'list_all_packages',
      description:
          'Return every package name on a Club server (capped server-side at '
          '~10000). Useful when the AI needs a name-completion list. For '
          'large registries prefer `search_packages` first.',
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
      final names = await client.listAllNames();
      return jsonResult({'packages': names, 'total': names.length});
    }),
  );
}
