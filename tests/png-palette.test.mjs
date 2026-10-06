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

function chunk(type, data = Buffer.alloc(0)) {
  const result = Buffer.alloc(data.length + 12);
  result.writeUInt32BE(data.length);
  result.write(type, 4, 4, "ascii");
  data.copy(result, 8);
  let crc = 0xffffffff;
  for (const byte of result.subarray(4, data.length + 8)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  result.writeUInt32BE((crc ^ 0xffffffff) >>> 0, data.length + 8);
  return result;
}

function indexedPng({ width, height, bitDepth, raw, paletteEntries, interlace = 0, transparent = false }) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = bitDepth;
  header[9] = 3;
  header[12] = interlace;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header),
    chunk("PLTE", Buffer.alloc(paletteEntries * 3)),
    ...(transparent ? [chunk("tRNS", Buffer.alloc(paletteEntries))] : []),
    chunk("IDAT", deflateSync(Buffer.from(raw))), chunk("IEND"),
  ]);
}

// Fixed bytes calculated from the PNG filter definitions, not from the helper.
// The two decoded rows are identical. Packed rows contain nonzero padding bits.
const vectors = [
  { depth: 1, width: 9, palette: 2, rows: [[85,127],[85,42],[85,127],[85,85],[85,42]], second: [[85,127],[85,42],[0,0],[43,21],[0,0]] },
  { depth: 2, width: 5, palette: 3, rows: [[25,63],[25,38],[25,63],[25,51],[25,38]], second: [[25,63],[25,38],[0,0],[13,19],[0,0]] },
  { depth: 4, width: 3, palette: 3, rows: [[1,47],[1,46],[1,47],[1,47],[1,46]], second: [[1,47],[1,46],[0,0],[1,23],[0,0]] },
  { depth: 8, width: 3, palette: 3, rows: [[0,1,2],[0,1,1],[0,1,2],[0,1,2],[0,1,1]], second: [[0,1,2],[0,1,1],[0,0,0],[0,1,1],[0,0,0]] },
];

function checkBoth(bytes, valid, dimensions) {
  if (valid) {
    assert.deepEqual(inspectRasterImage(bytes), { mime: "image/png", ...dimensions });
    const result = inspectRasterAsset(bytes, "fixture.png");
    assert.equal(result.width, dimensions.width);
    assert.equal(result.height, dimensions.height);
  } else {
    assert.throws(() => inspectRasterImage(bytes), /pixel index.*palette/i);
    assert.throws(() => inspectRasterAsset(bytes, "fixture.png"), /pixel index.*palette/i);
  }
}

for (const v of vectors) for (let filter = 0; filter <= 4; filter += 1) {
  test(`indexed ${v.depth}-bit filter ${filter}: fixed valid rows, padding and invalid last sample`, () => {
    const config = { width: v.width, height: 2, bitDepth: v.depth, raw: [filter,...v.rows[filter],filter,...v.second[filter]] };
    checkBoth(indexedPng({ ...config, paletteEntries: v.palette }), true, { width: v.width, height: 2 });
    checkBoth(indexedPng({ ...config, paletteEntries: v.palette, transparent: true }), true, { width: v.width, height: 2 });
    checkBoth(indexedPng({ ...config, paletteEntries: v.palette - 1, transparent: true }), false);
    const value = 1 << (8 - v.depth);
    checkBoth(indexedPng({ width: 1, height: 2, bitDepth: v.depth, paletteEntries: 1, raw: [filter,0,filter,value] }), false);
  });
}

for (const depth of [1,2,4,8]) for (let filter = 0; filter <= 4; filter += 1) {
  test(`Adam7 ${depth}-bit filter ${filter}: all passes, row resets and empty passes`, () => {
    const fill = { 1:255, 2:85, 4:17, 8:1 }[depth];
    const raw = [];
    // Every decoded pixel is index 1. This encoder only describes this fixed
    // uniform image; it does not implement or reuse a general PNG filter.
    for (const [x,y,dx,dy] of [[0,0,8,8],[4,0,8,8],[0,4,4,8],[2,0,4,4],[0,2,2,4],[1,0,2,2],[0,1,1,2]]) {
      const width = Math.ceil((9-x)/dx), height = Math.ceil((9-y)/dy);
      const bytes = Math.ceil(width*depth/8);
      for (let row = 0; row < height; row += 1) {
        raw.push(filter);
        for (let column = 0; column < bytes; column += 1) {
          let residual = fill;
          if (filter === 1) residual = column ? 0 : fill;
          else if (filter === 2) residual = row ? 0 : fill;
          else if (filter === 3) residual = (!row && !column) ? fill : (row && column) ? 0 : fill-Math.floor(fill/2);
          else if (filter === 4) residual = row || column ? 0 : fill;
          raw.push(residual);
        }
      }
    }
    checkBoth(indexedPng({ width:9,height:9,bitDepth:depth,interlace:1,paletteEntries:2,raw }), true, { width:9,height:9 });
    checkBoth(indexedPng({ width:9,height:9,bitDepth:depth,interlace:1,paletteEntries:1,raw }), false);
    const packed = 1 << (8-depth);
    checkBoth(indexedPng({ width:1,height:2,bitDepth:depth,interlace:1,paletteEntries:2,raw:[filter,packed,filter,packed] }), true, { width:1,height:2 });
    checkBoth(indexedPng({ width:1,height:2,bitDepth:depth,interlace:1,paletteEntries:1,raw:[filter,0,filter,packed] }), false);
  });
}

test("Paeth selects left, above and upper-left predictors with byte wraparound", () => {
  // Decoded rows: [0,2,1,0] and [1,0,2,1].
  const config = { width:4,height:2,bitDepth:8,raw:[4,0,2,255,255,4,1,254,2,0] };
  checkBoth(indexedPng({ ...config,paletteEntries:3 }), true, { width:4,height:2 });
  checkBoth(indexedPng({ ...config,paletteEntries:2 }), false);
});

test("startup and image retrieval reject checksum-matching PNGs containing out-of-range indices", async () => {
  const valid = indexedPng({ width:1,height:1,bitDepth:8,paletteEntries:1,raw:[0,0] });
  const invalid = indexedPng({ width:1,height:1,bitDepth:8,paletteEntries:1,raw:[0,1] });
  const badFixture = await buildFixture({ pngBytes:invalid });
  try {
    await assert.rejects(createSearchService({ root:badFixture.root }), error =>
      error.code === "INVALID_INDEX" && /pixel index.*palette/i.test(error.cause?.message));
  } finally { await rm(badFixture.root,{recursive:true,force:true}); }
  const fixture = await buildFixture({ pngBytes:valid });
  let service;
  try {
    service = await createSearchService({ root:fixture.root });
    assert.deepEqual(Buffer.from(service.readImage({asset_id:fixture.assets[0].assetId}).data,"base64"),valid);
    // Change only disposable evidence after startup. The requested row now
    // matches the bad file's hash/size, so its pixel validation is decisive.
    const revision = path.join(fixture.root,"revisions",fixture.databaseHash);
    await writeFile(path.join(revision,...fixture.assets[0].storageKey.split("/")),invalid);
    const database = new DatabaseSync(path.join(revision,"mql5-docs.sqlite"));
    try {
      database.prepare("UPDATE assets SET sha256=?,byte_count=? WHERE asset_id=?").run(
        createHash("sha256").update(invalid).digest("hex"),invalid.length,fixture.assets[0].assetId);
    } finally { database.close(); }
    assert.throws(() => service.readImage({asset_id:fixture.assets[0].assetId}), error =>
      error.code === "ASSET_INTEGRITY_FAILED" && /pixel index.*palette/i.test(error.cause?.message));
  } finally { service?.close(); await rm(fixture.root,{recursive:true,force:true}); }
});

test("indexing rejects an in-help PNG with an out-of-range palette index", async () => {
  const root = await mkdtemp(path.join(tmpdir(),"mql5-palette-index-"));
  try {
    await mkdir(path.join(root,"config"));
    await writeFile(path.join(root,"config","mql5-image-policy.json"),await readFile(new URL("../config/mql5-image-policy.json",import.meta.url)));
    const sources = [];
    for (const id of ["mql5","mql5book","neuronetworksbook"]) {
      const bytes = Buffer.from(`fixture-${id}`);
      await mkdir(path.join(root,"sources"),{recursive:true});
      await writeFile(path.join(root,"sources",`${id}.chm`),bytes);
      await mkdir(path.join(root,"extracted",id),{recursive:true});
      await writeFile(path.join(root,"extracted",id,"topic.htm"),`<div id="help"><h1>${id}</h1>${id==="mql5"?'<img src="diagram.png" alt="Technical diagram">':''}</div>`);
      sources.push({id,filename:`${id}.chm`,sha256:createHash("sha256").update(bytes).digest("hex"),expected_topics:1});
    }
    await writeFile(path.join(root,"corpus.lock.json"),JSON.stringify({schema_version:1,expected_total_topics:3,sources}));
    const image = path.join(root,"extracted","mql5","diagram.png");
    const options = { sourceDirectory:"sources",extractedDirectory:"extracted",outputDirectory:"output" };
    await writeFile(image,indexedPng({width:1,height:1,bitDepth:8,paletteEntries:1,raw:[0,0]}));
    await buildIndex(root,options);
    const before = await readFile(path.join(root,"output","mql5-docs.sqlite"));
    await writeFile(image,indexedPng({width:1,height:1,bitDepth:8,paletteEntries:1,raw:[0,1]}));
    await assert.rejects(buildIndex(root,options),/pixel index.*palette/i);
    assert.deepEqual(await readFile(path.join(root,"output","mql5-docs.sqlite")),before);
  } finally { await rm(root,{recursive:true,force:true}); }
});
