import { defineConfig } from 'astro/config';
import { fileURLToPath } from 'node:url';
import sitemap from '@astrojs/sitemap';
import svelte from '@astrojs/svelte';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'http://club.birju.dev',
  integrations: [
    svelte(),
    sitemap({
      filter: (page) => !page.includes('/dev/'),
    }),
  ],
  vite: {
    plugins: [tailwindcss()],
    resolve: {
      alias: {
        // motion-core CLI writes SvelteKit-style `$lib/...` imports. Point
        // that alias at our src/lib so the Rubik's Cube component resolves.
        $lib: fileURLToPath(new URL('./src/lib', import.meta.url)),
      },
    },
  },
});
