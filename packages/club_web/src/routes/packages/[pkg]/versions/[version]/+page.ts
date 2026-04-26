import type { PageLoad } from './$types';
import { loadPackage } from '../../_loadPackage';

export const load: PageLoad = async ({ params }) => {
  return loadPackage({ pkg: params.pkg, version: params.version });
};
