# OG images — source + build

This folder holds the Open Graph (social share) images for every page on
club.birju.dev.

## Two files per design

Each design lives as a pair:

    brutalist-monogram-ink.svg   ← source · editable, versioned
    brutalist-monogram-ink.png   ← output · rendered, shipped

**Do not hand-edit the `.png`.** Edit the SVG, then regenerate the PNG
with:

    npm run render:og

The render step is `sites/web/scripts/render-og.mjs`. It walks
`public/og/*.svg`, supersamples each SVG at 300 DPI with sharp + resvg,
and writes a 1200×630 palette-indexed PNG beside the SVG. Typical size
is 20–35 KB per image.

## Why PNG ships, not SVG

Social scrapers (X, Facebook, iMessage, Slack, LinkedIn, Discord) only
accept PNG or JPEG for `og:image`. SVG sources are editor-friendly and
resolution-independent but won't render as a link unfurl. We keep both
— SVG for iteration, PNG for production.

## Dimensions and tuning

- **1200 × 630** — the canonical OG size (1.91:1). Large enough for
  every platform, small enough to stay under the 5 MB OG limit.
- **Palette PNG** — our designs use ≤256 flat brand colors, so 8-bit
  palette encoding cuts file size 3–5× with no visible loss. sharp
  falls back to truecolor automatically if a design exceeds 256 colors.
- **Supersampled** — the SVG is rasterized at 300 DPI and then resized
  to 1200×630 with a Lanczos-3 kernel, giving crisp text and vectors.

## Assigning an image to a page

In the Astro page, pass `ogImage` to the Base layout (or through your
own layout that forwards it):

```astro
<Base
  title="Privacy — CLUB"
  description="…"
  path="/privacy"
  ogImage="/og/privacy.png"
/>
```

If you omit `ogImage`, the page uses the default in `src/layouts/Base.astro`
(`/og/brutalist-monogram-ink.png` — the landing design).

## Previewing a page's link unfurl

Open `/dev/link-previews` in the dev server. Every page is rendered
through mockups of iMessage, Slack, X, Facebook, Discord, Google, and a
browser tab. The design gallery at the top of that page lets you switch
the hero between every variant at full size.

## Adding a new design

1. Create the SVG at `public/og/<name>.svg`, viewBox `0 0 1200 630`.
2. Use the real brand mark + wordmark via `<use href="#mark" />` /
   `<use href="#wordmark" />` — see the existing files for the inlined
   `<symbol>` definitions.
3. Run `npm run render:og` to produce the PNG.
4. Register the new variant in `src/pages/dev/link-previews.astro` so it
   appears in the gallery.
5. Assign the PNG to pages via the `ogImage` prop.

## Current assignments

| Page        | OG image                           |
| ----------- | ---------------------------------- |
| `/`         | `/og/brutalist-monogram-ink.png`   |
| `/privacy`  | `/og/privacy.png`                  |
| `/terms`    | `/og/terms.png`                    |
