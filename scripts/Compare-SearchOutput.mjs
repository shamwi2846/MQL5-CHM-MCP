// Development check: complete search, batch-lookup, read and image output of the
// working tree must equal a pinned baseline release on the same verified corpus.
// Used to prove that performance work changes no results.
//
//   node scripts/Compare-SearchOutput.mjs [--root <package-or-checkout>] [--baseline <commit>] [--quick]
//
// --root defaults to this checkout (its data/ and revisions/ corpus fixture).
// The baseline's src/ and config/ are extracted once with `git archive` into
// build/search-baseline-<commit>/ (git-ignored) and resolve dependencies from
// this checkout's node_modules. Move the default baseline only when a release
// intentionally changes results.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync } from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath, pathToFileURL } from "node:url";

const DEFAULT_BASELINE = "1df81db2ef5739dc0df13f7c550b2dd2057a78e2"; // v1.3.13
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const options = { root: repository, baseline: DEFAULT_BASELINE, quick: false };
for (let i = 2; i < process.argv.length; i++) {
  const key = process.argv[i];
  if (key === "--quick") options.quick = true;
  else if (key === "--root" || key === "--baseline") {
    const value = process.argv[++i];
    if (!value || value.startsWith("--")) throw new Error(`${key} requires a value`);
    options[key.slice(2)] = value;
  } else throw new Error(`Unknown argument ${key}`);
}

const commit = execFileSync("git", ["-C", repository, "rev-parse", "--verify", `${options.baseline}^{commit}`], { encoding: "utf8" }).trim();
const baselineRoot = path.join(repository, "build", `search-baseline-${commit}`);
if (!existsSync(path.join(baselineRoot, "src", "search-service.mjs"))) {
  const staging = `${baselineRoot}.partial`;
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(staging, { recursive: true });
  const archive = execFileSync("git", ["-C", repository, "archive", "--format=tar", commit, "src", "config"], { maxBuffer: 64 * 1024 * 1024 });
  execFileSync("tar", ["-x", "-C", staging], { input: archive });
  renameSync(staging, baselineRoot);
}

const root = path.resolve(options.root);
const base = await import(pathToFileURL(path.join(baselineRoot, "src", "search-service.mjs")).href);
const next = await import(pathToFileURL(path.join(repository, "src", "search-service.mjs")).href);
const a = await base.createSearchService({ root });
const b = await next.createSearchService({ root });

const pointer = JSON.parse(readFileSync(path.join(root, "data", "active.json"), "utf8"));
const db = new DatabaseSync(path.join(root, "revisions", pointer.active_revision, "mql5-docs.sqlite"), { readOnly: true });
const titles = db.prepare("SELECT DISTINCT title AS v FROM topics ORDER BY v").all().map((r) => r.v);
const aliases = db.prepare("SELECT DISTINCT alias AS v FROM aliases ORDER BY v").all().map((r) => r.v);
const topics = db.prepare("SELECT topic_id, title FROM topics ORDER BY topic_id").all();
const assets = db.prepare("SELECT asset_id FROM assets WHERE exposure='exposed' AND mime_type IN ('image/png','image/jpeg') ORDER BY asset_id").all().map((r) => r.asset_id);
db.close();
const names = [...new Set([...titles, ...aliases])].filter((v) => v.length >= 1 && v.length <= 200);
const every = (list, step) => list.filter((_, i) => i % step === 0);
const typos = every(names.filter((v) => /^[A-Za-z_][A-Za-z0-9_]{4,}$/u.test(v)), options.quick ? 40 : 8).map((v) => v.slice(0, 2) + v.slice(3));
const concepts = ["trailing stop", "order send request", "position close by ticket", "indicator buffer copy", "moving average handle",
  "pending order expiration", "symbol info tick", "account margin free", "history deals select", "trade transaction event",
  "custom indicator drawing", "chart object create", "file write csv", "timer event", "array sort", "string to double",
  "neural network layer", "gradient descent", "OpenCL kernel", "strategy tester optimization", "OnTester custom criterion",
  "magic number", "deviation slippage", "filling mode", "stop level freeze level", "tick value", "lot step", "error 4756"];

// Continuation cursors are authenticated with a per-service random key, so their
// values differ between any two services by design; compare whether each cursor
// is present (and its type), and everything else exactly.
const cursorShape = (cursor) => cursor === null ? null : typeof cursor === "string" && cursor.length > 0 ? "<cursor>" : `<invalid ${typeof cursor}>`;
const withoutCursors = (value) => value && typeof value === "object"
  ? { ...value, next_cursor: cursorShape(value.next_cursor), next_image_cursor: cursorShape(value.next_image_cursor) }
  : value;
let checked = 0, mismatches = 0;
const timing = { base: 0, next: 0 };
const compare = (label, fn, expectError = false) => {
  let ra, rb, ea = null, eb = null;
  let t = performance.now();
  try { ra = fn(a); } catch (error) { ea = `${error.code}:${error.message}`; }
  timing.base += performance.now() - t; t = performance.now();
  try { rb = fn(b); } catch (error) { eb = `${error.code}:${error.message}`; }
  timing.next += performance.now() - t;
  checked++;
  // Valid inputs must succeed on both sides; only explicit bad-input cases may throw.
  if ((ea !== null || eb !== null) !== expectError || ea !== eb || JSON.stringify(ra) !== JSON.stringify(rb)) {
    mismatches++;
    if (mismatches <= 10) console.log("MISMATCH", label, ea, eb);
  }
};
const plans = [
  ["mql5 l1 noexp", every(names, options.quick ? 10 : 1), { source: "mql5", limit: 1, expand: false }],
  ["all l1 noexp", every(names, options.quick ? 20 : 2), { source: "all", limit: 1, expand: false }],
  ["mql5 l3 exp", every(names, options.quick ? 200 : 25), { source: "mql5", limit: 3 }],
  ["all l5 exp", every(names, options.quick ? 400 : 60), { source: "all", limit: 5 }],
  ["book l2 exp", every(names, options.quick ? 400 : 80), { source: "mql5book", limit: 2 }],
  ["nn l2 exp", every(names, options.quick ? 400 : 80), { source: "neuronetworksbook", limit: 2 }],
  ["typo mql5 l3", typos, { source: "mql5", limit: 3 }],
  ["typo all l2 noexp", typos, { source: "all", limit: 2, expand: false }],
  ["concept mql5 l5", concepts, { source: "mql5", limit: 5 }],
  ["concept all l8", concepts, { source: "all", limit: 8 }],
  ["concept nn l5", concepts, { source: "neuronetworksbook", limit: 5 }],
];
for (const [label, queries, searchOptions] of plans) {
  const before = checked;
  for (const query of queries) compare(`${label} ${query}`, (svc) => svc.search({ query, ...searchOptions }));
  console.log(`${label}: ${checked - before} queries`);
}
const ids = every(names.filter((v) => /^[A-Za-z_][A-Za-z0-9_]{0,127}$/u.test(v)), options.quick ? 10 : 1);
for (let i = 0; i < ids.length; i += 16) {
  const batch = ids.slice(i, i + 16);
  compare(`batch ${i}`, (svc) => svc.lookupIdentifiers({ identifiers: batch, source: "mql5", limit: 1 }));
  if (i % 64 === 0) compare(`batch-all ${i}`, (svc) => svc.lookupIdentifiers({ identifiers: batch, source: "all", limit: 3 }));
}
const readTopics = every(topics, options.quick ? 50 : 5);
for (const topic of readTopics) {
  compare(`read ${topic.topic_id}`, (svc) => withoutCursors(svc.read({ topic_id: topic.topic_id })));
  compare(`read-focus ${topic.topic_id}`, (svc) => withoutCursors(svc.read({ topic_id: topic.topic_id, focus: topic.title, include_related: false, include_images: false })));
}
console.log(`read: ${readTopics.length * 2} reads`);
const images = every(assets, options.quick ? 50 : 10);
for (const assetId of images) compare(`image ${assetId}`, (svc) => svc.readImage({ asset_id: assetId }));
console.log(`images: ${images.length} reads`);
compare("bad input", (svc) => svc.search({ query: "", source: "mql5" }), true);
compare("bad limit", (svc) => svc.search({ query: "OrderSend", source: "all", limit: 10 }), true);
console.log(`baseline ${commit.slice(0, 12)}: checked ${checked}, mismatches ${mismatches}, baseline ${(timing.base / 1000).toFixed(1)} s, working tree ${(timing.next / 1000).toFixed(1)} s`);
a.close(); b.close();
process.exitCode = mismatches ? 1 : 0;
