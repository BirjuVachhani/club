import { api } from '$lib/api/client';
import type { PageLoad } from './$types';

/**
 * A `/api/discover` hit. `data` (package), `scoreInfo`, and `listInfo`
 * are bundled by the server so list pages avoid an N+1 of follow-up
 * fetches. They are optional: a package the server failed to enrich
 * comes back as just `{ package, score }`.
 */
interface DiscoverHit {
  package: string;
  score: number;
  data?: any;
  scoreInfo?: any;
  listInfo?: any;
}

interface DiscoverResponse {
  packages: DiscoverHit[];
  totalCount: number;
  page: number;
  pageSize: number;
}

export interface HomePackage {
  name: string;
  description: string;
  version: string;
  publishedAt: string | null;
  repository: string | null;
  homepage: string | null;
  isFlutter: boolean;
}

export interface HomeData {
  dartPackages: HomePackage[];
  flutterPackages: HomePackage[];
  recentlyUpdated: HomePackage[];
  recentlyAdded: HomePackage[];
  totalPackages: number;
}

/** Maps a discover hit's bundled package data into a home-card model. */
function mapHit(hit: DiscoverHit): HomePackage | null {
  const data = hit.data;
  if (!data) return null;
  const pubspec = data.latest?.pubspec ?? {};
  const env = pubspec.environment ?? {};
  const deps = pubspec.dependencies ?? {};
  const isFlutter = Boolean(
    env?.flutter || (deps && typeof deps === 'object' && 'flutter' in deps) || pubspec.flutter,
  );
  return {
    name: data.name ?? hit.package,
    description: pubspec.description ?? '',
    version: data.latest?.version ?? '',
    publishedAt: data.latest?.published ?? null,
    repository: pubspec.repository ?? null,
    homepage: pubspec.homepage ?? null,
    isFlutter,
  };
}

async function fetchSection(
  sort: string,
  limit = 6,
): Promise<{ packages: HomePackage[]; total: number }> {
  try {
    const result = await api.get<DiscoverResponse>('/api/discover', {
      params: { q: '', sort, page: '1' },
    });
    const packages = result.packages
      .slice(0, limit)
      .map(mapHit)
      .filter((p): p is HomePackage => p !== null);
    return { packages, total: result.totalCount };
  } catch {
    return { packages: [], total: 0 };
  }
}

/**
 * Fetches every section the home page renders. Resolves to safe empty
 * defaults on failure so the consuming `{#await}` only needs a `:then`
 * branch.
 */
async function buildHome(): Promise<HomeData> {
  const [buckets, updated, added] = await Promise.all([
    // Pull a larger set sorted by updated so we have enough to split into
    // Dart and Flutter buckets for the home page.
    (async () => {
      try {
        const result = await api.get<DiscoverResponse>('/api/discover', {
          params: { q: '', sort: 'updated', page: '1' },
        });
        const all = result.packages
          .map(mapHit)
          .filter((p): p is HomePackage => p !== null);
        return {
          dart: all.filter((p) => !p.isFlutter).slice(0, 6),
          flutter: all.filter((p) => p.isFlutter).slice(0, 6),
          total: result.totalCount,
        };
      } catch {
        return { dart: [] as HomePackage[], flutter: [] as HomePackage[], total: 0 };
      }
    })(),
    fetchSection('updated'),
    fetchSection('created'),
  ]);

  return {
    dartPackages: buckets.dart,
    flutterPackages: buckets.flutter,
    recentlyUpdated: updated.packages,
    recentlyAdded: added.packages,
    totalPackages: buckets.total,
  };
}

export const load: PageLoad = () => {
  // Returned nested (not awaited) so the page paints its hero + skeletons
  // immediately while the package sections stream in. SvelteKit awaits
  // top-level promises but passes nested ones straight through.
  return { streamed: { home: buildHome() } };
};
