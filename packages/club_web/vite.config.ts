import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [{
    name: 'isolate-site-runner',
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        const url = (request as unknown as { url?: string }).url;
        if (url && /%(?:2f|5c)/i.test(url.split('?')[0])) {
          response.statusCode = 404; response.end('Not found'); return;
        }
        let pathname: string;
        try { pathname = new URL(decodeURIComponent(url?.split('?')[0] ?? '/'), 'http://localhost').pathname; }
        catch { response.statusCode = 404; response.end('Not found'); return; }
        // SvelteKit serves static files before Vite's regular proxy. Forward
        // runtime assets here so direct dev visits retain the HTTP sandbox.
        if (pathname.startsWith('/site-runner/')) {
          const method = (request as unknown as { method?: string }).method;
          void (async () => {
            try {
              const upstream = await fetch(new URL(pathname, 'http://localhost:8080'), { method });
              response.statusCode = upstream.status;
              for (const key of ['content-type', 'cache-control', 'content-security-policy', 'access-control-allow-origin', 'referrer-policy', 'x-content-type-options', 'x-frame-options']) {
                const value = upstream.headers.get(key);
                if (value) response.setHeader(key, value);
              }
              response.end(new Uint8Array(await upstream.arrayBuffer()));
            } catch {
              response.statusCode = 502;
              response.end('Preview runtime unavailable');
            }
          })();
          return;
        }
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
        if (pathname.startsWith('/content/')) {
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
