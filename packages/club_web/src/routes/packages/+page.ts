import { api } from '$lib/api/client';
import type { PackageGroupSummary } from '$lib/types/catalog';
import type { PageLoad } from './$types';

interface DiscoverHit {
  type: 'package' | 'group';
  package?: string;
  score: number;
  data?: any;
  scoreInfo?: any;
  listInfo?: ListInfoResponse;
  group?: PackageGroupSummary;
}

interface DiscoverResponse {
  items: DiscoverHit[];
  totalCount: number;
  packageCount: number;
  groupCount: number;
  page: number;
  pageSize: number;
}

export interface PackageListScreenshot { url: string; description: string | null; }
export interface PackageListItem {
  name: string; description: string; version: string; likes: number;
  points: number; maxPoints: number; downloads: number; tags: string[];
  topics: string[]; publishedAt: string | null; dartSdk: string | null;
  flutterSdk: string | null; repository: string | null; homepage: string | null;
  isDiscontinued: boolean; isUnlisted: boolean;
  publisher: { id: string; displayName: string; verified: boolean } | null;
  uploader: { displayName: string; email: string } | null;
  license: string | null; screenshots: PackageListScreenshot[];
}
interface ListInfoResponse {
  publisher: { id: string; displayName: string; verified: boolean } | null;
  uploaders: Array<{ displayName: string; email: string }>;
  license: string | null;
  screenshots?: Array<{ url: string; description: string | null }>;
}
export type CatalogListItem =
  | { type: 'package'; package: PackageListItem }
  | { type: 'group'; group: PackageGroupSummary };
export interface PackageListResults {
  items: CatalogListItem[];
  totalCount: number;
  packageCount: number;
  groupCount: number;
  pageSize: number;
}

function fallbackItem(name: string): PackageListItem {
  return { name, description: '', version: '', likes: 0, points: 0, maxPoints: 0,
    downloads: 0, tags: [], topics: [], publishedAt: null, dartSdk: null,
    flutterSdk: null, repository: null, homepage: null, isDiscontinued: false,
    isUnlisted: false, publisher: null, uploader: null, license: null, screenshots: [] };
}

function mapPackage(hit: DiscoverHit): PackageListItem {
  const name = hit.package ?? '';
  const pkg = hit.data;
  if (!pkg) return fallbackItem(name);
  const score = hit.scoreInfo;
  const listInfo = hit.listInfo;
  const pubspec = pkg.latest?.pubspec ?? {};
  const env = pubspec.environment ?? {};
  return {
    name: pkg.name ?? name, description: pubspec.description ?? '',
    version: pkg.latest?.version ?? '', likes: score?.likeCount ?? 0,
    points: score?.grantedPoints ?? 0, maxPoints: score?.maxPoints ?? 0,
    downloads: score?.downloadCount30Days ?? 0,
    tags: Array.isArray(score?.tags) ? score.tags : [],
    topics: Array.isArray(pubspec.topics) ? pubspec.topics : [],
    publishedAt: pkg.latest?.published ?? null, dartSdk: env.sdk ?? null,
    flutterSdk: env.flutter ?? null, repository: pubspec.repository ?? null,
    homepage: pubspec.homepage ?? null, isDiscontinued: pkg.isDiscontinued ?? false,
    isUnlisted: pkg.isUnlisted ?? false, publisher: listInfo?.publisher ?? null,
    uploader: listInfo?.uploaders?.[0] ?? null, license: listInfo?.license ?? null,
    screenshots: Array.isArray(listInfo?.screenshots)
      ? listInfo.screenshots.filter((s) => typeof s?.url === 'string' && s.url.length > 0)
          .map((s) => ({ url: s.url, description: typeof s.description === 'string' && s.description ? s.description : null }))
      : [],
  };
}

async function fetchResults(q: string, sort: string, page: string, type: string): Promise<PackageListResults> {
  try {
    const result = await api.get<DiscoverResponse>('/api/discover', {
      params: { q, sort, page, ...(type !== 'all' ? { type } : {}) },
    });
    return {
      items: result.items.flatMap((hit): CatalogListItem[] => {
        if (hit.type === 'group' && hit.group) return [{ type: 'group', group: hit.group }];
        return [{ type: 'package', package: mapPackage(hit) }];
      }),
      totalCount: result.totalCount, packageCount: result.packageCount,
      groupCount: result.groupCount, pageSize: result.pageSize,
    };
  } catch {
    return { items: [], totalCount: 0, packageCount: 0, groupCount: 0, pageSize: 20 };
  }
}

export const load: PageLoad = ({ url }) => {
  const q = url.searchParams.get('q') ?? '';
  const sort = url.searchParams.get('sort') ?? 'relevance';
  const page = url.searchParams.get('page') ?? '1';
  const type = url.searchParams.get('type') ?? 'all';
  return { query: q, sort, type, page: parseInt(page, 10),
    streamed: { results: fetchResults(q, sort, page, type) } };
};
