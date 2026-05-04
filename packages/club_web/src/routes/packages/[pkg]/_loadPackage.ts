/**
 * Shared loader for `/packages/[pkg]` (latest stable) and
 * `/packages/[pkg]/versions/[version]` (a specific version).
 *
 * When `version` is provided, we hit the versioned endpoints
 * (`/api/packages/<pkg>/versions/<version>/...`) and merge the version-scoped
 * data into the same shape the existing page consumes. When `version` is
 * omitted, we hit the package-level endpoints (which resolve to the latest
 * stable).
 *
 * The returned shape is identical in both modes so the shared
 * `PackageView.svelte` component doesn't need to know which URL the data
 * came from.
 */

import { api } from '$lib/api/client';

// SvelteKit's filename-based convention doesn't export a data-loader
// signature we can import, so we accept a minimal generic params object.
export interface LoadPackageParams {
  pkg: string;
  /** When provided, load this specific version instead of the latest stable. */
  version?: string;
}

export interface PackageScreenshot {
  /** Absolute URL served by the club server — safe to use in `<img src>`. */
  url: string;
  /** Optional caption from pubspec.yaml, shown in the carousel overlay. */
  description: string | null;
}

export async function loadPackage({ pkg, version }: LoadPackageParams) {
  try {
    // `/api/packages/<pkg>` returns the full versions list — we always need
    // this for the Versions tab and for resolving `latest`.
    const packageDataP = api.get<any>(`/api/packages/${pkg}`);

    // When a specific version is requested, we override the
    // version-specific endpoints. Otherwise the server-level
    // (`/score`, `/content`) endpoints already resolve to latest stable.
    // encodeURIComponent is required because version strings can contain
    // `+` (build metadata), which some proxies decode as space.
    const v = version ? encodeURIComponent(version) : null;
    const scoreUrl = v
      ? `/api/packages/${pkg}/versions/${v}/score`
      : `/api/packages/${pkg}/score`;
    const contentUrl = v
      ? `/api/packages/${pkg}/versions/${v}/content`
      : `/api/packages/${pkg}/content`;
    const versionInfoUrl = v ? `/api/packages/${pkg}/versions/${v}` : null;

    const [packageData, score, content, versionInfo, likesData, permissions] =
      await Promise.all([
        packageDataP,
        api.get<any>(scoreUrl).catch(() => null),
        api.get<any>(contentUrl).catch(() => null),
        versionInfoUrl
          ? api.get<any>(versionInfoUrl).catch(() => null)
          : Promise.resolve(null),
        api.get<any>(`/api/account/likes`).catch(() => null),
        api.get<any>(`/api/packages/${pkg}/permissions`).catch(() => null),
      ]);

    const likedPackages: string[] = (likesData?.likedPackages ?? []).map(
      (l: any) => l.package,
    );
    const isLiked = likedPackages.includes(pkg);

    // Prefer the explicit version's pubspec when we asked for one; fall back
    // to the latest pubspec for the default route.
    const pubspec = version
      ? versionInfo?.pubspec ?? {}
      : packageData?.latest?.pubspec ?? {};
    const deps = pubspec.dependencies ?? {};
    const env = pubspec.environment ?? {};
    const declaredExecutables = pubspec.executables ?? {};
    // Dart files directly in `bin/` are implicit executables even without
    // a matching `executables:` entry — union the two so the Installing
    // tab shows the section for either source.
    const binExecutables: string[] = Array.isArray(content?.binExecutables)
      ? content.binExecutables
      : [];

    const screenshots: PackageScreenshot[] = Array.isArray(content?.screenshots)
      ? content.screenshots
          .filter((s: any) => typeof s?.url === 'string' && s.url.length > 0)
          .map((s: any) => ({
            url: s.url,
            description:
              typeof s.description === 'string' && s.description.length > 0
                ? s.description
                : null,
          }))
      : [];
    const executables = Array.from(
      new Set<string>([
        ...Object.keys(declaredExecutables),
        ...binExecutables,
      ]),
    );

    // Auto-detect Flutter so the Installing tab shows `flutter pub add`
    // instead of `dart pub add`. Matches pub.dev's detection: either
    // `flutter` SDK is in environment, or any dep mentions `sdk: flutter`.
    const usesFlutter =
      !!env.flutter ||
      Object.values(deps).some(
        (v: any) => typeof v === 'object' && v && v.sdk === 'flutter',
      );

    const displayedVersion = version
      ? versionInfo?.version ?? version
      : packageData.latest?.version ?? '';
    const displayedPublishedAt = version
      ? versionInfo?.published ?? null
      : packageData.latest?.published ?? null;

    const latestStableVersion = packageData.latest?.version ?? '';
    const isLatest = !version || displayedVersion === latestStableVersion;

    // Only set by the server when a prerelease is strictly greater than
    // the latest stable (semver comparison via pub_semver). Used by the
    // header to show "Latest: x.y.z / Prerelease: a.b.c".
    const latestPrereleaseVersion: string | null =
      packageData.latestPrerelease?.version ?? null;

    return {
      pkg: {
        name: packageData.name,
        version: displayedVersion,
        description: pubspec.description ?? '',
        publishedAt: displayedPublishedAt,
        isDiscontinued: packageData.isDiscontinued ?? false,
        isUnlisted: packageData.isUnlisted ?? false,
        replacedBy: packageData.replacedBy ?? null,
        repository: pubspec.repository ?? pubspec.homepage ?? null,
        homepage: pubspec.homepage ?? null,
        documentation: pubspec.documentation ?? null,
        // Pre-computed so the template never crashes on malformed URLs
        // (e.g. `github.com/foo` with no scheme).
        homepageHost: _hostOf(pubspec.homepage),
        issueTracker: pubspec.issue_tracker ?? null,
        // Raw map straight from the pubspec — the sidebar renderer
        // normalizes string/hosted/sdk/git shapes into displayable links so
        // hosted-on-other-server deps and SDK/git deps don't get dropped.
        dependencies: deps,
        dartSdk: env.sdk ?? null,
        flutterSdk: env.flutter ?? null,
        // All versions (newest first). Used by the Versions tab.
        versions: (packageData.versions ?? [])
          .map((v: any) => ({
            version: v.version,
            published: v.published,
            retracted: v.retracted ?? false,
            isPrerelease: _isPrerelease(v.version),
            minDartSdk: _minSdk(v.pubspec?.environment?.sdk),
          }))
          .reverse(),
        readme: content?.readme ?? null,
        changelog: content?.changelog ?? null,
        example: content?.example ?? null,
        examplePath: content?.examplePath ?? null,
        topics: Array.isArray(pubspec.topics) ? pubspec.topics : [],
        executables,
        usesFlutter,
        screenshots,

        // Context flags used by the "viewing older version" banner and to
        // decide whether to hide retracted markers on the current version.
        isLatest,
        latestStableVersion,
        latestPrereleaseVersion,
        isViewingPrerelease: version ? _isPrerelease(displayedVersion) : false,
      },
      score: score
        ? {
            likes: score.likeCount ?? 0,
            points: score.grantedPoints ?? 0,
            maxPoints: score.maxPoints ?? 0,
            downloads: score.downloadCount30Days ?? 0,
            tags: score.tags ?? [],
          }
        : { likes: 0, points: 0, maxPoints: 0, downloads: 0, tags: [] },
      isLiked,
      canAdmin: permissions?.isAdmin ?? false,
    };
  } catch {
    return { pkg: null, score: null, isLiked: false, canAdmin: false };
  }
}

/**
 * Extract the minimum Dart SDK version from a pubspec environment constraint.
 * Handles `^3.0.0`, `>=2.17.0 <4.0.0`, bare `3.0.0`, and falls back to the raw
 * constraint string when none of those shapes match.
 */
function _minSdk(constraint: unknown): string | null {
  if (typeof constraint !== 'string') return null;
  const trimmed = constraint.trim();
  if (!trimmed) return null;
  const caret = trimmed.match(/^\^(\d+\.\d+(?:\.\d+)?)/);
  if (caret) return caret[1];
  const gte = trimmed.match(/>=\s*(\d+\.\d+(?:\.\d+)?)/);
  if (gte) return gte[1];
  const exact = trimmed.match(/^(\d+\.\d+(?:\.\d+)?)$/);
  if (exact) return exact[1];
  return trimmed;
}

/** Semver prerelease — presence of `-` in the base version portion. */
function _isPrerelease(version: string): boolean {
  if (!version) return false;
  // Strip build metadata then check for prerelease suffix.
  const base = version.split('+')[0];
  return base.includes('-');
}

/**
 * Safely extract the hostname from a homepage URL. Returns the raw input
 * string when the URL can't be parsed (e.g. pubspec homepage without a
 * scheme like "github.com/foo/bar") so the link still shows something
 * recognisable instead of crashing the page.
 */
function _hostOf(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}
