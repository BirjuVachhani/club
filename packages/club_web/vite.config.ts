import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [{
    name: 'isolate-site-runner',
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        const url = (request as unknown as { url?: string }).url;
        // Dev-only demo playback: exercise real download progress on localhost.
        // configureServer is never included in the production build.
        if (url && /^\/api\/packages\/club_gallery_demo\/sites\/[^/]+\/archive(?:\?|$)/.test(url)) {
          const incoming = request as unknown as {
            method: string; headers: Record<string, string | string[] | undefined>;
          };
          if (incoming.method !== 'GET') { next(); return; }
          const headers = new Headers();
          for (const [key, value] of Object.entries(incoming.headers)) {
            if (value && !['host', 'connection', 'if-none-match', 'if-modified-since', 'accept-encoding'].includes(key)) {
              headers.set(key, Array.isArray(value) ? value.join(', ') : value);
            }
          }
          void (async () => {
            try {
              const upstream = await fetch(new URL(url, 'http://localhost:8080'), { headers });
              response.statusCode = upstream.status;
              for (const key of ['content-type', 'etag', 'www-authenticate']) {
                const value = upstream.headers.get(key);
                if (value) response.setHeader(key, value);
              }
              response.setHeader('cache-control', 'no-store');
              const bytes = new Uint8Array(await upstream.arrayBuffer());
              response.setHeader('content-length', bytes.length);
              if (upstream.status !== 200) { response.end(bytes); return; }
              const size = Math.max(1, Math.ceil(bytes.length / 30));
              for (let offset = 0; offset < bytes.length; offset += size) {
                await new Promise(resolve => setTimeout(resolve, 200));
                if (response.destroyed) return;
                response.write(bytes.subarray(offset, offset + size));
              }
              response.end();
            } catch {
              if (!response.headersSent) response.statusCode = 502;
              response.end();
            }
          })();
          return;
        }
        if (url?.startsWith('/site-runner/') || url?.startsWith('/content/')) {
          response.statusCode = 404; response.end('Not found'); return;
        }
        next();
      });
    }
  }, tailwindcss(), sveltekit()],
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true
      },
      '/oauth': {
        target: 'http://localhost:8080',
        changeOrigin: true
      }
    }
  }
});
