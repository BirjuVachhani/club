import { api } from '$lib/api/client';
import type { PageLoad } from './$types';

/**
 * A `/api/discover` hit. `data` (package), `scoreInfo`, and `listInfo`
 * are bundled by the server so this page avoids an N+1 of follow-up
 * fetches. They are optional: a package the server failed to enrich
 * comes back as just `{ package, score }`.
 */
interface DiscoverHit {
  package: string;
  score: number;
  data?: any;
  scoreInfo?: any;
  listInfo?: ListInfoResponse;
}

interface DiscoverResponse {
  packages: DiscoverHit[];
  totalCount: number;
  page: number;
  pageSize: number;
}

export interface PackageListScreenshot {
  url: string;
  description: string | null;
}

export interface PackageListItem {
  name: string;
  description: string;
  version: string;
  likes: number;
  points: number;
  maxPoints: number;
  downloads: number;
  tags: string[];
  topics: string[];
  publishedAt: string | null;
  dartSdk: string | null;
  flutterSdk: string | null;
  repository: string | null;
  homepage: string | null;
  isDiscontinued: boolean;
  isUnlisted: boolean;
  publisher: { id: string; displayName: string; verified: boolean } | null;
  uploader: { displayName: string; email: string } | null;
  license: string | null;
  screenshots: PackageListScreenshot[];
}

interface ListInfoResponse {
  publisher: { id: string; displayName: string; verified: boolean } | null;
  uploaders: Array<{ displayName: string; email: string }>;
  license: string | null;
  screenshots?: Array<{ url: string; description: string | null }>;
}

export interface PackageListResults {
  packages: PackageListItem[];
  totalCount: number;
  pageSize: number;
}

/** A minimal row for a package the server could not enrich. */
function fallbackItem(name: string): PackageListItem {
  return {
    name,
    description: '',
    version: '',
    likes: 0,
    points: 0,
    maxPoints: 0,
    downloads: 0,
    tags: [],
    topics: [],
    publishedAt: null,
    dartSdk: null,
    flutterSdk: null,
    repository: null,
    homepage: null,
    isDiscontinued: false,
    isUnlisted: false,
    publisher: null,
    uploader: null,
    license: null,
    screenshots: [],
  };
}

/** Maps a discover hit's bundled payloads into a list-row model. */
function mapHit(hit: DiscoverHit): PackageListItem {
  const pkg = hit.data;
  if (!pkg) return fallbackItem(hit.package);

  const score = hit.scoreInfo;
  const listInfo = hit.listInfo;
  const pubspec = pkg.latest?.pubspec ?? {};
  const env = pubspec.environment ?? {};
  const firstUploader = listInfo?.uploaders?.[0] ?? null;
  return {
    name: pkg.name ?? hit.package,
    description: pubspec.description ?? '',
    version: pkg.latest?.version ?? '',
    likes: score?.likeCount ?? 0,
    points: score?.grantedPoints ?? 0,
    maxPoints: score?.maxPoints ?? 0,
    downloads: score?.downloadCount30Days ?? 0,
    tags: Array.isArray(score?.tags) ? score.tags : [],
    topics: Array.isArray(pubspec.topics) ? pubspec.topics : [],
    publishedAt: pkg.latest?.published ?? null,
    dartSdk: env.sdk ?? null,
    flutterSdk: env.flutter ?? null,
    repository: pubspec.repository ?? null,
    homepage: pubspec.homepage ?? null,
    isDiscontinued: pkg.isDiscontinued ?? false,
    isUnlisted: pkg.isUnlisted ?? false,
    publisher: listInfo?.publisher ?? null,
    uploader: firstUploader,
    license: listInfo?.license ?? null,
    screenshots: Array.isArray(listInfo?.screenshots)
      ? listInfo.screenshots
          .filter((s) => typeof s?.url === 'string' && s.url.length > 0)
          .map((s) => ({
            url: s.url,
            description:
              typeof s.description === 'string' && s.description.length > 0
                ? s.description
                : null,
          }))
      : [],
  };
}

/**
 * Runs a single enriched search request. The server bundles per-result
 * package/score/list-info, replacing the previous 1 + 3N fan-out.
 * Resolves to safe empty defaults on failure so the consuming `{#await}`
 * only needs a `:then` branch.
 */
async function fetchResults(
  q: string,
  sort: string,
  page: string,
): Promise<PackageListResults> {
  try {
    const result = await api.get<DiscoverResponse>('/api/discover', {
      params: { q, sort, page },
    });
    return {
      packages: result.packages.map(mapHit),
      totalCount: result.totalCount,
      pageSize: result.pageSize,
    };
  } catch {
    return { packages: [], totalCount: 0, pageSize: 20 };
  }
}

export const load: PageLoad = ({ url }) => {
  const q = url.searchParams.get('q') ?? '';
  const sort = url.searchParams.get('sort') ?? 'relevance';
  const page = url.searchParams.get('page') ?? '1';

  // `query`/`sort`/`page` come straight off the URL, so they're returned
  // resolved — the toolbar and sort control render instantly. The
  // enriched search is returned nested (not awaited) so the page shell
  // paints with skeletons while the results stream in.
  return {
    query: q,
    sort,
    page: parseInt(page, 10),
    streamed: { results: fetchResults(q, sort, page) },
  };
};
