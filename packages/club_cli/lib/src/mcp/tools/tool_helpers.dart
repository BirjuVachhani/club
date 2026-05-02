/// Shared helpers for MCP tool handlers in `club mcp`.
///
/// Every handler runs untrusted-shaped input from the AI client through the
/// same try/catch shape: typed [ClubApiException] errors become structured
/// `isError: true` results with friendly messages; anything else becomes a
/// generic failure result so a thrown bug never escapes the JSON-RPC channel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:club_api/club_api.dart';
import 'package:dart_mcp/server.dart';

import '../server_registry.dart';

/// Run [body] and convert exceptions into a `CallToolResult(isError: true)`.
///
/// Tool handlers return `CallToolResult` directly; this wrapper lets each
/// one focus on the happy path. Failure shape:
///
///   - [ClubApiException]: surfaces `code` + `message` to the AI so it can
///     decide whether to retry or apologize.
///   - [ServerRegistryError]: usage / config issues (wrong server, not
///     logged in) — surfaces the message + hint as plain text.
///   - Anything else: generic "internal error" with the runtime type. Stack
///     traces are sent to stderr (not the tool result) — they help the
///     human running `club mcp`, but the AI client gets a redacted message
///     in case the underlying exception's `toString()` exposes paths or
///     URLs the operator would rather not share.
Future<CallToolResult> safeCall(
  Future<CallToolResult> Function() body,
) async {
  try {
    return await body();
  } on ClubApiException catch (e) {
    return CallToolResult(
      isError: true,
      content: [
        TextContent(text: 'Server error (${e.statusCode} ${e.code}): ${e.message}'),
      ],
    );
  } on ServerRegistryError catch (e) {
    final hint = e.hint == null ? '' : '\nHint: ${e.hint}';
    return CallToolResult(
      isError: true,
      content: [TextContent(text: '${e.message}$hint')],
    );
  } catch (e, st) {
    stderr.writeln('club mcp: tool handler threw ${e.runtimeType}: $e\n$st');
    return CallToolResult(
      isError: true,
      content: [
        TextContent(text: 'Internal error: ${e.runtimeType}'),
      ],
    );
  }
}

/// Unwrap the args map from a tool request, handling the null-arguments case.
/// Every handler opens with `final a = argsOf(request);` — extracting this
/// kept the call sites uniform across the 13 tools.
Map<String, Object?> argsOf(CallToolRequest request) =>
    request.arguments ?? const <String, Object?>{};

/// Pretty-print [data] as JSON for `TextContent` payloads.
String jsonText(Object? data) =>
    const JsonEncoder.withIndent('  ').convert(data);

/// Build a [CallToolResult] whose single content block is JSON-formatted
/// [data]. The vast majority of read-only tools use this shape — the AI
/// already parses JSON well, and structured output beats prose for tool
/// results that other tools may chain on.
CallToolResult jsonResult(Object? data) =>
    CallToolResult(content: [TextContent(text: jsonText(data))]);

/// Optional-string accessor with empty-string normalization. Schema-validated
/// arguments arrive as `Object?`; we want `null`-or-`String` and treat empty
/// strings as missing.
String? optString(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is! String) return null;
  return v.isEmpty ? null : v;
}

/// Required-string accessor. Schema validation should already catch missing
/// values, but a defensive check keeps the failure mode useful.
String requiredString(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v is! String || v.isEmpty) {
    throw ArgumentError('Missing required argument "$key".');
  }
  return v;
}

/// Optional-int accessor that tolerates JSON numbers arriving as either int
/// or double from the model.
int? optInt(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Optional-bool accessor.
bool? optBool(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v is bool) return v;
  return null;
}
