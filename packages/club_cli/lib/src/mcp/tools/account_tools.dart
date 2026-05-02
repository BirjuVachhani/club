/// Account-scoped tools — packages owned by the authenticated user.
library;

import 'package:dart_mcp/server.dart';

import '../server_registry.dart';
import 'tool_helpers.dart';

void registerAccountTools(ToolsSupport server, ServerRegistry registry) {
  server.registerTool(
    Tool(
      name: 'list_my_packages',
      description:
          'List packages where the authenticated user is an uploader or a '
          'member of the owning publisher. Cursor-paginated via '
          '`pageToken`; pass the `nextPageToken` from a previous response.',
      inputSchema: Schema.object(
        properties: {
          'query': Schema.string(
            description: 'Optional substring filter on package name.',
          ),
          'pageToken': Schema.string(
            description:
                'Opaque cursor returned as `nextPageToken` in a previous '
                'response. Omit on the first page.',
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
      final client = registry.clientFor(optString(args, 'server'));
      final res = await client.getMyPackages(
        query: optString(args, 'query'),
        pageToken: optString(args, 'pageToken'),
      );
      return jsonResult(res);
    }),
  );
}
