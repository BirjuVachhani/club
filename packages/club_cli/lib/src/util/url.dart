/// URL helpers shared across commands.
///
/// Commands accept a server as either a bare host (`myclub.birju.dev`)
/// or a full URL (`https://myclub.birju.dev`). [parseServerInput] folds
/// both into a canonical URL string used for HTTP requests, dart pub
/// token registration, and credential-store keys. [displayServer] is the
/// inverse for user-facing output: drops the scheme and any default port
/// so the CLI prints `myclub.birju.dev` rather than the full URL.
library;

const _localhostNames = {'localhost', '127.0.0.1', '0.0.0.0'};

/// Parse [input] into a canonical server URL string.
///
/// Accepts bare hosts (`myclub.birju.dev`, `myclub.birju.dev:8080`),
/// hosts with paths (`myclub.birju.dev/club`), and full URLs
/// (`https://myclub.birju.dev`). Trailing slashes are stripped.
///
/// When the input has no scheme, `https` is inferred — except for
/// localhost-like hosts (`localhost`, `127.0.0.1`, `0.0.0.0`) which fall
/// back to `http`. Default ports (80 for http, 443 for https) are
/// dropped from the canonical form.
///
/// Throws [FormatException] on empty input or input without a host.
String parseServerInput(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Server cannot be empty.');
  }

  final hasScheme =
      trimmed.startsWith('http://') || trimmed.startsWith('https://');

  Uri parsed;
  try {
    parsed = hasScheme
        ? Uri.parse(trimmed)
        : Uri.parse('${_inferScheme(trimmed)}://$trimmed');
  } on FormatException {
    throw FormatException('Invalid server: $input');
  }

  if (parsed.host.isEmpty) {
    throw FormatException(
      'Server must include a host (e.g. myclub.birju.dev): $input',
    );
  }

  final scheme = parsed.scheme.toLowerCase();
  final host = parsed.host.toLowerCase();
  final buf = StringBuffer()
    ..write(scheme)
    ..write('://')
    ..write(host);
  if (parsed.hasPort && parsed.port != _defaultPort(scheme)) {
    buf.write(':${parsed.port}');
  }
  var path = parsed.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isNotEmpty) buf.write(path);
  return buf.toString();
}

/// Strip scheme and default port from [serverUrl] for user-facing output.
///
/// `https://myclub.birju.dev` → `myclub.birju.dev`
/// `http://localhost:8080`    → `localhost:8080`
/// `https://example.com:8443/club` → `example.com:8443/club`
String displayServer(String serverUrl) {
  final parsed = Uri.tryParse(serverUrl);
  if (parsed == null || parsed.host.isEmpty) return serverUrl;
  final buf = StringBuffer()..write(parsed.host);
  if (parsed.hasPort && parsed.port != _defaultPort(parsed.scheme)) {
    buf.write(':${parsed.port}');
  }
  if (parsed.path.isNotEmpty) buf.write(parsed.path);
  return buf.toString();
}

String _inferScheme(String hostPart) {
  var end = hostPart.length;
  for (var i = 0; i < hostPart.length; i++) {
    final c = hostPart[i];
    if (c == ':' || c == '/') {
      end = i;
      break;
    }
  }
  final host = hostPart.substring(0, end).toLowerCase();
  return _localhostNames.contains(host) ? 'http' : 'https';
}

int _defaultPort(String scheme) => scheme == 'https' ? 443 : 80;
