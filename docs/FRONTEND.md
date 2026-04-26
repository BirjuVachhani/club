# club — Frontend (SvelteKit)

The club web UI is a SvelteKit application that mirrors pub.dev's design.
It's built as a static export using `adapter-static` and served by the Dart
shelf server. No Node.js runs at runtime.

---

## Architecture

```
Build time (Docker):
  SvelteKit + adapter-static
    → npm run build
    → /build/ (HTML, JS, CSS)
    → Copied into Docker image

Runtime:
  Dart shelf server
    ├── /api/*     → JSON API handlers
    └── /*         → shelf_static serves SvelteKit build output
                     SvelteKit client-side router handles navigation
                     Pages call /api/* via fetch()
```

### Why Static Export

- **Single container**: No Node.js process alongside the Dart server
- **Fast**: Static files are served directly, no server-side rendering overhead
- **Simple**: The Dart server just serves files + API — no template engine needed
- **Cacheable**: Static assets get far-future cache headers

### How SPA Routing Works

The Dart server has a fallback rule: any request that doesn't match `/api/*`
and doesn't match a static file gets served `index.html`. SvelteKit's
client-side router then handles the URL and renders the correct page.

```dart
// In club_server router setup:
// 1. API routes (exact match)
// 2. Static files (if file exists in /app/static/web/)
// 3. Fallback: serve /app/static/web/index.html (SPA fallback)
```

Since we use `adapter-static` with `fallback: 'index.html'`, SvelteKit
generates a single `index.html` that bootstraps the client-side app.

---

## Project Structure

```
packages/club_web/
├── src/
│   ├── app.html                        # HTML shell (head, body)
│   ├── app.css                         # Global styles (imports pub.dev CSS)
│   ├── routes/
│   │   ├── +layout.svelte              # Root layout: header, footer, dark mode
│   │   ├── +layout.ts                  # Auth guard: redirect to /login if no token
│   │   ├── +page.svelte                # / → redirect to /packages
│   │   ├── login/
│   │   │   └── +page.svelte            # Login form
│   │   ├── packages/
│   │   │   ├── +page.svelte            # Package listing + search
│   │   │   ├── +page.ts                # Load: GET /api/search
│   │   │   └── [pkg]/
│   │   │       ├── +page.svelte        # Package detail (readme tab)
│   │   │       ├── +page.ts            # Load: GET /api/packages/<pkg>
│   │   │       ├── changelog/
│   │   │       │   └── +page.svelte
│   │   │       ├── versions/
│   │   │       │   ├── +page.svelte
│   │   │       │   └── +page.ts
│   │   │       ├── install/
│   │   │       │   └── +page.svelte
│   │   │       └── admin/
│   │   │           ├── +page.svelte
│   │   │           └── +page.ts
│   │   ├── publishers/
│   │   │   ├── +page.svelte
│   │   │   └── [id]/
│   │   │       ├── +page.svelte
│   │   │       └── +page.ts
│   │   ├── my-packages/
│   │   │   ├── +page.svelte
│   │   │   └── +page.ts
│   │   ├── my-liked-packages/
│   │   │   ├── +page.svelte
│   │   │   └── +page.ts
│   │   ├── settings/
│   │   │   └── tokens/
│   │   │       ├── +page.svelte
│   │   │       └── +page.ts
│   │   └── admin/
│   │       ├── users/
│   │       │   ├── +page.svelte
│   │       │   └── +page.ts
│   │       └── packages/
│   │           ├── +page.svelte
│   │           └── +page.ts
│   └── lib/
│       ├── components/
│       │   ├── PackageCard.svelte       # Package list item
│       │   ├── PackageHeader.svelte     # Package detail header
│       │   ├── InfoBox.svelte           # Package sidebar
│       │   ├── TabLayout.svelte         # Tabbed content
│       │   ├── TagBadge.svelte          # SDK/platform/status tags
│       │   ├── LikeButton.svelte        # Optimistic like toggle
│       │   ├── MarkdownRenderer.svelte  # Markdown → HTML with syntax highlighting
│       │   ├── SearchBar.svelte         # Search input with autocomplete
│       │   ├── FilterSidebar.svelte     # SDK, platform, status filters
│       │   ├── Pagination.svelte        # Page navigation
│       │   ├── SortControl.svelte       # Sort dropdown
│       │   ├── PublisherBadge.svelte    # Publisher display
│       │   ├── VersionList.svelte       # Version history table
│       │   ├── UploaderList.svelte      # Uploader management
│       │   └── SiteHeader.svelte        # Navigation bar
│       ├── stores/
│       │   ├── auth.ts                  # Auth state: token, user, isAdmin
│       │   └── theme.ts                 # Dark/light mode preference
│       ├── api/
│       │   └── client.ts               # Typed fetch wrapper for /api/*
│       └── utils/
│           ├── markdown.ts             # Markdown rendering config
│           └── format.ts               # Date, number formatting
├── static/
│   ├── css/
│   │   └── style.css                   # Compiled from pub.dev SCSS
│   ├── img/
│   │   ├── club-logo.svg             # club branding
│   │   └── ...                         # Icons from pub.dev
│   ├── material/                       # Material Design component bundle
│   └── favicon.ico
├── svelte.config.js
├── vite.config.ts
├── tsconfig.json
├── package.json
└── package-lock.json
```

---

## Configuration

### svelte.config.js

```javascript
import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

export default {
  kit: {
    adapter: adapter({
      pages: 'build',
      assets: 'build',
      fallback: 'index.html',  // SPA fallback for client-side routing
      precompress: true,        // Generate .br and .gz for static assets
      strict: false,            // Allow dynamic routes
    }),
    paths: {
      base: '',
    },
  },
  preprocess: vitePreprocess(),
};
```

### vite.config.ts

```typescript
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [sveltekit()],
  server: {
    proxy: {
      // During development, proxy API calls to the Dart server
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },
});
```

---

## Key Patterns

### Data Loading

Each page has a `+page.ts` that fetches data from the API:

```typescript
// src/routes/packages/[pkg]/+page.ts
import { api } from '$lib/api/client';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ params, fetch }) => {
  const [pkg, score] = await Promise.all([
    api.get(`/api/packages/${params.pkg}`, { fetch }),
    api.get(`/api/packages/${params.pkg}/score`, { fetch }),
  ]);

  return { package: pkg, score };
};
```

### API Client

A thin typed wrapper around `fetch`:

```typescript
// src/lib/api/client.ts
import { get } from 'svelte/store';
import { authToken } from '$lib/stores/auth';

class ApiClient {
  async get<T>(path: string, opts?: { fetch?: typeof fetch }): Promise<T> {
    const f = opts?.fetch ?? fetch;
    const token = get(authToken);
    const res = await f(path, {
      headers: {
        'Accept': 'application/vnd.pub.v2+json',
        ...(token ? { 'Authorization': `Bearer ${token}` } : {}),
      },
    });
    if (!res.ok) {
      const error = await res.json();
      throw new ApiError(res.status, error.error?.code, error.error?.message);
    }
    return res.json();
  }

  async post<T>(path: string, body: unknown, opts?: { fetch?: typeof fetch }): Promise<T> {
    const f = opts?.fetch ?? fetch;
    const token = get(authToken);
    const res = await f(path, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/vnd.pub.v2+json',
        ...(token ? { 'Authorization': `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const error = await res.json();
      throw new ApiError(res.status, error.error?.code, error.error?.message);
    }
    return res.json();
  }

  async put<T>(path: string, body: unknown, opts?: { fetch?: typeof fetch }): Promise<T> { ... }
  async delete(path: string, opts?: { fetch?: typeof fetch }): Promise<void> { ... }
}

export const api = new ApiClient();
```

### Auth Store

```typescript
// src/lib/stores/auth.ts
import { writable, derived } from 'svelte/store';
import { browser } from '$app/environment';

const STORAGE_KEY = 'club_auth';

function loadFromStorage() {
  if (!browser) return null;
  const raw = localStorage.getItem(STORAGE_KEY);
  return raw ? JSON.parse(raw) : null;
}

export const authState = writable(loadFromStorage());

export const authToken = derived(authState, ($s) => $s?.token ?? null);
export const currentUser = derived(authState, ($s) => $s?.user ?? null);
export const isAdmin = derived(authState, ($s) => $s?.user?.isAdmin ?? false);
export const isAuthenticated = derived(authState, ($s) => $s?.token != null);

export function login(token: string, user: { email: string; displayName: string; isAdmin: boolean }) {
  const state = { token, user };
  authState.set(state);
  if (browser) localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

export function logout() {
  authState.set(null);
  if (browser) localStorage.removeItem(STORAGE_KEY);
}
```

### Auth Guard

```typescript
// src/routes/+layout.ts
import { redirect } from '@sveltejs/kit';
import { get } from 'svelte/store';
import { isAuthenticated } from '$lib/stores/auth';
import type { LayoutLoad } from './$types';

export const load: LayoutLoad = async ({ url }) => {
  // Allow login page without auth
  if (url.pathname === '/login') return {};

  if (!get(isAuthenticated)) {
    throw redirect(302, `/login?redirect=${encodeURIComponent(url.pathname)}`);
  }

  return {};
};

// Static adapter: disable SSR (all rendering is client-side)
export const ssr = false;
export const prerender = false;
```

### Dark Mode

```typescript
// src/lib/stores/theme.ts
import { writable } from 'svelte/store';
import { browser } from '$app/environment';

type Theme = 'light' | 'dark';

function getInitialTheme(): Theme {
  if (!browser) return 'light';
  return (localStorage.getItem('theme') as Theme) ?? 'light';
}

export const theme = writable<Theme>(getInitialTheme());

export function toggleTheme() {
  theme.update((t) => {
    const next = t === 'light' ? 'dark' : 'light';
    if (browser) {
      localStorage.setItem('theme', next);
      document.body.classList.remove('light-theme', 'dark-theme');
      document.body.classList.add(`${next}-theme`);
    }
    return next;
  });
}
```

### Markdown Rendering

```typescript
// src/lib/utils/markdown.ts
import { marked } from 'marked';
import hljs from 'highlight.js';
import DOMPurify from 'dompurify';

marked.setOptions({
  highlight: (code, lang) => {
    if (lang && hljs.getLanguage(lang)) {
      return hljs.highlight(code, { language: lang }).value;
    }
    return hljs.highlightAuto(code).value;
  },
  gfm: true,
  breaks: false,
});

export function renderMarkdown(content: string): string {
  const html = marked.parse(content);
  return DOMPurify.sanitize(html);
}
```

---

## CSS / Design System

### Approach

pub.dev's SCSS is compiled once and included as a static CSS file. The
SvelteKit app uses the same CSS classes and custom properties.

### Files to Port

| Source (pub.dev) | Destination (club_web) | Action |
|------------------|------------------------|--------|
| `pkg/web_css/lib/style.scss` | `static/css/style.css` | Compile with `sass`, remove scoring/dartdoc styles |
| `pkg/web_css/lib/src/_variables.scss` | Included in compile | Light/dark theme tokens |
| `third_party/material/` | `static/material/` | Copy wholesale |
| `static/img/` | `static/img/` | Copy, replace logo |
| `static/js/dark-init.js` | Not needed | Dark mode handled by Svelte store |

### Theme Custom Properties

The CSS uses custom properties for theming. Same variables as pub.dev:

```css
:root, .light-theme {
  --pub-default-text-color: #4a4a4a;
  --pub-link-text-color: #0175C2;
  --pub-default-background: #fff;
  --pub-card-background: #fff;
  /* ... 50+ variables */
}

.dark-theme {
  --pub-default-text-color: #e0e0e0;
  --pub-link-text-color: #6db7f2;
  --pub-default-background: #1a1a2e;
  --pub-card-background: #16213e;
  /* ... */
}
```

---

## Development Workflow

### Prerequisites

```bash
node >= 22
npm >= 10
dart >= 3.7
```

### Setup

```bash
cd packages/club_web
npm install
```

### Development

Run the Dart API server and SvelteKit dev server simultaneously:

```bash
# Terminal 1: Start Dart API server
cd packages/club_server
dart run bin/server.dart

# Terminal 2: Start SvelteKit dev server with HMR
cd packages/club_web
npm run dev
# Open http://localhost:5173
# API calls are proxied to http://localhost:8080 via Vite config
```

### Build

```bash
cd packages/club_web
npm run build
# Output: packages/club_web/build/
```

### Preview Build

```bash
npm run preview
# Serves the built static files locally for verification
```

---

## Dependencies

### package.json

```json
{
  "name": "club-web",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite dev",
    "build": "vite build",
    "preview": "vite preview"
  },
  "devDependencies": {
    "@sveltejs/adapter-static": "^3.0.0",
    "@sveltejs/kit": "^2.0.0",
    "@sveltejs/vite-plugin-svelte": "^4.0.0",
    "svelte": "^5.0.0",
    "typescript": "^5.5.0",
    "vite": "^6.0.0"
  },
  "dependencies": {
    "marked": "^14.0.0",
    "highlight.js": "^11.10.0",
    "dompurify": "^3.1.0"
  }
}
```

### Key Libraries

| Library | Purpose |
|---------|---------|
| `@sveltejs/adapter-static` | Build to static HTML/JS/CSS |
| `marked` | Markdown → HTML |
| `highlight.js` | Syntax highlighting in code blocks |
| `dompurify` | HTML sanitization for rendered Markdown |

---

## Page Components

### Package Detail Page

The most complex page. Structure:

```svelte
<!-- src/routes/packages/[pkg]/+page.svelte -->
<script lang="ts">
  import PackageHeader from '$lib/components/PackageHeader.svelte';
  import TabLayout from '$lib/components/TabLayout.svelte';
  import InfoBox from '$lib/components/InfoBox.svelte';
  import MarkdownRenderer from '$lib/components/MarkdownRenderer.svelte';

  export let data;  // from +page.ts load function
  const { package: pkg, score } = data;
</script>

<div class="detail-wrapper">
  <div class="detail-header">
    <PackageHeader {pkg} {score} />
  </div>

  <div class="detail-container">
    <div class="detail-tabs">
      <TabLayout
        tabs={[
          { id: 'readme', label: 'Readme', href: `/packages/${pkg.name}` },
          { id: 'changelog', label: 'Changelog', href: `/packages/${pkg.name}/changelog` },
          { id: 'versions', label: 'Versions', href: `/packages/${pkg.name}/versions` },
          { id: 'install', label: 'Installing', href: `/packages/${pkg.name}/install` },
        ]}
        activeTab="readme"
      >
        <MarkdownRenderer content={pkg.latest.readme} />
      </TabLayout>
    </div>

    <aside class="detail-info-box">
      <InfoBox {pkg} {score} />
    </aside>
  </div>
</div>
```

### Package Listing Page

```svelte
<!-- src/routes/packages/+page.svelte -->
<script lang="ts">
  import PackageCard from '$lib/components/PackageCard.svelte';
  import SearchBar from '$lib/components/SearchBar.svelte';
  import FilterSidebar from '$lib/components/FilterSidebar.svelte';
  import Pagination from '$lib/components/Pagination.svelte';
  import SortControl from '$lib/components/SortControl.svelte';

  export let data;
  const { packages, totalCount, page } = data;
</script>

<div class="search-banner">
  <SearchBar />
</div>

<div class="listing-container">
  <aside class="listing-filters">
    <FilterSidebar />
  </aside>

  <main class="listing-content">
    <div class="listing-header">
      <span>{totalCount} packages</span>
      <SortControl />
    </div>

    {#each packages as pkg}
      <PackageCard {pkg} />
    {/each}

    <Pagination {page} total={totalCount} />
  </main>
</div>
```
