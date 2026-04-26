#!/usr/bin/env node
// Generate a 1200×630 PNG OG image for every doc page.
//
// How it works:
//   · Walks src/content/docs/**/*.{md,mdx}
//   · Parses the YAML frontmatter (title, description)
//   · Derives a URL slug from the file path (matches Starlight's routing)
//   · Infers a "section" from the first directory segment
//   · Builds an SVG in memory by substituting those fields into a shared
//     editorial template (paper bg, orange stripe, CLUB brand row, big
//     serif title, sans description)
//   · Rasterizes at 300 DPI with sharp + Lanczos-3 → palette PNG
//   · Writes to public/og/<slug>.png (mirrors the URL tree)
//
// Run with:  npm run render:og

import sharp from "sharp";
import { readdir, readFile, writeFile, mkdir, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const CONTENT_DIR = path.join(ROOT, "src", "content", "docs");
const ASSETS_DIR = path.join(ROOT, "src", "assets");
const OG_DIR = path.join(ROOT, "public", "og");

const WIDTH = 1200;
const HEIGHT = 630;

// ─── Section labels ────────────────────────────────────────────────
// Maps first-segment slug → human label shown in the eyebrow line.
const SECTION_LABELS = {
  "getting-started": "GETTING STARTED",
  "self-hosting": "SELF-HOSTING",
  "guides": "GUIDES",
  "cli": "CLI",
  "sdk": "CLIENT SDK",
  "api": "API REFERENCE",
  "configuration": "CONFIGURATION",
  "operations": "OPERATIONS",
};

// ─── Frontmatter parser (handles the subset we use) ────────────────
function parseFrontmatter(raw) {
  const m = raw.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return {};
  const out = {};
  for (const line of m[1].split("\n")) {
    const match = line.match(/^(\w+):\s*(.*?)\s*$/);
    if (!match) continue;
    const [, key, value] = match;
    if (value === "") continue; // nested keys (sidebar: …) are skipped
    // Strip surrounding quotes
    out[key] = value.replace(/^['"](.*)['"]$/, "$1");
  }
  return out;
}

// ─── Recursive walker for .md / .mdx ───────────────────────────────
async function walk(dir, base = dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      files.push(...(await walk(full, base)));
    } else if (/\.(md|mdx)$/.test(e.name)) {
      files.push({
        full,
        rel: path.relative(base, full),
      });
    }
  }
  return files;
}

// ─── Word-wrap helper (SVG has no flow text) ───────────────────────
function wrapWords(text, maxChars, maxLines) {
  const words = String(text).trim().split(/\s+/);
  const lines = [];
  let cur = "";
  for (const w of words) {
    const next = cur ? cur + " " + w : w;
    if (next.length > maxChars && cur) {
      lines.push(cur);
      cur = w;
      if (lines.length === maxLines) break;
    } else {
      cur = next;
    }
  }
  if (cur && lines.length < maxLines) lines.push(cur);
  // Truncate the last line if we hit the cap and there's remaining content
  if (lines.length === maxLines) {
    const consumed = lines.join(" ").split(/\s+/).length;
    if (consumed < words.length) {
      lines[maxLines - 1] = lines[maxLines - 1].replace(/\s*\S{0,3}$/, "") + "…";
    }
  }
  return lines;
}

// XML-safe text escape
function x(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ─── Load the CLUB wordmark symbol body (4 paths) once ─────────────
async function loadWordmarkBody() {
  const raw = await readFile(path.join(ASSETS_DIR, "club_logo_text.svg"), "utf8");
  const m = raw.match(/<svg[^>]*>([\s\S]*)<\/svg>/);
  if (!m) throw new Error("Could not extract body from club_logo_text.svg");
  // Remap any hard-coded fills so the wordmark inherits color from <use>
  return m[1].trim().replace(/fill="[^"]*"/g, 'fill="currentColor"');
}

// ─── Template composer ─────────────────────────────────────────────
// Produces a full SVG string for one page. All layout math lives here.
function composeSvg({ title, description, section, wordmarkBody }) {
  // ─ Fit the title ──────────────────────────────────────────────
  // The title typeface is Georgia bold with a ~-3 letter-spacing;
  // empirical ratio of avg char width ≈ 0.6 × font-size. We try a
  // single line first and only wrap when the required size would
  // drop below a readability floor.
  const TITLE_MAX_W = 1040; // canvas 1200 − 80px margin each side
  const CHAR_RATIO = 0.6;
  const fitSize = (text, cap) =>
    Math.min(cap, Math.floor(TITLE_MAX_W / (text.length * CHAR_RATIO)));

  let titleLines, titleSize;
  const single = fitSize(title, 118);
  if (single >= 90) {
    titleLines = [title];
    titleSize = single;
  } else {
    titleLines = wrapWords(title, 16, 2);
    const longest = Math.max(...titleLines.map((l) => l.length), 1);
    titleSize = Math.max(70, fitSize("x".repeat(longest), 100));
  }
  const titleLead = Math.round(titleSize * 0.95);

  // Description wrap — up to 2 lines, ~62 chars each (22pt fits easily)
  const descLines = wrapWords(description || "", 62, 2);
  const descLineSpacing = 32;

  // Anchor the whole text block to a fixed BOTTOM baseline so longer
  // content slides up rather than colliding with the bottom chrome
  // (corner brackets at y≈540-590, signature at y≈590).
  const DESC_LAST_BASELINE = 505;
  const descY = DESC_LAST_BASELINE - (descLines.length - 1) * descLineSpacing;
  const ruleY = descY - 45;
  const titleLastY = ruleY - 55;
  const titleBaseY = titleLastY - (titleLines.length - 1) * titleLead;

  const sectionLine = section
    ? `§ ${section}`
    : `§ DOCS`;

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" preserveAspectRatio="xMidYMid slice">
  <defs>
    <symbol id="mark" viewBox="0 0 690 690">
      <path d="M345 0C535.538 0 690 154.462 690 345C690 535.538 535.538 690 345 690C154.462 690 0 535.538 0 345C0 154.462 154.462 0 345 0ZM344.948 141.667C327.692 141.667 310.766 146.4 296.013 155.352C281.26 164.303 269.244 177.13 261.274 192.437C253.305 207.743 249.687 224.942 250.813 242.161C251.94 259.381 257.769 275.961 267.664 290.099C250.083 284.554 231.262 284.284 213.528 289.322C195.795 294.36 179.927 304.486 167.888 318.446C155.848 332.407 148.164 349.591 145.787 367.872C143.41 386.153 146.444 404.73 154.513 421.306C162.582 437.881 175.332 451.728 191.187 461.134C207.042 470.54 225.306 475.092 243.721 474.228C262.136 473.363 279.893 467.12 294.798 456.271C309.702 445.421 321.099 430.441 327.58 413.183C327.652 475.275 323.669 516.568 264.765 547.755H425.141C366.236 516.559 362.253 475.257 362.325 413.183C370.081 433.881 384.858 451.2 404.079 462.115C423.3 473.031 445.744 476.85 467.493 472.907C489.243 468.964 508.917 457.508 523.082 440.54C537.248 423.572 545.005 402.168 545 380.063C544.993 365.242 541.495 350.631 534.79 337.413C528.085 324.195 518.361 312.742 506.406 303.981C494.451 295.221 480.601 289.399 465.978 286.987C451.354 284.575 436.367 285.641 422.232 290.099C432.128 275.961 437.956 259.381 439.083 242.161C440.21 224.942 436.591 207.743 428.622 192.437C420.653 177.13 408.637 164.303 393.884 155.352C379.131 146.4 362.205 141.667 344.948 141.667Z" fill="currentColor"/>
    </symbol>
    <symbol id="wordmark" viewBox="0 0 1819 460">
${wordmarkBody}
    </symbol>
    <pattern id="grain" x="0" y="0" width="4" height="4" patternUnits="userSpaceOnUse">
      <circle cx="1" cy="1" r="0.4" fill="#141517" fill-opacity="0.035"/>
    </pattern>
  </defs>

  <!-- paper bg -->
  <rect width="1200" height="630" fill="#F7F8FA"/>
  <rect width="1200" height="630" fill="url(#grain)"/>
  <rect x="0" y="0" width="10" height="630" fill="#FF4F18"/>

  <!-- corner brackets · L-shapes 50px arms, 40px inset, subtle -->
  <g stroke="#141517" stroke-width="2" fill="none" stroke-linecap="square" opacity="0.9">
    <path d="M40 90 V40 H90"/>
    <path d="M1110 40 H1160 V90"/>
    <path d="M40 540 V590 H90"/>
    <path d="M1110 590 H1160 V540"/>
  </g>

  <!-- top brand row · mark + CLUB wordmark -->
  <g transform="translate(80, 70)">
    <use href="#mark" x="0" y="0" width="52" height="52" color="#FF4F18"/>
    <use href="#wordmark" x="64" y="8" width="150" height="36" color="#141517"/>
  </g>

  <!-- section eyebrow -->
  <text x="1120" y="98" text-anchor="end"
        font-family="ui-monospace, SFMono-Regular, Menlo, monospace"
        font-size="13" font-weight="700" letter-spacing="5"
        fill="#FF4F18">${x(sectionLine)}</text>

  <!-- serif title (1 or 2 lines) -->
  ${titleLines
    .map(
      (line, i) => `<text x="76" y="${titleBaseY + i * titleLead}"
        font-family="ui-serif, Georgia, 'Times New Roman', serif"
        font-size="${titleSize}" font-weight="700" letter-spacing="-3"
        fill="#141517">${x(line)}</text>`,
    )
    .join("\n  ")}

  <!-- rule -->
  <line x1="80" y1="${ruleY}" x2="220" y2="${ruleY}" stroke="#FF4F18" stroke-width="2"/>

  <!-- description (1-2 lines, sans) -->
  ${descLines
    .map(
      (line, i) => `<text x="80" y="${descY + i * 32}"
        font-family="system-ui, -apple-system, 'Segoe UI', Arial, sans-serif"
        font-size="22" font-weight="500"
        fill="#64748B">${x(line)}</text>`,
    )
    .join("\n  ")}

  <!-- bottom mono signature -->
  <text x="600" y="590" text-anchor="middle"
        font-family="ui-monospace, SFMono-Regular, Menlo, monospace"
        font-size="12" font-weight="700" letter-spacing="6"
        fill="#141517" opacity="0.55">— CLUB DOCS · DART &amp; FLUTTER —</text>
</svg>`;
}

// ─── Main ──────────────────────────────────────────────────────────
const files = await walk(CONTENT_DIR);
const wordmarkBody = await loadWordmarkBody();

console.log(`Generating OG images for ${files.length} doc pages → ${WIDTH}×${HEIGHT} PNG\n`);

let totalBytes = 0;
let ok = 0;
let skipped = 0;

for (const { full, rel } of files.sort((a, b) => a.rel.localeCompare(b.rel))) {
  const raw = await readFile(full, "utf8");
  const fm = parseFrontmatter(raw);
  const title = fm.title;
  const description = fm.description || "";

  if (!title) {
    console.warn(`  skip: ${rel} — no title`);
    skipped++;
    continue;
  }

  // Slug mirrors Starlight's routing: path without extension, with
  // /index collapsed to /
  const noExt = rel.replace(/\.(md|mdx)$/, "");
  const isIndex = noExt === "index" || noExt.endsWith("/index");
  const slug = isIndex ? noExt.replace(/\/?index$/, "") : noExt;
  const outPath = path.join(OG_DIR, (slug || "index") + ".png");

  // First directory segment → section label
  const firstSeg = slug.split("/")[0];
  const section = SECTION_LABELS[firstSeg] || null;

  const svg = composeSvg({ title, description, section, wordmarkBody });

  await mkdir(path.dirname(outPath), { recursive: true });
  await sharp(Buffer.from(svg), { density: 300 })
    .resize(WIDTH, HEIGHT, { fit: "cover", kernel: "lanczos3" })
    .png({
      compressionLevel: 9,
      adaptiveFiltering: true,
      palette: true,
      quality: 100,
      effort: 10,
    })
    .toFile(outPath);

  const s = await stat(outPath);
  totalBytes += s.size;
  ok++;
  const kb = (s.size / 1024).toFixed(1);
  console.log(`  ${rel.padEnd(42)} → ${path.relative(OG_DIR, outPath).padEnd(42)} ${kb.padStart(6)} KB`);
}

console.log(
  `\nRendered ${ok} · skipped ${skipped} · total ${(totalBytes / 1024).toFixed(1)} KB (${
    ok > 0 ? (totalBytes / ok / 1024).toFixed(1) : 0
  } KB avg)`,
);
