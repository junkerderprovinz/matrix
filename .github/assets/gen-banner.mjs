/**
 * Generates the Matrix README banner (house banner convention):
 *   matrix-banner.svg / .png : white 1600x500 - the "[m]" mark on the left, the
 *                              "matrix" wordmark + a cheeky claim to the right.
 *
 * Brand font: matrix.org's wordmark is Helvetica Neue Bold (matrix.org/branding).
 * Helvetica isn't on Windows, so we use its metric-identical clone Arial Bold from
 * the local install, rendered to PATHS only (geometry committed, never the font file
 * - same approach as the JDownloader banner's Arial Black). The claim uses Lato, the
 * shared claim font across all repos (OFL, fetched at runtime, never committed).
 *
 * The "[m]" logo is embedded from icon.png (there is no vector icon.svg). The OLD
 * logo-only banner is preserved as matrix-banner-logo.png/.svg - the support thread
 * uses that one; do not delete it.
 *
 * Text is converted to SVG paths by transforming each glyph's raw outline by hand
 * (opentype's getPath() intermittently emits NaN coords in file execution), so the
 * SVG is self-contained and the output is asserted NaN-free before writing.
 *
 * Deps: `npm i -g @resvg/resvg-js opentype.js`. Run: node .github/assets/gen-banner.mjs
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

// ---- content + styling -----------------------------------------------------
const NAME = "matrix"; // lowercase, exactly like the official [matrix] wordmark
const CLAIM = "Like the big messengers, but you hold the keys.";
const NAME_FONT = "C:/Windows/Fonts/arialbd.ttf"; // Arial Bold = Helvetica metric clone
const NAME_FILL = "#1a1a1a"; // near-black, matches the [m] mark
const CLAIM_FILL = "#5a5d5e"; // house claim grey
const W = 1600, H = 500;
const LH = 420; // [m] logo box (icon.png is square with internal padding)
const LW = LH;
let nameSize = 230; // shrunk below to fit
const claimSize = 42, gap = 56, lineGap = 22;
const MAX_GROUP = W - 160;
// ---------------------------------------------------------------------------

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

// Per-glyph: transform each glyph's own outline (font units) by hand - scale +
// baseline flip + advance. Avoids opentype's getPath() (NaN bug); pure finite math.
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

// Shrink the wordmark until the logo + name group fits the card with margins.
while (nameSize > 100 && LW + gap + glyphRunWidth(nameFont, NAME, nameSize) > MAX_GROUP) {
  nameSize -= 2;
}
const nameW = glyphRunWidth(nameFont, NAME, nameSize);
const claimW = glyphRunWidth(claimFont, CLAIM, claimSize);
const groupW = LW + gap + Math.max(nameW, claimW);
const startX = (W - groupW) / 2;
const LX = startX, LY = (H - LH) / 2;
const textX = startX + LW + gap;

const nameAsc = nameFont.ascender * em(nameFont, nameSize);
const nameDesc = -nameFont.descender * em(nameFont, nameSize);
const claimAsc = claimFont.ascender * em(claimFont, claimSize);
const blockH = nameAsc + nameDesc + lineGap + claimAsc;
const nameBaseline = H / 2 - blockH / 2 + nameAsc;
const claimBaseline = nameBaseline + nameDesc + lineGap + claimAsc;

const namePath = glyphRunPath(nameFont, NAME, textX, nameBaseline, nameSize);
const claimPath = glyphRunPath(claimFont, CLAIM, textX, claimBaseline, claimSize);
if (namePath.includes("NaN") || claimPath.includes("NaN")) {
  throw new Error("text path contains NaN - aborting");
}

// Embed the "[m]" mark from icon.png (no vector available) as a data URI.
const iconB64 = readFileSync(join(__dir, "icon.png")).toString("base64");
const logo = `<image x="${LX.toFixed(1)}" y="${LY.toFixed(1)}" width="${LW}" height="${LH}" href="data:image/png;base64,${iconB64}"/>`;

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="Matrix">
  <rect width="${W}" height="${H}" fill="#ffffff"/>
  ${logo}
  <path d="${namePath}" fill="${NAME_FILL}"/>
  <path d="${claimPath}" fill="${CLAIM_FILL}"/>
</svg>
`;
writeFileSync(join(__dir, "matrix-banner.svg"), svg);

const { Resvg } = require(`${gRoot}/@resvg/resvg-js`);
const png = new Resvg(svg, { fitTo: { mode: "width", value: W }, background: "white" }).render().asPng();
writeFileSync(join(__dir, "matrix-banner.png"), png);
console.log(`wrote matrix-banner.svg + .png (name ${Math.round(nameW)}px @${nameSize}, claim ${Math.round(claimW)}px, group ${Math.round(groupW)}px)`);
