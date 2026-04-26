/// Validate an OAuth redirect URI for the CLI's loopback flow.
///
/// RFC 8252 (OAuth for Native Apps) and the `/auth` spec both say that a
/// public client performing the authorization-code-plus-PKCE dance on a
/// desktop should use a loopback redirect. We accept **only** that shape:
/// strictly `http://` (not https — loopback is exempt from the HTTPS
/// requirement and users don't have trustworthy certs for 127.0.0.1),
/// one of a fixed set of loopback hostnames, and an explicit port so the
/// CLI's ephemeral listener binds somewhere deterministic.
///
/// Any laxer check (e.g. `startsWith('http://localhost')`) lets an
/// attacker slip in `http://localhost.evil.com/…` or
/// `http://localhost@evil.com/…` and swap the CLI's loopback listener
/// for a host they control — giving them the authorization code and,
/// once exchanged, a PAT.
bool isValidLoopbackRedirect(String? uri) {
  if (uri == null || uri.isEmpty) return false;
  final parsed = Uri.tryParse(uri);
  if (parsed == null) return false;
  if (parsed.scheme != 'http') return false;
  // Reject URIs with userinfo. `http://localhost@evil.com/…` parses with
  // host='evil.com' on strict parsers but some tolerant parsers (or naive
  // substring checks) would treat the string as pointing at localhost.
  if (parsed.userInfo.isNotEmpty) return false;
  // Require an explicit port so the CLI's ephemeral listener knows where
  // to bind.
  if (!parsed.hasPort) return false;
  // Strict hostname allowlist. Do not accept `localhost.<suffix>` or
  // any other variant.
  const loopbackHosts = {'localhost', '127.0.0.1', '[::1]', '::1'};
  if (!loopbackHosts.contains(parsed.host)) return false;
  return true;
}
