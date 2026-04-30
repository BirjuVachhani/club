import 'package:shelf/shelf.dart';

/// Attach defense-in-depth security headers to every response.
///
/// These headers reduce the blast radius of an XSS that slips through,
/// prevent the SPA from being framed (clickjacking), stop the browser
/// from MIME-sniffing API JSON into executable content, and tighten
/// referrer leakage on outbound links.
///
/// The CSP is deliberately strict: `default-src 'self'` with no inline
/// script or style. SvelteKit's static build output complies — if we
/// later need inline styles, switch to hash-based or nonce-based allow.
Middleware securityHeadersMiddleware() {
  // SvelteKit's adapter-static emits a small inline bootstrap script
  // that kicks off hydration; there's no per-request context so nonces
  // aren't an option, and the hash changes per build so pinning it here
  // would force us to rebuild the server every time the frontend is
  // rebuilt. `'unsafe-inline'` on script-src is the pragmatic tradeoff.
  //
  // Remaining defense-in-depth is still meaningful: HttpOnly session
  // cookies keep the session out of JS regardless of script-src;
  // frame-ancestors 'none' blocks clickjacking; object-src / base-uri
  // lock down the common XSS escalation paths; connect-src 'self' stops
  // exfiltration to third-party hosts.
  //
  // All fonts are bundled locally via `@fontsource*` imports, so no
  // external style-src / font-src hosts are needed.
  const csp =
      "default-src 'self'; "
      "base-uri 'self'; "
      "frame-ancestors 'none'; "
      "form-action 'self'; "
      "object-src 'none'; "
      "script-src 'self' 'unsafe-inline'; "
      "style-src 'self' 'unsafe-inline'; "
      "img-src 'self' https: data: blob:; "
      "font-src 'self' data:; "
      "connect-src 'self'";

  // Dartdoc output references only external scripts from `/documentation/`
  // (same-origin `static-assets/*.js`). There are no inline `<script>` bodies
  // and no `on*` event handlers in the standard dartdoc HTML, so we can drop
  // `'unsafe-inline'` from `script-src` entirely — which is the primary
  // defense here: even if a published package slips an inline script into
  // a README-derived page or an SVG, the browser refuses to execute it.
  //
  // We still need `'unsafe-inline'` on `style-src` because dartdoc inlines
  // small bits of style for highlighting, code blocks, and the sidebar
  // resize handle. An inline-style XSS is far less dangerous than an inline
  // script — it can't read cookies or make requests — so this is an
  // acceptable relaxation. `base-uri 'self'` and `object-src 'none'` close
  // the usual XSS-escalation vectors (`<base href="evil://">`, `<object>`,
  // `<embed>`, Flash). `frame-ancestors 'none'` prevents the docs from
  // being embedded in a victim page.
  //
  // Dartdoc's HTML is also scrubbed at ingest (see dartdoc/sanitizer.dart)
  // so that stored-XSS vectors never reach the user's browser in the first
  // place; the strict CSP is defense-in-depth on top of that.
  const dartdocCsp =
      "default-src 'self'; "
      "base-uri 'self'; "
      "frame-ancestors 'none'; "
      "form-action 'self'; "
      "object-src 'none'; "
      "script-src 'self'; "
      "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
      "font-src 'self' data: https://fonts.gstatic.com; "
      "img-src 'self' https: data:; "
      "connect-src 'self'";

  return (Handler inner) {
    return (Request request) async {
      final response = await inner(request);
      final isDocs = request.url.path.startsWith('documentation/');
      // IMPORTANT: do NOT spread `...response.headers` here. That getter
      // returns a singleValues view that joins multi-value headers with
      // commas, which would then be re-stored as a single header on
      // change() — collapsing the `Set-Cookie` list emitted by login,
      // logout, and session revoke into one invalid comma-joined header.
      // `change()` already merges these keys into the existing headers
      // without disturbing the rest.
      return response.change(
        headers: {
          'content-security-policy': isDocs ? dartdocCsp : csp,
          'x-content-type-options': 'nosniff',
          'x-frame-options': 'DENY',
          'referrer-policy': 'strict-origin-when-cross-origin',
          // HSTS is only meaningful over HTTPS. Harmless to set on HTTP
          // (browsers ignore it when received insecurely) and saves a
          // config knob. 63072000 = 2 years.
          'strict-transport-security': 'max-age=63072000; includeSubDomains',
        },
      );
    };
  };
}
