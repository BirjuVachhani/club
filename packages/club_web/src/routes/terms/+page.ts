import { api } from '$lib/api/client';
import type { PageLoad } from './$types';

interface LegalResponse {
  markdown: string;
  isCustom: boolean;
}

export const load: PageLoad = async () => {
  const { markdown } = await api.get<LegalResponse>('/api/legal/terms');
  return { markdown };
};
