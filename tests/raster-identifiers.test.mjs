import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import { deflateSync } from "node:zlib";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { buildIndex, inspectRasterAsset } from "../src/indexer.mjs";
import { createSearchService, inspectRasterImage } from "../src/search-service.mjs";
import { buildFixture } from "./helpers/runtime-fixture.mjs";

// Independently specified 1x1 RGBA pixels and GIF LZW codes (clear=4, pixel=0, end=5).
// CRCs cover the raw bytes, including deliberately invalid chunk identifiers.
function chunk(name, data = Buffer.alloc(0)) {
  const type = Buffer.from(name);
  assert.equal(type.length, 4);
  const result = Buffer.alloc(data.length + 12);
  result.writeUInt32BE(data.length); type.copy(result, 4); data.copy(result, 8);
  let crc = 0xffffffff;
  for (const byte of result.subarray(4, data.length + 8)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  result.writeUInt32BE((crc ^ 0xffffffff) >>> 0, data.length + 8);
  return result;
}

function png(change = null) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(1); header.writeUInt32BE(1, 4); header[8] = 8; header[9] = 6;
  const namedChunk = (name, data) => chunk(change?.name === name ? change.bytes : Buffer.from(name, "ascii"), data);
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), namedChunk("IHDR", header),
    namedChunk("tEXt", Buffer.from("Description\0Technical diagram", "ascii")),
    namedChunk("IDAT", deflateSync(Buffer.from([0, 255, 0, 0, 255]))), namedChunk("IEND"),
  ]);
}

function highBits(bytes, mask) {
  const changed = Buffer.from(bytes);
  for (let i = 0; i < changed.length; i += 1) if (mask & (1 << i)) changed[i] |= 0x80;
  return changed;
}
const gif89 = Buffer.from("47494638396101000100800000000000ffffff2c00000000010001000002024401003b", "hex");
const gif87 = Buffer.from(gif89); gif87.write("GIF87a", 0, "ascii");
const malformedPng = () => png({ name: "IHDR", bytes: highBits(Buffer.from("IHDR"), 15) });

test("image identifiers: valid PNG and exact GIF87a/GIF89a controls remain accepted", () => {
  assert.equal(inspectRasterAsset(png(), "diagram.png").mimeType, "image/png");
  assert.deepEqual(inspectRasterImage(png()), { mime: "image/png", width: 1, height: 1 });
  for (const bytes of [gif87, gif89]) {
    assert.equal(inspectRasterAsset(bytes, "diagram.gif").mimeType, "image/gif");
    assert.deepEqual(inspectRasterImage(bytes), { mime: "image/gif", width: 1, height: 1 });
  }
});

for (const name of ["IHDR", "tEXt", "IDAT", "IEND"]) {
  test(`image identifiers: PNG ${name} rejects every high-bit combination despite correct CRC`, () => {
    for (let mask = 1; mask < 16; mask += 1) {
      const bytes = png({ name, bytes: highBits(Buffer.from(name), mask) });
      assert.throws(() => inspectRasterAsset(bytes, "diagram.png"), /PNG.*chunk type/i, `indexer ${name} mask ${mask}`);
      assert.throws(() => inspectRasterImage(bytes), /PNG.*chunk type/i, `runtime ${name} mask ${mask}`);
    }
  });
}

test("image identifiers: PNG nonletters, reserved lowercase bit, and truncated names remain rejected", () => {
  for (const name of ["1HDR", "IH R", "IHdR", "IH\0R"]) {
    const bytes = png({ name: "IHDR", bytes: Buffer.from(name) });
    assert.throws(() => inspectRasterAsset(bytes, "diagram.png"), /PNG/i);
    assert.throws(() => inspectRasterImage(bytes), /PNG/i);
  }
  for (const length of [12, 13, 14, 15]) {
    assert.throws(() => inspectRasterAsset(png().subarray(0, length), "diagram.png"), /PNG/i);
    assert.throws(() => inspectRasterImage(png().subarray(0, length)), /PNG/i);
  }
});

for (const control of [gif87, gif89]) {
  test(`image identifiers: ${control.subarray(0, 6).toString("latin1")} rejects every high-bit header combination`, () => {
    for (let mask = 1; mask < 64; mask += 1) {
      const bytes = Buffer.from(control); highBits(control.subarray(0, 6), mask).copy(bytes);
      assert.throws(() => inspectRasterAsset(bytes, "diagram.gif"), /GIF|raster/i, `indexer mask ${mask}`);
      assert.throws(() => inspectRasterImage(bytes), /GIF|raster/i, `runtime mask ${mask}`);
    }
  });
}

test("image identifiers: truncated and unsupported GIF headers remain rejected", () => {
  for (const length of [0, 3, 5, 6, 12]) {
    assert.throws(() => inspectRasterAsset(gif89.subarray(0, length), "diagram.gif"), /GIF|raster/i);
    assert.throws(() => inspectRasterImage(gif89.subarray(0, length)), /GIF|raster/i);
  }
  const invalid = Buffer.from(gif89); invalid.write("GIF90a", 0, "ascii");
  assert.throws(() => inspectRasterAsset(invalid, "diagram.gif"), /GIF|raster/i);
  assert.throws(() => inspectRasterImage(invalid), /GIF|raster/i);
});

test("image identifiers: indexing refuses invalid PNG chunk names and preserves its prior output", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-identifiers-index-"));
  try {
    await mkdir(path.join(root, "config"));
    await writeFile(path.join(root, "config", "mql5-image-policy.json"), await readFile(new URL("../config/mql5-image-policy.json", import.meta.url)));
    const sources = [];
    for (const id of ["mql5", "mql5book", "neuronetworksbook"]) {
      const bytes = Buffer.from(`fixture-${id}`);
      await mkdir(path.join(root, "sources"), { recursive: true });
      await writeFile(path.join(root, "sources", `${id}.chm`), bytes);
      await mkdir(path.join(root, "extracted", id), { recursive: true });
      await writeFile(path.join(root, "extracted", id, "topic.htm"), `<div id="help"><h1>${id}</h1>${id === "mql5" ? '<img src="diagram.png" alt="Technical diagram">' : ''}</div>`);
      sources.push({ id, filename: `${id}.chm`, sha256: createHash("sha256").update(bytes).digest("hex"), expected_topics: 1 });
    }
    await writeFile(path.join(root, "corpus.lock.json"), JSON.stringify({ schema_version: 1, expected_total_topics: 3, sources }));
    const image = path.join(root, "extracted", "mql5", "diagram.png");
    const options = { sourceDirectory: "sources", extractedDirectory: "extracted", outputDirectory: "output" };
    await writeFile(image, png()); await buildIndex(root, options);
    const before = await readFile(path.join(root, "output", "mql5-docs.sqlite"));
    for (const name of ["IHDR", "tEXt", "IDAT", "IEND"]) {
      await writeFile(image, png({ name, bytes: highBits(Buffer.from(name), 15) }));
      await assert.rejects(buildIndex(root, options), /PNG.*chunk type/i);
      assert.deepEqual(await readFile(path.join(root, "output", "mql5-docs.sqlite")), before);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

async function replaceAsset(fixture, bytes) {
  const revision = path.join(fixture.root, "revisions", fixture.databaseHash);
  await writeFile(path.join(revision, ...fixture.assets[0].storageKey.split("/")), bytes);
  const database = new DatabaseSync(path.join(revision, "mql5-docs.sqlite"));
  try { database.prepare("UPDATE assets SET sha256=?,byte_count=? WHERE asset_id=?").run(
    createHash("sha256").update(bytes).digest("hex"), bytes.length, fixture.assets[0].assetId); }
  finally { database.close(); }
}

test("image identifiers: runtime startup and per-call checks reject checksum-matching malformed PNG names", async () => {
  const bad = await buildFixture({ pngBytes: malformedPng() });
  try {
    await assert.rejects(async () => { const unexpected = await createSearchService({ root: bad.root }); unexpected.close(); }, error =>
      error.code === "INVALID_INDEX" && /PNG.*chunk type/i.test(error.cause?.message));
  } finally { await rm(bad.root, { recursive: true, force: true }); }
  const fixture = await buildFixture({ pngBytes: png() }); let service;
  try {
    service = await createSearchService({ root: fixture.root });
    assert.deepEqual(Buffer.from(service.readImage({ asset_id: fixture.assets[0].assetId }).data, "base64"), png());
    await replaceAsset(fixture, malformedPng());
    assert.throws(() => service.readImage({ asset_id: fixture.assets[0].assetId }), error =>
      error.code === "ASSET_INTEGRITY_FAILED" && /PNG.*chunk type/i.test(error.cause?.message));
  } finally { service?.close(); await rm(fixture.root, { recursive: true, force: true }); }
});

test("image identifiers: bundled MCP image retrieval refuses malformed raw PNG names", { timeout: 30000 }, async () => {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const server = process.env.MQL5_CHM_TEST_SERVER ?? path.join(root, "build", "candidate-v12", "app", "server.mjs");
  const fixture = await buildFixture({ pngBytes: png() });
  const bootstrap = `import {main} from ${JSON.stringify(pathToFileURL(server).href)}; await main({root:${JSON.stringify(fixture.root)}});`;
  const transport = new StdioClientTransport({ command: process.env.MQL5_CHM_TEST_NODE ?? process.execPath,
    args: ["--input-type=module", "--eval", bootstrap], cwd: fixture.root, stderr: "pipe" });
  const client = new Client({ name: "raster-identifier-regression", version: "1.0.0" });
  try {
    await client.connect(transport);
    const valid = await client.callTool({ name: "mql5_chm_read_image", arguments: { asset_id: fixture.assets[0].assetId } });
    assert.notEqual(valid.isError, true);
    assert.deepEqual(Buffer.from(valid.content[0].data, "base64"), png());
    await replaceAsset(fixture, malformedPng());
    const rejected = await client.callTool({ name: "mql5_chm_read_image", arguments: { asset_id: fixture.assets[0].assetId } });
    assert.equal(rejected.isError, true);
    assert.equal(rejected.content.some(item => item.type === "image"), false);
    assert.match(JSON.stringify(rejected), /ASSET_INTEGRITY_FAILED/);
  } finally { await client.close(); await rm(fixture.root, { recursive: true, force: true }); }
});
