import type { PageLoad } from './$types';
import { loadPackage } from '../../_loadPackage';

export const load: PageLoad = ({ params }) => {
  // Returned nested (not awaited) so the page paints a skeleton
  // immediately while the version data streams in.
  return {
    streamed: {
      detail: loadPackage({ pkg: params.pkg, version: params.version }),
    },
  };
};
