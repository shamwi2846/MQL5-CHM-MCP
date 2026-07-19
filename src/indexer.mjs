import { createHash, randomUUID } from "node:crypto";
import {
  constants as fsConstants,
  createReadStream,
} from "node:fs";
import {
  access,
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { inflateSync } from "node:zlib";

// The slim entry point is sufficient for already-decoded strings and avoids
// Cheerio's stream/encoding-sniffer dependency in the portable ESM bundle.
import * as cheerio from "cheerio/slim";
import iconv from "iconv-lite";
import jpeg from "jpeg-js";

export const SCHEMA_VERSION = 3;
export const INDEX_CONTRACT = "mql5-chm-index-v3-assets-v2";
export const ASSET_ID_PATTERN = /^(?:mql5|mql5book|neuronetworksbook):asset:[0-9a-f]{24}$/u;

const DEFAULT_IMAGE_POLICY_RELATIVE_PATH = path.join("config", "mql5-image-policy.json");

export const SOURCE_DEFINITIONS = Object.freeze([
  Object.freeze({
    source: "mql5",
    filename: "mql5.chm",
    extractedDirectory: "mql5",
    sha256: "b6b3338a985e1efedc2c87fa478f648d7de53e1daa6d2a8a9e5359b8878e23fa",
    topicCount: 4_134,
  }),
  Object.freeze({
    source: "mql5book",
    filename: "mql5book.chm",
    extractedDirectory: "mql5book",
    sha256: "4c0d0e6ce858b410f63969fc5d6b64076da73ae7f4c010c212b6993d018a1f17",
    topicCount: 581,
  }),
  Object.freeze({
    source: "neuronetworksbook",
    filename: "neuronetworksbook.chm",
    extractedDirectory: "neuronetworksbook",
    sha256: "fe9470e6ac9452e34ecc54cd80dddf59475c8ae23cac7b5ef071b17f1c32d8f5",
    topicCount: 112,
  }),
]);

export const EXPECTED_TOTAL_TOPIC_COUNT = SOURCE_DEFINITIONS.reduce(
  (total, definition) => total + definition.topicCount,
  0,
);

const BLOCK_ELEMENTS = new Set([
  "address",
  "article",
  "aside",
  "blockquote",
  "dd",
  "details",
  "div",
  "dl",
  "dt",
  "figcaption",
  "figure",
  "footer",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "header",
  "li",
  "main",
  "nav",
  "ol",
  "p",
  "pre",
  "section",
  "table",
  "tbody",
  "tfoot",
  "th",
  "thead",
  "tr",
  "ul",
]);

const SKIPPED_ELEMENTS = new Set([
  "canvas",
  "noscript",
  "script",
  "style",
  "svg",
  "template",
]);

const HEADING_CLASS_PATTERN = /(?:^|\s)p_(?:h[1-6]|boldtitles?|subtitle|title|chapter(?:name|header)?)(?:\s|$)/i;
const CODE_CLASS_PATTERN = /(?:^|\s)(?:p_|f_)?(?:code|codeexample|syntax)(?:\s|$)/i;
const SEE_ALSO_CLASS_PATTERN = /(?:^|[_\s-])see[_\s-]?also(?:$|[_\s-])/i;
const INTERNAL_TOPIC_EXTENSION_PATTERN = /\.html?$/i;
const SOURCE_IDS = Object.freeze(SOURCE_DEFINITIONS.map((definition) => definition.source));

function compareOrdinal(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function normalizeSlashes(value) {
  return String(value).replaceAll("\\", "/");
}

export function normalizeText(value) {
  return String(value ?? "")
    .normalize("NFKD")
    .toLowerCase()
    .replace(/\p{M}/gu, "")
    .replace(/[^\p{L}\p{N}_]+/gu, " ")
    .trim()
    .replace(/\s+/gu, " ");
}

export function normalizeInternalPath(value) {
  let candidate = normalizeSlashes(value ?? "").trim();
  candidate = candidate.replace(/^mk:@msitstore:[^:]+::\//i, "");
  candidate = candidate.replace(/^\/+/, "");
  candidate = candidate.split("#", 1)[0].split("?", 1)[0];

  try {
    candidate = decodeURIComponent(candidate);
  } catch {
    // Keep a malformed percent escape as literal text. It can still be indexed
    // safely, and it cannot become a filesystem path in the runtime server.
  }

  const segments = candidate.split("/").filter((segment) => segment && segment !== ".");
  if (segments.some((segment) => segment === "..")) {
    throw new Error(`Unsafe CHM internal path: ${value}`);
  }
  return segments.join("/");
}

function decodeUriComponentSafely(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function normalizeLinkFragment(value) {
  return cleanInlineText(decodeUriComponentSafely(String(value ?? "")))
    .replace(/[\u0000-\u001f\u007f]/gu, "")
    .slice(0, 300);
}

/**
 * Resolve a CHM anchor against its containing topic without ever touching the
 * filesystem. Only same-CHM HTML topics are eligible. Root-relative links are
 * treated as CHM-root-relative, while traversal above that virtual root is
 * rejected.
 */
export function resolveInternalLink(sourceInternalPath, href) {
  const rawHref = String(href ?? "").trim();
  if (!rawHref || rawHref.startsWith("//") || /[\u0000-\u001f\u007f]/u.test(rawHref)) return null;
  if (/^[a-z][a-z0-9+.-]*:/iu.test(rawHref)) return null;

  const hashIndex = rawHref.indexOf("#");
  const targetWithQuery = hashIndex >= 0 ? rawHref.slice(0, hashIndex) : rawHref;
  const targetFragment = hashIndex >= 0 ? normalizeLinkFragment(rawHref.slice(hashIndex + 1)) : "";
  const queryIndex = targetWithQuery.indexOf("?");
  let targetPath = queryIndex >= 0 ? targetWithQuery.slice(0, queryIndex) : targetWithQuery;
  targetPath = normalizeSlashes(decodeUriComponentSafely(targetPath.trim()));
  if (
    targetPath.startsWith("//") ||
    /^[a-z][a-z0-9+.-]*:/iu.test(targetPath) ||
    /[\u0000-\u001f\u007f]/u.test(targetPath)
  ) return null;

  const sourcePath = normalizeInternalPath(sourceInternalPath);
  const combined = targetPath
    ? targetPath.startsWith("/")
      ? targetPath.slice(1)
      : path.posix.join(path.posix.dirname(sourcePath), targetPath)
    : sourcePath;

  const segments = [];
  for (const segment of normalizeSlashes(combined).split("/")) {
    if (!segment || segment === ".") continue;
    if (segment === "..") {
      if (!segments.length) return null;
      segments.pop();
      continue;
    }
    segments.push(segment);
  }

  const targetInternalPath = segments.join("/");
  if (!targetInternalPath || !INTERNAL_TOPIC_EXTENSION_PATTERN.test(targetInternalPath)) return null;
  return { targetInternalPath, targetFragment };
}

export function makeTopicId(source, internalPath) {
  const normalizedPath = normalizeInternalPath(internalPath).toLowerCase();
  const digest = createHash("sha256").update(normalizedPath, "utf8").digest("hex");
  return `${source}:${digest.slice(0, 24)}`;
}

export function makeAssetId(source, internalPath) {
  if (!SOURCE_IDS.includes(source)) throw new Error(`Unknown MQL5 CHM source: ${source}`);
  const normalizedPath = normalizeInternalPath(internalPath).toLowerCase();
  if (!normalizedPath) throw new Error("Asset internal path must not be empty.");
  const digest = createHash("sha256").update(normalizedPath, "utf8").digest("hex");
  return `${source}:asset:${digest.slice(0, 24)}`;
}

export function makeAssetPathDigest(internalPath) {
  const normalizedPath = normalizeInternalPath(internalPath).toLowerCase();
  if (!normalizedPath) throw new Error("Asset internal path must not be empty.");
  return createHash("sha256").update(normalizedPath, "utf8").digest("hex");
}

function decodeAssetReference(value) {
  let decoded = String(value ?? "");
  for (let pass = 0; pass < 4; pass += 1) {
    let next;
    try {
      next = decodeURIComponent(decoded);
    } catch {
      return null;
    }
    if (next === decoded) return decoded;
    decoded = next;
  }
  try {
    return decodeURIComponent(decoded) === decoded ? decoded : null;
  } catch {
    return null;
  }
}

/** Resolve a local image reference inside the CHM virtual root. */
export function resolveInternalAssetPath(sourceInternalPath, reference) {
  const raw = String(reference ?? "").trim();
  if (!raw || raw.startsWith("//") || /[\u0000-\u001f\u007f]/u.test(raw)) return null;
  const withoutFragment = raw.split("#", 1)[0];
  const withoutQuery = withoutFragment.split("?", 1)[0];
  const decoded = decodeAssetReference(withoutQuery);
  if (decoded === null) return null;
  let target = normalizeSlashes(decoded.trim());
  if (
    !target ||
    target.startsWith("//") ||
    /^[a-z][a-z0-9+.-]*:/iu.test(target) ||
    /^[a-z]:\//iu.test(target) ||
    /[\u0000-\u001f\u007f]/u.test(target)
  ) return null;

  const sourcePath = normalizeInternalPath(sourceInternalPath);
  const combined = target.startsWith("/")
    ? target.slice(1)
    : path.posix.join(path.posix.dirname(sourcePath), target);
  const segments = [];
  for (const segment of normalizeSlashes(combined).split("/")) {
    if (!segment || segment === ".") continue;
    if (segment === "..") {
      if (!segments.length) return null;
      segments.pop();
      continue;
    }
    if (segment.includes(":")) return null;
    segments.push(segment);
  }
  return segments.length ? segments.join("/") : null;
}

export function makeSectionId(topicId, ordinal) {
  if (!Number.isSafeInteger(ordinal) || ordinal < 0 || ordinal > 999_999) {
    throw new TypeError("Section ordinal must be a non-negative safe integer.");
  }
  return `${topicId}:s${String(ordinal).padStart(3, "0")}`;
}

export function computeCorpusRevision(sources) {
  if (!Array.isArray(sources) || sources.length !== SOURCE_IDS.length) {
    throw new Error(`Corpus revision requires exactly these sources: ${SOURCE_IDS.join(", ")}.`);
  }
  const bySource = new Map((sources ?? []).map((source) => [source.source, source]));
  const hash = createHash("sha256");
  for (const sourceId of SOURCE_IDS) {
    const source = bySource.get(sourceId);
    const sha256 = String(source?.actualHash ?? source?.sha256 ?? "").toLowerCase();
    if (!/^[0-9a-f]{64}$/u.test(sha256)) {
      throw new Error(`Missing or invalid SHA-256 for corpus source ${sourceId}.`);
    }
    hash.update(`${sourceId}\u0000${sha256}\u0000`, "utf8");
  }
  if (bySource.size !== SOURCE_IDS.length) {
    throw new Error(`Corpus revision requires exactly these sources: ${SOURCE_IDS.join(", ")}.`);
  }
  return hash.digest("hex");
}

const CRC32_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let index = 0; index < table.length; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
    }
    table[index] = value >>> 0;
  }
  return table;
})();

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = CRC32_TABLE[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function inspectPng(bytes, limits = {}) {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const maxBytes = Number(limits.max_bytes ?? Number.MAX_SAFE_INTEGER);
  const maxDimension = Number(limits.max_dimension ?? Number.MAX_SAFE_INTEGER);
  const maxPixels = Number(limits.max_pixels ?? Number.MAX_SAFE_INTEGER);
  if (bytes.length > maxBytes) throw new Error(`Image exceeds ${maxBytes} bytes.`);
  if (bytes.length < 33 || !bytes.subarray(0, 8).equals(signature)) {
    throw new Error("Malformed PNG signature or header.");
  }
  let offset = 8;
  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = 0;
  let interlace = 0;
  let sawHeader = false;
  let sawPalette = false;
  let sawData = false;
  let sawEnd = false;
  let leftDataSequence = false;
  const compressedChunks = [];
  while (offset < bytes.length) {
    if (offset + 12 > bytes.length) throw new Error("Truncated PNG chunk header.");
    const length = bytes.readUInt32BE(offset);
    const dataStart = offset + 8;
    const dataEnd = dataStart + length;
    const chunkEnd = dataEnd + 4;
    if (chunkEnd > bytes.length) throw new Error("Truncated PNG chunk data.");
    const typeBytes = bytes.subarray(offset + 4, offset + 8);
    const type = typeBytes.toString("ascii");
    if (!/^[A-Za-z]{4}$/u.test(type)) throw new Error("Malformed PNG chunk type.");
    if (!/[A-Z]/u.test(type[2])) throw new Error("PNG chunk type uses a reserved lowercase bit.");
    const expectedCrc = bytes.readUInt32BE(dataEnd);
    const actualCrc = crc32(bytes.subarray(offset + 4, dataEnd));
    if (actualCrc !== expectedCrc) throw new Error(`PNG CRC mismatch in ${type}.`);
    if (!sawHeader && type !== "IHDR") throw new Error("PNG IHDR must be the first chunk.");
    if (type === "IHDR") {
      if (sawHeader || length !== 13) throw new Error("Malformed or duplicate PNG IHDR.");
      width = bytes.readUInt32BE(dataStart);
      height = bytes.readUInt32BE(dataStart + 4);
      bitDepth = bytes[dataStart + 8];
      colorType = bytes[dataStart + 9];
      const validDepths = new Map([
        [0, new Set([1, 2, 4, 8, 16])],
        [2, new Set([8, 16])],
        [3, new Set([1, 2, 4, 8])],
        [4, new Set([8, 16])],
        [6, new Set([8, 16])],
      ]);
      if (!width || !height || !validDepths.get(colorType)?.has(bitDepth)) {
        throw new Error("PNG has invalid dimensions or color format.");
      }
      const pixelCount = width * height;
      if (width > maxDimension || height > maxDimension) throw new Error(`Image exceeds the ${maxDimension}-pixel dimension limit.`);
      if (!Number.isSafeInteger(pixelCount) || pixelCount > maxPixels) throw new Error(`Image exceeds the ${maxPixels}-pixel decoded limit.`);
      interlace = bytes[dataStart + 12];
      if (bytes[dataStart + 10] !== 0 || bytes[dataStart + 11] !== 0 || ![0, 1].includes(interlace)) {
        throw new Error("PNG has unsupported compression, filtering, or interlace metadata.");
      }
      sawHeader = true;
    } else if (type === "acTL" || type === "fcTL" || type === "fdAT") {
      throw new Error("Animated PNG (APNG) is not supported.");
    } else if (type === "PLTE") {
      if (sawPalette || sawData || !length || length > 768 || length % 3 !== 0 || [0, 4].includes(colorType)) throw new Error("Malformed or misplaced PNG palette.");
      if (colorType === 3 && length / 3 > 2 ** bitDepth) throw new Error("PNG palette exceeds its indexed bit depth.");
      sawPalette = true;
    } else if (type === "IDAT") {
      if (!sawHeader || sawEnd || leftDataSequence) throw new Error("PNG IDAT is out of order.");
      if (colorType === 3 && !sawPalette) throw new Error("Indexed PNG is missing its required palette.");
      sawData = true;
      compressedChunks.push(bytes.subarray(dataStart, dataEnd));
    } else if (type === "IEND") {
      if (length !== 0 || !sawData) throw new Error("Malformed PNG IEND.");
      sawEnd = true;
      offset = chunkEnd;
      if (offset !== bytes.length) throw new Error("PNG contains trailing bytes after IEND.");
      break;
    } else if (/[A-Z]/u.test(type[0])) {
      throw new Error(`Unsupported critical PNG chunk ${type}.`);
    } else if (sawData) {
      leftDataSequence = true;
    }
    offset = chunkEnd;
  }
  if (!sawHeader || !sawData || !sawEnd) throw new Error("Incomplete PNG image.");
  const channels = new Map([[0, 1], [2, 3], [3, 1], [4, 2], [6, 4]]).get(colorType);
  const bitsPerPixel = channels * bitDepth;
  const scanlineBytes = (scanWidth) => 1 + Math.ceil((scanWidth * bitsPerPixel) / 8);
  let expectedInflatedBytes = 0;
  const passes = [];
  if (interlace === 0) {
    expectedInflatedBytes = height * scanlineBytes(width);
    passes.push([width, height]);
  } else {
    for (const [startX, startY, stepX, stepY] of [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]]) {
      const passWidth = width <= startX ? 0 : Math.ceil((width - startX) / stepX);
      const passHeight = height <= startY ? 0 : Math.ceil((height - startY) / stepY);
      if (passWidth && passHeight) {
        expectedInflatedBytes += passHeight * scanlineBytes(passWidth);
        passes.push([passWidth, passHeight]);
      }
    }
  }
  let inflated;
  try {
    inflated = inflateSync(Buffer.concat(compressedChunks), { maxOutputLength: expectedInflatedBytes + 1 });
  } catch {
    throw new Error("PNG image data is not a valid bounded zlib stream.");
  }
  if (inflated.length !== expectedInflatedBytes) throw new Error("PNG image data length does not match its dimensions.");
  let inflatedOffset = 0;
  for (const [passWidth, passHeight] of passes) {
    const rowBytes = scanlineBytes(passWidth);
    for (let row = 0; row < passHeight; row += 1) {
      if (inflated[inflatedOffset] > 4) throw new Error("PNG scanline uses an invalid filter type.");
      inflatedOffset += rowBytes;
    }
  }
  return { mimeType: "image/png", width, height };
}

const JPEG_SOF_MARKERS = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
  0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
]);

function inspectJpeg(bytes, limits = {}) {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
    throw new Error("Malformed JPEG signature.");
  }
  let offset = 2;
  let width = 0;
  let height = 0;
  let sawEnd = false;
  let sawScan = false;
  let scanDataBytes = 0;
  while (offset < bytes.length) {
    if (bytes[offset] !== 0xff) throw new Error("Malformed JPEG marker stream.");
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
    if (offset >= bytes.length) throw new Error("Truncated JPEG marker.");
    const marker = bytes[offset];
    offset += 1;
    if (marker === 0xd9) {
      sawEnd = true;
      if (offset !== bytes.length) throw new Error("JPEG contains trailing bytes after EOI.");
      break;
    }
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) throw new Error("Truncated JPEG segment length.");
    const segmentLength = bytes.readUInt16BE(offset);
    if (segmentLength < 2 || offset + segmentLength > bytes.length) {
      throw new Error("Invalid JPEG segment length.");
    }
    if (JPEG_SOF_MARKERS.has(marker)) {
      if (segmentLength < 8) throw new Error("Truncated JPEG frame header.");
      height = bytes.readUInt16BE(offset + 3);
      width = bytes.readUInt16BE(offset + 5);
      if (!width || !height) throw new Error("JPEG has zero dimensions.");
      const maxDimension = Number(limits.max_dimension ?? Number.MAX_SAFE_INTEGER);
      const maxPixels = Number(limits.max_pixels ?? Number.MAX_SAFE_INTEGER);
      const pixelCount = width * height;
      if (width > maxDimension || height > maxDimension) throw new Error(`Image exceeds the ${maxDimension}-pixel dimension limit.`);
      if (!Number.isSafeInteger(pixelCount) || pixelCount > maxPixels) throw new Error(`Image exceeds the ${maxPixels}-pixel decoded limit.`);
    }
    if (marker === 0xda) {
      if (!width || !height || segmentLength < 6) throw new Error("JPEG scan precedes a valid frame header.");
      sawScan = true;
      offset += segmentLength;
      let foundMarker = false;
      while (offset < bytes.length) {
        if (bytes[offset] !== 0xff) {
          scanDataBytes += 1;
          offset += 1;
          continue;
        }
        let markerOffset = offset + 1;
        while (markerOffset < bytes.length && bytes[markerOffset] === 0xff) markerOffset += 1;
        if (markerOffset >= bytes.length) throw new Error("Truncated JPEG scan data.");
        const scanMarker = bytes[markerOffset];
        if (scanMarker === 0x00) {
          scanDataBytes += 1;
          offset = markerOffset + 1;
          continue;
        }
        if (scanMarker >= 0xd0 && scanMarker <= 0xd7) {
          offset = markerOffset + 1;
          continue;
        }
        offset = markerOffset - 1;
        foundMarker = true;
        break;
      }
      if (!foundMarker) throw new Error("JPEG scan has no terminating marker.");
      continue;
    }
    offset += segmentLength;
  }
  if (!sawEnd || !sawScan || !scanDataBytes || !width || !height) throw new Error("Incomplete JPEG image.");
  let decoded;
  try {
    decoded = jpeg.decode(bytes, {
      useTArray: true,
      formatAsRGBA: false,
      tolerantDecoding: false,
      maxResolutionInMP: Number(limits.max_pixels ?? 4_194_304) / 1_000_000,
      maxMemoryUsageInMB: 64,
    });
  } catch {
    throw new Error("JPEG image data could not be decoded safely.");
  }
  if (decoded.width !== width || decoded.height !== height) throw new Error("JPEG decoded dimensions do not match its frame header.");
  return { mimeType: "image/jpeg", width, height };
}

function inspectGif(bytes) {
  if (bytes.length < 13 || !["GIF87a", "GIF89a"].includes(bytes.subarray(0, 6).toString("ascii"))) {
    throw new Error("Malformed GIF signature or header.");
  }
  const width = bytes.readUInt16LE(6);
  const height = bytes.readUInt16LE(8);
  if (!width || !height || bytes.at(-1) !== 0x3b) throw new Error("Malformed or incomplete GIF image.");
  return { mimeType: "image/gif", width, height };
}

export function inspectRasterAsset(buffer, internalPath, limits = {}) {
  const bytes = Buffer.from(buffer ?? []);
  const maxBytes = Number(limits.max_bytes ?? Number.MAX_SAFE_INTEGER);
  if (bytes.length > maxBytes) throw new Error(`Image exceeds ${maxBytes} bytes.`);
  const extension = path.posix.extname(normalizeInternalPath(internalPath)).toLowerCase();
  let inspected;
  if (bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    inspected = inspectPng(bytes, limits);
    if (extension !== ".png") throw new Error("Image extension/signature mismatch: expected .png.");
  } else if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    inspected = inspectJpeg(bytes, limits);
    if (extension !== ".jpg" && extension !== ".jpeg") {
      throw new Error("Image extension/signature mismatch: expected .jpg or .jpeg.");
    }
  } else if (bytes.length >= 6 && ["GIF87a", "GIF89a"].includes(bytes.subarray(0, 6).toString("ascii"))) {
    inspected = inspectGif(bytes);
    if (extension !== ".gif") throw new Error("Image extension/signature mismatch: expected .gif.");
  } else {
    const prefix = bytes.subarray(0, 256).toString("utf8").trimStart().toLowerCase();
    if (prefix.startsWith("<svg") || prefix.startsWith("<!doctype html") || prefix.startsWith("<html")) {
      throw new Error("Disguised SVG or HTML is not a raster image.");
    }
    throw new Error("Unsupported or malformed raster image.");
  }

  const byteCount = bytes.length;
  const pixelCount = inspected.width * inspected.height;
  const maxDimension = Number(limits.max_dimension ?? Number.MAX_SAFE_INTEGER);
  const maxPixels = Number(limits.max_pixels ?? Number.MAX_SAFE_INTEGER);
  if (byteCount > maxBytes) throw new Error(`Image exceeds ${maxBytes} bytes.`);
  if (inspected.width > maxDimension || inspected.height > maxDimension) {
    throw new Error(`Image exceeds the ${maxDimension}-pixel dimension limit.`);
  }
  if (!Number.isSafeInteger(pixelCount) || pixelCount > maxPixels) {
    throw new Error(`Image exceeds the ${maxPixels}-pixel decoded limit.`);
  }
  return { ...inspected, byteCount, pixelCount };
}

export function inspectPolicyPinnedPngException(bytesInput, source, internalPathInput, limits, exception) {
  const bytes = Buffer.from(bytesInput ?? []);
  const internalPath = normalizeInternalPath(internalPathInput);
  if (
    source !== exception.source || internalPath.toLowerCase() !== exception.internalPath ||
    bytes.length !== exception.bytes ||
    createHash("sha256").update(bytes).digest("hex") !== exception.sha256 ||
    exception.validPngPrefixBytes >= bytes.length
  ) throw new Error("Pinned PNG exception does not match its exact hash or byte contract.");
  const prefix = bytes.subarray(0, exception.validPngPrefixBytes);
  const inspected = inspectRasterAsset(prefix, internalPath, {
    ...limits,
    // The package preserves the official full bytes. The strict PNG prefix is
    // independently bounded here, then the full raw byte cap is checked below.
    max_bytes: Math.max(Number(limits.max_bytes), prefix.length),
  });
  if (bytes.length > limits.max_bytes) throw new Error(`Image exceeds ${limits.max_bytes} bytes.`);
  return { ...inspected, byteCount: bytes.length };
}

export function detectHtmlEncoding(buffer) {
  if (!Buffer.isBuffer(buffer) && !(buffer instanceof Uint8Array)) {
    throw new TypeError("detectHtmlEncoding expects a Buffer or Uint8Array.");
  }

  const bytes = Buffer.from(buffer);
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return "utf-8";
  }
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    return "utf-16le";
  }
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    return "utf-16be";
  }

  // Charset declarations are ASCII-compatible even when the document itself
  // is Windows-1252 or ISO-8859-1, so latin1 is safe for this inspection pass.
  const header = bytes.subarray(0, Math.min(bytes.length, 65_536)).toString("latin1");
  const match = /charset\s*=\s*["']?\s*([a-z0-9._:-]+)/i.exec(header);
  const declared = (match?.[1] ?? "windows-1252").toLowerCase().replace(/_+/g, "-");
  const aliases = new Map([
    ["ansi", "windows-1252"],
    ["cp1252", "windows-1252"],
    ["windows1252", "windows-1252"],
    ["iso8859-1", "iso-8859-1"],
    ["iso-8859-1", "iso-8859-1"],
    ["latin1", "iso-8859-1"],
    ["latin-1", "iso-8859-1"],
    ["us-ascii", "windows-1252"],
    ["utf8", "utf-8"],
  ]);
  const encoding = aliases.get(declared) ?? declared;
  if (!iconv.encodingExists(encoding)) {
    throw new Error(`Unsupported HTML encoding declaration: ${declared}`);
  }
  return encoding;
}

export function decodeHtml(buffer) {
  const encoding = detectHtmlEncoding(buffer);
  return iconv.decode(Buffer.from(buffer), encoding).replace(/^\uFEFF/, "");
}

function cleanInlineText(value) {
  return String(value ?? "")
    .replace(/[\u00a0\u2007\u202f]/gu, " ")
    .replace(/[\u200b\u2060\ufeff]/gu, "")
    .replace(/\s+/gu, " ")
    .trim();
}

function elementName(node) {
  return String(node?.name ?? node?.tagName ?? "").toLowerCase();
}

function className(node) {
  return String(node?.attribs?.class ?? "");
}

function applyOffsetAwareReplacement(text, offsets, pattern, replacement) {
  const matches = [...text.matchAll(pattern)].map((match) => ({
    start: match.index,
    end: match.index + match[0].length,
    replacement: typeof replacement === "function" ? String(replacement(match[0])) : String(replacement),
  }));
  if (!matches.length) return { text, offsets };
  let cursor = 0;
  let result = "";
  for (const match of matches) {
    result += text.slice(cursor, match.start);
    result += match.replacement;
    cursor = match.end;
  }
  result += text.slice(cursor);

  const mapped = offsets.map((offset) => {
    let delta = 0;
    for (const match of matches) {
      if (offset < match.start) break;
      if (offset > match.end) {
        delta += match.replacement.length - (match.end - match.start);
        continue;
      }
      if (offset === match.end) return match.start + delta + match.replacement.length;
      return match.start + delta + Math.min(offset - match.start, match.replacement.length);
    }
    return offset + delta;
  });
  return { text: result, offsets: mapped };
}

function normalizeRenderedOutput(rawOutput, rawOffsets) {
  let stage = applyOffsetAwareReplacement(rawOutput, rawOffsets, /[ \t]+\n/gu, "\n");
  stage = applyOffsetAwareReplacement(stage.text, stage.offsets, /\n{3,}/gu, "\n\n");
  const leftTrim = stage.text.length - stage.text.trimStart().length;
  const trimmed = stage.text.trim();
  return {
    content: trimmed,
    offsets: stage.offsets.map((offset) => Math.max(0, Math.min(trimmed.length, offset - leftTrim))),
  };
}

/**
 * Render a Cheerio subtree as deterministic plain text. Explicit HTML breaks
 * and block boundaries become newlines. MQL5 code-example non-breaking spaces
 * are retained as ordinary spaces instead of being globally collapsed. Image
 * offsets are captured without inserting markers into the searchable text.
 */
export function renderHelpContentDetailed($, rootNode) {
  const node = rootNode?.cheerio ? rootNode.get(0) : rootNode;
  if (!node) return { content: "", images: [], headings: [] };

  let output = "";
  const imageEvents = [];
  const headingEvents = [];

  const newline = () => {
    output = output.replace(/[ \t]+$/u, "");
    if (output && !output.endsWith("\n")) output += "\n";
  };

  const appendNormal = (value) => {
    let text = String(value ?? "")
      .replace(/[\u00a0\u2007\u202f]/gu, " ")
      .replace(/[\u200b\u2060\ufeff]/gu, "")
      .replace(/\s+/gu, " ");
    if (!text) return;
    if (!output || output.endsWith("\n")) text = text.replace(/^ +/u, "");
    if (output.endsWith(" ") && text.startsWith(" ")) text = text.slice(1);
    output += text;
  };

  const appendCode = (value, preserveLiteralNewlines) => {
    let text = String(value ?? "")
      .replace(/\r\n?/gu, "\n")
      .replace(/[\u200b\u2060\ufeff]/gu, "");
    if (!preserveLiteralNewlines) {
      // Newlines between span tags are source formatting. Real code breaks in
      // these CHMs are represented by <br>, which is handled separately.
      text = text.replace(/[ \t]*\n[ \t]*/gu, "");
    }
    text = text.replace(/[\u00a0\u2007\u202f]/gu, " ");
    output += text;
  };

  const walk = (current, inCode = false, preserveLiteralNewlines = false) => {
    if (!current) return;
    if (current.type === "text") {
      if (inCode) appendCode(current.data, preserveLiteralNewlines);
      else appendNormal(current.data);
      return;
    }
    if (current.type === "comment") return;

    const tag = elementName(current);
    if (SKIPPED_ELEMENTS.has(tag)) return;
    if (tag === "img") {
      imageEvents.push({ element: current, rawOffset: output.length });
      return;
    }
    if (tag === "br") {
      newline();
      return;
    }
    if (tag === "hr") {
      newline();
      return;
    }

    const isBlock = BLOCK_ELEMENTS.has(tag);
    const codeHere = inCode || tag === "pre" || tag === "code" || CODE_CLASS_PATTERN.test(className(current));
    const literalHere = preserveLiteralNewlines || tag === "pre";
    if (isBlock) newline();
    const heading = headingTextForElement($, current, node);
    let headingEvent;
    if (heading && headingEvents.at(-1)?.heading !== heading) {
      headingEvent = { heading, rawOffset: output.length, rawEndOffset: output.length };
      headingEvents.push(headingEvent);
    }
    if (tag === "li") appendNormal("- ");

    const children = current.children ?? [];
    for (let index = 0; index < children.length; index += 1) {
      const child = children[index];
      walk(child, codeHere, literalHere);
      if (tag === "tr" && elementName(child) === "td" && index < children.length - 1) {
        appendNormal(" | ");
      }
    }

    if (headingEvent) headingEvent.rawEndOffset = output.length;
    if (isBlock) newline();
  };

  walk(node);
  const normalized = normalizeRenderedOutput(output, [
    ...imageEvents.map((event) => event.rawOffset),
    ...headingEvents.map((event) => event.rawOffset),
    ...headingEvents.map((event) => event.rawEndOffset),
  ]);
  const headingStartOffsetIndex = imageEvents.length;
  const headingEndOffsetIndex = headingStartOffsetIndex + headingEvents.length;
  return {
    content: normalized.content,
    images: imageEvents.map((event, index) => ({ element: event.element, textOffset: normalized.offsets[index] })),
    headings: headingEvents.flatMap((event, index) => {
      const startOffset = normalized.offsets[headingStartOffsetIndex + index];
      const endOffset = normalized.offsets[headingEndOffsetIndex + index];
      // Preserve the established section contract: headings whose rendered
      // node text contains structural line breaks were never section anchors.
      // Eligible starts still come exclusively from the actual DOM node.
      if (normalized.content.slice(startOffset, endOffset).trim() !== event.heading) return [];
      return [{ heading: event.heading, startOffset }];
    }),
  };
}

export function renderHelpContent($, rootNode) {
  return renderHelpContentDetailed($, rootNode).content;
}

function sitemapObjectValues(fragment) {
  const $ = cheerio.load(fragment);
  const values = new Map();
  $("param").each((_index, element) => {
    const key = cleanInlineText($(element).attr("name")).toLowerCase();
    const value = cleanInlineText($(element).attr("value"));
    if (key && value && !values.has(key)) values.set(key, value);
  });
  return values;
}

/**
 * Parse the deliberately loose HTML Help sitemap syntax used by .hhc/.hhk.
 * A small token parser is more reliable than relying on repaired <li> nesting.
 */
export function parseSitemap(html, { hierarchical = true } = {}) {
  const input = String(html ?? "");
  const tokenPattern = /<\/?ul\b[^>]*>|<object\b[^>]*>[\s\S]*?<\/object\s*>/giu;
  const stack = [];
  const entries = [];
  let pendingName = "";
  let match;

  while ((match = tokenPattern.exec(input)) !== null) {
    const token = match[0];
    if (/^<ul\b/i.test(token)) {
      if (hierarchical && pendingName) stack.push(pendingName);
      pendingName = "";
      continue;
    }
    if (/^<\/ul\b/i.test(token)) {
      if (hierarchical && stack.length) stack.pop();
      pendingName = "";
      continue;
    }

    const values = sitemapObjectValues(token);
    // Cheerio already decodes attribute entities. Loading the value as HTML a
    // second time would incorrectly treat template names such as "vector<T>"
    // as markup.
    const name = cleanInlineText(values.get("name") ?? "");
    const rawLocal = values.get("local") ?? "";
    let local = "";
    if (rawLocal) {
      try {
        local = normalizeInternalPath(rawLocal);
      } catch {
        local = "";
      }
    }
    if (name || local) {
      const breadcrumbParts = hierarchical
        ? [...stack, ...(name ? [name] : [])]
        : name
          ? [name]
          : [];
      entries.push({ name, local, breadcrumbParts });
    }
    pendingName = name;
  }
  return entries;
}

function addAuxiliaryEntry(map, internalPath, value) {
  const key = normalizeInternalPath(internalPath).toLowerCase();
  if (!key) return;
  const current = map.get(key) ?? { aliases: [], breadcrumbs: [] };
  if (value.alias) current.aliases.push(value.alias);
  if (value.breadcrumb?.length) current.breadcrumbs.push(value.breadcrumb);
  map.set(key, current);
}

async function enumerateFiles(directory, predicate = () => true) {
  const results = [];

  async function visit(currentDirectory) {
    const entries = await readdir(currentDirectory, { withFileTypes: true });
    entries.sort((left, right) => compareOrdinal(left.name.toLowerCase(), right.name.toLowerCase()));
    for (const entry of entries) {
      const fullPath = path.join(currentDirectory, entry.name);
      if (entry.isSymbolicLink()) {
        throw new Error(`Symbolic links are not allowed in extracted CHM trees: ${fullPath}`);
      }
      if (entry.isDirectory()) await visit(fullPath);
      else if (entry.isFile() && predicate(fullPath)) results.push(fullPath);
    }
  }

  await visit(directory);
  results.sort((left, right) => compareOrdinal(normalizeSlashes(left).toLowerCase(), normalizeSlashes(right).toLowerCase()));
  return results;
}

async function loadAuxiliaryMap(extractedDirectory) {
  const result = new Map();
  const auxiliaryFiles = await enumerateFiles(extractedDirectory, (filePath) => /\.(?:hhc|hhk)$/i.test(filePath));

  for (const filePath of auxiliaryFiles) {
    const extension = path.extname(filePath).toLowerCase();
    const decoded = decodeHtml(await readFile(filePath));
    const entries = parseSitemap(decoded, { hierarchical: extension === ".hhc" });
    for (const entry of entries) {
      if (!entry.local) continue;
      addAuxiliaryEntry(result, entry.local, {
        alias: entry.name,
        breadcrumb: extension === ".hhc" ? entry.breadcrumbParts : [],
      });
    }
  }
  return result;
}

function extractHtmlBreadcrumb($) {
  const text = cleanInlineText($(".nav").first().text());
  if (!text) return "";
  return text
    .split(/\s*\/\s*/u)
    .map(cleanInlineText)
    .filter(Boolean)
    .join(" > ");
}

function chooseBreadcrumb(auxiliaryEntry, htmlBreadcrumb, title) {
  const candidates = auxiliaryEntry?.breadcrumbs ?? [];
  if (candidates.length) {
    const best = [...candidates].sort((left, right) => {
      if (left.length !== right.length) return right.length - left.length;
      return compareOrdinal(left.join("\u0000"), right.join("\u0000"));
    })[0];
    return best.map(cleanInlineText).filter(Boolean).join(" > ");
  }
  return htmlBreadcrumb || title;
}

function collectAliases($, title, auxiliaryEntry) {
  const aliases = new Map();
  const add = (alias, sourceKind) => {
    const clean = cleanInlineText(alias);
    const normalized = normalizeText(clean);
    if (!clean || !normalized || aliases.has(normalized)) return;
    aliases.set(normalized, { alias: clean, normalizedAlias: normalized, sourceKind });
  };

  add(title, "html-title");
  $("meta").each((_index, element) => {
    const name = cleanInlineText($(element).attr("name")).toLowerCase();
    if (name !== "keywords" && name !== "keyword") return;
    const content = String($(element).attr("content") ?? "");
    for (const keyword of content.split(/[;,|]/u)) add(keyword, "html-keyword");
  });
  for (const alias of auxiliaryEntry?.aliases ?? []) add(alias, "help-index");
  return [...aliases.values()].sort((left, right) => compareOrdinal(left.normalizedAlias, right.normalizedAlias));
}

function renderElement($, element) {
  return renderHelpContent($, element).trim();
}

function callableIdentifierFromTitle(title) {
  let simplified = cleanInlineText(title)
    .replace(/\s*\((?:get|set)\s+method\)\s*$/iu, "")
    .replace(/\(\s*\)\s*$/u, "");
  for (;;) {
    const withoutTemplateArguments = simplified.replace(/<[^<>]*>/gu, "");
    if (withoutTemplateArguments === simplified) break;
    simplified = withoutTemplateArguments;
  }
  const identifiers = simplified.match(/[A-Za-z_][A-Za-z0-9_]*/gu);
  return identifiers?.at(-1) ?? "";
}

function escapeRegularExpression(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function findClosingParenthesis(text, openOffset) {
  let depth = 0;
  let quote = "";
  let lineComment = false;
  let blockComment = false;
  for (let index = openOffset; index < text.length; index += 1) {
    const character = text[index];
    const next = text[index + 1] ?? "";
    if (lineComment) {
      if (character === "\n") lineComment = false;
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (character === "\\") index += 1;
      else if (character === quote) quote = "";
      continue;
    }
    if (character === "/" && next === "/") {
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      continue;
    }
    if (character === "(") depth += 1;
    else if (character === ")") {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

function callableDeclarationEnd(text, closingParenthesis) {
  let cursor = closingParenthesis + 1;
  let endOffset = cursor;
  for (;;) {
    let tokenOffset = cursor;
    while (/\s/u.test(text[tokenOffset] ?? "")) tokenOffset += 1;
    const keyword = /^(?:const|override|final)\b/iu.exec(text.slice(tokenOffset));
    if (keyword) {
      cursor = tokenOffset + keyword[0].length;
      endOffset = cursor;
      continue;
    }
    const pureVirtual = /^=\s*0\b/u.exec(text.slice(tokenOffset));
    if (pureVirtual) {
      cursor = tokenOffset + pureVirtual[0].length;
      endOffset = cursor;
      continue;
    }
    if (text[tokenOffset] === ";") endOffset = tokenOffset + 1;
    return endOffset;
  }
}

function isTypedDeclarationPrefix(prefix) {
  return Boolean(prefix) &&
    !/[#{};=]/u.test(prefix) &&
    !/\b(?:if|for|while|switch|return|new|delete|sizeof)\b/iu.test(prefix) &&
    /^[A-Za-z_][A-Za-z0-9_:\s<>,*&~[\]]*$/u.test(prefix);
}

function matchingCallableDeclaration(text, title) {
  const identifier = callableIdentifierFromTitle(title);
  if (!identifier) return "";
  const callablePattern = new RegExp(
    `(^|[^A-Za-z0-9_])(${escapeRegularExpression(identifier)})\\s*\\(`,
    "giu",
  );
  for (const match of text.matchAll(callablePattern)) {
    const identifierOffset = match.index + match[1].length;
    const previousTerminator = text.lastIndexOf(");", identifierOffset);
    const previousBlankLine = text.lastIndexOf("\n\n", identifierOffset);
    const declarationStart = Math.max(
      previousTerminator >= 0 ? previousTerminator + 2 : 0,
      previousBlankLine >= 0 ? previousBlankLine + 2 : 0,
    );
    const declarationPrefix = text.slice(declarationStart, identifierOffset).trim();
    const openingParenthesis = text.indexOf("(", identifierOffset + identifier.length);
    const closingParenthesis = findClosingParenthesis(text, openingParenthesis);
    if (closingParenthesis < 0) continue;
    const declarationEnd = callableDeclarationEnd(text, closingParenthesis);
    const standaloneBareSignature =
      !declarationPrefix &&
      declarationStart === 0 &&
      !text.slice(declarationEnd).trim();
    if (!standaloneBareSignature && !isTypedDeclarationPrefix(declarationPrefix)) {
      continue;
    }
    return text.slice(declarationStart, declarationEnd).trim();
  }
  return "";
}

export function extractSignature($, helpRoot, title) {
  const trustedLabels = [
    title,
    $(helpRoot).find("h1, .p_H1, .f_H1").first().text(),
  ];
  const trustedIdentifiers = new Set(
    trustedLabels.map(callableIdentifierFromTitle).filter(Boolean),
  );
  const candidates = [];
  $(helpRoot)
    .find("pre, code, .p_CodeExample")
    .each((_index, element) => {
      const parent = $(element).parent();
      if (
        (elementName(element) === "code" && parent.is("pre")) ||
        (parent.length && parent.hasClass("p_CodeExample"))
      ) {
        return;
      }
      candidates.push(element);
    });

  for (const candidate of candidates) {
    const text = renderElement($, candidate)
      .replace(/\n{3,}/gu, "\n\n")
      .trim();
    if (!text || !text.includes("(")) continue;
    const explicitIdentifiers = new Set(
      $(candidate)
        .find(".f_Functions")
        .addBack(".f_Functions")
        .toArray()
        .map((element) => callableIdentifierFromTitle($(element).text()))
        .filter(Boolean),
    );
    let declaration = "";
    for (const identifier of trustedIdentifiers) {
      declaration = matchingCallableDeclaration(text, identifier);
      if (declaration && (!explicitIdentifiers.size || explicitIdentifiers.has(identifier))) {
        break;
      }
      declaration = "";
    }
    if (!declaration) continue;
    if (declaration.length > 800) declaration = `${declaration.slice(0, 797).trimEnd()}...`;
    return declaration;
  }
  return "";
}

function headingTextForElement($, element, helpRoot) {
  const tag = elementName(element);
  const classes = className(element);
  if (!/^h[1-6]$/u.test(tag) && !HEADING_CLASS_PATTERN.test(classes)) return "";
  if ($(element).parentsUntil(helpRoot, "[class]").toArray().some((parent) => HEADING_CLASS_PATTERN.test(className(parent)))) {
    return "";
  }
  const heading = cleanInlineText($(element).text());
  return heading.length <= 200 ? heading : "";
}

function linkRelationship($, element, helpRoot) {
  const contextNodes = [element, ...$(element).parentsUntil(helpRoot).toArray()];
  if (contextNodes.some((node) => SEE_ALSO_CLASS_PATTERN.test(className(node)))) return "see-also";

  const block = $(element).closest("p, li, td, dd, div").first();
  const blockText = normalizeText(block.text());
  if (blockText === "see also" || blockText.startsWith("see also ")) return "see-also";

  let previous = block.prev();
  while (previous.length && !cleanInlineText(previous.text())) previous = previous.prev();
  return normalizeText(previous.text()) === "see also" ? "see-also" : "inline";
}

/** Extract and deduplicate safe same-CHM topic anchors from div#help. */
export function extractInternalLinks($, helpRoot, sourceInternalPath) {
  const links = new Map();
  $(helpRoot)
    .find("a[href]")
    .each((_index, element) => {
      const resolved = resolveInternalLink(sourceInternalPath, $(element).attr("href"));
      if (!resolved) return;

      const relationship = linkRelationship($, element, helpRoot);
      const label = cleanInlineText(
        $(element).text() || $(element).attr("title") || $(element).find("img[alt]").first().attr("alt") ||
          path.posix.basename(resolved.targetInternalPath, path.posix.extname(resolved.targetInternalPath)),
      ).slice(0, 300);
      const key = `${resolved.targetInternalPath.toLowerCase()}\u0000${resolved.targetFragment}`;
      const existing = links.get(key);
      if (existing) {
        if (existing.relationship === "inline" && relationship === "see-also") {
          existing.relationship = "see-also";
          if (label) existing.label = label;
        }
        return;
      }
      links.set(key, { ...resolved, label, relationship });
    });

  return [...links.values()].map((link, ordinal) => ({ ...link, ordinal }));
}

export function splitSections(content, headingPositions, fallbackTitle = "Overview") {
  const text = String(content ?? "");
  if (!text) return [];

  const positioned = [];
  for (const rawHeading of headingPositions ?? []) {
    const heading = cleanInlineText(rawHeading?.heading);
    const startOffset = Number(rawHeading?.startOffset);
    if (!heading) continue;
    if (!Number.isSafeInteger(startOffset) || startOffset < 0 || startOffset > text.length) continue;
    if (positioned.at(-1)?.startOffset > startOffset) {
      throw new Error("Rendered heading offsets are not monotonic.");
    }
    if (positioned.some((entry) => entry.startOffset === startOffset)) continue;
    positioned.push({ heading, startOffset });
  }

  if (!positioned.length || positioned[0].startOffset > 0) {
    positioned.unshift({ heading: cleanInlineText(fallbackTitle) || "Overview", startOffset: 0 });
  } else {
    positioned[0].startOffset = 0;
  }

  return positioned
    .map((entry, ordinal) => {
      const endOffset = positioned[ordinal + 1]?.startOffset ?? text.length;
      return {
        ordinal,
        heading: entry.heading,
        startOffset: entry.startOffset,
        endOffset,
        content: text.slice(entry.startOffset, endOffset).trimEnd(),
      };
    })
    .filter((section) => section.content.length > 0)
    .map((section, ordinal) => ({ ...section, ordinal }));
}

function normalizeCaptionComponent(value, maximumLength = 500) {
  return String(value ?? "")
    .normalize("NFKC")
    .replace(/[\u0000-\u001f\u007f-\u009f]/gu, " ")
    .replace(/[\u00a0\u2007\u202f]/gu, " ")
    .replace(/[\u200b\u2060\ufeff]/gu, "")
    .replace(/\s+/gu, " ")
    .trim()
    .slice(0, maximumLength);
}

function isMeaningfulCaption(value, meaninglessCaptions) {
  const text = normalizeCaptionComponent(value);
  if (!text) return false;
  return !meaninglessCaptions.has(normalizeText(text));
}

function filenameCaption(internalPath, maximumLength) {
  const name = path.posix.basename(String(internalPath ?? ""), path.posix.extname(String(internalPath ?? "")));
  return normalizeCaptionComponent(name.replace(/[_-]+/gu, " "), maximumLength) || "Technical image";
}

function nearestImageText($, element, helpRoot, maximumLength) {
  const image = $(element);
  const block = image.closest("p, li, td, th, dd, dt, figure, div").first();
  if (block.length && block.get(0) !== helpRoot) {
    const clone = block.clone();
    clone.find("img, script, style, svg").remove();
    const text = normalizeCaptionComponent(clone.text(), maximumLength);
    if (text) return text;
  }
  const containingBlock = block.length ? block : image;
  for (const sibling of [containingBlock.prev(), containingBlock.next()]) {
    const text = normalizeCaptionComponent(sibling.text(), maximumLength);
    if (text) return text;
  }
  return "";
}

export function extractImageReferences($, helpRoot, sourceInternalPath, sections, {
  presentationAncestorSelectors = [],
  meaninglessCaptions = [],
  maxCaptionChars = 500,
  renderedHelp = undefined,
} = {}) {
  const rootNode = helpRoot?.cheerio ? helpRoot.get(0) : helpRoot;
  const rendered = renderedHelp ?? renderHelpContentDetailed($, rootNode);
  const meaningless = new Set(meaninglessCaptions.map((value) => normalizeText(value)).filter(Boolean));
  return rendered.images.map(({ element, textOffset }, occurrenceOrdinal) => {
    const image = $(element);
    const rawReference = String(image.attr("src") ?? "");
    const resolvedInternalPath = resolveInternalAssetPath(sourceInternalPath, rawReference);
    const figcaptionText = normalizeCaptionComponent(
      image.closest("figure").first().find("figcaption").first().text(),
      maxCaptionChars,
    );
    const titleText = normalizeCaptionComponent(image.attr("title"), maxCaptionChars);
    const altText = normalizeCaptionComponent(image.attr("alt"), maxCaptionChars);
    const nearbyText = nearestImageText($, element, rootNode, maxCaptionChars);
    const fallback = filenameCaption(resolvedInternalPath ?? rawReference, maxCaptionChars);
    let contextualCaption = fallback;
    let captionSource = "filename";
    for (const candidate of [
      [figcaptionText, "figcaption"],
      [titleText, "title"],
      [altText, "alt"],
      [nearbyText, "nearby"],
    ]) {
      if (isMeaningfulCaption(candidate[0], meaningless)) {
        contextualCaption = candidate[0];
        captionSource = candidate[1];
        break;
      }
    }
    const section = sections.find((candidate) =>
      textOffset >= candidate.startOffset && textOffset < candidate.endOffset,
    ) ?? sections.at(-1);
    const presentationOnly = presentationAncestorSelectors.some((selector) => {
      try {
        return image.closest(selector).length > 0;
      } catch {
        throw new Error(`Invalid image-policy selector: ${selector}`);
      }
    });
    return {
      occurrenceOrdinal,
      rawReference,
      internalPath: resolvedInternalPath,
      sectionOrdinal: section?.ordinal ?? 0,
      textOffset,
      figcaptionText,
      titleText,
      altText,
      nearbyText,
      contextualCaption,
      captionSource,
      presentationOnly,
    };
  });
}

export function parseHtmlTopic(html, {
  source,
  internalPath,
  auxiliaryEntry = undefined,
  imagePolicy = undefined,
} = {}) {
  const $ = cheerio.load(String(html ?? ""));
  const help = $("#help").first();
  if (!help.length) throw new Error(`Missing required div#help in ${source}/${internalPath}`);

  const title = cleanInlineText(
    $("title").first().text() ||
      help.find("h1, .p_H1, .f_H1").first().text() ||
      path.posix.basename(normalizeInternalPath(internalPath), path.posix.extname(internalPath)),
  );
  if (!title) throw new Error(`Unable to derive a title for ${source}/${internalPath}`);

  // A small number of official reference stubs contain only &nbsp; in #help.
  // They are still real CHM topics and must remain addressable; the title is
  // the only faithful searchable content available for those stubs.
  const renderedHelp = renderHelpContentDetailed($, help);
  const content = renderedHelp.content || title;

  const aliasRecords = collectAliases($, title, auxiliaryEntry);
  const breadcrumb = chooseBreadcrumb(auxiliaryEntry, extractHtmlBreadcrumb($), title);
  const signature = extractSignature($, help, title);
  const sections = splitSections(content, renderedHelp.headings, title);
  if (!sections.length) throw new Error(`No readable sections in ${source}/${internalPath}`);
  const links = extractInternalLinks($, help, internalPath);
  const imageReferences = extractImageReferences($, help, internalPath, sections, {
    presentationAncestorSelectors: imagePolicy?.presentation_ancestor_selectors ?? [],
    meaninglessCaptions: imagePolicy?.meaningless_captions ?? [],
    maxCaptionChars: imagePolicy?.limits?.max_caption_chars ?? 500,
    renderedHelp,
  });
  const contentSha256 = createHash("sha256").update(content, "utf8").digest("hex");

  return {
    source,
    internalPath: normalizeInternalPath(internalPath),
    title,
    normalizedTitle: normalizeText(title),
    breadcrumb,
    signature,
    content,
    contentLength: content.length,
    contentSha256,
    aliases: aliasRecords.map((entry) => entry.alias),
    aliasRecords,
    sections,
    links,
    imageReferences,
  };
}

export async function sha256File(filePath) {
  const hash = createHash("sha256");
  const stream = createReadStream(filePath);
  for await (const chunk of stream) hash.update(chunk);
  return hash.digest("hex");
}

function assertPathWithin(root, candidate, label, rootLabel = "project root") {
  const relative = path.relative(root, candidate);
  if (!relative || relative === ".") return;
  if (relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes the ${rootLabel}: ${candidate}`);
  }
}

function isSamePathOrDescendant(root, candidate) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return !relative || relative === "." || (
    !relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative)
  );
}

function pathsOverlap(left, right) {
  return isSamePathOrDescendant(left, right) || isSamePathOrDescendant(right, left);
}

function assertSafeOutputLocation(projectRoot, sourceDirectory, extractedRoot, outputDirectory) {
  if (path.resolve(outputDirectory).toLowerCase() === path.resolve(projectRoot).toLowerCase()) {
    throw new Error(`Output directory must not overlap the project/source root: ${outputDirectory}`);
  }
  if (pathsOverlap(outputDirectory, sourceDirectory)) {
    throw new Error(`Output directory must not overlap the source directory: ${outputDirectory}`);
  }
  if (pathsOverlap(outputDirectory, extractedRoot)) {
    throw new Error(`Output directory must not overlap the extracted documentation tree: ${outputDirectory}`);
  }

  for (const protectedName of [
    "app",
    "config",
    "data",
    "maintenance",
    "node_modules",
    "release",
    "revisions",
    "runtime",
    "scripts",
    "src",
    "tests",
    "tools",
  ]) {
    const protectedPath = path.join(projectRoot, protectedName);
    if (pathsOverlap(outputDirectory, protectedPath)) {
      throw new Error(
        `Output directory overlaps protected or immutable project path '${protectedName}': ${outputDirectory}`,
      );
    }
  }
}

async function assertPreparedOutputDirectory(outputDirectory, sourceFilenames) {
  const info = await lstat(outputDirectory).catch(() => null);
  if (!info) return;
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new Error(`Output directory must be an existing non-link directory: ${outputDirectory}`);
  }

  const entries = await readdir(outputDirectory, { withFileTypes: true });
  if (!entries.length) return;
  const carrierNames = new Set([
    ...sourceFilenames.map((filename) => filename.toLowerCase()),
    "corpus.lock.json",
  ]);
  const artifactNames = new Set(["mql5-docs.sqlite", "manifest.json", "assets"]);
  const allowedNames = new Set([...carrierNames, ...artifactNames, ".index-build.lock"]);
  const unexpected = entries
    .map((entry) => entry.name)
    .filter((name) => !allowedNames.has(name.toLowerCase()));
  if (unexpected.length) {
    throw new Error(
      `Output directory contains unexpected existing or pre-existing unowned content: ${unexpected.sort().join(", ")}.`,
    );
  }

  const names = new Set(entries.map((entry) => entry.name.toLowerCase()));
  const presentArtifacts = [...artifactNames].filter((name) => names.has(name));
  if (!presentArtifacts.length) return;
  if (presentArtifacts.length !== artifactNames.size) {
    throw new Error("Output directory contains an incomplete pre-existing index and is not safely owned.");
  }

  const manifestPath = path.join(outputDirectory, "manifest.json");
  const databasePath = path.join(outputDirectory, "mql5-docs.sqlite");
  const assetsPath = path.join(outputDirectory, "assets");
  await assertRealFile(manifestPath, "Existing output manifest");
  await assertRealFile(databasePath, "Existing output database");
  await assertRealDirectory(assetsPath, "Existing output assets");
  let manifest;
  try {
    manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  } catch (error) {
    throw new Error(`Output directory has an unreadable ownership manifest: ${error.message}`);
  }
  if (
    Number(manifest?.schema_version) !== SCHEMA_VERSION ||
    !["mql5-chm-index-v3-assets-v1", INDEX_CONTRACT].includes(manifest?.index_contract) ||
    manifest?.database?.filename !== "mql5-docs.sqlite" ||
    manifest?.assets?.directory !== "assets"
  ) {
    throw new Error("Output directory manifest does not identify a compatible owned index build.");
  }

  const databaseInfo = await stat(databasePath);
  const databaseSha256 = await sha256File(databasePath);
  if (
    manifest?.database?.sha256 !== databaseSha256 ||
    Number(manifest?.database?.bytes) !== databaseInfo.size ||
    manifest?.index_revision !== databaseSha256
  ) {
    throw new Error("Output directory database does not match its ownership manifest.");
  }

  let database;
  let catalogRows;
  try {
    database = new DatabaseSync(databasePath, {
      open: true,
      readOnly: true,
      allowExtension: false,
      enableForeignKeyConstraints: true,
      timeout: 10_000,
    });
    database.enableLoadExtension(false);
    const contract = database.prepare("SELECT value FROM metadata WHERE key='index_contract'").get()?.value;
    if (contract !== manifest.index_contract) {
      throw new Error("Existing output database contract does not match its manifest.");
    }
    catalogRows = database.prepare(`
      SELECT storage_key AS storageKey, sha256, byte_count AS byteCount
      FROM assets ORDER BY storage_key
    `).all();
  } catch (error) {
    throw new Error(`Output directory database ownership validation failed: ${error.message}`);
  } finally {
    database?.close();
  }

  if (Number(manifest?.assets?.cataloged_count) !== catalogRows.length) {
    throw new Error("Output directory asset count does not match its ownership manifest.");
  }
  const expectedAssets = new Map();
  for (const row of catalogRows) {
    const storageKey = normalizeSlashes(String(row.storageKey));
    if (!storageKey.startsWith("assets/") || !/^[0-9a-f]{64}$/u.test(String(row.sha256))) {
      throw new Error("Output directory database contains an invalid owned asset record.");
    }
    const relativePath = storageKey.slice("assets/".length);
    const key = relativePath.toLowerCase();
    if (!relativePath || expectedAssets.has(key)) {
      throw new Error("Output directory database contains a duplicate or invalid owned asset path.");
    }
    expectedAssets.set(key, {
      relativePath,
      sha256: String(row.sha256),
      byteCount: Number(row.byteCount),
    });
  }

  const actualFiles = await enumerateFiles(assetsPath);
  if (actualFiles.length !== expectedAssets.size) {
    throw new Error(
      `Output directory asset-tree closure mismatch: expected ${expectedAssets.size}, got ${actualFiles.length}.`,
    );
  }
  for (const filePath of actualFiles) {
    await assertNoLinkTraversal(assetsPath, filePath, "Existing output asset", "owned asset root");
    const relativePath = normalizeSlashes(path.relative(assetsPath, filePath));
    const expected = expectedAssets.get(relativePath.toLowerCase());
    if (!expected) {
      throw new Error(`Output directory asset-tree closure has unexpected existing content: ${relativePath}.`);
    }
    const fileInfo = await stat(filePath);
    if (fileInfo.size !== expected.byteCount || await sha256File(filePath) !== expected.sha256) {
      throw new Error(`Output directory owned asset failed integrity validation: ${relativePath}.`);
    }
  }
}

async function assertRealDirectory(directory, label) {
  const info = await lstat(directory).catch(() => null);
  if (!info?.isDirectory() || info.isSymbolicLink()) {
    throw new Error(`${label} must be an existing non-link directory: ${directory}`);
  }
  const canonical = await realpath(directory);
  if (path.resolve(canonical).toLowerCase() !== path.resolve(directory).toLowerCase()) {
    throw new Error(`${label} must not traverse a symbolic link or junction: ${directory}`);
  }
}

async function assertRealFile(filePath, label) {
  const info = await lstat(filePath).catch(() => null);
  if (!info?.isFile() || info.isSymbolicLink()) {
    throw new Error(`${label} must be an existing non-link file: ${filePath}`);
  }
}

async function assertNoLinkTraversal(root, candidate, label, rootLabel = "project root") {
  assertPathWithin(root, candidate, label, rootLabel);
  const relative = path.relative(root, candidate);
  if (!relative || relative === ".") return;
  let cursor = root;
  for (const segment of relative.split(path.sep)) {
    cursor = path.join(cursor, segment);
    const info = await lstat(cursor).catch((error) => {
      if (error?.code === "ENOENT") return null;
      throw error;
    });
    if (!info) return;
    if (info.isSymbolicLink()) {
      throw new Error(`${label} traverses a symbolic link or junction: ${cursor}`);
    }
  }
}

async function pathExists(filePath) {
  try {
    await access(filePath, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

export function createSchema(database) {
  database.exec(`
    PRAGMA application_id = 1297173557;
    PRAGMA user_version = ${SCHEMA_VERSION};
    PRAGMA foreign_keys = ON;
    PRAGMA journal_mode = DELETE;
    PRAGMA synchronous = FULL;
    PRAGMA temp_store = MEMORY;

    CREATE TABLE metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    ) STRICT;

    CREATE TABLE sources (
      source TEXT PRIMARY KEY,
      chm_filename TEXT NOT NULL,
      chm_sha256 TEXT NOT NULL CHECK(length(chm_sha256) = 64),
      chm_bytes INTEGER NOT NULL CHECK(chm_bytes > 0),
      topic_count INTEGER NOT NULL CHECK(topic_count >= 0),
      section_count INTEGER NOT NULL CHECK(section_count >= 0)
    ) STRICT;

    CREATE TABLE topics (
      topic_id TEXT PRIMARY KEY,
      source TEXT NOT NULL REFERENCES sources(source),
      internal_path TEXT NOT NULL,
      title TEXT NOT NULL,
      normalized_title TEXT NOT NULL,
      breadcrumb TEXT NOT NULL,
      signature TEXT NOT NULL,
      content_sha256 TEXT NOT NULL CHECK(length(content_sha256) = 64),
      content TEXT NOT NULL,
      content_length INTEGER NOT NULL CHECK(content_length >= 0),
      UNIQUE(source, internal_path)
    ) STRICT;

    CREATE TABLE aliases (
      alias TEXT NOT NULL,
      normalized_alias TEXT NOT NULL,
      topic_id TEXT NOT NULL REFERENCES topics(topic_id) ON DELETE CASCADE,
      source_kind TEXT NOT NULL,
      PRIMARY KEY(topic_id, normalized_alias)
    ) STRICT;

    CREATE TABLE sections (
      section_id TEXT PRIMARY KEY,
      topic_id TEXT NOT NULL REFERENCES topics(topic_id) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      heading TEXT NOT NULL,
      start_offset INTEGER NOT NULL CHECK(start_offset >= 0),
      end_offset INTEGER NOT NULL CHECK(end_offset >= start_offset),
      content TEXT NOT NULL,
      UNIQUE(topic_id, ordinal)
    ) STRICT;

    CREATE TABLE topic_links (
      source_topic_id TEXT NOT NULL REFERENCES topics(topic_id) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      target_topic_id TEXT REFERENCES topics(topic_id) ON DELETE CASCADE,
      target_internal_path TEXT NOT NULL,
      target_fragment TEXT NOT NULL,
      label TEXT NOT NULL,
      relationship TEXT NOT NULL CHECK(relationship IN ('see-also', 'inline')),
      resolution_status TEXT NOT NULL CHECK(resolution_status IN ('resolved', 'unresolved')),
      PRIMARY KEY(source_topic_id, ordinal),
      CHECK(
        (resolution_status = 'resolved' AND target_topic_id IS NOT NULL) OR
        (resolution_status = 'unresolved' AND target_topic_id IS NULL)
      )
    ) STRICT;

    CREATE TABLE assets (
      asset_id TEXT PRIMARY KEY,
      source TEXT NOT NULL REFERENCES sources(source),
      internal_path TEXT NOT NULL,
      path_sha256 TEXT NOT NULL CHECK(length(path_sha256) = 64),
      storage_key TEXT NOT NULL UNIQUE,
      mime_type TEXT NOT NULL,
      sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
      byte_count INTEGER NOT NULL CHECK(byte_count > 0),
      width INTEGER NOT NULL CHECK(width > 0),
      height INTEGER NOT NULL CHECK(height > 0),
      pixel_count INTEGER NOT NULL CHECK(pixel_count = width * height),
      exposure TEXT NOT NULL CHECK(exposure IN ('exposed', 'excluded')),
      exposure_reason TEXT NOT NULL,
      canonical_caption TEXT NOT NULL CHECK(length(canonical_caption) <= 500),
      UNIQUE(source, internal_path)
    ) STRICT;

    CREATE TABLE topic_assets (
      topic_id TEXT NOT NULL REFERENCES topics(topic_id) ON DELETE CASCADE,
      occurrence_ordinal INTEGER NOT NULL CHECK(occurrence_ordinal >= 0),
      asset_id TEXT NOT NULL REFERENCES assets(asset_id),
      section_id TEXT NOT NULL REFERENCES sections(section_id) ON DELETE CASCADE,
      text_offset INTEGER NOT NULL CHECK(text_offset >= 0),
      figcaption_text TEXT NOT NULL CHECK(length(figcaption_text) <= 500),
      title_text TEXT NOT NULL CHECK(length(title_text) <= 500),
      alt_text TEXT NOT NULL CHECK(length(alt_text) <= 500),
      nearby_text TEXT NOT NULL CHECK(length(nearby_text) <= 500),
      contextual_caption TEXT NOT NULL CHECK(length(contextual_caption) <= 500),
      caption_source TEXT NOT NULL CHECK(caption_source IN ('figcaption', 'title', 'alt', 'nearby', 'filename')),
      PRIMARY KEY(topic_id, occurrence_ordinal)
    ) STRICT;

    CREATE INDEX topics_source_title_idx ON topics(source, normalized_title);
    CREATE INDEX aliases_normalized_idx ON aliases(normalized_alias, topic_id);
    CREATE INDEX sections_topic_ordinal_idx ON sections(topic_id, ordinal);
    CREATE INDEX topic_links_target_idx ON topic_links(target_topic_id, relationship, source_topic_id);
    CREATE INDEX topic_links_source_relation_idx ON topic_links(source_topic_id, relationship, ordinal);
    CREATE UNIQUE INDEX assets_source_path_nocase_idx ON assets(source, lower(internal_path));
    CREATE INDEX assets_source_exposure_idx ON assets(source, exposure, asset_id);
    CREATE INDEX topic_assets_asset_idx ON topic_assets(asset_id, topic_id, occurrence_ordinal);
    CREATE INDEX topic_assets_section_idx ON topic_assets(topic_id, section_id, text_offset, occurrence_ordinal);

    CREATE VIRTUAL TABLE search_fts USING fts5(
      topic_id UNINDEXED,
      section_id UNINDEXED,
      source UNINDEXED,
      title,
      aliases,
      heading,
      breadcrumb,
      body,
      tokenize = 'unicode61 remove_diacritics 2',
      prefix = '2 3 4'
    );
  `);
}

function prepareStatements(database) {
  return {
    insertMetadata: database.prepare("INSERT INTO metadata(key, value) VALUES(?, ?)"),
    insertSource: database.prepare(`
      INSERT INTO sources(
        source, chm_filename, chm_sha256, chm_bytes, topic_count, section_count
      ) VALUES(?, ?, ?, ?, ?, 0)
    `),
    updateSourceSectionCount: database.prepare("UPDATE sources SET section_count = ? WHERE source = ?"),
    insertTopic: database.prepare(`
      INSERT INTO topics(
        topic_id, source, internal_path, title, normalized_title,
        breadcrumb, signature, content_sha256, content, content_length
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `),
    insertAlias: database.prepare(`
      INSERT INTO aliases(alias, normalized_alias, topic_id, source_kind)
      VALUES(?, ?, ?, ?)
    `),
    insertSection: database.prepare(`
      INSERT INTO sections(
        section_id, topic_id, ordinal, heading,
        start_offset, end_offset, content
      ) VALUES(?, ?, ?, ?, ?, ?, ?)
    `),
    insertFts: database.prepare(`
      INSERT INTO search_fts(
        topic_id, section_id, source, title, aliases, heading, breadcrumb, body
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
    `),
    insertTopicLink: database.prepare(`
      INSERT INTO topic_links(
        source_topic_id, ordinal, target_topic_id, target_internal_path,
        target_fragment, label, relationship, resolution_status
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
    `),
    insertAsset: database.prepare(`
      INSERT INTO assets(
        asset_id, source, internal_path, path_sha256, storage_key,
        mime_type, sha256, byte_count, width, height, pixel_count,
        exposure, exposure_reason, canonical_caption
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `),
    insertTopicAsset: database.prepare(`
      INSERT INTO topic_assets(
        topic_id, occurrence_ordinal, asset_id, section_id, text_offset,
        figcaption_text, title_text, alt_text, nearby_text,
        contextual_caption, caption_source
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `),
  };
}

function databaseScalar(database, sql, preferredKey) {
  const row = database.prepare(sql).get();
  if (!row) return undefined;
  if (preferredKey && Object.hasOwn(row, preferredKey)) return row[preferredKey];
  return Object.values(row)[0];
}

function validateDatabase(database, {
  expectedTopicCount,
  expectedSectionCount,
  expectedLinkCount,
  expectedResolvedLinkCount,
  expectedSources,
  expectedAssets,
  expectedOccurrenceCount,
  expectedAssetCatalogSha256,
}) {
  const integrity = String(databaseScalar(database, "PRAGMA integrity_check", "integrity_check") ?? "");
  if (integrity.toLowerCase() !== "ok") throw new Error(`SQLite integrity check failed: ${integrity}`);

  const foreignKeyFailures = database.prepare("PRAGMA foreign_key_check").all();
  if (foreignKeyFailures.length) {
    throw new Error(`SQLite foreign-key check returned ${foreignKeyFailures.length} failure(s).`);
  }

  const topicCount = Number(databaseScalar(database, "SELECT count(*) AS count FROM topics", "count"));
  const sourceCount = Number(databaseScalar(database, "SELECT count(*) AS count FROM sources", "count"));
  const sectionCount = Number(databaseScalar(database, "SELECT count(*) AS count FROM sections", "count"));
  const ftsCount = Number(databaseScalar(database, "SELECT count(*) AS count FROM search_fts", "count"));
  const linkCount = Number(databaseScalar(database, "SELECT count(*) AS count FROM topic_links", "count"));
  const resolvedLinkCount = Number(
    databaseScalar(database, "SELECT count(*) AS count FROM topic_links WHERE resolution_status = 'resolved'", "count"),
  );
  const assetCount = Number(databaseScalar(database, "SELECT count(*) AS count FROM assets", "count"));
  const occurrenceCount = Number(databaseScalar(database, "SELECT count(*) AS count FROM topic_assets", "count"));
  if (topicCount !== expectedTopicCount) {
    throw new Error(`Database topic count mismatch: expected ${expectedTopicCount}, got ${topicCount}.`);
  }
  if (sourceCount !== expectedSources.length) {
    throw new Error(`Database source count mismatch: expected ${expectedSources.length}, got ${sourceCount}.`);
  }
  if (sectionCount !== expectedSectionCount || ftsCount !== expectedSectionCount) {
    throw new Error(
      `Section/FTS count mismatch: expected ${expectedSectionCount}, sections=${sectionCount}, FTS=${ftsCount}.`,
    );
  }
  if (linkCount !== expectedLinkCount || resolvedLinkCount !== expectedResolvedLinkCount) {
    throw new Error(
      `Topic-link count mismatch: expected ${expectedLinkCount}/${expectedResolvedLinkCount} resolved, got ${linkCount}/${resolvedLinkCount}.`,
    );
  }
  if (assetCount !== expectedAssets.length || occurrenceCount !== expectedOccurrenceCount) {
    throw new Error(
      `Asset count mismatch: expected ${expectedAssets.length}/${expectedOccurrenceCount} occurrences, got ${assetCount}/${occurrenceCount}.`,
    );
  }

  for (const source of expectedSources) {
    const row = database.prepare(`
      SELECT topic_count, section_count,
        (SELECT count(*) FROM topics WHERE topics.source = sources.source) AS actual_topics,
        (SELECT count(*) FROM sections JOIN topics ON topics.topic_id = sections.topic_id
          WHERE topics.source = sources.source) AS actual_sections
      FROM sources WHERE source = ?
    `).get(source.source);
    if (!row || Number(row.topic_count) !== Number(row.actual_topics) || Number(row.section_count) !== Number(row.actual_sections)) {
      throw new Error(`Source count validation failed for ${source.source}.`);
    }
  }

  const invalidResolutionCount = Number(databaseScalar(database, `
    SELECT count(*) AS count
    FROM topic_links AS links
    JOIN topics AS source_topics ON source_topics.topic_id = links.source_topic_id
    LEFT JOIN topics AS target_topics ON target_topics.topic_id = links.target_topic_id
    WHERE (links.resolution_status = 'resolved' AND
      (target_topics.topic_id IS NULL OR target_topics.source <> source_topics.source))
      OR (links.resolution_status = 'unresolved' AND links.target_topic_id IS NOT NULL)
  `, "count"));
  if (invalidResolutionCount) {
    throw new Error(`Topic-link resolution validation returned ${invalidResolutionCount} failure(s).`);
  }

  const topicPaths = new Map();
  for (const row of database.prepare("SELECT topic_id, source, internal_path FROM topics").iterate()) {
    topicPaths.set(`${row.source}\u0000${String(row.internal_path).toLowerCase()}`, row.topic_id);
  }
  for (const row of database.prepare(`
    SELECT links.source_topic_id, links.target_topic_id, links.target_internal_path,
      links.resolution_status, source_topics.source
    FROM topic_links AS links
    JOIN topics AS source_topics ON source_topics.topic_id = links.source_topic_id
  `).iterate()) {
    const expectedTargetId = topicPaths.get(`${row.source}\u0000${String(row.target_internal_path).toLowerCase()}`) ?? null;
    if (row.target_topic_id !== expectedTargetId) {
      throw new Error(`Topic-link target-path validation failed for ${row.source_topic_id}.`);
    }
  }

  const duplicateLinkCount = Number(databaseScalar(database, `
    SELECT count(*) AS count FROM (
      SELECT source_topic_id, lower(target_internal_path), target_fragment, count(*) AS occurrences
      FROM topic_links
      GROUP BY source_topic_id, lower(target_internal_path), target_fragment
      HAVING occurrences > 1
    )
  `, "count"));
  if (duplicateLinkCount) throw new Error(`Topic-link deduplication validation found ${duplicateLinkCount} duplicate(s).`);

  for (const row of database.prepare("SELECT topic_id, content, content_length, content_sha256 FROM topics").iterate()) {
    const content = String(row.content);
    const expectedHash = createHash("sha256").update(content, "utf8").digest("hex");
    if (row.content_sha256 !== expectedHash) {
      throw new Error(`Topic content hash validation failed for ${row.topic_id}.`);
    }
    if (Number(row.content_length) !== content.length) {
      throw new Error(`Topic UTF-16 content-length validation failed for ${row.topic_id}.`);
    }
  }

  for (const row of database.prepare(`
    SELECT sections.section_id, sections.start_offset, sections.end_offset,
      sections.content AS section_content, topics.content AS topic_content
    FROM sections JOIN topics ON topics.topic_id = sections.topic_id
  `).iterate()) {
    const topicContent = String(row.topic_content);
    const startOffset = Number(row.start_offset);
    const endOffset = Number(row.end_offset);
    if (
      !Number.isSafeInteger(startOffset) ||
      !Number.isSafeInteger(endOffset) ||
      startOffset < 0 ||
      endOffset < startOffset ||
      endOffset > topicContent.length ||
      topicContent.slice(startOffset, endOffset).trimEnd() !== String(row.section_content)
    ) {
      throw new Error(`Section UTF-16 offset validation failed for ${row.section_id}.`);
    }
  }

  const invalidOccurrenceCount = Number(databaseScalar(database, `
    SELECT count(*) AS count
    FROM topic_assets AS occurrences
    JOIN topics ON topics.topic_id = occurrences.topic_id
    JOIN sections ON sections.section_id = occurrences.section_id
    WHERE sections.topic_id <> occurrences.topic_id
      OR occurrences.text_offset > topics.content_length
      OR occurrences.text_offset < sections.start_offset
      OR occurrences.text_offset > sections.end_offset
  `, "count"));
  if (invalidOccurrenceCount) {
    throw new Error(`Topic-asset association validation found ${invalidOccurrenceCount} failure(s).`);
  }

  const databaseAssets = database.prepare(`
    SELECT asset_id AS assetId, source, internal_path AS internalPath,
      path_sha256 AS pathSha256, storage_key AS storageKey, mime_type AS mimeType,
      sha256, byte_count AS byteCount, width, height, pixel_count AS pixelCount,
      exposure, exposure_reason AS exposureReason, canonical_caption AS canonicalCaption
    FROM assets ORDER BY asset_id
  `).all();
  for (const asset of databaseAssets) {
    if (!ASSET_ID_PATTERN.test(asset.assetId) || asset.assetId !== makeAssetId(asset.source, asset.internalPath)) {
      throw new Error(`Asset identifier validation failed for ${asset.assetId}.`);
    }
    if (asset.pathSha256 !== makeAssetPathDigest(asset.internalPath)) {
      throw new Error(`Asset path digest validation failed for ${asset.assetId}.`);
    }
    if (asset.storageKey !== `assets/${asset.source}/${asset.pathSha256}.bin`) {
      throw new Error(`Asset storage-key validation failed for ${asset.assetId}.`);
    }
  }
  if (computeAssetCatalogSha256(databaseAssets) !== expectedAssetCatalogSha256) {
    throw new Error("Asset catalog digest validation failed.");
  }

  database.exec("INSERT INTO search_fts(search_fts) VALUES('integrity-check')");
}

async function acquireBuildLock(lockPath) {
  try {
    const handle = await open(lockPath, "wx", 0o600);
    await handle.writeFile(`${JSON.stringify({ pid: process.pid, started_at: new Date().toISOString() })}\n`);
    await handle.sync();
    return handle;
  } catch (error) {
    if (error?.code === "EEXIST") {
      throw new Error(`Another index build may be active (lock exists): ${lockPath}`);
    }
    throw error;
  }
}

async function writeDurableJson(filePath, value) {
  await writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, { encoding: "utf8", flag: "wx" });
  // Windows requires a writable handle for FlushFileBuffers/fsync.
  const handle = await open(filePath, "r+");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function replaceBuildArtifacts(
  tempDatabasePath,
  databasePath,
  tempManifestPath,
  manifestPath,
  tempAssetsPath,
  assetsPath,
) {
  const nonce = `${process.pid}-${randomUUID()}`;
  const items = [
    { temporary: tempDatabasePath, target: databasePath, backup: `${databasePath}.backup-${nonce}` },
    { temporary: tempManifestPath, target: manifestPath, backup: `${manifestPath}.backup-${nonce}` },
    { temporary: tempAssetsPath, target: assetsPath, backup: `${assetsPath}.backup-${nonce}` },
  ];
  const backedUp = [];
  const installed = [];

  try {
    for (const item of items) {
      if (await pathExists(item.target)) {
        await rename(item.target, item.backup);
        backedUp.push(item);
      }
    }
    for (const item of items) {
      await rename(item.temporary, item.target);
      installed.push(item);
    }
  } catch (error) {
    for (const item of installed.reverse()) {
      await rm(item.target, { force: true, recursive: true }).catch(() => {});
    }
    for (const item of backedUp.reverse()) {
      await rename(item.backup, item.target).catch(() => {});
    }
    throw error;
  }

  for (const item of backedUp) await rm(item.backup, { force: true, recursive: true });
}

function requireIsoTimestamp(value, label) {
  const text = String(value ?? "");
  const parsed = Date.parse(text);
  if (
    !text ||
    text.length > 64 ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/u.test(text) ||
    Number.isNaN(parsed)
  ) {
    throw new Error(`${label} must be an ISO-8601 timestamp with an explicit timezone.`);
  }
  return new Date(parsed).toISOString();
}

function optionalBoundedString(value, label, maximumLength = 1_000) {
  if (value === null || value === undefined || value === "") return null;
  const text = String(value);
  if (text.length > maximumLength || /[\u0000-\u001f\u007f]/u.test(text)) {
    throw new Error(`${label} is invalid or exceeds ${maximumLength} characters.`);
  }
  return text;
}

async function loadImagePolicy(imagePolicyPath) {
  let raw;
  let policy;
  try {
    raw = await readFile(imagePolicyPath);
    policy = JSON.parse(raw.toString("utf8"));
  } catch (error) {
    throw new Error(`Unable to read image policy ${imagePolicyPath}: ${error.message}`);
  }
  if (policy?.schema_version !== 1 || policy?.policy_id !== "mql5-chm-technical-images-v1") {
    throw new Error("Unsupported MQL5 image-policy schema or policy ID.");
  }
  if (!Array.isArray(policy.catalog_extensions) || !Array.isArray(policy.public_mime_types)) {
    throw new Error("Image policy must declare catalog extensions and public MIME types.");
  }
  const catalogExtensions = new Set(policy.catalog_extensions.map((value) => String(value).toLowerCase()));
  const publicMimeTypes = new Set(policy.public_mime_types.map(String));
  for (const required of [".png", ".jpg", ".jpeg", ".gif"]) {
    if (!catalogExtensions.has(required)) throw new Error(`Image policy is missing catalog extension ${required}.`);
  }
  for (const required of ["image/png", "image/jpeg"]) {
    if (!publicMimeTypes.has(required)) throw new Error(`Image policy is missing public MIME type ${required}.`);
  }
  const limits = policy.limits ?? {};
  for (const [key, minimum, maximum] of [
    ["max_bytes", 1, 2 * 1024 * 1024],
    ["max_dimension", 1, 4096],
    ["max_pixels", 1, 4_194_304],
    ["max_caption_chars", 1, 500],
  ]) {
    const value = Number(limits[key]);
    if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
      throw new Error(`Image policy ${key} must be an integer between ${minimum} and ${maximum}.`);
    }
  }
  const denylist = new Map();
  if (!Array.isArray(policy.denylist)) throw new Error("Image policy denylist must be an array.");
  for (const entry of policy.denylist) {
    const source = String(entry?.source ?? "");
    if (!SOURCE_IDS.includes(source)) throw new Error(`Invalid image-policy source: ${source}`);
    const internalPath = normalizeInternalPath(entry?.path).toLowerCase();
    const reason = optionalBoundedString(entry?.reason, "Image-policy denial reason", 100);
    if (!internalPath || !reason) throw new Error("Image-policy denylist entries require path and reason.");
    const key = `${source}\u0000${internalPath}`;
    if (denylist.has(key)) throw new Error(`Duplicate image-policy denylist entry: ${source}/${internalPath}`);
    denylist.set(key, reason);
  }
  const selectors = policy.presentation_ancestor_selectors ?? [];
  const meaningless = policy.meaningless_captions ?? [];
  if (!Array.isArray(selectors) || !selectors.every((value) => typeof value === "string" && value.length <= 100)) {
    throw new Error("Image-policy presentation selectors are invalid.");
  }
  if (!Array.isArray(meaningless) || !meaningless.every((value) => typeof value === "string" && value.length <= 100)) {
    throw new Error("Image-policy meaningless-caption list is invalid.");
  }
  const integrityExceptions = new Map();
  if (!Array.isArray(policy.integrity_exceptions ?? [])) {
    throw new Error("Image-policy integrity exceptions must be an array.");
  }
  for (const entry of policy.integrity_exceptions ?? []) {
    const source = String(entry?.source ?? "");
    if (!SOURCE_IDS.includes(source)) throw new Error(`Invalid integrity-exception source: ${source}`);
    const internalPath = normalizeInternalPath(entry?.path).toLowerCase();
    const sha256 = String(entry?.sha256 ?? "").toLowerCase();
    const byteCount = Number(entry?.bytes);
    const validPngPrefixBytes = Number(entry?.valid_png_prefix_bytes);
    const reason = optionalBoundedString(entry?.reason, "Image integrity-exception reason", 100);
    if (
      !internalPath || path.posix.extname(internalPath) !== ".png" || !/^[0-9a-f]{64}$/u.test(sha256) ||
      !Number.isSafeInteger(byteCount) || byteCount < 1 || byteCount > limits.max_bytes ||
      !Number.isSafeInteger(validPngPrefixBytes) || validPngPrefixBytes < 33 || validPngPrefixBytes >= byteCount || !reason
    ) throw new Error("Invalid image-policy integrity exception.");
    const key = `${source}\u0000${internalPath}`;
    if (integrityExceptions.has(key)) throw new Error(`Duplicate integrity exception: ${source}/${internalPath}`);
    integrityExceptions.set(key, {
      source,
      internalPath,
      sha256,
      bytes: byteCount,
      validPngPrefixBytes,
      reason,
    });
  }
  return {
    policy,
    sha256: createHash("sha256").update(raw).digest("hex"),
    catalogExtensions,
    publicMimeTypes,
    denylist,
    integrityExceptions,
  };
}

function chooseCanonicalCaption(asset) {
  const sourceRank = new Map([
    ["figcaption", 0],
    ["title", 1],
    ["alt", 2],
    ["nearby", 3],
    ["filename", 4],
  ]);
  const candidates = asset.occurrences.map((occurrence) => ({
    caption: occurrence.contextualCaption,
    source: occurrence.captionSource,
    rank: sourceRank.get(occurrence.captionSource) ?? 99,
    topicId: occurrence.topicId,
    ordinal: occurrence.occurrenceOrdinal,
  }));
  if (!candidates.length) return filenameCaption(asset.internalPath, 500);
  candidates.sort((left, right) =>
    left.rank - right.rank ||
    compareOrdinal(normalizeText(left.caption), normalizeText(right.caption)) ||
    compareOrdinal(left.caption, right.caption) ||
    compareOrdinal(left.topicId, right.topicId) ||
    left.ordinal - right.ordinal,
  );
  return candidates[0].caption;
}

export function computeAssetTreeSha256(assets) {
  const hash = createHash("sha256");
  const sorted = [...assets].sort((left, right) => compareOrdinal(left.storageKey, right.storageKey));
  for (const asset of sorted) {
    hash.update(`${asset.storageKey}\u0000${asset.sha256}\u0000${asset.byteCount}\u0000`, "utf8");
  }
  return hash.digest("hex");
}

export function computeAssetCatalogSha256(assets) {
  const rows = [...assets]
    .sort((left, right) => compareOrdinal(left.assetId, right.assetId))
    .map((asset) => [
      asset.assetId,
      asset.source,
      asset.internalPath,
      asset.pathSha256,
      asset.storageKey,
      asset.mimeType,
      asset.sha256,
      asset.byteCount,
      asset.width,
      asset.height,
      asset.pixelCount,
      asset.exposure,
      asset.exposureReason,
      asset.canonicalCaption,
    ]);
  return createHash("sha256").update(JSON.stringify(rows), "utf8").digest("hex");
}

export function assertAssetIdentityAvailable(byPath, byId, identity) {
  const { source, internalPath, pathSha256, assetId } = identity;
  const pathKey = identity.pathKey ?? `${source}\u0000${normalizeInternalPath(internalPath).toLowerCase()}`;
  if (byPath.has(pathKey)) throw new Error(`Case-folded asset path collision: ${source}/${internalPath}`);
  const existingId = byId.get(assetId);
  if (existingId && existingId.pathSha256 !== pathSha256) throw new Error(`Truncated asset-ID collision: ${assetId}`);
  const registered = { source, internalPath, pathSha256, assetId };
  byPath.set(pathKey, registered);
  byId.set(assetId, registered);
  return registered;
}

async function catalogAssets(sources, imagePolicy) {
  const assets = [];
  const byPath = new Map();
  const byId = new Map();
  for (const source of sources) {
    const files = await enumerateFiles(source.extractedDirectory, (filePath) =>
      imagePolicy.catalogExtensions.has(path.extname(filePath).toLowerCase()),
    );
    for (const filePath of files) {
      const internalPath = normalizeInternalPath(path.relative(source.extractedDirectory, filePath));
      const foldedPath = internalPath.toLowerCase();
      const pathKey = `${source.source}\u0000${foldedPath}`;
      const pathSha256 = makeAssetPathDigest(internalPath);
      const assetId = makeAssetId(source.source, internalPath);
      assertAssetIdentityAvailable(byPath, byId, { source: source.source, internalPath, pathKey, pathSha256, assetId });
      const bytes = await readFile(filePath);
      const assetSha256 = createHash("sha256").update(bytes).digest("hex");
      const integrityException = imagePolicy.integrityExceptions.get(pathKey) ?? null;
      if (integrityException && integrityException.sha256 !== assetSha256) {
        throw new Error(`Image integrity exception hash mismatch: ${source.source}/${internalPath}`);
      }
      let inspected;
      try {
        inspected = integrityException
          ? inspectPolicyPinnedPngException(
              bytes,
              source.source,
              internalPath,
              imagePolicy.policy.limits,
              integrityException,
            )
          : inspectRasterAsset(bytes, internalPath, imagePolicy.policy.limits);
      } catch (error) {
        throw new Error(`Invalid raster asset ${source.source}/${internalPath}: ${error.message}`);
      }
      const deniedReason = imagePolicy.denylist.get(pathKey) ?? null;
      const asset = {
        assetId,
        source: source.source,
        internalPath,
        pathSha256,
        storageKey: `assets/${source.source}/${pathSha256}.bin`,
        mimeType: inspected.mimeType,
        sha256: assetSha256,
        byteCount: inspected.byteCount,
        width: inspected.width,
        height: inspected.height,
        pixelCount: inspected.pixelCount,
        deniedReason,
        integrityExceptionReason: integrityException?.reason ?? null,
        bytes,
        occurrences: [],
        exposure: "excluded",
        exposureReason: deniedReason ? `denylist:${deniedReason}` : "not-referenced-in-help",
        canonicalCaption: "",
      };
      assets.push(asset);
      byPath.set(pathKey, asset);
      byId.set(assetId, asset);
    }
  }
  return { assets, byPath };
}

async function externalizeAssets(assets, temporaryAssetsDirectory) {
  for (const asset of [...assets].sort((left, right) => compareOrdinal(left.storageKey, right.storageKey))) {
    const relative = asset.storageKey.split("/").slice(1);
    const target = path.join(temporaryAssetsDirectory, ...relative);
    assertPathWithin(temporaryAssetsDirectory, target, "Asset storage path");
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, asset.bytes, { flag: "wx" });
  }
  const files = await enumerateFiles(temporaryAssetsDirectory);
  if (files.length !== assets.length) {
    throw new Error(`External asset closure mismatch: expected ${assets.length} files, got ${files.length}.`);
  }
  const expectedByRelativePath = new Map(assets.map((asset) => [
    asset.storageKey.slice("assets/".length).toLowerCase(),
    asset,
  ]));
  for (const filePath of files) {
    const relativePath = normalizeInternalPath(path.relative(temporaryAssetsDirectory, filePath));
    const asset = expectedByRelativePath.get(relativePath.toLowerCase());
    if (!asset) throw new Error(`Unexpected external asset file: ${relativePath}`);
    const info = await stat(filePath);
    const digest = await sha256File(filePath);
    if (info.size !== asset.byteCount || digest !== asset.sha256) {
      throw new Error(`External asset integrity check failed: ${relativePath}`);
    }
  }
}

async function loadSourceDefinitions(corpusLockPath) {
  let lock;
  try {
    lock = JSON.parse(await readFile(corpusLockPath, "utf8"));
  } catch (error) {
    throw new Error(`Unable to read corpus lock ${corpusLockPath}: ${error.message}`);
  }
  if (!Array.isArray(lock.sources) || lock.sources.length !== SOURCE_IDS.length) {
    throw new Error(`Corpus lock must declare exactly ${SOURCE_IDS.length} sources.`);
  }

  const entries = new Map(lock.sources.map((entry) => [String(entry?.id ?? ""), entry]));
  const definitions = SOURCE_DEFINITIONS.map((baseline) => {
    const entry = entries.get(baseline.source);
    if (!entry) throw new Error(`Corpus lock is missing source ${baseline.source}.`);
    if (entry.filename !== baseline.filename) {
      throw new Error(`Corpus lock filename for ${baseline.source} must be ${baseline.filename}.`);
    }
    const sha256 = String(entry.sha256 ?? "").toLowerCase();
    const topicCount = Number(entry.expected_topics);
    if (!/^[0-9a-f]{64}$/u.test(sha256)) throw new Error(`Invalid SHA-256 for ${baseline.source}.`);
    if (!Number.isSafeInteger(topicCount) || topicCount < 1) {
      throw new Error(`Invalid expected_topics for ${baseline.source}.`);
    }
    const declaredBytes = entry.bytes === undefined ? null : Number(entry.bytes);
    if (declaredBytes !== null && (!Number.isSafeInteger(declaredBytes) || declaredBytes < 1)) {
      throw new Error(`Invalid bytes for ${baseline.source}.`);
    }
    return {
      ...baseline,
      sha256,
      topicCount,
      declaredBytes,
      httpLastModified: optionalBoundedString(entry.http_last_modified, `${baseline.source} HTTP Last-Modified`),
      httpEtag: optionalBoundedString(entry.http_etag, `${baseline.source} HTTP ETag`),
      retrievedAt: entry.retrieved_at ? requireIsoTimestamp(entry.retrieved_at, `${baseline.source} retrieved_at`) : null,
    };
  });
  if (entries.size !== definitions.length) throw new Error("Corpus lock contains an unknown or duplicate source ID.");

  const expectedTotal = definitions.reduce((total, definition) => total + definition.topicCount, 0);
  if (lock.expected_total_topics !== undefined && Number(lock.expected_total_topics) !== expectedTotal) {
    throw new Error(`Corpus lock total mismatch: expected ${expectedTotal}, got ${lock.expected_total_topics}.`);
  }
  return definitions;
}

async function preflightSources(workspaceRoot, {
  sourceDirectory,
  extractedRoot,
  definitions,
  defaultRetrievedAt,
  sourceMetadata = {},
}) {
  const prepared = [];
  for (const definition of definitions) {
    const chmPath = path.join(sourceDirectory, definition.filename);
    const extractedDirectory = path.join(extractedRoot, definition.extractedDirectory);
    assertPathWithin(workspaceRoot, chmPath, "CHM path", "maintenance workspace root");
    assertPathWithin(workspaceRoot, extractedDirectory, "Extracted CHM directory", "maintenance workspace root");

    const chmInfo = await lstat(chmPath).catch(() => null);
    if (!chmInfo?.isFile()) throw new Error(`Required CHM is missing: ${chmPath}`);
    const extractedInfo = await lstat(extractedDirectory).catch(() => null);
    if (!extractedInfo?.isDirectory()) {
      throw new Error(`Extracted CHM directory is missing: ${extractedDirectory}`);
    }

    const actualHash = await sha256File(chmPath);
    if (actualHash !== definition.sha256) {
      throw new Error(
        `${definition.filename} SHA-256 mismatch: expected ${definition.sha256}, got ${actualHash}.`,
      );
    }
    if (definition.declaredBytes !== null && definition.declaredBytes !== chmInfo.size) {
      throw new Error(
        `${definition.filename} byte-size mismatch: expected ${definition.declaredBytes}, got ${chmInfo.size}.`,
      );
    }

    const htmlFiles = await enumerateFiles(extractedDirectory, (filePath) => /\.(?:html?|HTML?)$/i.test(filePath));
    if (htmlFiles.length !== definition.topicCount) {
      throw new Error(
        `${definition.source} topic count mismatch: expected ${definition.topicCount}, got ${htmlFiles.length}.`,
      );
    }
    const metadata = sourceMetadata?.[definition.source] ?? {};
    const retrievedAt = requireIsoTimestamp(
      metadata.retrieved_at ?? definition.retrievedAt ?? defaultRetrievedAt,
      `${definition.source} retrieved_at`,
    );
    prepared.push({
      ...definition,
      chmPath,
      extractedDirectory,
      htmlFiles,
      actualHash,
      bytes: chmInfo.size,
      httpLastModified: optionalBoundedString(
        metadata.http_last_modified ?? definition.httpLastModified,
        `${definition.source} HTTP Last-Modified`,
      ),
      httpEtag: optionalBoundedString(metadata.http_etag ?? definition.httpEtag, `${definition.source} HTTP ETag`),
      retrievedAt,
    });
  }
  return prepared;
}

function parseCliArguments(argv) {
  const values = {
    root: "",
    workspaceRoot: "",
    sourceDirectory: "",
    extractedDirectory: "",
    outputDirectory: "",
    corpusLockPath: "",
    sourceMetadataPath: "",
    imagePolicyPath: "",
  };
  const switches = new Map([
    ["--root", "root"],
    ["--workspace-root", "workspaceRoot"],
    ["--source-directory", "sourceDirectory"],
    ["--extracted-directory", "extractedDirectory"],
    ["--output-directory", "outputDirectory"],
    ["--corpus-lock", "corpusLockPath"],
    ["--source-metadata", "sourceMetadataPath"],
    ["--image-policy", "imagePolicyPath"],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const key = switches.get(argument);
    if (key) {
      if (values[key] || index + 1 >= argv.length) {
        throw new Error(`${argument} must be provided at most once with a value.`);
      }
      values[key] = argv[index + 1];
      index += 1;
    } else if (argument === "--help" || argument === "-h") {
      return { help: true, root: "" };
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  if (!values.root) throw new Error("Usage: node src/indexer.mjs --root <projectRoot> [path options]");
  return { help: false, ...values };
}

export async function buildIndex(projectRootInput, options = {}) {
  const projectRoot = path.resolve(String(projectRootInput ?? ""));
  await assertRealDirectory(projectRoot, "Project root");

  const workspaceRoot = options.workspaceRoot
    ? path.resolve(projectRoot, options.workspaceRoot)
    : projectRoot;
  await assertRealDirectory(workspaceRoot, "Maintenance workspace root");

  const sourceDirectory = options.sourceDirectory ? path.resolve(workspaceRoot, options.sourceDirectory) : workspaceRoot;
  const extractedRoot = options.extractedDirectory
    ? path.resolve(workspaceRoot, options.extractedDirectory)
    : path.join(workspaceRoot, "build", "extracted");
  const outputDirectory = options.outputDirectory
    ? path.resolve(workspaceRoot, options.outputDirectory)
    : path.join(workspaceRoot, "build", "index-candidate");
  const corpusLockPath = options.corpusLockPath
    ? path.resolve(workspaceRoot, options.corpusLockPath)
    : path.join(workspaceRoot, "corpus.lock.json");
  const sourceMetadataPath = options.sourceMetadataPath
    ? path.resolve(workspaceRoot, options.sourceMetadataPath)
    : "";
  const imagePolicyPath = options.imagePolicyPath
    ? path.resolve(projectRoot, options.imagePolicyPath)
    : path.join(projectRoot, DEFAULT_IMAGE_POLICY_RELATIVE_PATH);
  const databasePath = path.join(outputDirectory, "mql5-docs.sqlite");
  const manifestPath = path.join(outputDirectory, "manifest.json");
  const assetsPath = path.join(outputDirectory, "assets");
  assertPathWithin(workspaceRoot, sourceDirectory, "Source directory", "maintenance workspace root");
  assertPathWithin(workspaceRoot, extractedRoot, "Extracted directory", "maintenance workspace root");
  assertPathWithin(workspaceRoot, outputDirectory, "Output directory", "maintenance workspace root");
  assertPathWithin(workspaceRoot, corpusLockPath, "Corpus lock path", "maintenance workspace root");
  if (sourceMetadataPath) assertPathWithin(workspaceRoot, sourceMetadataPath, "Source metadata path", "maintenance workspace root");
  assertPathWithin(projectRoot, imagePolicyPath, "Image policy path");
  assertPathWithin(workspaceRoot, databasePath, "Database path", "maintenance workspace root");
  assertPathWithin(workspaceRoot, manifestPath, "Manifest path", "maintenance workspace root");
  assertPathWithin(workspaceRoot, assetsPath, "Assets path", "maintenance workspace root");
  assertSafeOutputLocation(projectRoot, sourceDirectory, extractedRoot, outputDirectory);
  await assertNoLinkTraversal(workspaceRoot, sourceDirectory, "Source directory", "maintenance workspace root");
  await assertNoLinkTraversal(workspaceRoot, extractedRoot, "Extracted directory", "maintenance workspace root");
  await assertNoLinkTraversal(workspaceRoot, outputDirectory, "Output directory", "maintenance workspace root");
  await assertNoLinkTraversal(workspaceRoot, corpusLockPath, "Corpus lock path", "maintenance workspace root");
  if (sourceMetadataPath) await assertNoLinkTraversal(workspaceRoot, sourceMetadataPath, "Source metadata path", "maintenance workspace root");
  await assertNoLinkTraversal(projectRoot, imagePolicyPath, "Image policy path");
  await assertRealDirectory(sourceDirectory, "Source directory");
  await assertRealDirectory(extractedRoot, "Extracted directory");
  await assertRealFile(corpusLockPath, "Corpus lock");
  if (sourceMetadataPath) await assertRealFile(sourceMetadataPath, "Source metadata");
  await assertRealFile(imagePolicyPath, "Image policy");
  const definitions = await loadSourceDefinitions(corpusLockPath);
  await assertPreparedOutputDirectory(outputDirectory, definitions.map((definition) => definition.filename));
  await mkdir(outputDirectory, { recursive: true });
  await assertNoLinkTraversal(workspaceRoot, outputDirectory, "Output directory", "maintenance workspace root");
  await assertRealDirectory(outputDirectory, "Output directory");

  const lockPath = path.join(outputDirectory, ".index-build.lock");
  const lockHandle = await acquireBuildLock(lockPath);
  const nonce = `${process.pid}-${randomUUID()}`;
  const tempDatabasePath = path.join(outputDirectory, `.mql5-docs.sqlite.tmp-${nonce}`);
  const tempManifestPath = path.join(outputDirectory, `.manifest.json.tmp-${nonce}`);
  const tempAssetsPath = path.join(outputDirectory, `.assets.tmp-${nonce}`);
  let database;

  try {
    const buildTimestamp = new Date().toISOString();
    const imagePolicy = await loadImagePolicy(imagePolicyPath);
    let sourceMetadata = options.sourceMetadata ?? {};
    if (sourceMetadataPath) {
      try {
        sourceMetadata = JSON.parse(await readFile(sourceMetadataPath, "utf8"));
      } catch (error) {
        throw new Error(`Unable to read source metadata ${sourceMetadataPath}: ${error.message}`);
      }
    }
    if (!sourceMetadata || Array.isArray(sourceMetadata) || typeof sourceMetadata !== "object") {
      throw new Error("Source metadata must be an object keyed by source ID.");
    }
    const sources = await preflightSources(workspaceRoot, {
      sourceDirectory,
      extractedRoot,
      definitions,
      defaultRetrievedAt: buildTimestamp,
      sourceMetadata,
    });
    const expectedTotalTopics = definitions.reduce((total, definition) => total + definition.topicCount, 0);
    const corpusSha256 = computeCorpusRevision(sources);
    const assetCatalog = await catalogAssets(sources, imagePolicy);
    await mkdir(tempAssetsPath, { recursive: false });

    database = new DatabaseSync(tempDatabasePath, {
      open: true,
      readOnly: false,
      allowExtension: false,
      enableForeignKeyConstraints: true,
      timeout: 10_000,
    });
    database.enableLoadExtension(false);
    createSchema(database);
    const statements = prepareStatements(database);
    let totalTopics = 0;
    let totalSections = 0;
    let totalLinks = 0;
    let resolvedLinks = 0;
    const sourceSectionCounts = new Map();
    const topicIdsByPath = new Map();
    const pendingLinks = [];
    const pendingTopicAssets = [];

    database.exec("BEGIN IMMEDIATE");
    try {
      for (const source of sources) {
        statements.insertSource.run(
          source.source,
          source.filename,
          source.actualHash,
          source.bytes,
          source.topicCount,
        );
        const auxiliaryMap = await loadAuxiliaryMap(source.extractedDirectory);
        let sourceTopics = 0;
        let sourceSections = 0;

        for (const htmlPath of source.htmlFiles) {
          const internalPath = normalizeInternalPath(path.relative(source.extractedDirectory, htmlPath));
          const auxiliaryEntry = auxiliaryMap.get(internalPath.toLowerCase());
          const decoded = decodeHtml(await readFile(htmlPath));
          const topic = parseHtmlTopic(decoded, {
            source: source.source,
            internalPath,
            auxiliaryEntry,
            imagePolicy: imagePolicy.policy,
          });
          const topicId = makeTopicId(source.source, internalPath);
          topicIdsByPath.set(`${source.source}\u0000${topic.internalPath.toLowerCase()}`, topicId);
          const aliasText = topic.aliasRecords.map((entry) => entry.alias).join(" | ");

          statements.insertTopic.run(
            topicId,
            topic.source,
            topic.internalPath,
            topic.title,
            topic.normalizedTitle,
            topic.breadcrumb,
            topic.signature,
            topic.contentSha256,
            topic.content,
            topic.contentLength,
          );
          for (const alias of topic.aliasRecords) {
            statements.insertAlias.run(alias.alias, alias.normalizedAlias, topicId, alias.sourceKind);
          }
          for (const section of topic.sections) {
            const sectionId = makeSectionId(topicId, section.ordinal);
            statements.insertSection.run(
              sectionId,
              topicId,
              section.ordinal,
              section.heading,
              section.startOffset,
              section.endOffset,
              section.content,
            );
            statements.insertFts.run(
              topicId,
              sectionId,
              topic.source,
              topic.title,
              aliasText,
              section.heading,
              topic.breadcrumb,
              section.content,
            );
            totalSections += 1;
            sourceSections += 1;
          }

          for (const link of topic.links) pendingLinks.push({ ...link, source: source.source, sourceTopicId: topicId });
          for (const reference of topic.imageReferences) {
            if (!reference.internalPath) {
              throw new Error(
                `Unsafe or external in-help image reference in ${source.source}/${internalPath}: ${reference.rawReference}`,
              );
            }
            const asset = assetCatalog.byPath.get(`${source.source}\u0000${reference.internalPath.toLowerCase()}`);
            if (!asset) {
              throw new Error(
                `Missing or unsupported in-help image in ${source.source}/${internalPath}: ${reference.internalPath}`,
              );
            }
            const occurrence = {
              ...reference,
              topicId,
              assetId: asset.assetId,
              sectionId: makeSectionId(topicId, reference.sectionOrdinal),
            };
            asset.occurrences.push(occurrence);
            if (!reference.presentationOnly && !asset.deniedReason) asset.hasTechnicalOccurrence = true;
            pendingTopicAssets.push(occurrence);
          }
          sourceTopics += 1;
          totalTopics += 1;
        }

        if (sourceTopics !== source.topicCount) {
          throw new Error(
            `${source.source} indexed topic mismatch: expected ${source.topicCount}, got ${sourceTopics}.`,
          );
        }
        statements.updateSourceSectionCount.run(sourceSections, source.source);
        sourceSectionCounts.set(source.source, sourceSections);
      }

      if (totalTopics !== expectedTotalTopics) {
        throw new Error(
          `Indexed corpus count mismatch: expected ${expectedTotalTopics}, got ${totalTopics}.`,
        );
      }

      for (const link of pendingLinks) {
        const targetTopicId = topicIdsByPath.get(`${link.source}\u0000${link.targetInternalPath.toLowerCase()}`) ?? null;
        const resolutionStatus = targetTopicId ? "resolved" : "unresolved";
        statements.insertTopicLink.run(
          link.sourceTopicId,
          link.ordinal,
          targetTopicId,
          link.targetInternalPath,
          link.targetFragment,
          link.label,
          link.relationship,
          resolutionStatus,
        );
        totalLinks += 1;
        if (targetTopicId) resolvedLinks += 1;
      }

      for (const asset of assetCatalog.assets) {
        if (asset.deniedReason) {
          asset.exposure = "excluded";
          asset.exposureReason = `denylist:${asset.deniedReason}`;
        } else if (asset.hasTechnicalOccurrence) {
          if (!imagePolicy.publicMimeTypes.has(asset.mimeType)) {
            throw new Error(
              `Unsupported technical image MIME ${asset.mimeType} for ${asset.source}/${asset.internalPath}.`,
            );
          }
          asset.exposure = "exposed";
          asset.exposureReason = asset.integrityExceptionReason
            ? `technical-in-help:${asset.integrityExceptionReason}`
            : "technical-in-help";
        } else if (asset.occurrences.length) {
          asset.exposure = "excluded";
          asset.exposureReason = "presentation-only";
        } else {
          asset.exposure = "excluded";
          asset.exposureReason = "not-referenced-in-help";
        }
        asset.canonicalCaption = chooseCanonicalCaption(asset);
      }

      assetCatalog.assets.sort((left, right) => compareOrdinal(left.assetId, right.assetId));
      for (const asset of assetCatalog.assets) {
        statements.insertAsset.run(
          asset.assetId,
          asset.source,
          asset.internalPath,
          asset.pathSha256,
          asset.storageKey,
          asset.mimeType,
          asset.sha256,
          asset.byteCount,
          asset.width,
          asset.height,
          asset.pixelCount,
          asset.exposure,
          asset.exposureReason,
          asset.canonicalCaption,
        );
      }
      pendingTopicAssets.sort((left, right) =>
        compareOrdinal(left.topicId, right.topicId) || left.occurrenceOrdinal - right.occurrenceOrdinal,
      );
      for (const occurrence of pendingTopicAssets) {
        statements.insertTopicAsset.run(
          occurrence.topicId,
          occurrence.occurrenceOrdinal,
          occurrence.assetId,
          occurrence.sectionId,
          occurrence.textOffset,
          occurrence.figcaptionText,
          occurrence.titleText,
          occurrence.altText,
          occurrence.nearbyText,
          occurrence.contextualCaption,
          occurrence.captionSource,
        );
      }

      const assetTreeSha256 = computeAssetTreeSha256(assetCatalog.assets);
      const assetCatalogSha256 = computeAssetCatalogSha256(assetCatalog.assets);
      const exposedAssets = assetCatalog.assets.filter((asset) => asset.exposure === "exposed");
      const exposedAssetIds = new Set(exposedAssets.map((asset) => asset.assetId));
      const exposedOccurrenceCount = pendingTopicAssets.filter((occurrence) =>
        exposedAssetIds.has(occurrence.assetId),
      ).length;
      const assetTotalBytes = assetCatalog.assets.reduce((total, asset) => total + asset.byteCount, 0);

      const metadata = new Map([
        ["schema_version", String(SCHEMA_VERSION)],
        ["index_contract", INDEX_CONTRACT],
        ["corpus_sha256", corpusSha256],
        ["image_policy_sha256", imagePolicy.sha256],
        ["asset_catalog_sha256", assetCatalogSha256],
        ["asset_tree_sha256", assetTreeSha256],
        ["total_topic_count", String(totalTopics)],
        ["total_section_count", String(totalSections)],
        ["topic_link_count", String(totalLinks)],
        ["resolved_topic_link_count", String(resolvedLinks)],
        ["unresolved_topic_link_count", String(totalLinks - resolvedLinks)],
        ["asset_count", String(assetCatalog.assets.length)],
        ["exposed_asset_count", String(exposedAssets.length)],
        ["excluded_asset_count", String(assetCatalog.assets.length - exposedAssets.length)],
        ["topic_asset_count", String(pendingTopicAssets.length)],
        ["exposed_topic_asset_count", String(exposedOccurrenceCount)],
        ["asset_total_bytes", String(assetTotalBytes)],
      ]);
      for (const [key, value] of metadata) statements.insertMetadata.run(key, value);
      await externalizeAssets(assetCatalog.assets, tempAssetsPath);
      database.exec("COMMIT");

      database.exec("INSERT INTO search_fts(search_fts) VALUES('optimize')");
      database.exec("VACUUM");
      validateDatabase(database, {
        expectedTopicCount: expectedTotalTopics,
        expectedSectionCount: totalSections,
        expectedLinkCount: totalLinks,
        expectedResolvedLinkCount: resolvedLinks,
        expectedSources: sources,
        expectedAssets: assetCatalog.assets,
        expectedOccurrenceCount: pendingTopicAssets.length,
        expectedAssetCatalogSha256: assetCatalogSha256,
      });
      database.close();
      database = undefined;

      const databaseSha256 = await sha256File(tempDatabasePath);
      const databaseInfo = await stat(tempDatabasePath);
      const assetStatsBySource = Object.fromEntries(SOURCE_IDS.map((sourceId) => {
        const sourceAssets = assetCatalog.assets.filter((asset) => asset.source === sourceId);
        const sourceExposedIds = new Set(
          sourceAssets.filter((asset) => asset.exposure === "exposed").map((asset) => asset.assetId),
        );
        const sourceOccurrences = pendingTopicAssets.filter((occurrence) => occurrence.topicId.startsWith(`${sourceId}:`));
        return [sourceId, {
          cataloged_count: sourceAssets.length,
          exposed_count: sourceExposedIds.size,
          excluded_count: sourceAssets.length - sourceExposedIds.size,
          occurrence_count: sourceOccurrences.length,
          exposed_occurrence_count: sourceOccurrences.filter((occurrence) =>
            sourceExposedIds.has(occurrence.assetId),
          ).length,
          total_bytes: sourceAssets.reduce((total, asset) => total + asset.byteCount, 0),
        }];
      }));
      const manifest = {
        schema_version: SCHEMA_VERSION,
        index_contract: INDEX_CONTRACT,
        index_revision: databaseSha256,
        corpus_revision: corpusSha256,
        corpus_sha256: corpusSha256,
        database: {
          filename: "mql5-docs.sqlite",
          sha256: databaseSha256,
          bytes: databaseInfo.size,
        },
        sources: Object.fromEntries(
          sources.map((source) => [
            source.source,
            {
              filename: source.filename,
              sha256: source.actualHash,
              bytes: source.bytes,
              http_last_modified: source.httpLastModified,
              http_etag: source.httpEtag,
              retrieved_at: source.retrievedAt,
              topic_count: source.topicCount,
              section_count: sourceSectionCounts.get(source.source),
              asset_count: assetStatsBySource[source.source].cataloged_count,
              exposed_asset_count: assetStatsBySource[source.source].exposed_count,
              excluded_asset_count: assetStatsBySource[source.source].excluded_count,
              topic_asset_count: assetStatsBySource[source.source].occurrence_count,
              exposed_topic_asset_count: assetStatsBySource[source.source].exposed_occurrence_count,
              asset_bytes: assetStatsBySource[source.source].total_bytes,
            },
          ]),
        ),
        total_topic_count: totalTopics,
        total_section_count: totalSections,
        topic_link_count: totalLinks,
        resolved_topic_link_count: resolvedLinks,
        unresolved_topic_link_count: totalLinks - resolvedLinks,
        assets: {
          directory: "assets",
          cataloged_count: assetCatalog.assets.length,
          exposed_count: exposedAssets.length,
          excluded_count: assetCatalog.assets.length - exposedAssets.length,
          occurrence_count: pendingTopicAssets.length,
          exposed_occurrence_count: exposedOccurrenceCount,
          total_bytes: assetTotalBytes,
          catalog_sha256: assetCatalogSha256,
          tree_sha256: assetTreeSha256,
          policy_sha256: imagePolicy.sha256,
          by_source: assetStatsBySource,
        },
        indexed_at: buildTimestamp,
        build_timestamp: buildTimestamp,
      };
      await writeDurableJson(tempManifestPath, manifest);

      // Verify the serialized manifest before replacing either production file.
      const serializedManifest = JSON.parse(await readFile(tempManifestPath, "utf8"));
      if (serializedManifest.database.sha256 !== databaseSha256) {
        throw new Error("Serialized manifest database hash verification failed.");
      }
      await replaceBuildArtifacts(
        tempDatabasePath,
        databasePath,
        tempManifestPath,
        manifestPath,
        tempAssetsPath,
        assetsPath,
      );

      return {
        databasePath,
        manifestPath,
        assetsPath,
        databaseSha256,
        indexRevision: databaseSha256,
        corpusSha256,
        totalTopics,
        totalSections,
        totalLinks,
        resolvedLinks,
        unresolvedLinks: totalLinks - resolvedLinks,
        assetCount: assetCatalog.assets.length,
        exposedAssetCount: exposedAssets.length,
        excludedAssetCount: assetCatalog.assets.length - exposedAssets.length,
        topicAssetCount: pendingTopicAssets.length,
        exposedTopicAssetCount: exposedOccurrenceCount,
        assetTotalBytes,
      };
    } catch (error) {
      try {
        database.exec("ROLLBACK");
      } catch {
        // A post-commit validation failure has no active transaction to roll back.
      }
      throw error;
    }
  } finally {
    if (database) {
      try {
        database.close();
      } catch {
        // Preserve the original build error.
      }
    }
    await rm(tempDatabasePath, { force: true }).catch(() => {});
    await rm(`${tempDatabasePath}-journal`, { force: true }).catch(() => {});
    await rm(`${tempDatabasePath}-wal`, { force: true }).catch(() => {});
    await rm(`${tempDatabasePath}-shm`, { force: true }).catch(() => {});
    await rm(tempManifestPath, { force: true }).catch(() => {});
    await rm(tempAssetsPath, { force: true, recursive: true }).catch(() => {});
    await lockHandle.close().catch(() => {});
    await unlink(lockPath).catch(() => {});
  }
}

export async function main(argv = process.argv.slice(2)) {
  const arguments_ = parseCliArguments(argv);
  if (arguments_.help) {
    process.stdout.write(
      "Usage: node src/indexer.mjs --root <projectRoot> [--source-directory <dir>] " +
        "[--workspace-root <dir>] [--extracted-directory <dir>] [--output-directory <dir>] [--corpus-lock <json>] " +
        "[--source-metadata <json>] [--image-policy <json>]\n",
    );
    return;
  }
  const result = await buildIndex(arguments_.root, {
    workspaceRoot: arguments_.workspaceRoot || undefined,
    sourceDirectory: arguments_.sourceDirectory || undefined,
    extractedDirectory: arguments_.extractedDirectory || undefined,
    outputDirectory: arguments_.outputDirectory || undefined,
    corpusLockPath: arguments_.corpusLockPath || undefined,
    sourceMetadataPath: arguments_.sourceMetadataPath || undefined,
    imagePolicyPath: arguments_.imagePolicyPath || undefined,
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (invokedPath && invokedPath === modulePath) {
  main().catch((error) => {
    process.stderr.write(`MQL5 CHM index build failed: ${error?.stack ?? error}\n`);
    process.exitCode = 1;
  });
}
