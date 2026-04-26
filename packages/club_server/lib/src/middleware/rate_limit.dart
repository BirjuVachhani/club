import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';

/// Simple in-memory token-bucket rate limiter keyed by client IP.
///
/// Used to slow down credential stuffing on `/api/auth/login`, brute force
/// of the setup code on `/api/setup/verify`, and similar auth choke
/// points. Each guarded route carries its own bucket so a user who
/// tripped the login limit can still hit /me or other endpoints.
///
/// In-memory is correct for a single-process server (club's deployment
/// model). If CLUB ever goes multi-node, swap the store for Redis.
///
/// The bucket map is bounded (see [maxKeys]) with LRU eviction — an
/// attacker rotating through IPv6 /64s cannot grow memory without bound.
/// A periodic sweeper also drops buckets whose entries are all outside
/// the rolling window so idle keys don't accumulate forever. The
/// sweeper is internal to the limiter — managing its own stale state
/// is part of what a self-bounded rate limiter does (same pattern a
/// cache uses to manage its own eviction).
class RateLimiter {
  RateLimiter({
    required this.maxRequests,
    required this.window,
    required this.trustProxy,
    this.maxKeys = 10000,
    Duration sweepInterval = const Duration(minutes: 1),
  }) {
    _sweepTimer = Timer.periodic(sweepInterval, (_) => _sweep());
  }

  /// Maximum requests allowed within [window] per key.
  final int maxRequests;

  /// Rolling window size. Each entry in a bucket lives for this duration.
  final Duration window;

  /// Whether to use `X-Forwarded-For` for key derivation. Must match the
  /// server's proxy trust setting — otherwise clients can trivially bypass
  /// the limiter by sending a fake XFF header.
  final bool trustProxy;

  /// Upper bound on distinct keys we retain. If an attacker rotates
  /// through more than this many IPs, we LRU-evict the oldest. Legit
  /// users retain their counters because their key is kept warm.
  final int maxKeys;

  /// Insertion-ordered map — `_buckets.keys.first` is the LRU key.
  final Map<String, List<DateTime>> _buckets = <String, List<DateTime>>{};

  late final Timer _sweepTimer;

  /// Returns true if the request should proceed; false if it's over the
  /// limit. Records the hit regardless (a blocked attacker still counts
  /// against their own budget so they can't reset by hitting more).
  bool check(String key) {
    final now = DateTime.now().toUtc();
    final cutoff = now.subtract(window);

    // Touch the key so LRU treats it as recently used.
    final bucket = _buckets.remove(key) ?? <DateTime>[];
    bucket.removeWhere((t) => t.isBefore(cutoff));
    _buckets[key] = bucket;

    // Cap memory. Evict LRU entries (iteration order == insertion order,
    // which we just refreshed for the current key).
    while (_buckets.length > maxKeys) {
      _buckets.remove(_buckets.keys.first);
    }

    if (bucket.length >= maxRequests) {
      return false;
    }
    bucket.add(now);
    return true;
  }

  /// Remaining capacity in the current window (informational — used for
  /// friendlier error messages, never relied on for enforcement).
  Duration retryAfter(String key) {
    final bucket = _buckets[key];
    if (bucket == null || bucket.isEmpty) return Duration.zero;
    final oldest = bucket.first;
    final remaining = window - DateTime.now().toUtc().difference(oldest);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String keyFor(Request request) {
    if (trustProxy) {
      final xff = request.headers['x-forwarded-for'];
      if (xff != null && xff.isNotEmpty) {
        return xff.split(',').first.trim();
      }
    }
    final conn = request.context['shelf.io.connection_info'];
    if (conn is HttpConnectionInfo) {
      return conn.remoteAddress.address;
    }
    return 'unknown';
  }

  /// Drop buckets whose entries are all outside the rolling window.
  /// Called periodically by [_sweepTimer] so idle keys don't pile up
  /// forever. Cheap — single pass over the bucket map.
  void _sweep() {
    final cutoff = DateTime.now().toUtc().subtract(window);
    _buckets.removeWhere(
      (_, bucket) => bucket.every((t) => t.isBefore(cutoff)),
    );
  }

  /// Exposed for tests and shutdown symmetry. Production never stops
  /// the limiter — it lives as long as the server process, and the
  /// timer dies with the isolate.
  void dispose() => _sweepTimer.cancel();
}

/// Bundle of every [RateLimiter] the server uses. Owned by the bootstrap
/// layer (so it can register their [RateLimiter.sweep] methods with the
/// `Scheduler`) and passed into the router so it can wire each limiter
/// onto the appropriate route.
class RateLimiters {
  RateLimiters({
    required this.login,
    required this.signup,
    required this.setup,
    required this.invite,
  });

  final RateLimiter login;
  final RateLimiter signup;
  final RateLimiter setup;
  final RateLimiter invite;

  /// All limiters in one list, for iteration in the scheduler.
  List<RateLimiter> get all => [login, signup, setup, invite];

  /// Deliberately-tuned production defaults. Numbers are conservative —
  /// honest users hit these endpoints a handful of times, attackers
  /// orders of magnitude more.
  factory RateLimiters.defaults({required bool trustProxy}) {
    // Login is the credential-stuffing target.
    final login = RateLimiter(
      maxRequests: 10,
      window: const Duration(minutes: 15),
      trustProxy: trustProxy,
    );
    // Signup shares login's ceiling: timing equalization in createUser
    // removes the direct oracle, but a high-throughput signup loop could
    // still probe via DB-lookup timing. Per-IP cap keeps that expensive.
    final signup = RateLimiter(
      maxRequests: 10,
      window: const Duration(minutes: 15),
      trustProxy: trustProxy,
    );
    // Setup brute-forces the 6-digit verify code.
    final setup = RateLimiter(
      maxRequests: 5,
      window: const Duration(minutes: 15),
      trustProxy: trustProxy,
    );
    // Invite acceptance is the "first password" flow for admin-created
    // users. An attacker who grabs an invite token (e.g. via leaked
    // email) gets a small budget per window before backing off.
    final invite = RateLimiter(
      maxRequests: 10,
      window: const Duration(minutes: 15),
      trustProxy: trustProxy,
    );
    return RateLimiters(
      login: login,
      signup: signup,
      setup: setup,
      invite: invite,
    );
  }
}

/// Middleware that enforces [limiter] on requests whose path matches any
/// entry in [paths] (exact match) or starts with any entry in
/// [prefixPaths] (prefix match). Non-matching requests pass through
/// untouched.
Middleware rateLimitMiddleware({
  required RateLimiter limiter,
  Set<String> paths = const {},
  Set<String> prefixPaths = const {},
}) {
  return (Handler inner) {
    return (Request request) async {
      final path = '/${request.url.path}';
      final matches =
          paths.contains(path) || prefixPaths.any((p) => path.startsWith(p));
      if (!matches) return inner(request);

      final key = limiter.keyFor(request);
      if (!limiter.check(key)) {
        final retry = limiter.retryAfter(key);
        return Response(
          429,
          body:
              '{"error":{"code":"RateLimited","message":"Too many requests. Try again in ${retry.inSeconds}s."}}',
          headers: {
            'content-type': 'application/json',
            'retry-after': '${retry.inSeconds.clamp(1, 3600)}',
          },
        );
      }
      return inner(request);
    };
  };
}
