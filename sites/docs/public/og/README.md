# Docs OG images — auto-generated

Every page under `docs.club.birju.dev` gets its own 1200×630 PNG Open
Graph image, generated from the page's frontmatter. Unlike the product
site where each design is hand-composed, this folder is 100%
machine-built — **do not commit hand edits here**.

## How it works

`sites/docs/scripts/render-og.mjs` walks every file in
`src/content/docs/**/*.{md,mdx}`, parses the YAML frontmatter for
`title` + `description`, and composes a per-page SVG in memory from a
shared editorial template (paper bg, orange stripe, CLUB brand lockup,
section eyebrow, serif title, sans description, docs signature). That
SVG is rasterized with sharp at 300 DPI + Lanczos-3 into a 1200×630
palette PNG and written here, mirroring the URL tree:

    src/content/docs/cli/publishing.mdx
       → public/og/cli/publishing.png
       → og:image URL /og/cli/publishing.png
       → served at https://docs.club.birju.dev/og/cli/publishing.png

The root `src/content/docs/index.mdx` becomes `public/og/index.png`.

## Running it

    npm run render:og        # regenerate all OG PNGs
    npm run build            # runs render:og first, then astro build

`build` runs the generator automatically, so shipped docs always have
up-to-date images. No need to remember.

## Per-page OG tags

`src/components/Head.astro` overrides Starlight's default Head and
emits these tags per route, with the URL pointing at the matching PNG:

    <meta property="og:image" content="…/og/<slug>.png" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:image:type" content="image/png" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:image" content="…/og/<slug>.png" />

Everything else (title, description, canonical, theme) stays on the
Starlight default.

## Adding a new page

Just add a new `.mdx` file under `src/content/docs/` with a `title` and
`description` in the frontmatter. On the next build the generator
picks it up automatically — no manual image authoring.

## Editing the template

The SVG template lives inline in `render-og.mjs` as a JS template
string (see `composeSvg(...)`). Edit the layout there, then run
`npm run render:og` to regenerate every page at once.

Section labels (the small orange eyebrow, e.g. "§ GETTING STARTED")
are mapped from the first directory segment of each page's path — see
the `SECTION_LABELS` object at the top of the script.

## Output sizes

With the current template and 49 pages, the whole OG library lands
around **1.4 MB total** (~29 KB average per PNG). All palette-indexed
8-bit PNGs.
