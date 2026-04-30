import { api } from '$lib/api/client';
import type { PageLoad } from './$types';

interface SearchResponse {
  packages: Array<{ package: string; score: number }>;
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

async function fetchHit(name: string): Promise<HomePackage | null> {
  try {
    const pkg = await api.get<any>(`/api/packages/${name}`);
    const pubspec = pkg.latest?.pubspec ?? {};
    const env = pubspec.environment ?? {};
    const deps = pubspec.dependencies ?? {};
    const isFlutter = Boolean(
      env?.flutter || (deps && typeof deps === 'object' && 'flutter' in deps) || pubspec.flutter,
    );
    return {
      name: pkg.name ?? name,
      description: pubspec.description ?? '',
      version: pkg.latest?.version ?? '',
      publishedAt: pkg.latest?.published ?? null,
      repository: pubspec.repository ?? null,
      homepage: pubspec.homepage ?? null,
      isFlutter,
    };
  } catch {
    return null;
  }
}

async function fetchSection(
  sort: string,
  limit = 6,
): Promise<{ packages: HomePackage[]; total: number }> {
  try {
    const result = await api.get<SearchResponse>('/api/search', {
      params: { q: '', sort, page: '1' },
    });

    const packages = (
      await Promise.all(result.packages.slice(0, limit).map((h) => fetchHit(h.package)))
    ).filter((p): p is HomePackage => p !== null);

    return { packages, total: result.totalCount };
  } catch {
    return { packages: [], total: 0 };
  }
}

export const load: PageLoad = async () => {
  const [buckets, updated, added] = await Promise.all([
    // Pull a larger set sorted by updated so we have enough to split into
    // Dart and Flutter buckets for the home page.
    (async () => {
      try {
        const result = await api.get<SearchResponse>('/api/search', {
          params: { q: '', sort: 'updated', page: '1' },
        });
        const all = (
          await Promise.all(result.packages.map((h) => fetchHit(h.package)))
        ).filter((p): p is HomePackage => p !== null);
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
};
