#!/usr/bin/env node
// Rasterize every SVG in public/og/*.svg into a 1200×630 PNG.
//
// Why: social scrapers (X, Facebook, iMessage, Slack, LinkedIn, Discord)
// require PNG or JPEG for og:image. The SVG sources in public/og/ are
// the editable originals; the PNGs committed alongside them are what
// actually ships in <meta property="og:image" content="…"> tags.
//
// Quality strategy:
//   · Supersample — render the SVG at density 300 (~4×) then downsample
//     with a Lanczos-3 kernel for crisp text and vectors.
//   · Palette PNG (palette: true) — because our designs use flat brand
//     colors, 8-bit palette encoding cuts file size 3–5× with no visible
//     loss. Sharp falls back to truecolor automatically if >256 colors.
//   · compressionLevel 9 + effort 10 — pay the one-time build cost for
//     the smallest possible bytes on the wire.
//
// Run with:  npm run render:og

import sharp from "sharp";
import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OG_DIR = path.resolve(__dirname, "..", "public", "og");
const WIDTH = 1200;
const HEIGHT = 630;

const entries = await readdir(OG_DIR);
const svgs = entries.filter((f) => f.endsWith(".svg")).sort();

if (svgs.length === 0) {
  console.error(`No SVGs found in ${OG_DIR}`);
  process.exit(1);
}

console.log(`Rendering ${svgs.length} OG image${svgs.length === 1 ? "" : "s"} → ${WIDTH}×${HEIGHT} PNG\n`);

let totalBytes = 0;
for (const f of svgs) {
  const svgPath = path.join(OG_DIR, f);
  const pngPath = path.join(OG_DIR, f.replace(/\.svg$/, ".png"));
  const svg = await readFile(svgPath);

  await sharp(svg, { density: 300 })
    .resize(WIDTH, HEIGHT, { fit: "cover", kernel: "lanczos3" })
    .png({
      compressionLevel: 9,
      adaptiveFiltering: true,
      palette: true,
      quality: 100,
      effort: 10,
    })
    .toFile(pngPath);

  const s = await stat(pngPath);
  totalBytes += s.size;
  const kb = (s.size / 1024).toFixed(1);
  console.log(`  ${f.padEnd(32)} → ${path.basename(pngPath).padEnd(32)} ${kb.padStart(7)} KB`);
}

console.log(`\nTotal: ${(totalBytes / 1024).toFixed(1)} KB across ${svgs.length} files`);
