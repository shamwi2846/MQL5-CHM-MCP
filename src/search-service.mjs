import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import {
  closeSync,
  createReadStream,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  statSync
} from "node:fs";
import { dirname, extname, isAbsolute, parse, relative, resolve, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { crc32, inflateSync } from "node:zlib";
import { validatePngScanlines } from "./png-scanlines.mjs";
import { createPngTransparencyValidator } from "./png-transparency.mjs";
import { hasGifHeader, readPngChunkType } from "./raster-identifiers.mjs";
import expansionConfig from "../config/mql5-query-expansions.json" with { type: "json" };
import jpeg from "jpeg-js";
var MODULE_PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
var ACTIVE_RELATIVE_PATH = "data/active.json";
var UPDATE_STATUS_RELATIVE_PATH = "maintenance/update-status.json";
var DATABASE_FILENAME = "mql5-docs.sqlite";
var DATABASE_APPLICATION_ID = 1_297_173_557;
var LEGACY_SCHEMA_VERSION = 2;
var IMAGE_SCHEMA_VERSION = 3;
var LEGACY_INDEX_CONTRACT = "mql5-chm-index-v3-assets-v1";
var PREVIOUS_INDEX_CONTRACT = "mql5-chm-index-v3-assets-v2";
var PREVIOUS_HEADING_INDEX_CONTRACT = "mql5-chm-index-v3-assets-v3";
export const SUPPORTED_INDEX_CONTRACT = "mql5-chm-index-v3-assets-v4";
var ACCEPTED_INDEX_CONTRACTS = /* @__PURE__ */ new Set([
  LEGACY_INDEX_CONTRACT,
  PREVIOUS_INDEX_CONTRACT,
  PREVIOUS_HEADING_INDEX_CONTRACT,
  SUPPORTED_INDEX_CONTRACT
]);
var CURSOR_DOMAIN = "mql5-chm-read-cursor-v2\0";
var IMAGE_CURSOR_DOMAIN = "mql5-chm-image-cursor-v1\0";
var CURSOR_HMAC_KEY = randomBytes(32);
var TOPIC_ID_PATTERN = /^(mql5|mql5book|neuronetworksbook):[0-9a-f]{24}$/;
var SECTION_ID_PATTERN = /^(mql5|mql5book|neuronetworksbook):[0-9a-f]{24}:s\d{3}$/;
var ASSET_ID_PATTERN = /^(mql5|mql5book|neuronetworksbook):asset:[0-9a-f]{24}$/;
var ASSET_STORAGE_PATTERN = /^assets\/(mql5|mql5book|neuronetworksbook)\/([0-9a-f]{64})\.bin$/;
var EXPECTED_FTS_SCHEMA = "create virtual table search_fts using fts5(topic_id unindexed,section_id unindexed,source unindexed,title,aliases,heading,breadcrumb,body,tokenize='unicode61 remove_diacritics 2',prefix='2 3 4')";
var MAX_IMAGE_BYTES = 2 * 1024 * 1024;
var MAX_IMAGE_DIMENSION = 4096;
var MAX_IMAGE_PIXELS = 4194304;
var PINNED_TRAILING_PNG = Object.freeze({
  source: "neuronetworksbook",
  internalPath: "opencl_test.png",
  sha256: "04d0d664766a185021ab8aa26eb657fa58860a1113f5d4cb844ee674e5fee8f0",
  byteCount: 23807,
  pngPrefixBytes: 10372,
  exposureReason: "technical-in-help:official-png-trailing-data"
});
var SOURCES = Object.freeze({
  mql5: Object.freeze({
    filename: "mql5.chm",
    minimum_topic_count: 4134,
    online_scope: "site:mql5.com/en/docs"
  }),
  mql5book: Object.freeze({
    filename: "mql5book.chm",
    minimum_topic_count: 581,
    online_scope: "site:mql5.com/en/book"
  }),
  neuronetworksbook: Object.freeze({
    filename: "neuronetworksbook.chm",
    minimum_topic_count: 112,
    online_scope: "site:mql5.com/en/neurobook"
  })
});
var SOURCE_NAMES = Object.freeze(Object.keys(SOURCES));
var SEARCH_SOURCES = Object.freeze(["all", ...SOURCE_NAMES]);
var SEARCH_INPUT_KEYS = /* @__PURE__ */ new Set(["query", "source", "limit", "expand", "require_current"]);
const BATCH_INPUT_KEYS = new Set(["identifiers", "source", "limit", "require_current"]);
const BATCH_IDENTIFIER_PATTERN = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/u;
var READ_INPUT_KEYS = /* @__PURE__ */ new Set([
  "topic_id",
  "section_id",
  "focus",
  "cursor",
  "max_chars",
  "include_related",
  "related_limit",
  "include_images",
  "image_limit",
  "image_cursor"
]);
var SEARCH_STOPWORDS = /* @__PURE__ */ new Set([
  "a",
  "an",
  "and",
  "are",
  "do",
  "does",
  "find",
  "for",
  "from",
  "how",
  "i",
  "in",
  "is",
  "of",
  "the",
  "to",
  "what",
  "when",
  "where",
  "with"
]);
var COMMON_EXPECTED_COLUMNS = Object.freeze({
  metadata: ["key", "value"],
  topics: [
    "topic_id",
    "source",
    "internal_path",
    "title",
    "normalized_title",
    "breadcrumb",
    "signature",
    "content_sha256",
    "content",
    "content_length"
  ],
  aliases: ["alias", "normalized_alias", "topic_id", "source_kind"],
  sections: [
    "section_id",
    "topic_id",
    "ordinal",
    "heading",
    "start_offset",
    "end_offset",
    "content"
  ],
  topic_links: [
    "source_topic_id",
    "ordinal",
    "target_topic_id",
    "target_internal_path",
    "target_fragment",
    "label",
    "relationship",
    "resolution_status"
  ],
  search_fts: [
    "topic_id",
    "section_id",
    "source",
    "title",
    "aliases",
    "heading",
    "breadcrumb",
    "body"
  ]
});
var LEGACY_SOURCE_COLUMNS = Object.freeze([
  "source",
  "chm_filename",
  "chm_sha256",
  "chm_bytes",
  "http_last_modified",
  "http_etag",
  "retrieved_at",
  "topic_count",
  "section_count"
]);
var IMAGE_SOURCE_COLUMNS = Object.freeze([
  "source",
  "chm_filename",
  "chm_sha256",
  "chm_bytes",
  "topic_count",
  "section_count"
]);
var ASSET_COLUMNS = Object.freeze([
  "asset_id",
  "source",
  "internal_path",
  "path_sha256",
  "storage_key",
  "mime_type",
  "sha256",
  "byte_count",
  "width",
  "height",
  "pixel_count",
  "exposure",
  "exposure_reason",
  "canonical_caption"
]);
var TOPIC_ASSET_COLUMNS = Object.freeze([
  "topic_id",
  "occurrence_ordinal",
  "asset_id",
  "section_id",
  "text_offset",
  "figcaption_text",
  "title_text",
  "alt_text",
  "nearby_text",
  "contextual_caption",
  "caption_source"
]);
var REVISION_PATTERN = /^[0-9a-f]{64}$/;
var ISO_TIMESTAMP_PATTERN = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/;
var MATCH_KINDS = Object.freeze(["exact", "fts", "expanded", "fuzzy"]);
var UPDATE_STATUSES = Object.freeze(["up-to-date", "different-revision-available", "check-unavailable"]);
var EXPANSION_RANK_WEIGHT = 0.35;
var Mql5ChmError = class extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = "Mql5ChmError";
    this.code = code;
  }
};
function fail(code, message, options) {
  throw new Mql5ChmError(code, message, options);
}
export function isSupportedIndexContract(value) {
  return ACCEPTED_INDEX_CONTRACTS.has(value);
}
export function hasInvalidTopicContentRows(rows) {
  return !Array.isArray(rows) || rows.some((row) =>
    !isRecord(row) || typeof row.content !== "string" ||
    !Number.isSafeInteger(row.content_length) || row.content_length < 0 || row.content.length !== row.content_length ||
    typeof row.content_sha256 !== "string" || row.content_sha256.length !== 64
  );
}
function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function rejectUnknownInputKeys(input, allowedKeys, label) {
  const unknownKey = Object.keys(input).find((key) => !allowedKeys.has(key));
  if (unknownKey !== void 0) {
    fail("INVALID_ARGUMENT", `${label} contains an unknown argument: ${unknownKey}.`);
  }
}
function normalizeStoredTopicPath(value) {
  if (typeof value !== "string") return null;
  let candidate = value.replaceAll("\\", "/").trim();
  candidate = candidate.replace(/^mk:@msitstore:[^:]+::\//i, "");
  candidate = candidate.replace(/^\/+/, "");
  candidate = candidate.split("#", 1)[0].split("?", 1)[0];
  try {
    candidate = decodeURIComponent(candidate);
  } catch {
    // The indexer deliberately preserves malformed percent escapes as literal
    // text; canonicality below still requires the stored value to be exact.
  }
  const segments = candidate.split("/").filter((segment) => segment && segment !== ".");
  if (segments.some((segment) => segment === "..")) return null;
  return segments.join("/");
}
function expectedTopicId(source, internalPath) {
  const normalizedPath = normalizeStoredTopicPath(internalPath);
  const extension = normalizedPath ? extname(normalizedPath).toLowerCase() : "";
  if (
    !SOURCE_NAMES.includes(source) ||
    !normalizedPath ||
    normalizedPath !== internalPath ||
    ![".htm", ".html"].includes(extension)
  ) return null;
  const digest = createHash("sha256").update(normalizedPath.toLowerCase(), "utf8").digest("hex");
  return `${source}:${digest.slice(0, 24)}`;
}
function requireString(value, label, pattern) {
  if (typeof value !== "string" || value.length === 0 || pattern && !pattern.test(value)) {
    fail("INVALID_MANIFEST", `${label} is invalid.`);
  }
  return value;
}
function requireSafeInteger(value, label, minimum = 0) {
  if (!Number.isSafeInteger(value) || value < minimum) {
    fail("INVALID_MANIFEST", `${label} is invalid.`);
  }
  return value;
}
function canonicalPath(pathname) {
  return process.platform === "win32" ? pathname.toLowerCase() : pathname;
}
function assertConfined(root, pathname, label) {
  const absoluteRoot = resolve(root);
  const absolutePath = resolve(pathname);
  let realRoot;
  let realPath;
  try {
    realRoot = realpathSync.native(absoluteRoot);
    realPath = realpathSync.native(absolutePath);
  } catch (error51) {
    fail("MISSING_PACKAGE_FILE", `${label} is missing or inaccessible.`, { cause: error51 });
  }
  const realRelative = relative(canonicalPath(realRoot), canonicalPath(realPath));
  if (realRelative === ".." || realRelative.startsWith(`..${sep}`) || isAbsolute(realRelative)) {
    fail("PATH_ESCAPE", `${label} resolves outside the MCP package root.`);
  }
  return realPath;
}
function assertNoReparse(pathname, label, expectedKind) {
  let info;
  try {
    info = lstatSync(pathname);
  } catch (error) {
    fail("MISSING_PACKAGE_FILE", `${label} is missing or inaccessible.`, { cause: error });
  }
  let traversesReparse = true;
  try {
    const absolutePath = resolve(pathname);
    const filesystemRoot = parse(absolutePath).root;
    let cursor = filesystemRoot;
    traversesReparse = relative(filesystemRoot, absolutePath)
      .split(sep)
      .filter(Boolean)
      .some((segment) => {
        cursor = resolve(cursor, segment);
        return lstatSync(cursor).isSymbolicLink();
      });
  } catch {
    traversesReparse = true;
  }
  if (info.isSymbolicLink() || traversesReparse || expectedKind === "file" && !info.isFile() || expectedKind === "directory" && !info.isDirectory()) {
    fail("INVALID_PACKAGE_FILE", `${label} is not an approved regular ${expectedKind}.`);
  }
  return info;
}
function resolveProjectRoot({ root, env = process.env } = {}) {
  const candidate = root ?? env.MQL5_CHM_MCP_ROOT ?? MODULE_PROJECT_ROOT;
  if (typeof candidate !== "string" || candidate.trim().length === 0) {
    fail("INVALID_ROOT", "The MCP package root is invalid.");
  }
  return resolve(candidate);
}
function normalizeText(value) {
  return String(value ?? "").normalize("NFKD").toLowerCase().replace(new RegExp("\\p{M}", "gu"), "").replace(/[^\p{L}\p{N}_]+/gu, " ").trim().replace(/\s+/g, " ");
}
function compareOrdinal(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}
function ftsTokens(value, maximum = 16) {
  const tokens = normalizeText(value).match(/[\p{L}\p{N}_]+/gu) ?? [];
  const meaningful = tokens.filter((token) => !SEARCH_STOPWORDS.has(token));
  return [...new Set(meaningful.length ? meaningful : tokens)].slice(0, maximum);
}
function buildFtsQuery(value) {
  return ftsTokens(value).map((token) => `"${token.replaceAll('"', '""')}"*`).join(" AND ");
}
function loadExpansions(value) {
  if (!isRecord(value) || value.schema_version !== 1 || !Array.isArray(value.expansions) || value.expansions.length > 64) {
    throw new Error("The bundled MQL5 query expansion configuration is invalid.");
  }
  return value.expansions.map((entry) => {
    if (!isRecord(entry) || !Array.isArray(entry.phrases) || !Array.isArray(entry.terms) || entry.phrases.length < 1 || entry.phrases.length > 16 || entry.terms.length < 1 || entry.terms.length > 16) {
      throw new Error("The bundled MQL5 query expansion entry is invalid.");
    }
    const phrases = entry.phrases.map((phrase) => normalizeText(phrase)).filter((phrase) => phrase.length >= 3 && phrase.length <= 100);
    const terms = entry.terms.map((term) => String(term).trim()).filter((term) => term.length >= 2 && term.length <= 100);
    if (phrases.length !== entry.phrases.length || terms.length !== entry.terms.length) {
      throw new Error("The bundled MQL5 query expansion terms are invalid.");
    }
    return Object.freeze({ phrases: Object.freeze(phrases), terms: Object.freeze(terms) });
  });
}
var QUERY_EXPANSIONS = Object.freeze(loadExpansions(expansionConfig));
function getExpandedTerms(query, enabled) {
  if (!enabled) return [];
  const normalized = normalizeText(query);
  if (!normalized) return [];
  const exactIdentifier = /^[\p{L}_][\p{L}\p{N}_]*(?:::[\p{L}_][\p{L}\p{N}_]*)?$/u.test(String(query).trim());
  if (exactIdentifier && !normalized.includes(" ")) return [];
  const terms = [];
  for (const entry of QUERY_EXPANSIONS) {
    if (entry.phrases.some((phrase) => normalized.includes(phrase) || phrase.includes(normalized))) {
      terms.push(...entry.terms);
    }
  }
  return [...new Set(terms)].slice(0, 12);
}
function trigramSet(value) {
  const normalized = normalizeText(value);
  if (!normalized) return /* @__PURE__ */ new Set();
  const padded = `  ${normalized}  `;
  const grams = /* @__PURE__ */ new Set();
  for (let index = 0; index <= padded.length - 3; index += 1) {
    grams.add(padded.slice(index, index + 3));
  }
  return grams;
}
function trigramSimilarity(left, right) {
  const normalizedLeft = normalizeText(left);
  const normalizedRight = normalizeText(right);
  if (!normalizedLeft || !normalizedRight) return 0;
  if (normalizedLeft === normalizedRight) return 1;
  const leftGrams = trigramSet(normalizedLeft);
  const rightGrams = trigramSet(normalizedRight);
  let common = 0;
  for (const gram of leftGrams) {
    if (rightGrams.has(gram)) common += 1;
  }
  return 2 * common / (leftGrams.size + rightGrams.size);
}
function sourcePreference(source) {
  return source === "mql5" ? 0 : source === "mql5book" ? 1 : 2;
}
function compactWhitespace(value) {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}
function makeSnippet(content, query, maximum = 500) {
  const text = compactWhitespace(content);
  if (text.length <= maximum) return text;
  const matchAt = findFocusMatch(text, query).index;
  const contextBefore = Math.floor(maximum * 0.28);
  let start = matchAt < 0 ? 0 : Math.max(0, matchAt - contextBefore);
  let end = Math.min(text.length, start + maximum);
  if (end === text.length) start = Math.max(0, end - maximum);
  const snippetCodePoints = Array.from(text.slice(start, end));
  if (start > 0 && snippetCodePoints.length > 0) snippetCodePoints[0] = "\u2026";
  if (end < text.length && snippetCodePoints.length > 0) snippetCodePoints[snippetCodePoints.length - 1] = "\u2026";
  return snippetCodePoints.join("");
}
async function sha256File(pathname) {
  return await new Promise((resolveHash, rejectHash) => {
    const hash2 = createHash("sha256");
    const stream = createReadStream(pathname);
    stream.on("error", rejectHash);
    stream.on("data", (chunk) => hash2.update(chunk));
    stream.on("end", () => resolveHash(hash2.digest("hex")));
  });
}
function readJsonFile(pathname, label, maximumBytes, code = "INVALID_MANIFEST") {
  let raw;
  try {
    const size = statSync(pathname).size;
    if (size <= 0 || size > maximumBytes) fail(code, `${label} size is invalid.`);
    raw = readFileSync(pathname, "utf8");
  } catch (error51) {
    if (error51 instanceof Mql5ChmError) throw error51;
    fail(code, `${label} could not be read.`, { cause: error51 });
  }
  try {
    const parsed = JSON.parse(raw);
    if (!isRecord(parsed)) fail(code, `${label} must be a JSON object.`);
    return parsed;
  } catch (error51) {
    if (error51 instanceof Mql5ChmError) throw error51;
    fail(code, `${label} is not valid JSON.`, { cause: error51 });
  }
}
function requireExactKeys(value, expected, label, code) {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail(code, `${label} has unexpected properties.`);
  }
}
function requireIsoTimestamp(value, label, code = "INVALID_MANIFEST") {
  const match = typeof value === "string" ? ISO_TIMESTAMP_PATTERN.exec(value) : null;
  const timestamp = match ? Date.parse(value) : Number.NaN;
  const parsed = Number.isFinite(timestamp) ? new Date(timestamp) : null;
  if (!match || !parsed ||
      parsed.getUTCFullYear() !== Number(match[1]) ||
      parsed.getUTCMonth() + 1 !== Number(match[2]) ||
      parsed.getUTCDate() !== Number(match[3]) ||
      parsed.getUTCHours() !== Number(match[4]) ||
      parsed.getUTCMinutes() !== Number(match[5]) ||
      parsed.getUTCSeconds() !== Number(match[6])) {
    fail(code, `${label} is invalid.`);
  }
  return value;
}
function requireNullableBoundedString(value, label, maximum = 512) {
  if (value !== null && (typeof value !== "string" || value.length > maximum || /[\u0000-\u001f\u007f]/u.test(value))) {
    fail("INVALID_MANIFEST", `${label} is invalid.`);
  }
  return value;
}
function parseActivePointer(pointerPath) {
  const pointer = readJsonFile(pointerPath, "The active revision pointer", 16 * 1024, "INVALID_ACTIVE_POINTER");
  requireExactKeys(
    pointer,
    ["schema_version", "active_revision", "previous_revision", "activated_at"],
    "The active revision pointer",
    "INVALID_ACTIVE_POINTER"
  );
  if (![1, 2].includes(pointer.schema_version) || typeof pointer.active_revision !== "string" || !REVISION_PATTERN.test(pointer.active_revision)) {
    fail("INVALID_ACTIVE_POINTER", "The active revision pointer is invalid.");
  }
  if (pointer.previous_revision !== null && (typeof pointer.previous_revision !== "string" || !REVISION_PATTERN.test(pointer.previous_revision))) {
    fail("INVALID_ACTIVE_POINTER", "The previous revision is invalid.");
  }
  if (pointer.previous_revision === pointer.active_revision) {
    fail("INVALID_ACTIVE_POINTER", "The previous revision must differ from the active revision.");
  }
  requireIsoTimestamp(pointer.activated_at, "activated_at", "INVALID_ACTIVE_POINTER");
  return pointer;
}
function computeManifestRevision(sources) {
  const hash = createHash("sha256");
  for (const source of SOURCE_NAMES) {
    hash.update(`${source}\0${sources[source].sha256}\0`, "utf8");
  }
  return hash.digest("hex");
}
function parseManifest(manifestPath, activeRevision, pointerSchemaVersion) {
  const manifest = readJsonFile(manifestPath, "The revision manifest", 256 * 1024);
  if (![LEGACY_SCHEMA_VERSION, IMAGE_SCHEMA_VERSION].includes(manifest.schema_version) || !isRecord(manifest.database) || !isRecord(manifest.sources)) {
    fail("INVALID_MANIFEST", "The revision manifest schema is unsupported or incomplete.");
  }
  if (manifest.database.filename !== DATABASE_FILENAME) fail("INVALID_MANIFEST", "The database filename is invalid.");
  requireString(manifest.database.sha256, "database.sha256", REVISION_PATTERN);
  requireSafeInteger(manifest.database.bytes, "database.bytes", 1);
  const corpusRevision = requireString(manifest.corpus_revision ?? manifest.corpus_sha256, "corpus_revision", REVISION_PATTERN);
  requireString(manifest.corpus_sha256, "corpus_sha256", REVISION_PATTERN);
  if (manifest.corpus_sha256 !== corpusRevision) fail("INVALID_MANIFEST", "The manifest corpus aliases disagree.");
  if (manifest.schema_version === LEGACY_SCHEMA_VERSION) {
    if (pointerSchemaVersion === 1 && corpusRevision !== activeRevision) {
      fail("INVALID_MANIFEST", "The legacy corpus revision is not active.");
    }
    if (pointerSchemaVersion === 2 && manifest.database.sha256 !== activeRevision) {
      fail("INVALID_MANIFEST", "The legacy index revision is not active.");
    }
  } else {
    requireString(manifest.index_revision, "index_revision", REVISION_PATTERN);
    requireString(manifest.index_contract, "index_contract");
    if (!isSupportedIndexContract(manifest.index_contract)) fail("INVALID_MANIFEST", "The schema-3 index contract is unsupported.");
    if (!isRecord(manifest.assets) || manifest.assets.directory !== "assets" || !isRecord(manifest.assets.by_source)) {
      fail("INVALID_MANIFEST", "The schema-3 asset manifest is incomplete.");
    }
    requireString(manifest.assets.catalog_sha256, "assets.catalog_sha256", REVISION_PATTERN);
    requireString(manifest.assets.tree_sha256, "assets.tree_sha256", REVISION_PATTERN);
    requireString(manifest.assets.policy_sha256, "assets.policy_sha256", REVISION_PATTERN);
    if (manifest.index_revision !== manifest.database.sha256 || manifest.index_revision !== activeRevision) {
      fail("INVALID_MANIFEST", "The schema-3 index revision is not active.");
    }
  }
  requireIsoTimestamp(manifest.indexed_at, "indexed_at");
  requireIsoTimestamp(manifest.build_timestamp, "build_timestamp");
  for (const name of [
    "total_topic_count",
    "total_section_count",
    "topic_link_count",
    "resolved_topic_link_count",
    "unresolved_topic_link_count"
  ]) requireSafeInteger(manifest[name], name, 0);
  if (manifest.topic_link_count !== manifest.resolved_topic_link_count + manifest.unresolved_topic_link_count) {
    fail("INVALID_MANIFEST", "The topic-link counts are inconsistent.");
  }
  if (Object.keys(manifest.sources).sort().join("\0") !== [...SOURCE_NAMES].sort().join("\0")) {
    fail("INVALID_MANIFEST", "The manifest contains unexpected documentation sources.");
  }
  let totalTopics = 0;
  let totalSections = 0;
  for (const [source, expected] of Object.entries(SOURCES)) {
    const entry = manifest.sources[source];
    if (!isRecord(entry) || entry.filename !== expected.filename) fail("INVALID_MANIFEST", `The ${source} source entry is invalid.`);
    requireString(entry.sha256, `${source}.sha256`, REVISION_PATTERN);
    requireSafeInteger(entry.bytes, `${source}.bytes`, 1);
    requireSafeInteger(entry.topic_count, `${source}.topic_count`, expected.minimum_topic_count);
    requireSafeInteger(entry.section_count, `${source}.section_count`, entry.topic_count);
    requireIsoTimestamp(entry.retrieved_at, `${source}.retrieved_at`);
    requireNullableBoundedString(entry.http_last_modified, `${source}.http_last_modified`);
    requireNullableBoundedString(entry.http_etag, `${source}.http_etag`);
    totalTopics += entry.topic_count;
    totalSections += entry.section_count;
  }
  if (manifest.total_topic_count !== totalTopics || manifest.total_section_count !== totalSections) {
    fail("INVALID_MANIFEST", "The manifest totals do not match the source totals.");
  }
  if (computeManifestRevision(manifest.sources) !== corpusRevision) {
    fail("INVALID_MANIFEST", "The canonical source revision does not match the declared corpus revision.");
  }
  if (manifest.schema_version === IMAGE_SCHEMA_VERSION) {
    for (const name of ["cataloged_count", "exposed_count", "excluded_count", "occurrence_count", "exposed_occurrence_count", "total_bytes"]) {
      requireSafeInteger(manifest.assets[name], `assets.${name}`, 0);
    }
    if (manifest.assets.cataloged_count !== manifest.assets.exposed_count + manifest.assets.excluded_count) {
      fail("INVALID_MANIFEST", "The manifest asset counts are inconsistent.");
    }
    if (Object.keys(manifest.assets.by_source).sort().join("\0") !== [...SOURCE_NAMES].sort().join("\0")) {
      fail("INVALID_MANIFEST", "The asset manifest contains unexpected documentation sources.");
    }
    for (const source of SOURCE_NAMES) {
      const entry = manifest.assets.by_source[source];
      if (!isRecord(entry)) fail("INVALID_MANIFEST", `The ${source} asset summary is invalid.`);
      for (const name of ["cataloged_count", "exposed_count", "excluded_count", "occurrence_count", "exposed_occurrence_count", "total_bytes"]) {
        requireSafeInteger(entry[name], `assets.by_source.${source}.${name}`, 0);
      }
      if (entry.cataloged_count !== entry.exposed_count + entry.excluded_count) fail("INVALID_MANIFEST", `The ${source} asset counts are inconsistent.`);
    }
    const sum = (name) => SOURCE_NAMES.reduce((total, source) => total + manifest.assets.by_source[source][name], 0);
    for (const [manifestName, sourceName] of [
      ["cataloged_count", "cataloged_count"],
      ["exposed_count", "exposed_count"],
      ["excluded_count", "excluded_count"],
      ["occurrence_count", "occurrence_count"],
      ["exposed_occurrence_count", "exposed_occurrence_count"],
      ["total_bytes", "total_bytes"]
    ]) {
      if (manifest.assets[manifestName] !== sum(sourceName)) fail("INVALID_MANIFEST", `The assets.${manifestName} total is inconsistent.`);
    }
  }
  manifest.corpus_revision = corpusRevision;
  return manifest;
}
function verifyColumns(database, table, expectedColumns) {
  const rows = database.prepare(`PRAGMA table_info(${table})`).all();
  const actualColumns = rows.map((row) => row.name);
  if (actualColumns.length !== expectedColumns.length || expectedColumns.some((column, index) => actualColumns[index] !== column)) {
    fail("INVALID_INDEX", `The ${table} table has an unexpected schema.`);
  }
}
function inspectPng(buffer) {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (buffer.length > MAX_IMAGE_BYTES) throw new Error("PNG exceeds the image byte limit.");
  if (buffer.length < 45 || !buffer.subarray(0, 8).equals(signature)) throw new Error("Invalid PNG signature.");
  let offset = 8;
  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = 0;
  let interlace = 0;
  let sawHeader = false;
  let sawPalette = false;
  let paletteEntries = 0;
  let sawData = false;
  let sawEnd = false;
  let leftDataSequence = false;
  const validateTransparency = createPngTransparencyValidator();
  const compressedChunks = [];
  while (offset + 12 <= buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const end = offset + 12 + length;
    if (end > buffer.length) throw new Error("Truncated PNG chunk.");
    const typeBytes = buffer.subarray(offset + 4, offset + 8);
    const type = readPngChunkType(typeBytes);
    if (!/[A-Z]/u.test(type[2])) throw new Error("Invalid PNG chunk type.");
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    const declaredCrc = buffer.readUInt32BE(offset + 8 + length);
    // Native CRC-32/IEEE over the contiguous chunk type and data, without a copy.
    if (crc32(buffer.subarray(offset + 4, offset + 8 + length)) !== declaredCrc) throw new Error("Invalid PNG chunk CRC.");
    validateTransparency(type, length, { colorType, paletteEntries, sawPalette, sawData });
    if (!sawHeader) {
      if (type !== "IHDR" || length !== 13) throw new Error("PNG IHDR is missing.");
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
      const validDepths = new Map([[0, new Set([1, 2, 4, 8, 16])], [2, new Set([8, 16])], [3, new Set([1, 2, 4, 8])], [4, new Set([8, 16])], [6, new Set([8, 16])]]);
      if (!width || !height || !validDepths.get(colorType)?.has(bitDepth)) throw new Error("PNG has invalid dimensions or color format.");
      const pixelCount = width * height;
      if (width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION || !Number.isSafeInteger(pixelCount) || pixelCount > MAX_IMAGE_PIXELS) {
        throw new Error("PNG exceeds the image dimension or pixel limit.");
      }
      if (data[10] !== 0 || data[11] !== 0 || ![0, 1].includes(interlace)) throw new Error("PNG has unsupported metadata.");
      sawHeader = true;
    } else if (type === "IHDR") {
      throw new Error("Duplicate PNG IHDR.");
    }
    if (type === "acTL" || type === "fcTL" || type === "fdAT") throw new Error("APNG is not supported.");
    if (type === "PLTE") {
      if (sawPalette || sawData || !length || length > 768 || length % 3 !== 0 || [0, 4].includes(colorType)) throw new Error("Malformed or misplaced PNG palette.");
      if (colorType === 3 && length / 3 > 2 ** bitDepth) throw new Error("PNG palette exceeds its indexed bit depth.");
      paletteEntries = length / 3;
      sawPalette = true;
    }
    if (type === "IDAT") {
      if (!sawHeader || sawEnd || leftDataSequence) throw new Error("PNG IDAT is out of order.");
      if (colorType === 3 && !sawPalette) throw new Error("Indexed PNG is missing its required palette.");
      sawData = true;
      compressedChunks.push(data);
    }
    if (type === "IEND") {
      if (length !== 0 || !sawData || end !== buffer.length) throw new Error("Invalid PNG terminator.");
      sawEnd = true;
      break;
    }
    if (!["IHDR", "PLTE", "IDAT", "IEND", "acTL", "fcTL", "fdAT"].includes(type) && /[A-Z]/u.test(type[0])) {
      throw new Error(`Unsupported critical PNG chunk ${type}.`);
    }
    if (sawData && type !== "IDAT") leftDataSequence = true;
    offset = end;
  }
  if (!sawHeader || !sawData || !sawEnd) throw new Error("Incomplete PNG.");
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
  validatePngScanlines(inflated, passes, { bitsPerPixel, bitDepth, colorType, paletteEntries });
  return { mime: "image/png", width, height };
}
function inspectJpeg(buffer) {
  if (buffer.length < 4 || buffer[0] !== 0xff || buffer[1] !== 0xd8) throw new Error("Invalid JPEG framing.");
  let offset = 2;
  let width = 0;
  let height = 0;
  let sawScan = false;
  let sawEnd = false;
  let scanDataBytes = 0;
  const sofMarkers = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);
  while (offset < buffer.length) {
    if (buffer[offset] !== 0xff) throw new Error("Invalid JPEG marker.");
    while (offset < buffer.length && buffer[offset] === 0xff) offset += 1;
    if (offset >= buffer.length) throw new Error("Truncated JPEG marker.");
    const marker = buffer[offset++];
    if (marker === 0xd9) {
      sawEnd = true;
      if (offset !== buffer.length) throw new Error("JPEG contains trailing bytes after EOI.");
      break;
    }
    if (marker === 0x00 || marker === 0xd8) throw new Error("Invalid JPEG marker sequence.");
    if (marker >= 0xd0 && marker <= 0xd7 || marker === 0x01) continue;
    if (offset + 2 > buffer.length) throw new Error("Truncated JPEG segment.");
    const length = buffer.readUInt16BE(offset);
    if (length < 2 || offset + length > buffer.length) throw new Error("Invalid JPEG segment length.");
    if (sofMarkers.has(marker)) {
      if (length < 8) throw new Error("Invalid JPEG frame header.");
      height = buffer.readUInt16BE(offset + 3);
      width = buffer.readUInt16BE(offset + 5);
      if (!width || !height) throw new Error("JPEG has zero dimensions.");
      const pixelCount = width * height;
      if (width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION || !Number.isSafeInteger(pixelCount) || pixelCount > MAX_IMAGE_PIXELS) {
        throw new Error("JPEG exceeds the image dimension or pixel limit.");
      }
    }
    if (marker === 0xda) {
      if (!width || !height || length < 6) throw new Error("JPEG scan precedes a valid frame header.");
      sawScan = true;
      offset += length;
      let foundMarker = false;
      while (offset < buffer.length) {
        if (buffer[offset] !== 0xff) {
          scanDataBytes += 1;
          offset += 1;
          continue;
        }
        let markerOffset = offset + 1;
        while (markerOffset < buffer.length && buffer[markerOffset] === 0xff) markerOffset += 1;
        if (markerOffset >= buffer.length) throw new Error("Truncated JPEG scan data.");
        const scanMarker = buffer[markerOffset];
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
    offset += length;
  }
  if (!sawEnd || !sawScan || !scanDataBytes || !width || !height) throw new Error("Incomplete JPEG image.");
  let decoded;
  try {
    decoded = jpeg.decode(buffer, {
      useTArray: true,
      formatAsRGBA: false,
      tolerantDecoding: false,
      maxResolutionInMP: MAX_IMAGE_PIXELS / 1_000_000,
      maxMemoryUsageInMB: 64,
    });
  } catch {
    throw new Error("JPEG image data could not be decoded safely.");
  }
  if (decoded.width !== width || decoded.height !== height) throw new Error("JPEG decoded dimensions do not match its frame header.");
  return { mime: "image/jpeg", width, height };
}
function inspectGif(buffer) {
  if (buffer.length < 13 || !hasGifHeader(buffer)) {
    throw new Error("Invalid GIF signature.");
  }
  const width = buffer.readUInt16LE(6);
  const height = buffer.readUInt16LE(8);
  let offset = 13;
  if (buffer[10] & 0x80) offset += 3 * (2 ** ((buffer[10] & 0x07) + 1));
  if (offset > buffer.length) throw new Error("Truncated GIF global color table.");
  const skipSubBlocks = () => {
    let totalBytes = 0;
    while (offset < buffer.length) {
      const length = buffer[offset++];
      if (length === 0) return totalBytes;
      if (offset + length > buffer.length) throw new Error("Truncated GIF data block.");
      offset += length;
      totalBytes += length;
    }
    throw new Error("Unterminated GIF data block.");
  };
  let sawImage = false;
  while (offset < buffer.length) {
    const marker = buffer[offset++];
    if (marker === 0x3b) {
      if (!sawImage || offset !== buffer.length) throw new Error("Invalid GIF terminator.");
      return { mime: "image/gif", width, height };
    }
    if (marker === 0x21) {
      if (offset >= buffer.length) throw new Error("Truncated GIF extension.");
      offset += 1;
      skipSubBlocks();
      continue;
    }
    if (marker !== 0x2c || offset + 9 > buffer.length) throw new Error("Invalid GIF block.");
    const left = buffer.readUInt16LE(offset);
    const top = buffer.readUInt16LE(offset + 2);
    const imageWidth = buffer.readUInt16LE(offset + 4);
    const imageHeight = buffer.readUInt16LE(offset + 6);
    if (!imageWidth || !imageHeight || left + imageWidth > width || top + imageHeight > height) {
      throw new Error("GIF image descriptor is outside the logical canvas bounds.");
    }
    const packed = buffer[offset + 8];
    offset += 9;
    if (packed & 0x80) offset += 3 * (2 ** ((packed & 0x07) + 1));
    if (offset >= buffer.length) throw new Error("Truncated GIF image data.");
    const minimumCodeSize = buffer[offset++];
    if (minimumCodeSize < 2 || minimumCodeSize > 8) throw new Error("Invalid GIF LZW code size.");
    if (skipSubBlocks() < 1) throw new Error("GIF image data is empty.");
    sawImage = true;
  }
  throw new Error("Incomplete GIF.");
}
function inspectRasterImage(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 4) throw new Error("Raster data is invalid.");
  let inspected;
  if (buffer[0] === 0x89 && buffer[1] === 0x50) inspected = inspectPng(buffer);
  else if (buffer[0] === 0xff && buffer[1] === 0xd8) inspected = inspectJpeg(buffer);
  else if (hasGifHeader(buffer)) inspected = inspectGif(buffer);
  else throw new Error("Unsupported raster signature.");
  assertRasterBounds(buffer.length, inspected.width, inspected.height);
  return inspected;
}
function inspectCatalogRasterImage(buffer, row, fullSha256) {
  try {
    return inspectRasterImage(buffer);
  } catch (error) {
    const pinned = PINNED_TRAILING_PNG;
    if (row.source !== pinned.source || row.internal_path !== pinned.internalPath || row.sha256 !== pinned.sha256 ||
        fullSha256 !== pinned.sha256 || row.byte_count !== pinned.byteCount || buffer.length !== pinned.byteCount ||
        row.mime_type !== "image/png" || row.exposure !== "exposed" || row.exposure_reason !== pinned.exposureReason) {
      throw error;
    }
    return inspectRasterImage(buffer.subarray(0, pinned.pngPrefixBytes));
  }
}
function assertRasterBounds(byteCount, width, height) {
  if (!Number.isSafeInteger(byteCount) || byteCount < 1 || byteCount > MAX_IMAGE_BYTES ||
      !Number.isSafeInteger(width) || width < 1 || width > MAX_IMAGE_DIMENSION ||
      !Number.isSafeInteger(height) || height < 1 || height > MAX_IMAGE_DIMENSION ||
      width * height > MAX_IMAGE_PIXELS) {
    throw new Error("Raster bounds are invalid.");
  }
}
function validateInternalAssetPath(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 1024 || value.includes("\\") ||
      value !== value.normalize("NFC") || value.startsWith("/") || value.endsWith("/") || /[\u0000-\u001f\u007f%?#:]/u.test(value)) {
    return false;
  }
  const segments = value.split("/");
  return segments.every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
}
function makeRuntimeAssetId(source, internalPath) {
  const digest = createHash("sha256").update(internalPath.toLowerCase(), "utf8").digest("hex");
  return `${source}:asset:${digest.slice(0, 24)}`;
}
function listAssetTree(assetRoot, revisionRoot) {
  const files = [];
  const directories = new Set(["assets"]);
  const visit = (directory) => {
    const directoryInfo = lstatSync(directory);
    if (directoryInfo.isSymbolicLink() || !directoryInfo.isDirectory()) {
      throw new Error("Asset tree contains a reparse point or invalid directory.");
    }
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const pathname = resolve(directory, entry.name);
      const info = lstatSync(pathname);
      if (entry.isSymbolicLink() || info.isSymbolicLink()) {
        throw new Error("Asset tree contains a reparse point.");
      }
      const key = relative(revisionRoot, pathname).split(sep).join("/");
      if (entry.isDirectory() && info.isDirectory()) {
        directories.add(key);
        visit(pathname);
      } else if (entry.isFile() && info.isFile()) {
        files.push(key);
      } else {
        throw new Error("Asset tree contains an unsupported filesystem object.");
      }
    }
  };
  visit(assetRoot);
  files.sort();
  return { files, directories };
}
function verifyAssetCatalog(database, manifest, packageInfo) {
  const rows = database.prepare(
    "SELECT asset_id, source, internal_path, path_sha256, storage_key, mime_type, sha256, byte_count, width, height, pixel_count, exposure, exposure_reason, canonical_caption FROM assets ORDER BY storage_key"
  ).all();
  if (rows.length !== manifest.assets.cataloged_count) fail("INVALID_INDEX", "The asset catalog count does not match the manifest.");
  const expectedFiles = new Set();
  const expectedDirectories = new Set(["assets"]);
  const treeHash = createHash("sha256");
  let totalBytes = 0;
  let exposed = 0;
  const seenIds = new Set();
  const catalogRows = database.prepare(
    "SELECT asset_id, source, internal_path, path_sha256, storage_key, mime_type, sha256, byte_count, width, height, pixel_count, exposure, exposure_reason, canonical_caption FROM assets ORDER BY asset_id"
  ).all().map((row) => [
    row.asset_id, row.source, row.internal_path, row.path_sha256, row.storage_key, row.mime_type, row.sha256,
    row.byte_count, row.width, row.height, row.pixel_count, row.exposure, row.exposure_reason, row.canonical_caption
  ]);
  const catalogHash = createHash("sha256").update(JSON.stringify(catalogRows), "utf8").digest("hex");
  if (catalogHash !== manifest.assets.catalog_sha256) fail("INVALID_INDEX", "The asset-catalog digest is invalid.");
  for (const row of rows) {
    try {
      if (!ASSET_ID_PATTERN.test(row.asset_id) || !SOURCE_NAMES.includes(row.source) || !validateInternalAssetPath(row.internal_path)) {
        throw new Error("Invalid asset identity.");
      }
      const pathDigest = createHash("sha256").update(row.internal_path.toLowerCase(), "utf8").digest("hex");
      if (row.asset_id !== makeRuntimeAssetId(row.source, row.internal_path) || row.path_sha256 !== pathDigest || seenIds.has(row.asset_id)) {
        throw new Error("Asset identity collision or digest mismatch.");
      }
      seenIds.add(row.asset_id);
      const storage = ASSET_STORAGE_PATTERN.exec(row.storage_key);
      if (!storage || storage[1] !== row.source || storage[2] !== row.path_sha256) throw new Error("Invalid opaque storage key.");
      if (!REVISION_PATTERN.test(row.sha256) || !["exposed", "excluded"].includes(row.exposure)) throw new Error("Invalid asset classification.");
      if (typeof row.exposure_reason !== "string" || row.exposure_reason.length < 1 || row.exposure_reason.length > 500 || /[\u0000-\u001f\u007f]/u.test(row.exposure_reason)) {
        throw new Error("Invalid asset exposure reason.");
      }
      if (typeof row.canonical_caption !== "string" || row.canonical_caption.length > 500 || /[\u0000-\u001f\u007f]/u.test(row.canonical_caption)) {
        throw new Error("Invalid asset caption.");
      }
      assertRasterBounds(row.byte_count, row.width, row.height);
      if (row.pixel_count !== row.width * row.height) throw new Error("Invalid pixel count.");
      const expectedExtensionMime = new Map([[".png", "image/png"], [".jpg", "image/jpeg"], [".jpeg", "image/jpeg"], [".gif", "image/gif"]]).get(extname(row.internal_path).toLowerCase());
      if (!expectedExtensionMime || row.mime_type !== expectedExtensionMime) throw new Error("Asset extension and MIME disagree.");
      if (row.exposure === "exposed" && !["image/png", "image/jpeg"].includes(row.mime_type)) throw new Error("Unsupported asset is exposed.");
      const pathname = assertConfined(packageInfo.projectRoot, resolve(packageInfo.revisionRoot, ...row.storage_key.split("/")), "An immutable asset");
      const info = lstatSync(pathname);
      if (info.isSymbolicLink() || !info.isFile() || info.size !== row.byte_count) throw new Error("Asset file metadata mismatch.");
      const bytes = readFileSync(pathname);
      const digest = createHash("sha256").update(bytes).digest("hex");
      const inspected = inspectCatalogRasterImage(bytes, row, digest);
      assertRasterBounds(bytes.length, inspected.width, inspected.height);
      if (digest !== row.sha256 || inspected.mime !== row.mime_type || inspected.width !== row.width || inspected.height !== row.height) {
        throw new Error("Asset file integrity mismatch.");
      }
      expectedFiles.add(row.storage_key);
      expectedDirectories.add(`assets/${row.source}`);
      totalBytes += row.byte_count;
      if (row.exposure === "exposed") exposed += 1;
      treeHash.update(`${row.storage_key}\0${row.sha256}\0${row.byte_count}\0`, "utf8");
    } catch (error) {
      fail("INVALID_INDEX", "The immutable asset catalog failed validation.", { cause: error });
    }
  }
  if (totalBytes !== manifest.assets.total_bytes || exposed !== manifest.assets.exposed_count || rows.length - exposed !== manifest.assets.excluded_count) {
    fail("INVALID_INDEX", "The asset catalog totals do not match the manifest.");
  }
  if (treeHash.digest("hex") !== manifest.assets.tree_sha256) fail("INVALID_INDEX", "The asset-tree digest is invalid.");
  let closure;
  try {
    const assetCandidate = resolve(packageInfo.revisionRoot, "assets");
    assertNoReparse(assetCandidate, "The immutable asset directory", "directory");
    const assetRoot = assertConfined(packageInfo.projectRoot, assetCandidate, "The immutable asset directory");
    closure = listAssetTree(assetRoot, packageInfo.revisionRoot);
  } catch (error) {
    if (error instanceof Mql5ChmError) throw error;
    fail("INVALID_INDEX", "The immutable asset directory failed validation.", { cause: error });
  }
  if (closure.files.length !== expectedFiles.size || closure.files.some((key) => !expectedFiles.has(key)) ||
      closure.directories.size !== expectedDirectories.size || [...closure.directories].some((key) => !expectedDirectories.has(key))) {
    fail("INVALID_INDEX", "The immutable asset directory does not exactly match the catalog.");
  }
  const occurrenceCount = database.prepare("SELECT COUNT(*) AS count FROM topic_assets").get().count;
  const exposedOccurrenceCount = database.prepare(
    "SELECT COUNT(*) AS count FROM topic_assets ta JOIN assets a ON a.asset_id=ta.asset_id WHERE a.exposure='exposed'"
  ).get().count;
  const invalidOccurrences = database.prepare(
    "SELECT COUNT(*) AS count FROM topic_assets ta " +
    "LEFT JOIN topics t ON t.topic_id=ta.topic_id LEFT JOIN assets a ON a.asset_id=ta.asset_id " +
    "LEFT JOIN sections s ON s.section_id=ta.section_id AND s.topic_id=ta.topic_id " +
    "WHERE t.topic_id IS NULL OR a.asset_id IS NULL OR a.source <> t.source OR ta.occurrence_ordinal < 0 OR ta.text_offset < 0 OR ta.text_offset > t.content_length " +
    "OR ta.section_id IS NULL OR s.section_id IS NULL OR ta.text_offset < s.start_offset OR ta.text_offset > s.end_offset " +
    "OR length(ta.figcaption_text)>500 OR length(ta.title_text)>500 " +
    "OR length(ta.alt_text)>500 OR length(ta.nearby_text)>500 " +
    "OR length(ta.contextual_caption)>500 OR length(ta.caption_source)>500"
  ).get().count;
  const occurrenceTextRows = database.prepare(
    "SELECT figcaption_text, title_text, alt_text, nearby_text, contextual_caption, caption_source FROM topic_assets"
  ).all();
  const invalidOccurrenceText = occurrenceTextRows.some((row) => ["figcaption_text", "title_text", "alt_text", "nearby_text", "contextual_caption", "caption_source"].some((name) =>
    typeof row[name] !== "string" || row[name].length > 500 || /[\u0000-\u001f\u007f]/u.test(row[name])
  ));
  if (occurrenceCount !== manifest.assets.occurrence_count || exposedOccurrenceCount !== manifest.assets.exposed_occurrence_count || invalidOccurrences || invalidOccurrenceText) {
    fail("INVALID_INDEX", "The topic-asset associations failed validation.");
  }
  for (const source of SOURCE_NAMES) {
    const row = database.prepare(
      "SELECT COUNT(*) AS asset_count, COALESCE(SUM(byte_count),0) AS asset_bytes, " +
      "COALESCE(SUM(CASE WHEN exposure='exposed' THEN 1 ELSE 0 END),0) AS exposed_asset_count, " +
      "COALESCE(SUM(CASE WHEN exposure='excluded' THEN 1 ELSE 0 END),0) AS excluded_asset_count FROM assets WHERE source=?"
    ).get(source);
    const occurrences = database.prepare(
      "SELECT COUNT(*) AS topic_asset_count, COALESCE(SUM(CASE WHEN a.exposure='exposed' THEN 1 ELSE 0 END),0) AS exposed_topic_asset_count " +
      "FROM topic_assets ta JOIN assets a ON a.asset_id=ta.asset_id WHERE a.source=?"
    ).get(source);
    const declared = manifest.assets.by_source[source];
    if (row.asset_count !== declared.cataloged_count || row.asset_bytes !== declared.total_bytes ||
        row.exposed_asset_count !== declared.exposed_count || row.excluded_asset_count !== declared.excluded_count ||
        occurrences.topic_asset_count !== declared.occurrence_count || occurrences.exposed_topic_asset_count !== declared.exposed_occurrence_count) {
      fail("INVALID_INDEX", `The ${source} asset totals do not match the manifest.`);
    }
  }
}
function verifyDatabase(database, manifest, packageInfo) {
  const applicationId = Number(database.prepare("PRAGMA application_id").get()?.application_id);
  if (applicationId !== DATABASE_APPLICATION_ID) {
    fail("INVALID_INDEX", "The documentation database application ID is invalid.");
  }
  const userVersion = Number(database.prepare("PRAGMA user_version").get()?.user_version);
  if (userVersion !== manifest.schema_version) {
    fail("INVALID_INDEX", "The documentation database schema version does not match the package manifest.");
  }
  const integrityRows = database.prepare("PRAGMA integrity_check(1)").all();
  if (integrityRows.length !== 1 || String(integrityRows[0][Object.keys(integrityRows[0])[0]]).toLowerCase() !== "ok") {
    fail("INVALID_INDEX", "The documentation database failed its integrity check.");
  }
  const objectNames = manifest.schema_version === IMAGE_SCHEMA_VERSION
    ? "'metadata','sources','topics','aliases','sections','topic_links','search_fts','assets','topic_assets'"
    : "'metadata','sources','topics','aliases','sections','topic_links','search_fts'";
  const objects = database.prepare(`SELECT name, type, sql FROM sqlite_master WHERE name IN (${objectNames})`).all();
  const byName = new Map(objects.map((entry) => [entry.name, entry]));
  for (const table of Object.keys(COMMON_EXPECTED_COLUMNS)) {
    if (!byName.has(table)) fail("INVALID_INDEX", `The ${table} table is missing.`);
    verifyColumns(database, table, COMMON_EXPECTED_COLUMNS[table]);
  }
  if (!byName.has("sources")) fail("INVALID_INDEX", "The sources table is missing.");
  verifyColumns(database, "sources", manifest.schema_version === IMAGE_SCHEMA_VERSION ? IMAGE_SOURCE_COLUMNS : LEGACY_SOURCE_COLUMNS);
  if (manifest.schema_version === IMAGE_SCHEMA_VERSION) {
    for (const [table, columns] of [["assets", ASSET_COLUMNS], ["topic_assets", TOPIC_ASSET_COLUMNS]]) {
      if (!byName.has(table)) fail("INVALID_INDEX", `The ${table} table is missing.`);
      verifyColumns(database, table, columns);
    }
  }
  const ftsSql = String(byName.get("search_fts")?.sql ?? "")
    .toLowerCase()
    .replace(/\s+/gu, " ")
    .replace(/\s*([(),=])\s*/gu, "$1")
    .trim();
  if (ftsSql !== EXPECTED_FTS_SCHEMA) {
    fail("INVALID_INDEX", "The search index schema is invalid.");
  }
  const metadataRows = database.prepare("SELECT key, value FROM metadata").all();
  const metadata = Object.fromEntries(metadataRows.map((row) => [row.key, row.value]));
  const expectedMetadataKeys = manifest.schema_version === IMAGE_SCHEMA_VERSION
    ? [
      "schema_version", "index_contract", "corpus_sha256", "image_policy_sha256", "asset_catalog_sha256", "asset_tree_sha256",
      "total_topic_count", "total_section_count", "topic_link_count", "resolved_topic_link_count", "unresolved_topic_link_count",
      "asset_count", "exposed_asset_count", "excluded_asset_count", "topic_asset_count", "exposed_topic_asset_count", "asset_total_bytes"
    ]
    : [
      "schema_version", "build_timestamp", "indexed_at", "corpus_sha256", "total_topic_count", "total_section_count",
      "topic_link_count", "resolved_topic_link_count", "unresolved_topic_link_count"
    ];
  if (Object.keys(metadata).sort().join("\0") !== expectedMetadataKeys.sort().join("\0")) {
    fail("INVALID_INDEX", "The database metadata contract is invalid.");
  }
  if (
    metadata.schema_version !== String(manifest.schema_version) ||
    metadata.corpus_sha256 !== manifest.corpus_sha256 ||
    metadata.total_topic_count !== String(manifest.total_topic_count) ||
    metadata.total_section_count !== String(manifest.total_section_count) ||
    metadata.topic_link_count !== String(manifest.topic_link_count) ||
    metadata.resolved_topic_link_count !== String(manifest.resolved_topic_link_count) ||
    metadata.unresolved_topic_link_count !== String(manifest.unresolved_topic_link_count)
  ) {
    fail("INVALID_INDEX", "The database metadata does not match the package manifest.");
  }
  if (manifest.schema_version === LEGACY_SCHEMA_VERSION && metadata.build_timestamp !== manifest.build_timestamp) {
    fail("INVALID_INDEX", "The legacy database timestamp does not match the package manifest.");
  }
  if (manifest.schema_version === IMAGE_SCHEMA_VERSION && (
    metadata.index_contract !== manifest.index_contract ||
    metadata.image_policy_sha256 !== manifest.assets.policy_sha256 ||
    metadata.asset_catalog_sha256 !== manifest.assets.catalog_sha256 ||
    metadata.asset_tree_sha256 !== manifest.assets.tree_sha256 ||
    metadata.asset_count !== String(manifest.assets.cataloged_count) ||
    metadata.exposed_asset_count !== String(manifest.assets.exposed_count) ||
    metadata.excluded_asset_count !== String(manifest.assets.excluded_count) ||
    metadata.topic_asset_count !== String(manifest.assets.occurrence_count) ||
    metadata.exposed_topic_asset_count !== String(manifest.assets.exposed_occurrence_count) ||
    metadata.asset_total_bytes !== String(manifest.assets.total_bytes)
  )) fail("INVALID_INDEX", "The schema-3 database metadata does not match the package manifest.");

  const foreignKeyFailures = database.prepare("PRAGMA foreign_key_check").all();
  if (foreignKeyFailures.length !== 0) {
    fail("INVALID_INDEX", "The documentation database failed its foreign-key check.");
  }

  const total = database.prepare("SELECT COUNT(*) AS count FROM topics").get().count;
  if (total !== manifest.total_topic_count) {
    fail("INVALID_INDEX", "The documentation database has an unexpected topic count.");
  }
  const dbSources = database.prepare(
    manifest.schema_version === IMAGE_SCHEMA_VERSION
      ? "SELECT source, chm_filename, chm_sha256, chm_bytes, topic_count, section_count FROM sources ORDER BY source"
      : "SELECT source, chm_filename, chm_sha256, chm_bytes, http_last_modified, http_etag, retrieved_at, topic_count, section_count FROM sources ORDER BY source"
  ).all();
  if (dbSources.length !== SOURCE_NAMES.length) {
    fail("INVALID_INDEX", "The database source table is incomplete.");
  }
  for (const row of dbSources) {
    const expected = SOURCES[row.source];
    const declared = manifest.sources[row.source];
    if (
      !expected || !declared || row.chm_filename !== expected.filename || row.chm_sha256 !== declared.sha256 ||
      row.chm_bytes !== declared.bytes || row.topic_count !== declared.topic_count || row.section_count !== declared.section_count ||
      (manifest.schema_version === LEGACY_SCHEMA_VERSION &&
        (row.http_last_modified !== declared.http_last_modified || row.http_etag !== declared.http_etag || row.retrieved_at !== declared.retrieved_at))
    ) {
      fail("INVALID_INDEX", `The database source ${row.source} is invalid.`);
    }
    const actualCount = database.prepare("SELECT COUNT(*) AS count FROM topics WHERE source = ?").get(row.source).count;
    if (actualCount !== declared.topic_count) {
      fail("INVALID_INDEX", `The ${row.source} database topic count is invalid.`);
    }
    const actualSectionCount = database.prepare(
      "SELECT COUNT(*) AS count FROM sections s JOIN topics t ON t.topic_id=s.topic_id WHERE t.source=?"
    ).get(row.source).count;
    if (actualSectionCount !== declared.section_count) {
      fail("INVALID_INDEX", `The ${row.source} database section count is invalid.`);
    }
  }

  const topicRows = database.prepare(
    "SELECT topic_id, source, internal_path, title, normalized_title, breadcrumb, signature, content, content_length, content_sha256 FROM topics"
  ).all();
  const invalidTopics = hasInvalidTopicContentRows(topicRows) || topicRows.some((row) => {
    const expectedId = expectedTopicId(row.source, row.internal_path);
    const expectedContentHash = createHash("sha256").update(row.content, "utf8").digest("hex");
    return (
      expectedId === null ||
      !TOPIC_ID_PATTERN.test(row.topic_id) ||
      row.topic_id !== expectedId ||
      typeof row.title !== "string" ||
      row.title.length === 0 ||
      typeof row.normalized_title !== "string" ||
      row.normalized_title !== normalizeText(row.title) ||
      typeof row.breadcrumb !== "string" ||
      typeof row.signature !== "string" ||
      row.content_sha256 !== expectedContentHash
    );
  });

  const topicById = new Map(topicRows.map((row) => [row.topic_id, row]));
  const topicByPath = new Map(
    topicRows.map((row) => [`${row.source}\0${row.internal_path.toLowerCase()}`, row.topic_id])
  );
  const sectionCount = database.prepare("SELECT COUNT(*) AS count FROM sections").get().count;
  const sectionRows = database.prepare(
    "SELECT section_id, topic_id, ordinal, heading, start_offset, end_offset, content FROM sections ORDER BY topic_id, ordinal"
  );
  const sectionById = new Map();
  const sectionedTopicIds = new Set();
  let invalidSections = sectionCount !== manifest.total_section_count;
  let partitionTopicId = null;
  let nextOrdinal = 0;
  let nextStartOffset = 0;
  const closePartition = () => {
    if (partitionTopicId !== null && nextStartOffset !== topicById.get(partitionTopicId)?.content_length) {
      invalidSections = true;
    }
  };
  for (const row of sectionRows.iterate()) {
    const topic = topicById.get(row.topic_id);
    if (row.topic_id !== partitionTopicId) {
      closePartition();
      partitionTopicId = row.topic_id;
      nextOrdinal = 0;
      nextStartOffset = 0;
    }
    const expectedSectionId = `${row.topic_id}:s${String(row.ordinal).padStart(3, "0")}`;
    if (
      !topic ||
      !TOPIC_ID_PATTERN.test(row.topic_id) ||
      !SECTION_ID_PATTERN.test(row.section_id) ||
      !Number.isSafeInteger(row.ordinal) ||
      row.ordinal !== nextOrdinal ||
      row.ordinal < 0 ||
      row.ordinal > 999 ||
      row.section_id !== expectedSectionId ||
      !Number.isSafeInteger(row.start_offset) ||
      !Number.isSafeInteger(row.end_offset) ||
      row.start_offset !== nextStartOffset ||
      row.end_offset < row.start_offset ||
      row.end_offset > (topic?.content_length ?? -1) ||
      typeof row.heading !== "string" ||
      typeof row.content !== "string" ||
      topic?.content.slice(row.start_offset, row.end_offset).trimEnd() !== row.content ||
      sectionById.has(row.section_id)
    ) {
      invalidSections = true;
    }
    sectionById.set(row.section_id, { topic_id: row.topic_id, heading: row.heading });
    sectionedTopicIds.add(row.topic_id);
    nextOrdinal = row.ordinal + 1;
    nextStartOffset = row.end_offset;
  }
  closePartition();
  if (sectionedTopicIds.size !== topicRows.length) invalidSections = true;

  const aliasRows = database.prepare(
    "SELECT alias, normalized_alias, topic_id, source_kind FROM aliases"
  );
  const aliasRowsByTopic = new Map();
  let invalidAliases = false;
  for (const row of aliasRows.iterate()) {
    const topic = topicById.get(row.topic_id);
    if (
      !topic ||
      typeof row.alias !== "string" ||
      row.alias.length === 0 ||
      typeof row.normalized_alias !== "string" ||
      row.normalized_alias.length === 0 ||
      row.normalized_alias !== normalizeText(row.alias) ||
      !["html-title", "html-keyword", "help-index"].includes(row.source_kind)
    ) {
      invalidAliases = true;
    }
    if (!aliasRowsByTopic.has(row.topic_id)) aliasRowsByTopic.set(row.topic_id, []);
    aliasRowsByTopic.get(row.topic_id).push(row);
  }
  const expectedAliasText = new Map();
  for (const topic of topicRows) {
    const rows = aliasRowsByTopic.get(topic.topic_id) ?? [];
    rows.sort((left, right) => compareOrdinal(left.normalized_alias, right.normalized_alias));
    if (!rows.some((row) =>
      row.normalized_alias === topic.normalized_title && row.source_kind === "html-title"
    )) invalidAliases = true;
    expectedAliasText.set(topic.topic_id, rows.map((row) => row.alias).join(" | "));
  }

  const ftsCount = database.prepare("SELECT COUNT(*) AS count FROM search_fts").get().count;
  const ftsRows = database.prepare(
    "SELECT f.topic_id, f.section_id, f.source, f.title, f.aliases, f.heading, f.breadcrumb, f.body, " +
    "s.content AS section_content FROM search_fts f LEFT JOIN sections s ON s.section_id=f.section_id"
  );
  const seenFtsSections = new Set();
  let invalidFts = ftsCount !== manifest.total_section_count;
  for (const row of ftsRows.iterate()) {
    const topic = topicById.get(row.topic_id);
    const section = sectionById.get(row.section_id);
    if (
      !topic ||
      !section ||
      section.topic_id !== row.topic_id ||
      seenFtsSections.has(row.section_id) ||
      row.source !== topic.source ||
      row.title !== topic.title ||
      row.aliases !== expectedAliasText.get(row.topic_id) ||
      row.heading !== section.heading ||
      row.breadcrumb !== topic.breadcrumb ||
      row.body !== row.section_content
    ) {
      invalidFts = true;
    }
    seenFtsSections.add(row.section_id);
  }
  if (seenFtsSections.size !== sectionById.size) invalidFts = true;

  const linkCount = database.prepare("SELECT COUNT(*) AS count FROM topic_links").get().count;
  const linkRows = database.prepare(
    "SELECT source_topic_id, ordinal, target_topic_id, target_internal_path, target_fragment, label, relationship, resolution_status FROM topic_links"
  );
  const duplicateLinkKeys = new Set();
  let resolvedLinkCount = 0;
  let unresolvedLinkCount = 0;
  let invalidLinks = linkCount !== manifest.topic_link_count;
  for (const row of linkRows.iterate()) {
    const sourceTopic = topicById.get(row.source_topic_id);
    const pathIsCanonicalHtml = sourceTopic && expectedTopicId(sourceTopic.source, row.target_internal_path) !== null;
    const expectedTargetId = sourceTopic
      ? topicByPath.get(`${sourceTopic.source}\0${String(row.target_internal_path).toLowerCase()}`) ?? null
      : null;
    const duplicateKey = `${row.source_topic_id}\0${String(row.target_internal_path).toLowerCase()}\0${row.target_fragment}`;
    if (
      !sourceTopic ||
      !Number.isSafeInteger(row.ordinal) ||
      row.ordinal < 0 ||
      typeof row.target_internal_path !== "string" ||
      !pathIsCanonicalHtml ||
      typeof row.target_fragment !== "string" ||
      typeof row.label !== "string" ||
      !["inline", "see-also"].includes(row.relationship) ||
      !["resolved", "unresolved"].includes(row.resolution_status) ||
      row.resolution_status === "resolved" && (
        expectedTargetId === null ||
        row.target_topic_id !== expectedTargetId ||
        topicById.get(row.target_topic_id)?.source !== sourceTopic.source
      ) ||
      row.resolution_status === "unresolved" && (
        row.target_topic_id !== null ||
        expectedTargetId !== null
      ) ||
      duplicateLinkKeys.has(duplicateKey)
    ) {
      invalidLinks = true;
    }
    duplicateLinkKeys.add(duplicateKey);
    if (row.resolution_status === "resolved") resolvedLinkCount += 1;
    if (row.resolution_status === "unresolved") unresolvedLinkCount += 1;
  }
  if (
    resolvedLinkCount !== manifest.resolved_topic_link_count ||
    unresolvedLinkCount !== manifest.unresolved_topic_link_count
  ) invalidLinks = true;

  if (invalidTopics || invalidSections || invalidAliases || invalidFts || invalidLinks) {
    fail("INVALID_INDEX", "The documentation database failed relational consistency checks.");
  }
  if (manifest.schema_version === IMAGE_SCHEMA_VERSION) verifyAssetCatalog(database, manifest, packageInfo);
}
async function verifyPackage({ root } = {}) {
  const projectRoot = resolveProjectRoot({ root });
  const pointerCandidate = resolve(projectRoot, ACTIVE_RELATIVE_PATH);
  assertNoReparse(pointerCandidate, "The active revision pointer", "file");
  const pointerPath = assertConfined(projectRoot, pointerCandidate, "The active revision pointer");
  const activePointer = parseActivePointer(pointerPath);
  const revisionCandidate = resolve(projectRoot, "revisions", activePointer.active_revision);
  assertNoReparse(revisionCandidate, "The active revision directory", "directory");
  const revisionRoot = assertConfined(
    projectRoot,
    revisionCandidate,
    "The active revision directory"
  );
  const manifestCandidate = resolve(revisionRoot, "manifest.json");
  assertNoReparse(manifestCandidate, "The revision manifest", "file");
  const manifestPath = assertConfined(projectRoot, manifestCandidate, "The revision manifest");
  const manifest = parseManifest(manifestPath, activePointer.active_revision, activePointer.schema_version);
  for (const [source, expected] of Object.entries(SOURCES)) {
    const chmCandidate = resolve(revisionRoot, expected.filename);
    assertNoReparse(chmCandidate, `${source} CHM`, "file");
    const chmPath = assertConfined(projectRoot, chmCandidate, `${source} CHM`);
    const actualHash = await sha256File(chmPath);
    if (actualHash !== manifest.sources[source].sha256 || statSync(chmPath).size !== manifest.sources[source].bytes) {
      fail("CHM_HASH_MISMATCH", `The ${source} CHM does not match the approved SHA-256 hash.`);
    }
  }
  const databaseCandidate = resolve(revisionRoot, DATABASE_FILENAME);
  assertNoReparse(databaseCandidate, "The documentation database", "file");
  const databasePath = assertConfined(
    projectRoot,
    databaseCandidate,
    "The documentation database"
  );
  if (statSync(databasePath).size !== manifest.database.bytes) {
    fail("DATABASE_HASH_MISMATCH", "The documentation database size does not match the manifest.");
  }
  const databaseHash = await sha256File(databasePath);
  if (databaseHash !== manifest.database.sha256) {
    fail("DATABASE_HASH_MISMATCH", "The documentation database SHA-256 does not match the manifest.");
  }
  return { projectRoot, pointerPath, activePointer, revisionRoot, manifestPath, databasePath, databaseHash, manifest };
}
function readUpdateStatus(projectRoot, activeIndexRevision, activeCorpusRevision) {
  try {
    const pathname = resolve(projectRoot, UPDATE_STATUS_RELATIVE_PATH);
    const info = statSync(pathname);
    if (!info.isFile()) return null;
    const safePath = assertConfined(projectRoot, pathname, "The update status");
    const status = readJsonFile(safePath, "The update status", 32 * 1024, "INVALID_UPDATE_STATUS");
    if (status.schema_version === 1) {
      requireExactKeys(
        status,
        ["schema_version", "checked_at", "status", "active_revision", "candidate_revision", "message"],
        "The update status",
        "INVALID_UPDATE_STATUS"
      );
    } else if (status.schema_version === 2) {
      requireExactKeys(
        status,
        ["schema_version", "checked_at", "status", "active_revision", "active_corpus_revision", "candidate_revision", "candidate_corpus_revision", "message"],
        "The update status",
        "INVALID_UPDATE_STATUS"
      );
    } else fail("INVALID_UPDATE_STATUS", "The update status schema is unsupported.");
    if (!UPDATE_STATUSES.includes(status.status) ||
        typeof status.active_revision !== "string" || !REVISION_PATTERN.test(status.active_revision) ||
        status.candidate_revision !== null && (typeof status.candidate_revision !== "string" || !REVISION_PATTERN.test(status.candidate_revision)) ||
        typeof status.message !== "string" || status.message.length < 1 || status.message.length > 500 || /[\u0000-\u001f\u007f]/u.test(status.message)) {
      fail("INVALID_UPDATE_STATUS", "The update status is invalid.");
    }
    if (status.schema_version === 2 && (
      typeof status.active_corpus_revision !== "string" || !REVISION_PATTERN.test(status.active_corpus_revision) ||
      status.candidate_corpus_revision !== null && (typeof status.candidate_corpus_revision !== "string" || !REVISION_PATTERN.test(status.candidate_corpus_revision))
    )) fail("INVALID_UPDATE_STATUS", "The update status corpus revisions are invalid.");
    requireIsoTimestamp(status.checked_at, "checked_at", "INVALID_UPDATE_STATUS");
    return status.schema_version === 1
      ? status.active_revision === activeCorpusRevision ? status : null
      : status.active_revision === activeIndexRevision && status.active_corpus_revision === activeCorpusRevision ? status : null;
  } catch {
    // Update status is optional, advisory metadata. Never let it disable the
    // immutable local documentation index when it is missing or malformed.
    return null;
  }
}
function validateSearchInput(input) {
  if (!isRecord(input)) fail("INVALID_ARGUMENT", "Search input must be an object.");
  rejectUnknownInputKeys(input, SEARCH_INPUT_KEYS, "Search input");
  const query = typeof input.query === "string" ? input.query.trim() : "";
  if (query.length < 1 || query.length > 200) {
    fail("INVALID_ARGUMENT", "query must contain 1 to 200 characters.");
  }
  const source = input.source === void 0 ? "all" : input.source;
  if (!SEARCH_SOURCES.includes(source)) {
    fail("INVALID_ARGUMENT", "source must be all, mql5, mql5book, or neuronetworksbook.");
  }
  const limit = input.limit === void 0 ? 3 : input.limit;
  if (!Number.isInteger(limit) || limit < 1 || limit > 8) {
    fail("INVALID_ARGUMENT", "limit must be an integer from 1 to 8.");
  }
  const expand = input.expand === void 0 ? true : input.expand;
  const requireCurrent = input.require_current === void 0 ? false : input.require_current;
  if (typeof expand !== "boolean") fail("INVALID_ARGUMENT", "expand must be a boolean.");
  if (typeof requireCurrent !== "boolean") fail("INVALID_ARGUMENT", "require_current must be a boolean.");
  return { query, source, limit, expand, requireCurrent };
}
function validateBatchInput(input) {
  if (!isRecord(input)) fail("INVALID_ARGUMENT", "Identifier lookup input must be an object.");
  rejectUnknownInputKeys(input, BATCH_INPUT_KEYS, "Identifier lookup input");
  if (!Array.isArray(input.identifiers) || input.identifiers.length < 1 || input.identifiers.length > 16) {
    fail("INVALID_ARGUMENT", "identifiers must contain 1 to 16 names.");
  }
  // Validate the complete request before running even the first search; holes,
  // non-string names and expression/path syntax must never become queries.
  for (const identifier of input.identifiers) {
    if (typeof identifier !== "string" || !BATCH_IDENTIFIER_PATTERN.test(identifier)) {
      fail("INVALID_ARGUMENT", "Each identifier must be an ASCII name of 1 to 128 characters.");
    }
  }
  const source = input.source === undefined ? "mql5" : input.source;
  const limit = input.limit === undefined ? 1 : input.limit;
  const requireCurrent = input.require_current === undefined ? false : input.require_current;
  if (!SEARCH_SOURCES.includes(source)) fail("INVALID_ARGUMENT", "source must be all, mql5, mql5book, or neuronetworksbook.");
  if (!Number.isInteger(limit) || limit < 1 || limit > 3) fail("INVALID_ARGUMENT", "limit must be an integer from 1 to 3 per identifier.");
  if (typeof requireCurrent !== "boolean") fail("INVALID_ARGUMENT", "require_current must be a boolean.");
  return { identifiers: [...input.identifiers], source, limit, requireCurrent };
}
function validateReadInput(input) {
  if (!isRecord(input)) fail("INVALID_ARGUMENT", "Read input must be an object.");
  rejectUnknownInputKeys(input, READ_INPUT_KEYS, "Read input");
  if (typeof input.topic_id !== "string" || !TOPIC_ID_PATTERN.test(input.topic_id)) {
    fail("INVALID_ARGUMENT", "topic_id is not a valid stable MQL5 CHM topic ID.");
  }
  if (input.section_id !== void 0) {
    if (typeof input.section_id !== "string" || !SECTION_ID_PATTERN.test(input.section_id)) {
      fail("INVALID_ARGUMENT", "section_id is not a valid stable MQL5 CHM section ID.");
    }
    if (!input.section_id.startsWith(`${input.topic_id}:`)) {
      fail("INVALID_ARGUMENT", "section_id does not belong to topic_id.");
    }
  }
  let focus;
  if (input.focus !== void 0) {
    focus = typeof input.focus === "string" ? input.focus.trim() : "";
    if (focus.length < 1 || focus.length > 200) {
      fail("INVALID_ARGUMENT", "focus must contain 1 to 200 characters.");
    }
  }
  if (input.cursor !== void 0 && (typeof input.cursor !== "string" || input.cursor.length < 10 || input.cursor.length > 2048)) {
    fail("INVALID_ARGUMENT", "cursor is invalid.");
  }
  if (input.cursor && focus) {
    fail("INVALID_ARGUMENT", "focus cannot be combined with a continuation cursor.");
  }
  if (input.image_cursor !== void 0 && (typeof input.image_cursor !== "string" || input.image_cursor.length < 10 || input.image_cursor.length > 2048)) {
    fail("INVALID_ARGUMENT", "image_cursor is invalid.");
  }
  if (input.image_cursor && (input.cursor || focus)) {
    fail("INVALID_ARGUMENT", "image_cursor cannot be combined with cursor or focus.");
  }
  const maxChars = input.max_chars === void 0 ? 4e3 : input.max_chars;
  if (!Number.isInteger(maxChars) || maxChars < 500 || maxChars > 8e3) {
    fail("INVALID_ARGUMENT", "max_chars must be an integer from 500 to 8000.");
  }
  const includeRelated = input.include_related === void 0 ? true : input.include_related;
  const relatedLimit = input.related_limit === void 0 ? 3 : input.related_limit;
  if (typeof includeRelated !== "boolean") fail("INVALID_ARGUMENT", "include_related must be a boolean.");
  if (!Number.isInteger(relatedLimit) || relatedLimit < 0 || relatedLimit > 5) {
    fail("INVALID_ARGUMENT", "related_limit must be an integer from 0 to 5.");
  }
  const includeImages = input.include_images === void 0 ? true : input.include_images;
  const imageLimit = input.image_limit === void 0 ? 5 : input.image_limit;
  if (typeof includeImages !== "boolean") fail("INVALID_ARGUMENT", "include_images must be a boolean.");
  if (!Number.isInteger(imageLimit) || imageLimit < 1 || imageLimit > 8) {
    fail("INVALID_ARGUMENT", "image_limit must be an integer from 1 to 8.");
  }
  if (input.image_cursor && !includeImages) fail("INVALID_ARGUMENT", "image_cursor requires include_images=true.");
  return {
    topicId: input.topic_id,
    sectionId: input.section_id,
    focus,
    cursor: input.cursor,
    maxChars,
    includeRelated,
    relatedLimit,
    includeImages,
    imageLimit,
    imageCursor: input.image_cursor
  };
}
function validateReadImageInput(input) {
  if (!isRecord(input) || Object.keys(input).length !== 1 || typeof input.asset_id !== "string" || !ASSET_ID_PATTERN.test(input.asset_id)) {
    fail("INVALID_ARGUMENT", "asset_id must be one stable MQL5 CHM asset ID and no other arguments are accepted.");
  }
  return input.asset_id;
}
function cursorTag(body) {
  return createHmac("sha256", CURSOR_HMAC_KEY).update(CURSOR_DOMAIN).update(body).digest("hex").slice(0, 24);
}
function encodeCursor({ indexRevision, topicId, sectionId = null, offset }) {
  if (!REVISION_PATTERN.test(indexRevision) || !TOPIC_ID_PATTERN.test(topicId)) {
    fail("INVALID_CURSOR", "Cannot encode an invalid topic cursor.");
  }
  if (sectionId !== null && (!SECTION_ID_PATTERN.test(sectionId) || !sectionId.startsWith(`${topicId}:`))) {
    fail("INVALID_CURSOR", "Cannot encode an invalid section cursor.");
  }
  if (!Number.isSafeInteger(offset) || offset < 0) fail("INVALID_CURSOR", "Cannot encode an invalid offset.");
  const body = Buffer.from(JSON.stringify({ v: 2, i: indexRevision, t: topicId, s: sectionId, o: offset }), "utf8").toString(
    "base64url"
  );
  return `${body}.${cursorTag(body)}`;
}
function decodeCursor(cursor) {
  if (typeof cursor !== "string" || cursor.length < 10 || cursor.length > 2048) {
    fail("INVALID_CURSOR", "The continuation cursor is invalid.");
  }
  const parts = cursor.split(".");
  if (parts.length !== 2 || !/^[A-Za-z0-9_-]+$/.test(parts[0]) || !/^[0-9a-f]{24}$/.test(parts[1])) {
    fail("INVALID_CURSOR", "The continuation cursor is invalid.");
  }
  const expected = Buffer.from(cursorTag(parts[0]), "ascii");
  const actual = Buffer.from(parts[1], "ascii");
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
    fail("INVALID_CURSOR", "The continuation cursor failed validation.");
  }
  let payload;
  try {
    const decoded = Buffer.from(parts[0], "base64url");
    if (decoded.toString("base64url") !== parts[0]) fail("INVALID_CURSOR", "The cursor encoding is invalid.");
    payload = JSON.parse(decoded.toString("utf8"));
  } catch (error51) {
    if (error51 instanceof Mql5ChmError) throw error51;
    fail("INVALID_CURSOR", "The continuation cursor payload is invalid.", { cause: error51 });
  }
  if (!isRecord(payload)) {
    fail("INVALID_CURSOR", "The continuation cursor payload is invalid.");
  }
  requireExactKeys(payload, ["v", "i", "t", "s", "o"], "The continuation cursor payload", "INVALID_CURSOR");
  if (payload.v !== 2 || typeof payload.i !== "string" || !REVISION_PATTERN.test(payload.i) || typeof payload.t !== "string" || !TOPIC_ID_PATTERN.test(payload.t) || payload.s !== null && (typeof payload.s !== "string" || !SECTION_ID_PATTERN.test(payload.s) || !payload.s.startsWith(`${payload.t}:`)) || !Number.isSafeInteger(payload.o) || payload.o < 0) {
    fail("INVALID_CURSOR", "The continuation cursor payload is invalid.");
  }
  return { indexRevision: payload.i, topicId: payload.t, sectionId: payload.s, offset: payload.o };
}
function imageCursorTag(body) {
  return createHmac("sha256", CURSOR_HMAC_KEY).update(IMAGE_CURSOR_DOMAIN).update(body).digest("hex").slice(0, 24);
}
function encodeImageCursor({ indexRevision, topicId, sectionId = null, offset }) {
  if (!REVISION_PATTERN.test(indexRevision) || !TOPIC_ID_PATTERN.test(topicId) ||
      sectionId !== null && (!SECTION_ID_PATTERN.test(sectionId) || !sectionId.startsWith(`${topicId}:`)) ||
      !Number.isSafeInteger(offset) || offset < 0) {
    fail("INVALID_IMAGE_CURSOR", "Cannot encode invalid image continuation state.");
  }
  const body = Buffer.from(JSON.stringify({ v: 1, i: indexRevision, t: topicId, s: sectionId, o: offset }), "utf8").toString("base64url");
  return `${body}.${imageCursorTag(body)}`;
}
function decodeImageCursor(cursor) {
  if (typeof cursor !== "string" || cursor.length < 10 || cursor.length > 2048) fail("INVALID_IMAGE_CURSOR", "The image cursor is invalid.");
  const parts = cursor.split(".");
  if (parts.length !== 2 || !/^[A-Za-z0-9_-]+$/.test(parts[0]) || !/^[0-9a-f]{24}$/.test(parts[1])) {
    fail("INVALID_IMAGE_CURSOR", "The image cursor is invalid.");
  }
  const expected = Buffer.from(imageCursorTag(parts[0]), "ascii");
  const actual = Buffer.from(parts[1], "ascii");
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) fail("INVALID_IMAGE_CURSOR", "The image cursor failed validation.");
  let payload;
  try {
    const decoded = Buffer.from(parts[0], "base64url");
    if (decoded.toString("base64url") !== parts[0]) throw new Error("non-canonical encoding");
    payload = JSON.parse(decoded.toString("utf8"));
  } catch (error) {
    fail("INVALID_IMAGE_CURSOR", "The image cursor payload is invalid.", { cause: error });
  }
  if (!isRecord(payload)) fail("INVALID_IMAGE_CURSOR", "The image cursor payload is invalid.");
  requireExactKeys(payload, ["v", "i", "t", "s", "o"], "The image cursor payload", "INVALID_IMAGE_CURSOR");
  if (payload.v !== 1 || typeof payload.i !== "string" || !REVISION_PATTERN.test(payload.i) ||
      typeof payload.t !== "string" || !TOPIC_ID_PATTERN.test(payload.t) ||
      payload.s !== null && (typeof payload.s !== "string" || !SECTION_ID_PATTERN.test(payload.s) || !payload.s.startsWith(`${payload.t}:`)) ||
      !Number.isSafeInteger(payload.o) || payload.o < 0) {
    fail("INVALID_IMAGE_CURSOR", "The image cursor payload is invalid.");
  }
  return { indexRevision: payload.i, topicId: payload.t, sectionId: payload.s, offset: payload.o };
}
function makeCitation({ row, sectionId = null, manifest, indexSha256 }) {
  const source = manifest.sources[row.source];
  return {
    source_file: source.filename,
    title: row.title,
    breadcrumb: row.breadcrumb,
    topic_id: row.topic_id,
    section_id: sectionId,
    source_revision: source.sha256,
    corpus_revision: manifest.corpus_sha256,
    index_revision: indexSha256
  };
}
function rowToSearchResult(row, query, suppliedSnippet, matchKind, matchedTerms, manifest, indexSha256) {
  if (!MATCH_KINDS.includes(matchKind)) fail("INTERNAL_ERROR", "The search match kind is invalid.");
  const sectionId = row.section_id ?? null;
  return {
    topic_id: row.topic_id,
    section_id: sectionId,
    source: row.source,
    title: row.title,
    breadcrumb: row.breadcrumb,
    signature: row.signature,
    source_revision: manifest.sources[row.source].sha256,
    match_kind: matchKind,
    matched_terms: [...new Set((matchedTerms ?? []).map((term) => String(term).trim()).filter(Boolean))].slice(0, 12),
    citation: makeCitation({ row, sectionId, manifest, indexSha256 }),
    snippet: makeSnippet(suppliedSnippet ?? row.content, query, 500)
  };
}
function addUnique(results, seenTopics, candidate, limit) {
  if (results.length >= limit || seenTopics.has(candidate.topic_id)) return false;
  seenTopics.add(candidate.topic_id);
  results.push(candidate);
  return true;
}
function fuzzyThreshold(query) {
  const length = normalizeText(query).length;
  return length <= 4 ? 0.48 : length <= 8 ? 0.36 : 0.28;
}
function exactQueryTerms(query) {
  const wholeQuery = normalizeText(query);
  const identifierTerms = (String(query).match(/[\p{L}_][\p{L}\p{N}_]{2,}/gu) ?? []).filter(
    (term) => /[_\d]/u.test(term) || /[\p{Ll}][\p{Lu}]/u.test(term) || term.length >= 3 && term === term.toUpperCase()
  ).map(normalizeText).filter((term) => term && !SEARCH_STOPWORDS.has(term));
  return [...new Set([wholeQuery, ...identifierTerms ?? []].filter(Boolean))].slice(0, 16);
}
function findFocusMatch(text, focus, start = 0, end = text.length) {
  const phrase = String(focus ?? "").trim();
  if (!phrase) return { index: -1, kind: "none" };
  const escape = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = phrase.split(/\s+/u).map(escape).join("\\s+");
  const findWithin = (pattern) => {
    const expression = new RegExp(pattern, "giu");
    expression.lastIndex = start;
    const match = expression.exec(text);
    return match && match.index + match[0].length <= end ? match : null;
  };
  const exact = findWithin("(?<![\\p{L}\\p{N}_])" + pattern + "(?![\\p{L}\\p{N}_])");
  if (exact) return { index: exact.index, kind: "exact" };
  const terms = ftsTokens(phrase).sort((a, b) => b.length - a.length);
  for (const term of terms) {
    const match = findWithin("(?<![\\p{L}\\p{N}_])" + escape(term) + "(?![\\p{L}\\p{N}_])");
    if (match) return { index: match.index, kind: "approximate" };
  }
  for (const term of [phrase, ...terms]) {
    const match = findWithin(escape(term));
    if (match) return { index: match.index, kind: "approximate" };
  }
  return { index: -1, kind: "none" };
}
function locateFocusOffset(text, focus, maxChars) {
  if (!focus || text.length <= maxChars) return 0;
  const at = findFocusMatch(text, focus).index;
  return at < 0 ? 0 : safeUtf16Boundary(text, Math.max(0, at - Math.floor(maxChars * 0.2)));
}
function boundedEnd(text, start, maximum) {
  const hardEnd = Math.min(text.length, start + maximum);
  if (hardEnd === text.length) return hardEnd;
  const minimumEnd = start + Math.floor(maximum * 0.72);
  const window = text.slice(minimumEnd, hardEnd);
  const newline = window.lastIndexOf("\n");
  if (newline >= 0) return safeUtf16Boundary(text, minimumEnd + newline + 1);
  const whitespace = Math.max(window.lastIndexOf(". "), window.lastIndexOf(" "));
  return safeUtf16Boundary(text, whitespace >= 0 ? minimumEnd + whitespace + 1 : hardEnd);
}
function splitsSurrogatePair(text, offset) {
  if (offset <= 0 || offset >= text.length) return false;
  const before = text.charCodeAt(offset - 1);
  const after = text.charCodeAt(offset);
  return before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff;
}
function safeUtf16Boundary(text, offset) {
  return splitsSurrogatePair(text, offset) ? offset - 1 : offset;
}
var Mql5ChmSearchService = class {
  constructor(database, packageInfo) {
    this.database = database;
    this.projectRoot = packageInfo.projectRoot;
    this.indexSha256 = packageInfo.databaseHash;
    this.manifest = packageInfo.manifest;
    this.activePointer = packageInfo.activePointer;
    this.revisionRoot = packageInfo.revisionRoot;
    this.assetSupportAvailable = packageInfo.manifest.schema_version === IMAGE_SCHEMA_VERSION;
    this.closed = false;
  }
  #assertOpen() {
    if (this.closed) fail("SERVICE_CLOSED", "The documentation search service is closed.");
  }
  #corpusExpansionTerms(seedTerms) {
    const normalizedSeeds = [...new Set(seedTerms.map(normalizeText).filter(Boolean))].slice(0, 16);
    if (normalizedSeeds.length === 0) return [];
    const seedTopicIds = [];
    const findSeeds = this.database.prepare(
      "SELECT t.topic_id FROM topics t WHERE t.normalized_title=? OR EXISTS " +
      "(SELECT 1 FROM aliases a WHERE a.topic_id=t.topic_id AND a.normalized_alias=?) " +
      "ORDER BY CASE WHEN t.normalized_title=? THEN 0 ELSE 1 END, " +
      "CASE t.source WHEN 'mql5' THEN 0 WHEN 'mql5book' THEN 1 ELSE 2 END, t.topic_id LIMIT 4"
    );
    for (const seed of normalizedSeeds) {
      for (const row of findSeeds.all(seed, seed, seed)) seedTopicIds.push(row.topic_id);
    }
    const uniqueTopicIds = [...new Set(seedTopicIds)].slice(0, 32);
    if (uniqueTopicIds.length === 0) return [];
    const placeholders = uniqueTopicIds.map(() => "?").join(",");
    const aliasRows = this.database.prepare(
      `SELECT alias FROM aliases WHERE topic_id IN (${placeholders}) ORDER BY normalized_alias, topic_id LIMIT 32`
    ).all(...uniqueTopicIds);
    const linkRows = this.database.prepare(
      `SELECT t.title, l.label, l.relationship, l.ordinal FROM topic_links l ` +
      `JOIN topics t ON t.topic_id=l.target_topic_id WHERE l.source_topic_id IN (${placeholders}) ` +
      "AND l.resolution_status='resolved' AND l.target_topic_id IS NOT NULL " +
      "ORDER BY CASE l.relationship WHEN 'see-also' THEN 0 ELSE 1 END, l.ordinal, t.topic_id LIMIT 32"
    ).all(...uniqueTopicIds);
    const candidates = [
      ...aliasRows.map((row) => row.alias),
      ...linkRows.flatMap((row) => [row.title, row.label])
    ];
    const terms = [];
    const seen = new Set(normalizedSeeds);
    for (const candidate of candidates) {
      const term = String(candidate ?? "").trim();
      const normalized = normalizeText(term);
      if (term.length < 2 || term.length > 100 || !normalized || seen.has(normalized)) continue;
      seen.add(normalized);
      terms.push(term);
      if (terms.length >= 12) break;
    }
    return terms;
  }
  search(input) {
    this.#assertOpen();
    const { query, source, limit, expand, requireCurrent } = validateSearchInput(input);
    const normalizedQuery = normalizeText(query);
    const sourceClause = source === "all" ? "" : " AND t.source = ?";
    const sourceArgs = source === "all" ? [] : [source];
    const fetchLimit = Math.max(limit * 5, 24);
    const results = [];
    const seenTopics = new Set();
    const addRows = (rows, matchKind, matchedTerms, snippetField = null, resultLimit = limit) => {
      for (const row of rows) {
        const snippet = snippetField ? row[snippetField] : undefined;
        addUnique(
          results,
          seenTopics,
          rowToSearchResult(row, query, snippet, matchKind, matchedTerms, this.manifest, this.indexSha256),
          resultLimit
        );
      }
    };

    if (normalizedQuery) {
      const exactStatement = this.database.prepare(
        "SELECT t.topic_id, NULL AS section_id, t.source, t.title, t.breadcrumb, t.signature, t.content, " +
        "CASE WHEN t.normalized_title = ? THEN 0 ELSE 1 END AS exact_kind FROM topics t " +
        "WHERE (t.normalized_title = ? OR EXISTS (SELECT 1 FROM aliases a WHERE a.topic_id=t.topic_id AND a.normalized_alias=?))" +
        sourceClause +
        " ORDER BY exact_kind, CASE t.source WHEN 'mql5' THEN 0 WHEN 'mql5book' THEN 1 ELSE 2 END, length(t.breadcrumb), t.topic_id LIMIT ?"
      );
      for (const exactTerm of exactQueryTerms(query)) {
        const rows = exactStatement.all(exactTerm, exactTerm, exactTerm, ...sourceArgs, fetchLimit);
        addRows(rows, "exact", [exactTerm]);
        if (results.length >= limit) break;
      }
    }

    const originalTerms = ftsTokens(query);
    const originalFts = buildFtsQuery(query);
    let originalRows = [];
    if (results.length < limit && originalFts) {
      originalRows = this.database.prepare(
        "SELECT t.topic_id, f.section_id, t.source, t.title, t.breadcrumb, t.signature, t.content, " +
        "snippet(search_fts, 7, '', '', ' … ', 64) AS matched_text, " +
        "bm25(search_fts, 0.0, 0.0, 0.0, 10.0, 9.0, 7.0, 4.0, 1.0) AS rank " +
        "FROM search_fts f JOIN topics t ON t.topic_id=f.topic_id WHERE search_fts MATCH ?" +
        sourceClause +
        " ORDER BY rank - CASE t.source WHEN 'mql5' THEN 0.35 WHEN 'mql5book' THEN 0.15 ELSE 0.0 END, t.topic_id LIMIT ?"
      ).all(originalFts, ...sourceArgs, fetchLimit);
    }

    const mappedExpansionTerms = getExpandedTerms(query, expand);
    const corpusExpansionTerms = expand ? this.#corpusExpansionTerms([query, ...mappedExpansionTerms]) : [];
    const expandedTerms = [...new Set([...mappedExpansionTerms, ...corpusExpansionTerms])].slice(0, 16);
    const expandedCandidates = [];
    if (results.length < limit && expandedTerms.length) {
      const expandedExactStatement = this.database.prepare(
        "SELECT t.topic_id, NULL AS section_id, t.source, t.title, t.breadcrumb, t.signature, t.content, t.content AS matched_text, 0.0 AS rank " +
        "FROM topics t WHERE (t.normalized_title=? OR EXISTS (SELECT 1 FROM aliases a WHERE a.topic_id=t.topic_id AND a.normalized_alias=?))" +
        sourceClause +
        " ORDER BY CASE WHEN t.normalized_title=? THEN 0 ELSE 1 END, " +
        "CASE t.source WHEN 'mql5' THEN 0 WHEN 'mql5book' THEN 1 ELSE 2 END, t.topic_id LIMIT ?"
      );
      const statement = this.database.prepare(
        "SELECT t.topic_id, f.section_id, t.source, t.title, t.breadcrumb, t.signature, t.content, " +
        "snippet(search_fts, 7, '', '', ' … ', 64) AS matched_text, " +
        "bm25(search_fts, 0.0, 0.0, 0.0, 8.0, 7.0, 5.0, 3.0, 1.0) AS rank " +
        "FROM search_fts f JOIN topics t ON t.topic_id=f.topic_id WHERE search_fts MATCH ?" +
        sourceClause +
        " ORDER BY rank, CASE t.source WHEN 'mql5' THEN 0 WHEN 'mql5book' THEN 1 ELSE 2 END, t.topic_id LIMIT ?"
      );
      for (const [termIndex, term] of expandedTerms.entries()) {
        const normalizedTerm = normalizeText(term);
        if (normalizedTerm) {
          const exactRows = expandedExactStatement.all(normalizedTerm, normalizedTerm, ...sourceArgs, normalizedTerm, fetchLimit);
          expandedCandidates.push(...exactRows.map((row) => ({ row, term, priority: 0, termIndex })));
        }
        const expandedFts = buildFtsQuery(term);
        if (!expandedFts) continue;
        const rows = statement.all(expandedFts, ...sourceArgs, fetchLimit);
        expandedCandidates.push(...rows.map((row) => ({ row, term, priority: 1, termIndex })));
      }
      expandedCandidates.sort((left, right) =>
        left.priority - right.priority ||
        left.termIndex - right.termIndex ||
        left.row.rank - right.row.rank ||
        sourcePreference(left.row.source) - sourcePreference(right.row.source) ||
        compareOrdinal(left.row.title, right.row.title) ||
        compareOrdinal(left.row.topic_id, right.row.topic_id)
      );
    }

    if (results.length < limit) {
      const originalCandidates = [];
      const originalTopics = new Set(seenTopics);
      for (const row of originalRows) {
        if (originalTopics.has(row.topic_id)) continue;
        originalTopics.add(row.topic_id);
        originalCandidates.push(row);
      }
      const uniqueExpandedCandidates = [];
      const expandedTopics = new Set(seenTopics);
      for (const candidate of expandedCandidates) {
        if (expandedTopics.has(candidate.row.topic_id)) continue;
        expandedTopics.add(candidate.row.topic_id);
        uniqueExpandedCandidates.push(candidate);
      }
      const weightedByTopic = new Map();
      for (const [index, row] of originalCandidates.entries()) {
        weightedByTopic.set(row.topic_id, {
          row,
          matchKind: "fts",
          matchedTerms: originalTerms,
          weight: 1 / (index + 1),
          kindPriority: 0,
          index,
        });
      }
      for (const [index, candidate] of uniqueExpandedCandidates.entries()) {
        const expanded = {
          row: candidate.row,
          matchKind: "expanded",
          matchedTerms: [candidate.term],
          weight: EXPANSION_RANK_WEIGHT / (index + 1),
          kindPriority: 1,
          index,
        };
        const existing = weightedByTopic.get(candidate.row.topic_id);
        if (!existing || expanded.weight > existing.weight) weightedByTopic.set(candidate.row.topic_id, expanded);
      }
      const weightedCandidates = [...weightedByTopic.values()].sort((left, right) =>
        right.weight - left.weight ||
        left.kindPriority - right.kindPriority ||
        left.index - right.index ||
        sourcePreference(left.row.source) - sourcePreference(right.row.source) ||
        compareOrdinal(left.row.topic_id, right.row.topic_id)
      );
      for (const candidate of weightedCandidates) {
        addRows([candidate.row], candidate.matchKind, candidate.matchedTerms, "matched_text");
        if (results.length >= limit) break;
      }
    }

    if (results.length < limit && normalizedQuery) {
      const fuzzyRows = this.database.prepare(
        "SELECT t.topic_id, NULL AS section_id, t.source, t.title, t.normalized_title, t.breadcrumb, " +
        "t.signature, COALESCE(group_concat(a.normalized_alias, char(31)), '') AS aliases " +
        "FROM topics t LEFT JOIN aliases a ON a.topic_id=t.topic_id WHERE 1=1" +
        sourceClause +
        " GROUP BY t.topic_id ORDER BY t.topic_id"
      ).all(...sourceArgs);
      const threshold = fuzzyThreshold(query);
      const ranked = fuzzyRows.map((row) => {
        let score = trigramSimilarity(normalizedQuery, row.normalized_title);
        for (const alias of row.aliases.split(String.fromCharCode(31)).filter(Boolean)) {
          score = Math.max(score, trigramSimilarity(normalizedQuery, alias));
        }
        return { row, score };
      }).filter(({ score }) => score >= threshold).sort(
        (left, right) =>
          right.score - left.score ||
          sourcePreference(left.row.source) - sourcePreference(right.row.source) ||
          compareOrdinal(left.row.title, right.row.title) ||
          compareOrdinal(left.row.topic_id, right.row.topic_id)
      );
      const contentStatement = this.database.prepare("SELECT content FROM topics WHERE topic_id=?");
      for (const candidate of ranked) {
        if (results.length >= limit) break;
        if (seenTopics.has(candidate.row.topic_id)) continue;
        const content = contentStatement.get(candidate.row.topic_id)?.content;
        if (typeof content !== "string") fail("INVALID_INDEX", "A fuzzy-search topic is missing its documentation content.");
        addRows([{ ...candidate.row, content }], "fuzzy", [query]);
      }
    }

    const updateStatus = readUpdateStatus(this.projectRoot, this.indexSha256, this.manifest.corpus_sha256);
    let reason = null;
    if (requireCurrent) reason = "current-information-requested";
    else if (results.length === 0) reason = "no-local-match";
    else if (results[0].match_kind === "fuzzy") reason = "fuzzy-only";
    else if (updateStatus?.status === "different-revision-available") reason = "newer-revision-available";
    const safeOnlineQuery = query.replaceAll('"', "");
    const officialSearchQuery = source === "all"
      ? Object.values(SOURCES).map((entry) => `${entry.online_scope} "${safeOnlineQuery}"`).join(" OR ")
      : `${SOURCES[source].online_scope} "${safeOnlineQuery}"`;
    return {
      query,
      source,
      count: results.length,
      index_sha256: this.indexSha256,
      corpus_revision: this.manifest.corpus_sha256,
      online_check: {
        recommended: reason !== null,
        reason,
        official_search_query: reason === null ? null : officialSearchQuery.slice(0, safeUtf16Boundary(officialSearchQuery, 500))
      },
      results
    };
  }
  lookupIdentifiers(input) {
    this.#assertOpen();
    const { identifiers, source, limit, requireCurrent } = validateBatchInput(input);
    const lookups = identifiers.map((identifier) => {
      const result = this.search({ query: identifier, source, limit, expand: false, require_current: requireCurrent });
      return {
        identifier,
        match_status: result.results.some((entry) => entry.match_kind === "exact") ? "exact" : result.count ? "non_exact" : "none",
        count: result.count,
        online_check: result.online_check,
        results: result.results,
      };
    });
    return {
      source,
      limit,
      count: lookups.length,
      result_count: lookups.reduce((total, lookup) => total + lookup.count, 0),
      index_sha256: this.indexSha256,
      corpus_revision: this.manifest.corpus_sha256,
      lookups,
    };
  }
  #selectFocusedSection(topicId, focus) {
    const ftsQuery = buildFtsQuery(focus);
    if (ftsQuery) {
      // Topic metadata is repeated on every section; only section text can locate the focus.
      const rows = this.database.prepare(
        "SELECT s.section_id, s.heading, s.start_offset, s.end_offset, s.content, bm25(search_fts, 0.0, 0.0, 0.0, 8.0, 7.0, 10.0, 3.0, 1.0) AS rank FROM search_fts f JOIN sections s ON s.section_id=f.section_id WHERE search_fts MATCH ? AND f.topic_id=? AND f.section_id IS NOT NULL ORDER BY rank, s.ordinal"
      ).all(`{heading body}: (${ftsQuery})`, topicId);
      const exact = rows.find((row) => findFocusMatch(row.content, focus).kind === "exact" || findFocusMatch(row.heading, focus).kind === "exact");
      if (exact) return { ...exact, focus_match: "exact" };
      if (rows.length) return { ...rows[0], focus_match: "approximate" };
    }
    const normalizedFocus = normalizeText(focus);
    if (!normalizedFocus) return null;
    const sections = this.database.prepare(
      "SELECT section_id, heading, start_offset, end_offset, content FROM sections WHERE topic_id=? ORDER BY ordinal"
    ).all(topicId);
    let best = null;
    let bestScore = -1;
    for (const section of sections) {
      const normalizedHeading = normalizeText(section.heading);
      const normalizedBody = normalizeText(section.content);
      const score = (normalizedHeading === normalizedFocus ? 3 : 0) + (normalizedHeading.includes(normalizedFocus) ? 1.5 : 0) + (normalizedBody.includes(normalizedFocus) ? 1 : 0) + trigramSimilarity(normalizedFocus, normalizedHeading);
      if (score > bestScore) {
        bestScore = score;
        best = section;
      }
    }
    return best && bestScore >= fuzzyThreshold(focus) ? { ...best, focus_match: "approximate" } : null;
  }
  #relatedTopics(topic, limit) {
    if (limit <= 0) return [];
    const linked = this.database.prepare(
      "SELECT t.topic_id, t.source, t.title, t.breadcrumb, " +
      "CASE WHEN MIN(CASE l.relationship WHEN 'see-also' THEN 0 ELSE 1 END)=0 THEN 'see-also' ELSE 'inline' END AS relationship, " +
      "MIN(l.ordinal) AS first_ordinal " +
      "FROM topic_links l JOIN topics t ON t.topic_id=l.target_topic_id " +
      "WHERE l.source_topic_id=? AND l.resolution_status='resolved' AND l.target_topic_id IS NOT NULL AND l.target_topic_id<>? " +
      "GROUP BY t.topic_id, t.source, t.title, t.breadcrumb " +
      "ORDER BY MIN(CASE l.relationship WHEN 'see-also' THEN 0 ELSE 1 END), first_ordinal, " +
      "CASE t.source WHEN 'mql5' THEN 0 WHEN 'mql5book' THEN 1 ELSE 2 END, t.topic_id LIMIT ?"
    ).all(topic.topic_id, topic.topic_id, limit);
    const rows = [...linked];
    const seen = new Set(rows.map((row) => row.topic_id));
    if (rows.length < limit) {
      const sameTitle = this.database.prepare(
        "SELECT topic_id, source, title, breadcrumb, 'same-title' AS relationship " +
        "FROM topics WHERE normalized_title=? AND topic_id<>? AND source<>? " +
        "ORDER BY CASE source WHEN 'mql5' THEN 0 WHEN 'mql5book' THEN 1 ELSE 2 END, topic_id LIMIT ?"
      ).all(normalizeText(topic.title), topic.topic_id, topic.source, limit - rows.length);
      for (const row of sameTitle) {
        if (!seen.has(row.topic_id) && rows.length < limit) {
          seen.add(row.topic_id);
          rows.push(row);
        }
      }
    }
    return rows.slice(0, limit).map((row) => ({
      topic_id: row.topic_id,
      source: row.source,
      title: row.title,
      breadcrumb: row.breadcrumb,
      relationship: row.relationship,
      source_revision: this.manifest.sources[row.source].sha256,
      citation: makeCitation({ row, sectionId: null, manifest: this.manifest, indexSha256: this.indexSha256 })
    }));
  }
  #topicImages(topic, sectionId, start, limit) {
    if (!this.assetSupportAvailable) return { images: [], imageCount: 0, nextImageCursor: null };
    const sectionClause = sectionId ? " AND ta.section_id=?" : "";
    const args = sectionId ? [topic.topic_id, sectionId] : [topic.topic_id];
    const rows = this.database.prepare(
      "SELECT ta.asset_id, ta.section_id, ta.occurrence_ordinal, ta.text_offset, ta.contextual_caption, " +
      "a.canonical_caption, a.mime_type, a.byte_count, a.width, a.height, s.ordinal AS section_ordinal " +
      "FROM topic_assets ta JOIN assets a ON a.asset_id=ta.asset_id " +
      "LEFT JOIN sections s ON s.section_id=ta.section_id AND s.topic_id=ta.topic_id " +
      "WHERE ta.topic_id=? AND a.exposure='exposed'" + sectionClause +
      " ORDER BY COALESCE(s.ordinal,2147483647), ta.text_offset, ta.occurrence_ordinal, ta.asset_id"
    ).all(...args);
    const deduplicated = [];
    const byAsset = new Map();
    for (const row of rows) {
      const existing = byAsset.get(row.asset_id);
      if (existing) {
        existing.occurrence_count += 1;
        continue;
      }
      const reference = {
        asset_id: row.asset_id,
        contextual_caption: row.contextual_caption || row.canonical_caption,
        mime_type: row.mime_type,
        width: row.width,
        height: row.height,
        bytes: row.byte_count,
        section_id: row.section_id,
        occurrence_count: 1,
        citation: makeCitation({ row: topic, sectionId: row.section_id, manifest: this.manifest, indexSha256: this.indexSha256 })
      };
      byAsset.set(row.asset_id, reference);
      deduplicated.push(reference);
    }
    if (!Number.isSafeInteger(start) || start < 0 ||
        (deduplicated.length === 0 ? start !== 0 : start >= deduplicated.length)) {
      fail("INVALID_IMAGE_CURSOR", "The image cursor offset is outside the selected image references.");
    }
    const images = deduplicated.slice(start, start + limit);
    const nextOffset = start + images.length;
    return {
      images,
      imageCount: deduplicated.length,
      nextImageCursor: nextOffset < deduplicated.length
        ? encodeImageCursor({ indexRevision: this.indexSha256, topicId: topic.topic_id, sectionId, offset: nextOffset })
        : null
    };
  }
  read(input) {
    this.#assertOpen();
    const { topicId, sectionId, focus, cursor, maxChars, includeRelated, relatedLimit, includeImages, imageLimit, imageCursor } = validateReadInput(input);
    let continuation = null;
    let imageContinuation = null;
    if (imageCursor) {
      if (!this.assetSupportAvailable) fail("ASSET_CATALOG_UNAVAILABLE", "This verified revision does not contain an image catalog.");
      imageContinuation = decodeImageCursor(imageCursor);
      if (imageContinuation.indexRevision !== this.indexSha256) fail("INVALID_IMAGE_CURSOR", "The image cursor belongs to a different index revision.");
      if (imageContinuation.topicId !== topicId) fail("INVALID_IMAGE_CURSOR", "The image cursor belongs to a different topic.");
      if (sectionId && imageContinuation.sectionId !== sectionId) fail("INVALID_IMAGE_CURSOR", "The image cursor belongs to a different section.");
    } else if (cursor) {
      continuation = decodeCursor(cursor);
      if (continuation.indexRevision !== this.indexSha256) {
        fail("INVALID_CURSOR", "The continuation cursor belongs to a different index revision.");
      }
      if (continuation.topicId !== topicId) {
        fail("INVALID_CURSOR", "The continuation cursor belongs to a different topic.");
      }
      if (sectionId && continuation.sectionId !== sectionId) {
        fail("INVALID_CURSOR", "The continuation cursor belongs to a different section.");
      }
    }
    const topic = this.database.prepare("SELECT topic_id, source, title, breadcrumb, signature, content, content_length FROM topics WHERE topic_id=?").get(topicId);
    if (!topic) fail("TOPIC_NOT_FOUND", "No documentation topic exists for topic_id.");
    let selectedSectionId = sectionId ?? null;
    let selectedText = topic.content;
    let selectedHeading = null;
    let selectedFocusKind = null;
    let focusMatch = null;
    let topicBaseOffset = 0;
    let offset = 0;
    let imageStart = 0;
    if (imageCursor) {
      selectedSectionId = imageContinuation.sectionId;
      imageStart = imageContinuation.offset;
    } else if (cursor) {
      selectedSectionId = continuation.sectionId;
      offset = continuation.offset;
    } else if (!sectionId && focus) {
      const focused = this.#selectFocusedSection(topicId, focus);
      if (focused) {
        selectedSectionId = focused.section_id;
        selectedFocusKind = focused.focus_match;
      }
    }
    if (selectedSectionId) {
      const section = this.database.prepare(
        "SELECT section_id, heading, start_offset, end_offset, content FROM sections WHERE section_id=? AND topic_id=?"
      ).get(selectedSectionId, topicId);
      if (!section) fail("SECTION_NOT_FOUND", "No documentation section exists for section_id and topic_id.");
      selectedText = section.content;
      selectedHeading = section.heading;
      topicBaseOffset = section.start_offset;
    }
    if (!cursor && !imageCursor && focus) {
      offset = locateFocusOffset(selectedText, focus, maxChars);
    }
    if (offset < 0 || offset >= selectedText.length + (selectedText.length === 0 ? 1 : 0)) {
      fail("INVALID_CURSOR", "The continuation cursor offset is outside the selected documentation text.");
    }
    if (splitsSurrogatePair(selectedText, offset)) {
      fail("INVALID_CURSOR", "The continuation cursor offset splits a UTF-16 surrogate pair.");
    }
    const end = imageCursor ? offset : boundedEnd(selectedText, offset, maxChars);
    const text = imageCursor ? "" : selectedText.slice(offset, end);
    if (!cursor && !imageCursor && focus) {
      // Keep original token boundaries while requiring the full match inside this passage.
      const match = findFocusMatch(selectedText, focus, offset, end);
      focusMatch = match.kind === "exact" ? "exact" : match.kind === "approximate" || selectedFocusKind ? "approximate" : "none";
    }
    const nextCursor = !imageCursor && end < selectedText.length ? encodeCursor({ indexRevision: this.indexSha256, topicId, sectionId: selectedSectionId, offset: end }) : null;
    const imagePage = includeImages
      ? this.#topicImages(topic, selectedSectionId, imageStart, imageLimit)
      : { images: [], imageCount: 0, nextImageCursor: null };
    return {
      topic_id: topic.topic_id,
      section_id: selectedSectionId,
      source: topic.source,
      title: topic.title,
      breadcrumb: topic.breadcrumb,
      signature: topic.signature,
      source_revision: this.manifest.sources[topic.source].sha256,
      corpus_revision: this.manifest.corpus_sha256,
      section_heading: selectedHeading,
      focus_match: focusMatch,
      start_offset: offset,
      end_offset: end,
      topic_start_offset: topicBaseOffset + offset,
      topic_end_offset: topicBaseOffset + end,
      total_chars: selectedText.length,
      returned_chars: text.length,
      index_sha256: this.indexSha256,
      citation: makeCitation({
        row: topic,
        sectionId: selectedSectionId,
        manifest: this.manifest,
        indexSha256: this.indexSha256
      }),
      related: !imageCursor && includeRelated ? this.#relatedTopics(topic, relatedLimit) : [],
      next_cursor: nextCursor,
      images: imagePage.images,
      image_count: imagePage.imageCount,
      next_image_cursor: imagePage.nextImageCursor,
      image_continuation: Boolean(imageCursor),
      text
    };
  }
  readImage(input) {
    this.#assertOpen();
    const assetId = validateReadImageInput(input);
    if (!this.assetSupportAvailable) fail("ASSET_CATALOG_UNAVAILABLE", "This verified revision does not contain an image catalog.");
    const row = this.database.prepare(
      "SELECT asset_id, source, internal_path, storage_key, mime_type, sha256, byte_count, width, height, exposure, exposure_reason, canonical_caption " +
      "FROM assets WHERE asset_id=? AND exposure='exposed' AND mime_type IN ('image/png','image/jpeg')"
    ).get(assetId);
    if (!row) fail("ASSET_NOT_AVAILABLE", "The requested technical image is not available.");
    let bytes;
    let handle;
    try {
      const storage = ASSET_STORAGE_PATTERN.exec(row.storage_key);
      if (!storage || storage[1] !== row.source) throw new Error("Invalid asset storage key.");
      const candidate = resolve(this.revisionRoot, ...row.storage_key.split("/"));
      assertNoReparse(candidate, "The requested immutable asset", "file");
      const pathname = assertConfined(this.projectRoot, candidate, "The requested immutable asset");
      handle = openSync(pathname, "r");
      const info = fstatSync(handle);
      if (!info.isFile() || info.size < 1 || info.size > MAX_IMAGE_BYTES || info.size !== row.byte_count) {
        throw new Error("Invalid asset file metadata.");
      }
      bytes = Buffer.allocUnsafe(info.size);
      let offset = 0;
      while (offset < bytes.length) {
        const count = readSync(handle, bytes, offset, bytes.length - offset, offset);
        if (count <= 0) throw new Error("Asset file ended before its declared size.");
        offset += count;
      }
      if (fstatSync(handle).size !== row.byte_count) throw new Error("Asset file size changed during validation.");
      const digest = createHash("sha256").update(bytes).digest("hex");
      const inspected = inspectCatalogRasterImage(bytes, row, digest);
      assertRasterBounds(bytes.length, inspected.width, inspected.height);
      if (digest !== row.sha256 || inspected.mime !== row.mime_type || inspected.width !== row.width || inspected.height !== row.height) {
        throw new Error("Asset bytes do not match the catalog.");
      }
    } catch (error) {
      fail("ASSET_INTEGRITY_FAILED", "The requested technical image failed integrity validation.", { cause: error });
    } finally {
      if (handle !== void 0) {
        try { closeSync(handle); } catch { /* Integrity validation already determines the public result. */ }
      }
    }
    const primary = this.database.prepare(
      "SELECT t.topic_id, t.source, t.title, t.breadcrumb, ta.section_id " +
      "FROM topic_assets ta JOIN topics t ON t.topic_id=ta.topic_id WHERE ta.asset_id=? " +
      "ORDER BY CASE t.source WHEN 'mql5' THEN 0 WHEN 'mql5book' THEN 1 ELSE 2 END, t.topic_id, ta.occurrence_ordinal LIMIT 1"
    ).get(assetId);
    const associationCount = this.database.prepare("SELECT COUNT(*) AS count FROM topic_assets WHERE asset_id=?").get(assetId).count;
    if (!primary || associationCount < 1) fail("ASSET_INTEGRITY_FAILED", "The requested technical image failed integrity validation.");
    return {
      data: bytes.toString("base64"),
      metadata: {
        asset_id: row.asset_id,
        source: row.source,
        canonical_caption: row.canonical_caption,
        mime_type: row.mime_type,
        bytes: row.byte_count,
        width: row.width,
        height: row.height,
        sha256: row.sha256,
        association_count: associationCount,
        primary_topic_citation: makeCitation({ row: primary, sectionId: primary.section_id, manifest: this.manifest, indexSha256: this.indexSha256 }),
        source_revision: this.manifest.sources[row.source].sha256,
        corpus_revision: this.manifest.corpus_sha256,
        index_revision: this.indexSha256
      }
    };
  }
  status() {
    this.#assertOpen();
    const manifest = this.manifest;
    const sources = SOURCE_NAMES.map((source) => {
      const assetSummary = manifest.assets?.by_source?.[source];
      return {
        source,
        filename: manifest.sources[source].filename,
        sha256: manifest.sources[source].sha256,
        bytes: manifest.sources[source].bytes,
        http_last_modified: manifest.sources[source].http_last_modified,
        http_etag: manifest.sources[source].http_etag,
        retrieved_at: manifest.sources[source].retrieved_at,
        topic_count: manifest.sources[source].topic_count,
        section_count: manifest.sources[source].section_count,
        asset_count: assetSummary?.cataloged_count ?? 0,
        exposed_asset_count: assetSummary?.exposed_count ?? 0,
        excluded_asset_count: assetSummary?.excluded_count ?? 0,
        asset_occurrence_count: assetSummary?.occurrence_count ?? 0,
        exposed_asset_occurrence_count: assetSummary?.exposed_occurrence_count ?? 0,
        asset_bytes: assetSummary?.total_bytes ?? 0
      };
    });
    const assetStatus = {
      available: this.assetSupportAvailable,
      cataloged: manifest.assets?.cataloged_count ?? 0,
      exposed: manifest.assets?.exposed_count ?? 0,
      excluded: manifest.assets?.excluded_count ?? 0,
      occurrences: manifest.assets?.occurrence_count ?? 0,
      exposed_occurrences: manifest.assets?.exposed_occurrence_count ?? 0,
      bytes: manifest.assets?.total_bytes ?? 0,
      by_source: Object.fromEntries(sources.map((source) => [source.source, {
        cataloged: source.asset_count,
        exposed: source.exposed_asset_count,
        excluded: source.excluded_asset_count,
        occurrences: source.asset_occurrence_count,
        exposed_occurrences: source.exposed_asset_occurrence_count,
        bytes: source.asset_bytes
      }]))
    };
    return {
      schema_version: manifest.schema_version,
      active_revision: this.activePointer.active_revision,
      index_revision: this.indexSha256,
      previous_revision: this.activePointer.previous_revision,
      activated_at: this.activePointer.activated_at,
      corpus_revision: manifest.corpus_sha256,
      index_sha256: this.indexSha256,
      indexed_at: manifest.indexed_at,
      build_timestamp: manifest.build_timestamp,
      totals: {
        topics: manifest.total_topic_count,
        sections: manifest.total_section_count,
        topic_links: manifest.topic_link_count,
        resolved_topic_links: manifest.resolved_topic_link_count,
        unresolved_topic_links: manifest.unresolved_topic_link_count
      },
      asset_support_available: this.assetSupportAvailable,
      assets: assetStatus,
      sources,
      update_check: readUpdateStatus(this.projectRoot, this.indexSha256, manifest.corpus_sha256)
    };
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    this.database.close();
  }
};
async function createSearchService(options = {}) {
  const projectRoot = resolveProjectRoot(options);
  const packageInfo = await verifyPackage({ root: projectRoot });
  let database;
  try {
    database = new DatabaseSync(packageInfo.databasePath, {
      open: true,
      readOnly: true,
      allowExtension: false,
      enableForeignKeyConstraints: true
    });
    database.enableLoadExtension(false);
    database.enableDefensive(true);
    verifyDatabase(database, packageInfo.manifest, packageInfo);
    const closingHash = await sha256File(packageInfo.databasePath);
    if (closingHash !== packageInfo.databaseHash) {
      fail("DATABASE_HASH_MISMATCH", "The documentation database changed during startup validation.");
    }
    return new Mql5ChmSearchService(database, packageInfo);
  } catch (error51) {
    try {
      database?.close();
    } catch {
    }
    if (error51 instanceof Mql5ChmError) throw error51;
    fail("INVALID_INDEX", "The documentation database could not be opened safely.", { cause: error51 });
  }
}

export {
  Mql5ChmError,
  Mql5ChmSearchService,
  buildFtsQuery,
  createSearchService,
  decodeCursor,
  decodeImageCursor,
  encodeCursor,
  encodeImageCursor,
  ftsTokens,
  inspectRasterImage,
  makeRuntimeAssetId,
  makeSnippet,
  normalizeText,
  resolveProjectRoot,
  sha256File,
  trigramSimilarity,
  verifyPackage,
};
