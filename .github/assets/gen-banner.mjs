/**
 * Generates the README banners: matrix-banner.svg/.png on white and
 * matrix-banner-dark.svg/.png on GitHub's dark #0d1117, both 1600x500 with the
 * "[m]" mark on the left and the wordmark and claim to its right.
 *
 * icon.png (a black mark on an opaque white box) is the only source of the mark, so
 * both themes embed that raster unchanged and the dark one recolours it with an
 * feColorMatrix. matrix-banner-logo.png/.svg is the logo-only banner the support
 * thread uses; keep it.
 *
 * The wordmark is Arial Bold, the metric clone of matrix.org's Helvetica Neue Bold,
 * and the claim is Lato, fetched at run time. Both are rendered to paths so no font
 * file is committed. Glyph outlines are transformed by hand because opentype's
 * getPath() sometimes emits NaN coordinates.
 *
 * Needs `npm i -g @resvg/resvg-js opentype.js`. Run: node .github/assets/gen-banner.mjs
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";

const require = createRequire(import.meta.url);
const gRoot = execSync("npm root -g").toString().trim();
const opentype = require(`${gRoot}/opentype.js`);

const __dir = dirname(fileURLToPath(import.meta.url));

const NAME = "matrix"; // lowercase, exactly like the official [matrix] wordmark
const CLAIM = "Text like nobody's reading. Because nobody can.";
const NAME_FONT = "C:/Windows/Fonts/arialbd.ttf";
const W = 1600, H = 500;

// The themes differ only in colour. Without a logoTint icon.png is embedded as is,
// its white box disappearing into the white background.
const THEMES = [
  { suffix: "", bg: "#ffffff", name: "#1f2328", claim: "#5a5d5e", logoTint: null },
  { suffix: "-dark", bg: "#0d1117", name: "#e6edf3", claim: "#9aa4ad", logoTint: "#e6edf3" },
];
const LH = 508; // [m] logo box (icon.png is square with internal padding)
const LW = LH;
let nameSize = 132; // shrinks below when the group gets too wide
let claimSize = 44; const gap = 70, lineGap = 8;
const MAX_GROUP = W - 160;

const nameFont = opentype.parse(loadLocal(NAME_FONT));
const latoFile = join(tmpdir(), "Matrix-Lato-Regular.ttf");
await ensureFont(latoFile, "https://github.com/google/fonts/raw/main/ofl/lato/Lato-Regular.ttf");
const claimFont = opentype.parse(readFileSync(latoFile));

function loadLocal(p) {
  if (!existsSync(p)) throw new Error(`font not found: ${p} (install Arial Bold to regenerate)`);
  return readFileSync(p);
}
async function ensureFont(file, url) {
  if (!existsSync(file)) {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`font fetch ${res.status}: ${url}`);
    writeFileSync(file, Buffer.from(await res.arrayBuffer()));
  }
}

function glyphRunWidth(font, text, size) {
  const scale = size / font.unitsPerEm;
  let w = 0;
  for (const ch of text) w += font.charToGlyph(ch).advanceWidth * scale;
  return w;
}
function glyphRunPath(font, text, x, baseline, size) {
  const scale = size / font.unitsPerEm;
  const n = (v) => v.toFixed(2);
  let d = "", cx = x;
  for (const ch of text) {
    const g = font.charToGlyph(ch);
    for (const c of g.path.commands) {
      if (c.type === "M") d += `M${n(cx + c.x * scale)} ${n(baseline - c.y * scale)}`;
      else if (c.type === "L") d += `L${n(cx + c.x * scale)} ${n(baseline - c.y * scale)}`;
      else if (c.type === "C")
        d += `C${n(cx + c.x1 * scale)} ${n(baseline - c.y1 * scale)} ${n(cx + c.x2 * scale)} ${n(baseline - c.y2 * scale)} ${n(cx + c.x * scale)} ${n(baseline - c.y * scale)}`;
      else if (c.type === "Q")
        d += `Q${n(cx + c.x1 * scale)} ${n(baseline - c.y1 * scale)} ${n(cx + c.x * scale)} ${n(baseline - c.y * scale)}`;
      else if (c.type === "Z") d += "Z";
    }
    cx += g.advanceWidth * scale;
  }
  return d;
}

const em = (f, s) => s / f.unitsPerEm;

while (nameSize > 100 && LW + gap + glyphRunWidth(nameFont, NAME, nameSize) > MAX_GROUP) {
  nameSize -= 2;
}
const nameW = glyphRunWidth(nameFont, NAME, nameSize);
const claimW = glyphRunWidth(claimFont, CLAIM, claimSize);
const groupW = LW + gap + Math.max(nameW, claimW);
const startX = 165;
const LX = startX - 55, LY = (H - LH) / 2; // -55 cancels icon.png's padding so the visible mark starts at startX
const textX = startX + LW - 110 + gap; // -110 cancels the padding on both sides of icon.png
while (claimSize > 24 && textX + glyphRunWidth(claimFont, CLAIM, claimSize) > W - 40) claimSize -= 1;

const nameAsc = nameFont.ascender * em(nameFont, nameSize);
const nameDesc = -nameFont.descender * em(nameFont, nameSize);
const claimAsc = claimFont.ascender * em(claimFont, claimSize);
const blockH = nameAsc + nameDesc + lineGap + claimAsc;
const nameBaseline = H / 2 - blockH / 2 + nameAsc;
const claimBaseline = nameBaseline + nameDesc + lineGap + claimAsc;

const namePath = glyphRunPath(nameFont, NAME, textX, nameBaseline, nameSize);
const claimPath = glyphRunPath(claimFont, CLAIM, textX, claimBaseline, claimSize);
if (namePath.includes("NaN") || claimPath.includes("NaN")) {
  throw new Error("text path contains NaN");
}

// With a tint, the colour matrix maps luminance to alpha (the black mark opaque, the
// white box transparent; the factor 1.15 lifts the near-black #1a1a1a to full alpha)
// and paints every pixel in the tint. sRGB interpolation keeps the anti-aliased
// edges of the sRGB raster.
const iconB64 = readFileSync(join(__dir, "icon.png")).toString("base64");
function logoMark(tint) {
  const img = `<image x="${LX.toFixed(1)}" y="${LY.toFixed(1)}" width="${LW}" height="${LH}" href="data:image/png;base64,${iconB64}"`;
  if (!tint) return `${img}/>`;
  const [r, g, b] = [1, 3, 5].map((i) => (parseInt(tint.slice(i, i + 2), 16) / 255).toFixed(4));
  const f = 1.15;
  const values = [
    `0 0 0 0 ${r}`,
    `0 0 0 0 ${g}`,
    `0 0 0 0 ${b}`,
    `${(-0.2126 * f).toFixed(4)} ${(-0.7152 * f).toFixed(4)} ${(-0.0722 * f).toFixed(4)} 0 ${f}`,
  ].join("  ");
  // The filter region is clamped to the image because the constant alpha offset
  // would paint the default -10%/120% margin as a frame around the logo.
  return `<filter id="tint" x="0" y="0" width="1" height="1" color-interpolation-filters="sRGB"><feColorMatrix type="matrix" values="${values}"/></filter>
  ${img} filter="url(#tint)"/>`;
}

const { Resvg } = require(`${gRoot}/@resvg/resvg-js`);
for (const t of THEMES) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="Matrix">
  <rect width="${W}" height="${H}" fill="${t.bg}"/>
  ${logoMark(t.logoTint)}
  <path d="${namePath}" fill="${t.name}"/>
  <path d="${claimPath}" fill="${t.claim}"/>
</svg>
`;
  writeFileSync(join(__dir, `matrix-banner${t.suffix}.svg`), svg);
  const png = new Resvg(svg, { fitTo: { mode: "width", value: W }, background: t.bg }).render().asPng();
  writeFileSync(join(__dir, `matrix-banner${t.suffix}.png`), png);
  console.log(`wrote matrix-banner${t.suffix}.svg + .png`);
}
console.log(`(name ${Math.round(nameW)}px @${nameSize}, claim ${Math.round(claimW)}px, group ${Math.round(groupW)}px)`);
