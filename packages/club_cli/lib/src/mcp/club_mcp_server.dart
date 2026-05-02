/// MCP server class for `club mcp`.
///
/// Wires the [ServerRegistry] to a `dart_mcp` server with `ToolsSupport` +
/// `LoggingSupport`. Each tool group is registered through its own
/// `register*Tools(...)` function so handlers stay isolated and the wiring
/// here is mostly declarative.
///
/// In pinned mode (single `--server`) we still register `list_servers` and
/// `switch_server` so the AI can discover the constraint instead of guessing.
/// `switch_server` itself errors out cleanly via the registry.
library;

import 'package:dart_mcp/server.dart';

import '../version.dart';
import 'server_registry.dart';
import 'tools/account_tools.dart';
import 'tools/dependency_tools.dart';
import 'tools/package_tools.dart';
import 'tools/search_tools.dart';
import 'tools/server_tools.dart';

base class ClubMcpServer extends MCPServer with ToolsSupport, LoggingSupport {
  ClubMcpServer(super.channel, ServerRegistry registry)
    : _registry = registry,
      super.fromStreamChannel(
        implementation: Implementation(
          name: 'club',
          version: clubCliVersion,
        ),
        instructions: _buildInstructions(registry),
      ) {
    registerServerTools(this, _registry);
    registerSearchTools(this, _registry);
    registerPackageTools(this, _registry);
    registerAccountTools(this, _registry);
    registerDependencyTools(this, _registry);
  }

  final ServerRegistry _registry;

  ServerRegistry get registry => _registry;
}

String _buildInstructions(ServerRegistry registry) {
  final mode = registry.isPinned ? 'pinned' : 'discovered';
  final active = registry.active;
  return 'Browse and inspect packages on a private Club Dart registry. '
      'Mode: $mode. Active server: ${active.url}'
      '${active.email != null ? ' (${active.email})' : ''}. '
      'Use `list_servers` to see available servers, `whoami` to verify the '
      'auth token, `search_packages` / `get_package` / `get_package_content` '
      'to explore, and `add_dependency_snippet` to produce a pubspec entry.';
}
