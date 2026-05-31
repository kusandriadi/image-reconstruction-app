#!/usr/bin/env node
// Generates PWA icons for PixUp using only Node.js built-ins (no deps).
// A rounded square with an orange->teal diagonal gradient and a white
// lightning bolt (matching the in-app brand mark).
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

// ─── CRC32 + PNG chunk helpers ────────────────────────────────────────────────
const crcTable = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let j = 0; j < 8; j++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c;
  }
  return t;
})();

function crc32(buf) {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) crc = crcTable[(crc ^ buf[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const t = Buffer.from(type, 'ascii');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const crcOut = Buffer.alloc(4);
  crcOut.writeUInt32BE(crc32(Buffer.concat([t, data])));
  return Buffer.concat([len, t, data, crcOut]);
}

// Lightning-bolt polygon (24x24 viewBox, matches the Submit button icon)
const BOLT = [
  [13, 2], [3, 14], [12, 14], [11, 22], [21, 10], [12, 10],
];

function pointInPoly(px, py, poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const xi = poly[i][0], yi = poly[i][1];
    const xj = poly[j][0], yj = poly[j][1];
    const intersect = (yi > py) !== (yj > py) &&
      px < ((xj - xi) * (py - yi)) / (yj - yi) + xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

function lerp(a, b, t) { return Math.round(a + (b - a) * t); }

function generateIcon(size) {
  const pixels = Buffer.alloc(size * size * 4, 0);
  const cx = size / 2;
  const cy = size / 2;
  const cornerRadius = size * 0.22;
  const half = size / 2;
  const boltScale = size * 1.3; // bolt fills ~middle of the tile

  // Brand colors
  const orange = [243, 147, 27];
  const teal = [27, 154, 215];

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4;
      const dx = x - cx;
      const dy = y - cy;

      // Rounded-rectangle clip
      const rx = Math.abs(dx) - (half - cornerRadius);
      const ry = Math.abs(dy) - (half - cornerRadius);
      const inBounds = rx <= 0 || ry <= 0 ||
        Math.sqrt(Math.max(0, rx) ** 2 + Math.max(0, ry) ** 2) <= cornerRadius;
      if (!inBounds) continue; // transparent

      // Diagonal gradient background
      const t = (x + y) / (2 * size);
      pixels[i] = lerp(orange[0], teal[0], t);
      pixels[i + 1] = lerp(orange[1], teal[1], t);
      pixels[i + 2] = lerp(orange[2], teal[2], t);
      pixels[i + 3] = 255;

      // White lightning bolt (map pixel into the 24x24 bolt space)
      const bx = (dx / boltScale) * 24 + 12;
      const by = (dy / boltScale) * 24 + 12;
      if (pointInPoly(bx, by, BOLT)) {
        pixels[i] = 255;
        pixels[i + 1] = 255;
        pixels[i + 2] = 255;
        pixels[i + 3] = 255;
      }
    }
  }

  // Encode PNG (RGBA, no filtering)
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8-bit RGBA
  const ihdrChunk = pngChunk('IHDR', ihdr);

  const stride = 1 + size * 4;
  const raw = Buffer.alloc(size * stride);
  for (let y = 0; y < size; y++) {
    raw[y * stride] = 0; // filter: none
    pixels.copy(raw, y * stride + 1, y * size * 4, (y + 1) * size * 4);
  }
  const idat = pngChunk('IDAT', zlib.deflateSync(raw, { level: 9 }));
  const iend = pngChunk('IEND', Buffer.alloc(0));
  return Buffer.concat([sig, ihdrChunk, idat, iend]);
}

const iconsDir = path.join(__dirname, '..', 'icons');
fs.mkdirSync(iconsDir, { recursive: true });

for (const size of [192, 512]) {
  fs.writeFileSync(path.join(iconsDir, `icon-${size}.png`), generateIcon(size));
  console.log(`Generated icons/icon-${size}.png`);
}
fs.writeFileSync(path.join(iconsDir, 'apple-touch-icon.png'), generateIcon(180));
console.log('Generated icons/apple-touch-icon.png');
console.log('All icons generated.');
