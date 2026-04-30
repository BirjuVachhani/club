import { api } from '$lib/api/client';
import type { PageLoad } from './$types';

interface SearchResponse {
  packages: Array<{ package: string; score: number }>;
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

export const load: PageLoad = async ({ url }) => {
  const q = url.searchParams.get('q') ?? '';
  const sort = url.searchParams.get('sort') ?? 'relevance';
  const page = url.searchParams.get('page') ?? '1';

  try {
    const searchResult = await api.get<SearchResponse>('/api/search', {
      params: { q, sort, page },
    });

    // Fetch details + score for each package in the search results
    const packages: PackageListItem[] = await Promise.all(
      searchResult.packages.map(async (hit) => {
        try {
          const [pkg, score, listInfo] = await Promise.all([
            api.get<any>(`/api/packages/${hit.package}`),
            api
              .get<any>(`/api/packages/${hit.package}/score`)
              .catch(() => null),
            api
              .get<ListInfoResponse>(`/api/packages/${hit.package}/list-info`)
              .catch(() => null),
          ]);
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
        } catch {
          return {
            name: hit.package,
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
      }),
    );

    return {
      packages,
      totalCount: searchResult.totalCount,
      query: q,
      sort,
      page: parseInt(page),
      pageSize: searchResult.pageSize,
    };
  } catch {
    return {
      packages: [] as PackageListItem[],
      totalCount: 0,
      query: q,
      sort,
      page: parseInt(page),
      pageSize: 20,
    };
  }
};
