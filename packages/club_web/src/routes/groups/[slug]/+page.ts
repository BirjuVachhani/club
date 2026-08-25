import { api } from '$lib/api/client';
import type { PackageGroupDetail } from '$lib/types/catalog';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ params, url }) => {
  const page = url.searchParams.get('page') ?? '0';
  const [group, packages] = await Promise.all([
    api.get<PackageGroupDetail>(`/api/groups/${params.slug}`),
    api.get<any>(`/api/groups/${params.slug}/packages`, { params: { page } }),
  ]);
  return { group, packages };
};
