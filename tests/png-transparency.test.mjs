import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { deflateSync } from "node:zlib";
import { DatabaseSync } from "node:sqlite";
import { buildIndex, inspectRasterAsset } from "../src/indexer.mjs";
import { createSearchService, inspectRasterImage } from "../src/search-service.mjs";
import { buildFixture } from "./helpers/runtime-fixture.mjs";

// Fixture CRCs and pixel bytes are constructed independently of the validators.
function chunk(type, data = Buffer.alloc(0)) {
  const bytes = Buffer.alloc(data.length + 12);
  bytes.writeUInt32BE(data.length); bytes.write(type, 4, 4, "ascii"); data.copy(bytes, 8);
  let crc = 0xffffffff;
  for (const byte of bytes.subarray(4, data.length + 8)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  bytes.writeUInt32BE((crc ^ 0xffffffff) >>> 0, data.length + 8);
  return bytes;
}

function png({ color = 3, depth = 8, alpha = Buffer.from([0]), palette = color === 3,
  entries = 2, placement = "before-data", duplicate = false, interlace = 0 } = {}) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(1); header.writeUInt32BE(1, 4);
  header[8] = depth; header[9] = color; header[12] = interlace;
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[color];
  const data = chunk("IDAT", deflateSync(Buffer.alloc(1 + Math.ceil(channels * depth / 8))));
  const table = palette ? [chunk("PLTE", Buffer.alloc(entries * 3))] : [];
  const transparency = alpha === null ? [] : [chunk("tRNS", alpha), ...(duplicate ? [chunk("tRNS", alpha)] : [])];
  const middle = placement === "before-palette" ? [...transparency, ...table, data]
    : placement === "after-data" ? [...table, data, ...transparency] : [...table, ...transparency, data];
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk("IHDR", header), ...middle, chunk("IEND")]);
}

function accepted(bytes) {
  assert.equal(inspectRasterAsset(bytes, "diagram.png").mimeType, "image/png");
  assert.deepEqual(inspectRasterImage(bytes), { mime: "image/png", width: 1, height: 1 });
}
function rejected(bytes) {
  assert.throws(() => inspectRasterAsset(bytes, "diagram.png"), /PNG.*transparency/i);
  assert.throws(() => inspectRasterImage(bytes), /PNG.*transparency/i);
}

for (const depth of [1,2,4,8]) for (const interlace of [0,1]) {
  test(`indexed transparency ${depth}-bit interlace ${interlace}: absent, shorter and full tables`, () => {
    for (const alpha of [null, Buffer.alloc(0), Buffer.from([0]), Buffer.from([0,255])]) {
      accepted(png({ depth, interlace, alpha }));
    }
    rejected(png({ depth, interlace, alpha: Buffer.from([0,255,128]) }));
  });
}
for (const depth of [1,2,4,8,16]) {
  test(`grayscale ${depth}-bit transparency requires exactly two bytes`, () => {
    accepted(png({ color:0, depth, alpha:Buffer.from([255,255]) }));
    for (const length of [0,1,3]) rejected(png({ color:0, depth, alpha:Buffer.alloc(length) }));
  });
}
for (const depth of [8,16]) {
  test(`truecolor ${depth}-bit transparency requires exactly six bytes`, () => {
    accepted(png({ color:2, depth, alpha:Buffer.alloc(6,255) }));
    accepted(png({ color:2, depth, palette:true, alpha:Buffer.alloc(6) }));
    for (const length of [0,2,5,7]) rejected(png({ color:2, depth, alpha:Buffer.alloc(length) }));
    for (const color of [4,6]) rejected(png({ color, depth, alpha:Buffer.alloc(6) }));
  });
}
test("transparency chunks cannot repeat or follow data or precede an optional/required palette", () => {
  for (const color of [0,2,3]) {
    const alpha = Buffer.alloc({0:2,2:6,3:1}[color]);
    rejected(png({ color, alpha, duplicate:true }));
    rejected(png({ color, alpha, placement:"after-data" }));
    if (color !== 0) rejected(png({ color, alpha, palette:true, placement:"before-palette" }));
  }
});

test("runtime startup and per-call retrieval reject checksum-matching malformed transparency", async () => {
  const invalid = png({ alpha:Buffer.alloc(3) });
  const bad = await buildFixture({ pngBytes:invalid });
  try {
    await assert.rejects(async () => { const unexpected = await createSearchService({ root:bad.root }); unexpected.close(); }, error =>
      error.code === "INVALID_INDEX" && /PNG.*transparency/i.test(error.cause?.message));
  } finally { await rm(bad.root,{recursive:true,force:true}); }
  const valid = png(); const fixture = await buildFixture({ pngBytes:valid }); let service;
  try {
    service = await createSearchService({ root:fixture.root });
    assert.deepEqual(Buffer.from(service.readImage({asset_id:fixture.assets[0].assetId}).data,"base64"),valid);
    const revision = path.join(fixture.root,"revisions",fixture.databaseHash);
    await writeFile(path.join(revision,...fixture.assets[0].storageKey.split("/")),invalid);
    const db = new DatabaseSync(path.join(revision,"mql5-docs.sqlite"));
    try { db.prepare("UPDATE assets SET sha256=?,byte_count=? WHERE asset_id=?").run(
      createHash("sha256").update(invalid).digest("hex"),invalid.length,fixture.assets[0].assetId); }
    finally { db.close(); }
    assert.throws(() => service.readImage({asset_id:fixture.assets[0].assetId}), error =>
      error.code === "ASSET_INTEGRITY_FAILED" && /PNG.*transparency/i.test(error.cause?.message));
  } finally { service?.close(); await rm(fixture.root,{recursive:true,force:true}); }
});

test("indexing rejects malformed transparency while preserving its previous database", async () => {
  const root = await mkdtemp(path.join(tmpdir(),"mql5-transparency-index-"));
  try {
    await mkdir(path.join(root,"config"));
    await writeFile(path.join(root,"config","mql5-image-policy.json"),await readFile(new URL("../config/mql5-image-policy.json",import.meta.url)));
    const sources = [];
    for (const id of ["mql5","mql5book","neuronetworksbook"]) {
      const bytes = Buffer.from(`fixture-${id}`);
      await mkdir(path.join(root,"sources"),{recursive:true}); await writeFile(path.join(root,"sources",`${id}.chm`),bytes);
      await mkdir(path.join(root,"extracted",id),{recursive:true});
      await writeFile(path.join(root,"extracted",id,"topic.htm"),`<div id="help"><h1>${id}</h1>${id==="mql5"?'<img src="diagram.png" alt="Technical diagram">':''}</div>`);
      sources.push({id,filename:`${id}.chm`,sha256:createHash("sha256").update(bytes).digest("hex"),expected_topics:1});
    }
    await writeFile(path.join(root,"corpus.lock.json"),JSON.stringify({schema_version:1,expected_total_topics:3,sources}));
    const image = path.join(root,"extracted","mql5","diagram.png");
    const options = {sourceDirectory:"sources",extractedDirectory:"extracted",outputDirectory:"output"};
    await writeFile(image,png()); await buildIndex(root,options);
    const before = await readFile(path.join(root,"output","mql5-docs.sqlite"));
    await writeFile(image,png({alpha:Buffer.alloc(3)}));
    await assert.rejects(buildIndex(root,options),/PNG.*transparency/i);
    assert.deepEqual(await readFile(path.join(root,"output","mql5-docs.sqlite")),before);
  } finally { await rm(root,{recursive:true,force:true}); }
});
