import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { deflateSync } from "node:zlib";
import jpeg from "jpeg-js";

import {
  ASSET_ID_PATTERN,
  INDEX_CONTRACT,
  assertAssetIdentityAvailable,
  buildIndex,
  computeImagePolicySha256,
  inspectRasterAsset,
  inspectPolicyPinnedPngException,
  makeAssetId,
  makeAssetPathDigest,
  parseHtmlTopic,
  resolveInternalAssetPath,
} from "../src/indexer.mjs";

test("image-policy identity is stable across Git line-ending conversion", () => {
  const lf = '{\n  "schema_version": 1,\n  "policy_id": "test"\n}\n';
  const crlf = lf.replaceAll("\n", "\r\n");
  assert.notEqual(createHash("sha256").update(lf).digest("hex"), createHash("sha256").update(crlf).digest("hex"));
  assert.equal(computeImagePolicySha256(lf), computeImagePolicySha256(crlf));
});

const crcTable = (() => {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) value = (value & 1) ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    table[index] = value >>> 0;
  }
  return table;
})();

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data = Buffer.alloc(0)) {
  const typeBytes = Buffer.from(type, "ascii");
  const output = Buffer.alloc(12 + data.length);
  output.writeUInt32BE(data.length, 0);
  typeBytes.copy(output, 4);
  data.copy(output, 8);
  output.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])), 8 + data.length);
  return output;
}

function makePng(width = 2, height = 3, extraChunks = [], rawImageData = null, headerOverrides = {}) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = headerOverrides.bitDepth ?? 8;
  header[9] = headerOverrides.colorType ?? 6;
  header[12] = headerOverrides.interlace ?? 0;
  const imageData = rawImageData ?? Buffer.alloc(height * (1 + width * 4));
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", header),
    ...extraChunks,
    pngChunk("IDAT", deflateSync(imageData)),
    pngChunk("IEND"),
  ]);
}

function makeMinimalJpeg(width = 7, height = 5) {
  return jpeg.encode({ width, height, data: Buffer.alloc(width * height * 4, 0x7f) }, 90).data;
}

test("asset IDs and virtual asset paths are stable and traversal-safe", () => {
  const expectedDigest = createHash("sha256").update("images/ordersend.png", "utf8").digest("hex");
  assert.equal(makeAssetPathDigest("Images/OrderSend.png"), expectedDigest);
  assert.equal(makeAssetId("mql5", "Images/OrderSend.png"), `mql5:asset:${expectedDigest.slice(0, 24)}`);
  assert.equal(makeAssetId("mql5", "Images/OrderSend.png"), makeAssetId("mql5", "images/ordersend.png"));
  assert.match(makeAssetId("mql5book", "chart.png"), ASSET_ID_PATTERN);

  assert.equal(resolveInternalAssetPath("reference/trade/order.htm", "../../images/order.png?x=1#top"), "images/order.png");
  assert.equal(resolveInternalAssetPath("reference/trade/order.htm", "/images/order.png"), "images/order.png");
  for (const unsafe of [
    "../../../escape.png",
    "%252e%252e/%252e%252e/%252e%252e/escape.png",
    "https://example.test/image.png",
    "data:image/png;base64,AAAA",
    "file:///C:/image.png",
    "C:%5Cimage.png",
    "\\\\server\\share\\image.png",
    "javascript:alert(1)",
    "bad\u0000.png",
  ]) assert.equal(resolveInternalAssetPath("reference/trade/order.htm", unsafe), null, unsafe);
});

test("asset identity registry rejects case-folded paths and truncated-ID collisions", () => {
  const byPath = new Map();
  const byId = new Map();
  const firstId = makeAssetId("mql5", "Images/Diagram.png");
  assertAssetIdentityAvailable(byPath, byId, {
    source: "mql5", internalPath: "Images/Diagram.png", pathSha256: makeAssetPathDigest("Images/Diagram.png"), assetId: firstId,
  });
  assert.throws(() => assertAssetIdentityAvailable(byPath, byId, {
    source: "mql5", internalPath: "images/diagram.PNG", pathSha256: makeAssetPathDigest("images/diagram.PNG"), assetId: firstId,
  }), /Case-folded/);

  const collisionId = `mql5:asset:${"f".repeat(24)}`;
  const collisionPaths = new Map();
  const collisionIds = new Map();
  assertAssetIdentityAvailable(collisionPaths, collisionIds, {
    source: "mql5", internalPath: "a.png", pathSha256: "a".repeat(64), assetId: collisionId,
  });
  assert.throws(() => assertAssetIdentityAvailable(collisionPaths, collisionIds, {
    source: "mql5", internalPath: "b.png", pathSha256: "b".repeat(64), assetId: collisionId,
  }), /Truncated asset-ID/);
});

test("raster inspection validates static PNG/JPEG structure and bounds", () => {
  const png = makePng(2, 3);
  assert.deepEqual(inspectRasterAsset(png, "diagram.png", {
    max_bytes: 2_097_152,
    max_dimension: 4_096,
    max_pixels: 4_194_304,
  }), { mimeType: "image/png", width: 2, height: 3, byteCount: png.length, pixelCount: 6 });

  const jpeg = makeMinimalJpeg(7, 5);
  assert.deepEqual(inspectRasterAsset(jpeg, "photo.jpg"), {
    mimeType: "image/jpeg", width: 7, height: 5, byteCount: jpeg.length, pixelCount: 35,
  });
  const malformedJpeg = Buffer.from([
    0xff, 0xd8,
    0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00,
    0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00,
    0x00, 0xff, 0xd9,
  ]);
  assert.throws(() => inspectRasterAsset(malformedJpeg, "missing-tables.jpg"), /JPEG/);

  assert.throws(() => inspectRasterAsset(makePng(2, 3, [pngChunk("acTL", Buffer.alloc(8))]), "animated.png"), /APNG/);
  assert.throws(() => inspectRasterAsset(makePng(1, 1, [], Buffer.from([5, 0, 0, 0, 0])), "bad-filter.png"), /filter/i);
  assert.throws(() => inspectRasterAsset(makePng(1, 1, [], Buffer.from([0, 0]), { colorType: 3, bitDepth: 8 }), "missing-palette.png"), /palette/i);
  assert.throws(() => inspectRasterAsset(makePng(1, 1, [pngChunk("ABCD")]), "critical.png"), /critical/i);
  assert.throws(() => inspectRasterAsset(makePng(1, 1, [pngChunk("abca")]), "reserved.png"), /chunk type/i);
  const badCrc = Buffer.from(png);
  badCrc[29] ^= 1;
  assert.throws(() => inspectRasterAsset(badCrc, "broken.png"), /CRC/);
  assert.throws(() => inspectRasterAsset(png, "disguised.jpg"), /extension\/signature/);
  assert.throws(() => inspectRasterAsset(Buffer.from("<svg></svg>"), "disguised.png"), /SVG or HTML/);
  assert.throws(() => inspectRasterAsset(makePng(4_097, 1), "wide.png", {
    max_bytes: 2_097_152, max_dimension: 4_096, max_pixels: 4_194_304,
  }), /dimension limit/);
  assert.throws(() => inspectRasterAsset(makePng(4_097, 1, [], Buffer.from([0])), "bounded-before-inflate.png", {
    max_bytes: 2_097_152, max_dimension: 4_096, max_pixels: 4_194_304,
  }), /dimension limit/);
  const tooManyBytes = Buffer.alloc(2_097_153);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(tooManyBytes);
  assert.throws(() => inspectRasterAsset(tooManyBytes, "too-large.png", {
    max_bytes: 2_097_152, max_dimension: 4_096, max_pixels: 4_194_304,
  }), /bytes/);
  assert.throws(() => inspectRasterAsset(makePng(0, 1, [], Buffer.from([0])), "zero.png"), /dimensions/);
  const zeroWidthJpeg = Buffer.from(jpeg);
  const sofOffset = zeroWidthJpeg.indexOf(Buffer.from([0xff, 0xc0]));
  assert.notEqual(sofOffset, -1);
  zeroWidthJpeg[sofOffset + 7] = 0;
  zeroWidthJpeg[sofOffset + 8] = 0;
  assert.throws(() => inspectRasterAsset(zeroWidthJpeg, "zero.jpg"), /zero dimensions|JPEG/);
  assert.throws(() => inspectRasterAsset(Buffer.concat([jpeg, Buffer.from([0])]), "trailing.jpg"), /trailing|JPEG/);
  assert.throws(() => inspectRasterAsset(jpeg.subarray(0, jpeg.length - 3), "truncated.jpg"), /JPEG/);
  const gif = Buffer.from("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==", "base64");
  assert.deepEqual(inspectRasterAsset(gif, "copyright.gif"), {
    mimeType: "image/gif", width: 1, height: 1, byteCount: gif.length, pixelCount: 1,
  });
  const imageDescriptor = gif.indexOf(0x2c);
  const zeroDescriptor = Buffer.from(gif);
  zeroDescriptor.writeUInt16LE(0, imageDescriptor + 5);
  assert.throws(() => inspectRasterAsset(zeroDescriptor, "copyright.gif"), /GIF|dimension/i);
  const outsideCanvas = Buffer.from(gif);
  outsideCanvas.writeUInt16LE(1, imageDescriptor + 1);
  assert.throws(() => inspectRasterAsset(outsideCanvas, "copyright.gif"), /GIF|dimension/i);
  assert.throws(() => inspectRasterAsset(makePng(2_049, 2_048), "pixels.png", {
    max_bytes: 2_097_152, max_dimension: 4_096, max_pixels: 4_194_304,
  }), /decoded limit/);
});

test("topic parsing records caption provenance, section, and offsets without changing text", () => {
  const topic = parseHtmlTopic(`<!doctype html><html><head><title>Image Topic</title></head><body>
    <div id="help"><h1>Image Topic</h1><p>Before <img src="images/a.png" alt="Alt A"> after.</p>
    <h2>Diagram</h2><figure><img src="images/b.png" title="Title B" alt="Alt B"><figcaption>Figure B</figcaption></figure></div>
  </body></html>`, {
    source: "mql5",
    internalPath: "reference/image-topic.htm",
    imagePolicy: {
      limits: { max_caption_chars: 500 },
      meaningless_captions: ["image"],
      presentation_ancestor_selectors: ["#footer-links"],
    },
  });

  assert.equal(topic.imageReferences.length, 2);
  assert.ok(!topic.content.includes("images/a.png"));
  assert.ok(!topic.content.includes("Alt A"));
  assert.match(topic.content, /Before\s+after\./);
  assert.deepEqual(topic.imageReferences.map((image) => image.captionSource), ["alt", "figcaption"]);
  assert.deepEqual(topic.imageReferences.map((image) => image.contextualCaption), ["Alt A", "Figure B"]);
  assert.equal(topic.imageReferences[1].sectionOrdinal, 1);
  for (const image of topic.imageReferences) {
    assert.ok(image.textOffset >= 0 && image.textOffset <= topic.content.length);
  }
});

for (const [name, body, expectedSections, expectedOffsets, expectedContent] of [
  ["image-only paragraph before a heading", '<h1>First</h1><p>Hello</p><p><img src="a.png"></p><h2>Second</h2><p>Later</p>', [0], [12], "First\nHello\nSecond\nLater"],
  ["trailing space in normal text", '<h1>First</h1><p>Hello <img src="a.png"></p><h2>Second</h2><p>Later</p>', [0], [11], "First\nHello\nSecond\nLater"],
  ["trailing spaces in code", '<h1>First</h1><pre>A    <img src="a.png"></pre><h2>Second</h2><p>Later</p>', [0], [7], "First\nA\nSecond\nLater"],
  ["consecutive zero-width images", '<h1>First</h1><p>Hello</p><p><img src="a.png"><img src="b.png"></p><h2>Second</h2><p>Later</p>', [0, 0], [12, 12], "First\nHello\nSecond\nLater"],
  ["nested styled heading and its image", '<h1>First</h1><p class="p_H2"><span class="f_H2">Second<img src="a.png"></span></p><p>Later</p>', [1], [12], "First\nSecond\nLater"],
  ["discarded multiline heading", '<h1>First</h1><h2>Discarded<br>heading <img src="a.png"></h2><h2>Second</h2><p>Later</p>', [0], [23], "First\nDiscarded\nheading\nSecond\nLater"],
  ["duplicate heading", '<h1>First</h1><h2>First</h2><img src="a.png"><h2>Second</h2><p>Later</p>', [0], [12], "First\nFirst\nSecond\nLater"],
  ["document boundaries", '<img src="a.png"><h1>First</h1><p>Hello</p><h2>Second</h2><p>Later</p><img src="b.png">', [0, 1], [0, 24], "First\nHello\nSecond\nLater"],
  ["heading-free topic", '<img src="a.png"><p>Hello <img src="b.png"></p>', [0, 0], [0, 5], "Hello"],
  ["supplementary Unicode and trimmed code", '<h1>😀 First</h1><pre>😀    <img src="a.png"></pre><h2>Next</h2><p>Later</p>', [0], [11], "😀 First\n😀\nNext\nLater"],
]) {
  test(`image DOM association preserves text and real offsets: ${name}`, () => {
    const html = `<title>Fixture</title><div id="help">${body}</div>`;
    const options = { source: "mql5", internalPath: "fixture.htm" };
    const topic = parseHtmlTopic(html, options);
    const textOnly = parseHtmlTopic(html.replace(/<img\b[^>]*>/gu, ""), options);
    assert.equal(topic.content, expectedContent);
    assert.equal(topic.contentSha256, textOnly.contentSha256);
    assert.deepEqual(topic.sections, textOnly.sections);
    assert.deepEqual(topic.imageReferences.map((image) => image.sectionOrdinal), expectedSections);
    assert.deepEqual(topic.imageReferences.map((image) => image.textOffset), expectedOffsets);
  });
}

test("genuine CButton excerpt assigns ControlsButton to inheritance, preserving the boundary offset", async () => {
  const bytes = await readFile(new URL("./fixtures/cbutton-image-boundary.htm", import.meta.url));
  const provenance = JSON.parse(await readFile(new URL("./fixtures/cbutton-image-boundary.provenance.json", import.meta.url), "utf8"));
  assert.equal(createHash("sha256").update(bytes).digest("hex"), provenance.fixture_sha256);
  const topic = parseHtmlTopic(bytes.toString("utf8"), { source: "mql5", internalPath: "cbutton.htm" });
  assert.equal(topic.sections[4].heading, "Inheritance hierarchy");
  assert.equal(topic.sections[5].heading, "Class Methods by Groups");
  assert.equal(topic.imageReferences.length, 1);
  assert.equal(topic.imageReferences[0].altText, "ControlsButton");
  assert.equal(topic.imageReferences[0].sectionOrdinal, 4);
  assert.equal(topic.imageReferences[0].textOffset, 327);
  assert.equal(topic.imageReferences[0].textOffset, topic.sections[5].startOffset);
});

test("caption precedence, normalization, and filename fallback are deterministic and bounded", () => {
  const longTitle = `  ${"X".repeat(520)}\tignored  `;
  const topic = parseHtmlTopic(`<div id="help"><h1>Captions</h1>
    <p><img src="title.png" title="  Preferred\t title  " alt="Alt loses"></p>
    <p>Nearby explanatory text <img src="nearby.png"></p>
    <img src="fallback_file-name.png">
    <p><img src="long.png" title="${longTitle}"></p>
  </div>`, {
    source: "mql5",
    internalPath: "reference/captions.htm",
    imagePolicy: {
      limits: { max_caption_chars: 500 },
      meaningless_captions: ["image"],
      presentation_ancestor_selectors: ["#footer-links"],
    },
  });
  assert.deepEqual(topic.imageReferences.map((entry) => entry.captionSource), ["title", "nearby", "filename", "title"]);
  assert.equal(topic.imageReferences[0].contextualCaption, "Preferred title");
  assert.match(topic.imageReferences[1].contextualCaption, /Nearby explanatory text/);
  assert.equal(topic.imageReferences[2].contextualCaption, "fallback file name");
  assert.equal(topic.imageReferences[3].contextualCaption.length, 500);
  assert.doesNotMatch(topic.imageReferences[3].contextualCaption, /[\u0000-\u001f\u007f]/u);
});

test("bounded image captions never split a Unicode surrogate pair", () => {
  const safePrefix = "a".repeat(499);
  const topic = parseHtmlTopic(
    `<div id="help"><h1>Caption</h1><img src="unicode.png" alt="${safePrefix}😀tail"></div>`,
    {
      source: "mql5",
      internalPath: "reference/caption.htm",
      imagePolicy: { limits: { max_caption_chars: 500 } },
    },
  );
  assert.equal(topic.imageReferences[0].altText, safePrefix);
  assert.equal(topic.imageReferences[0].contextualCaption, safePrefix);
});

test("versioned policy keeps the exact initial decorative denylist", async () => {
  const policy = JSON.parse(await readFile(new URL("../config/mql5-image-policy.json", import.meta.url), "utf8"));
  assert.equal(policy.schema_version, 1);
  assert.equal(policy.policy_id, "mql5-chm-technical-images-v1");
  assert.equal(policy.denylist.length, 11);
  assert.deepEqual(policy.limits, {
    max_bytes: 2_097_152,
    max_dimension: 4_096,
    max_pixels: 4_194_304,
    max_caption_chars: 500,
  });
});

test("the one official trailing-PNG exception is exact and near matches fail", async () => {
  const policy = JSON.parse(await readFile(new URL("../config/mql5-image-policy.json", import.meta.url), "utf8"));
  const entry = policy.integrity_exceptions[0];
  const bytes = await readFile(new URL("../build/extracted/neuronetworksbook/opencl_test.png", import.meta.url));
  const exception = {
    source: entry.source,
    internalPath: entry.path,
    sha256: entry.sha256,
    bytes: entry.bytes,
    validPngPrefixBytes: entry.valid_png_prefix_bytes,
    reason: entry.reason,
  };
  assert.throws(() => inspectRasterAsset(bytes, entry.path, policy.limits), /trailing bytes/);
  assert.deepEqual(
    inspectPolicyPinnedPngException(bytes, entry.source, entry.path, policy.limits, exception),
    { mimeType: "image/png", width: 643, height: 105, byteCount: 23_807, pixelCount: 67_515 },
  );
  const changed = Buffer.from(bytes);
  changed[changed.length - 1] ^= 1;
  assert.throws(
    () => inspectPolicyPinnedPngException(changed, entry.source, entry.path, policy.limits, exception),
    /exact hash or byte contract/,
  );
  assert.throws(
    () => inspectPolicyPinnedPngException(bytes, entry.source, "opencl-test.png", policy.limits, exception),
    /exact hash or byte contract/,
  );
  assert.throws(
    () => inspectPolicyPinnedPngException(bytes, entry.source, entry.path, policy.limits, {
      ...exception,
      validPngPrefixBytes: exception.validPngPrefixBytes - 1,
    }),
    /PNG|incomplete|truncated|CRC/,
  );
});

async function installImagePolicy(root) {
  const policy = await readFile(new URL("../config/mql5-image-policy.json", import.meta.url));
  await mkdir(path.join(root, "config"), { recursive: true });
  await writeFile(path.join(root, "config", "mql5-image-policy.json"), policy);
}

async function createMiniCorpus(root, { includePolicy = true } = {}) {
  if (includePolicy) await installImagePolicy(root);
  const sourceRoot = path.join(root, "sources");
  const extractedRoot = path.join(root, "extracted");
  await mkdir(sourceRoot, { recursive: true });
  const png = makePng(2, 3);
  const sourceSpecs = [
    {
      id: "mql5",
      filename: "mql5.chm",
      html: `<div id="help"><h1>API</h1><p>First <img src="diagram.png" alt="Technical diagram"></p><figure><img src="diagram.png" alt="Technical diagram"><figcaption>Preferred canonical figure</figcaption></figure></div>`,
      assets: [["diagram.png", png]],
    },
    {
      id: "mql5book",
      filename: "mql5book.chm",
      html: `<div id="help"><h1>Book</h1><div id="footer-links"><img src="code_base_icon.png" alt="CodeBase"></div></div>`,
      assets: [["code_base_icon.png", png]],
    },
    {
      id: "neuronetworksbook",
      filename: "neuronetworksbook.chm",
      html: `<div id="help"><h1>Neural Book</h1><p>No image here.</p></div>`,
      assets: [],
    },
  ];
  const lockSources = [];
  for (const spec of sourceSpecs) {
    const chmBytes = Buffer.from(`fixture-${spec.id}`);
    await writeFile(path.join(sourceRoot, spec.filename), chmBytes);
    const extracted = path.join(extractedRoot, spec.id);
    await mkdir(extracted, { recursive: true });
    await writeFile(path.join(extracted, "topic.htm"), spec.html, "utf8");
    for (const [name, bytes] of spec.assets) await writeFile(path.join(extracted, name), bytes);
    lockSources.push({
      id: spec.id,
      filename: spec.filename,
      sha256: createHash("sha256").update(chmBytes).digest("hex"),
      bytes: chmBytes.length,
      expected_topics: 1,
    });
  }
  await writeFile(path.join(root, "corpus.lock.json"), JSON.stringify({
    schema_version: 1,
    expected_total_topics: 3,
    sources: lockSources,
  }));
  return png;
}

function miniCorpusBuildOptions(options = {}) {
  return { sourceDirectory: "sources", extractedDirectory: "extracted", ...options };
}

test("index builds reject impossible ISO calendar timestamps instead of normalizing them", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-timestamp-"));
  try {
    await createMiniCorpus(root);
    for (const [ordinal, retrievedAt] of [
      ["calendar", "2026-02-31T00:00:00Z"],
      ["clock", "2026-01-01T24:00:00Z"],
      ["upper-year", "9999-12-31T23:59:59-14:00"],
      ["lower-year", "0000-01-01T00:00:00+14:00"],
    ]) {
      await assert.rejects(
        buildIndex(root, miniCorpusBuildOptions({
          outputDirectory: `candidate-${ordinal}`,
          sourceMetadata: { mql5: { retrieved_at: retrievedAt } },
        })),
        /must be an ISO-8601 timestamp with an explicit timezone/,
        retrievedAt,
      );
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("project policy stays separate from an external maintenance workspace", async () => {
  const container = await mkdtemp(path.join(tmpdir(), "mql5-index-workspace-"));
  const projectRoot = path.join(container, "project");
  const workspaceRoot = path.join(container, "external maintenance workspace");
  try {
    await mkdir(projectRoot);
    await mkdir(workspaceRoot);
    await installImagePolicy(projectRoot);
    await createMiniCorpus(workspaceRoot, { includePolicy: false });

    const result = await buildIndex(projectRoot, miniCorpusBuildOptions({
      workspaceRoot,
      outputDirectory: "candidate",
      sourceMetadata: {
        mql5: { retrieved_at: "2026-01-01T00:00:00Z" },
        mql5book: { retrieved_at: "2026-01-01T00:00:00Z" },
        neuronetworksbook: { retrieved_at: "2026-01-01T00:00:00Z" },
      },
    }));

    assert.equal(path.dirname(result.databasePath), path.join(workspaceRoot, "candidate"));
    assert.equal(await readFile(path.join(projectRoot, "config", "mql5-image-policy.json"), "utf8"),
      await readFile(new URL("../config/mql5-image-policy.json", import.meta.url), "utf8"));
  } finally {
    await rm(container, { recursive: true, force: true });
  }
});

test("source and output paths cannot escape the maintenance workspace", async () => {
  const container = await mkdtemp(path.join(tmpdir(), "mql5-index-boundary-"));
  const projectRoot = path.join(container, "project");
  const workspaceRoot = path.join(container, "workspace");
  const outsideRoot = path.join(container, "outside");
  try {
    await mkdir(projectRoot);
    await mkdir(workspaceRoot);
    await mkdir(outsideRoot);

    await assert.rejects(
      buildIndex(projectRoot, { workspaceRoot, sourceDirectory: outsideRoot }),
      /Source directory escapes the maintenance workspace root/,
    );
    await assert.rejects(
      buildIndex(projectRoot, { workspaceRoot, outputDirectory: outsideRoot }),
      /Output directory escapes the maintenance workspace root/,
    );
  } finally {
    await rm(container, { recursive: true, force: true });
  }
});

test("a junction cannot be used as the maintenance workspace root", async (t) => {
  const container = await mkdtemp(path.join(tmpdir(), "mql5-index-junction-"));
  const projectRoot = path.join(container, "project");
  const actualWorkspace = path.join(container, "actual-workspace");
  const workspaceJunction = path.join(container, "workspace-junction");
  let junctionCreated = false;
  try {
    await mkdir(projectRoot);
    await mkdir(actualWorkspace);
    try {
      await symlink(actualWorkspace, workspaceJunction, "junction");
      junctionCreated = true;
    } catch (error) {
      if (["EPERM", "EACCES", "ENOTSUP"].includes(error?.code)) {
        t.skip(`Junction creation is unavailable: ${error.code}`);
        return;
      }
      throw error;
    }

    await assert.rejects(
      buildIndex(projectRoot, { workspaceRoot: workspaceJunction }),
      /Maintenance workspace root must be an existing non-link directory/,
    );
  } finally {
    if (junctionCreated) await unlink(workspaceJunction).catch(() => {});
    await rm(container, { recursive: true, force: true });
  }
});

test("descendant junctions cannot route source or output outside the maintenance workspace", async (t) => {
  const container = await mkdtemp(path.join(tmpdir(), "mql5-index-descendant-junction-"));
  const projectRoot = path.join(container, "project");
  const workspaceRoot = path.join(container, "workspace");
  const externalCorpus = path.join(container, "external-corpus");
  const externalOutput = path.join(container, "external-output");
  const sourceJunction = path.join(workspaceRoot, "source-junction");
  const outputJunction = path.join(workspaceRoot, "output-junction");
  const createdJunctions = [];
  try {
    await mkdir(projectRoot);
    await mkdir(workspaceRoot);
    await mkdir(externalCorpus);
    await mkdir(externalOutput);
    await installImagePolicy(projectRoot);
    await createMiniCorpus(externalCorpus, { includePolicy: false });

    try {
      await symlink(externalCorpus, sourceJunction, "junction");
      createdJunctions.push(sourceJunction);
      await symlink(externalOutput, outputJunction, "junction");
      createdJunctions.push(outputJunction);
    } catch (error) {
      if (["EPERM", "EACCES", "ENOTSUP"].includes(error?.code)) {
        t.skip(`Junction creation is unavailable: ${error.code}`);
        return;
      }
      throw error;
    }

    await assert.rejects(
      buildIndex(projectRoot, {
        workspaceRoot,
        sourceDirectory: path.join("source-junction", "sources"),
        extractedDirectory: path.join("source-junction", "extracted"),
        corpusLockPath: path.join("source-junction", "corpus.lock.json"),
        outputDirectory: "source-candidate",
      }),
      /junction|reparse|symbolic link|escapes/i,
    );

    await createMiniCorpus(workspaceRoot, { includePolicy: false });
    await assert.rejects(
      buildIndex(projectRoot, miniCorpusBuildOptions({
        workspaceRoot,
        outputDirectory: path.join("output-junction", "candidate"),
      })),
      /junction|reparse|symbolic link|escapes/i,
    );
  } finally {
    for (const junction of createdJunctions.reverse()) await unlink(junction).catch(() => {});
    await rm(container, { recursive: true, force: true });
  }
});

test("output validation rejects overlap and pre-existing unowned directories before writing", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-output-safety-"));
  try {
    await createMiniCorpus(root);
    const buildOptions = (options = {}) => miniCorpusBuildOptions(options);

    const rootSentinel = path.join(root, "assets", "sentinel.txt");
    await mkdir(path.dirname(rootSentinel));
    await writeFile(rootSentinel, "keep-root-sentinel", "utf8");
    await assert.rejects(
      buildIndex(root, buildOptions({ outputDirectory: "." })),
      /Output directory .*overlap|protected|source/i,
    );
    assert.equal(await readFile(rootSentinel, "utf8"), "keep-root-sentinel");
    await assert.rejects(readFile(path.join(root, ".index-build.lock")), /ENOENT/);

    const nestedInSource = path.join(root, "sources", "candidate");
    await assert.rejects(
      buildIndex(root, buildOptions({ outputDirectory: nestedInSource })),
      /overlap.*source|source.*overlap/i,
    );
    await assert.rejects(readFile(path.join(nestedInSource, ".index-build.lock")), /ENOENT/);

    const unowned = path.join(root, "candidate-unowned");
    await mkdir(unowned);
    const candidateSentinel = path.join(unowned, "sentinel.txt");
    await writeFile(candidateSentinel, "keep-candidate-sentinel", "utf8");
    await assert.rejects(
      buildIndex(root, buildOptions({ outputDirectory: unowned })),
      /pre-existing unowned|unexpected existing/i,
    );
    assert.equal(await readFile(candidateSentinel, "utf8"), "keep-candidate-sentinel");
    await assert.rejects(readFile(path.join(unowned, ".index-build.lock")), /ENOENT/);

    const immutableRevision = path.join(root, "revisions", "f".repeat(64));
    await mkdir(immutableRevision, { recursive: true });
    await assert.rejects(
      buildIndex(root, buildOptions({ outputDirectory: immutableRevision })),
      /protected|immutable|revisions/i,
    );
    assert.deepEqual(await readdir(immutableRevision), []);

    const owned = await buildIndex(root, buildOptions({ outputDirectory: "candidate-owned" }));
    const nestedSentinel = path.join(owned.assetsPath, "sentinel.txt");
    await writeFile(nestedSentinel, "keep-owned-tree-sentinel", "utf8");
    await assert.rejects(
      buildIndex(root, buildOptions({ outputDirectory: "candidate-owned" })),
      /asset.*closure|unowned|unexpected existing/i,
    );
    assert.equal(await readFile(nestedSentinel, "utf8"), "keep-owned-tree-sentinel");
    await unlink(nestedSentinel);
    const rebuilt = await buildIndex(root, buildOptions({ outputDirectory: "candidate-owned" }));
    assert.equal(rebuilt.indexRevision, owned.indexRevision);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("schema-3 builds preserve JavaScript UTF-16 offsets for supplementary Unicode", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-utf16-"));
  try {
    await createMiniCorpus(root);
    await writeFile(
      path.join(root, "extracted", "mql5", "topic.htm"),
      `<html><head><meta charset="utf-8"><title>Astral API</title></head><body>
        <div id="help"><h1>Astral API</h1><p>A\ud83d\ude00B</p><h2>Details</h2><p>C\ud83d\ude80D</p></div>
      </body></html>`,
      "utf8",
    );
    const result = await buildIndex(root, miniCorpusBuildOptions({ outputDirectory: "candidate" }));
    const database = new DatabaseSync(result.databasePath, { readOnly: true });
    try {
      const topic = database.prepare(`
        SELECT content, content_length AS contentLength, length(content) AS sqliteLength
        FROM topics WHERE source='mql5'
      `).get();
      assert.equal(topic.contentLength, topic.content.length);
      assert.ok(topic.contentLength > topic.sqliteLength);
      const sections = database.prepare(`
        SELECT start_offset AS startOffset, end_offset AS endOffset, sections.content AS content
        FROM sections JOIN topics USING(topic_id)
        WHERE topics.source='mql5' ORDER BY ordinal
      `).all();
      for (const section of sections) {
        assert.equal(topic.content.slice(section.startOffset, section.endOffset).trimEnd(), section.content);
      }
    } finally {
      database.close();
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("index builds reject an oversized raster file by size before cataloguing it", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-oversized-"));
  try {
    await createMiniCorpus(root);
    await writeFile(path.join(root, "extracted", "mql5", "huge.png"), Buffer.alloc(2_097_153));
    await assert.rejects(
      buildIndex(root, miniCorpusBuildOptions({ outputDirectory: "candidate" })),
      /Invalid raster asset mql5\/huge\.png: Image exceeds 2097152 bytes\./u,
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("real index builds can explicitly reclaim a dead local legacy lock", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-legacy-lock-"));
  try {
    await createMiniCorpus(root);
    const outputDirectory = path.join(root, "candidate");
    await mkdir(outputDirectory);
    const lockPath = path.join(outputDirectory, ".index-build.lock");
    const legacy = { pid: 2_147_483_647, started_at: "2026-01-01T00:00:00.000Z" };
    await writeFile(lockPath, `${JSON.stringify(legacy)}\n`, "utf8");

    await assert.rejects(
      buildIndex(root, miniCorpusBuildOptions({ outputDirectory: "candidate" })),
      /explicit proof|local to this host/i,
    );
    assert.equal(await readFile(lockPath, "utf8"), `${JSON.stringify(legacy)}\n`);

    const proofOptions = process.platform === "win32"
      ? { reclaimDeadLegacyLock: true, legacyLocalStorageProbe: () => true }
      : { legacySameHostProof: () => true };
    const result = await buildIndex(root, miniCorpusBuildOptions({
      outputDirectory: "candidate",
      ...proofOptions,
    }));
    assert.match(result.indexRevision, /^[0-9a-f]{64}$/u);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("finalizer cleanup failure retains strict owner evidence for retry", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-finalizer-retry-"));
  try {
    await createMiniCorpus(root);
    const outputDirectory = path.join(root, "candidate");
    let injected = false;
    await assert.rejects(
      buildIndex(root, miniCorpusBuildOptions({
        outputDirectory: "candidate",
        async cleanupRemove(target, options) {
          if (!injected && path.basename(target).startsWith(".manifest.json.candidate-")) {
            injected = true;
            await writeFile(target, "stranded candidate manifest\n", "utf8");
            const error = new Error("synthetic sharing violation");
            error.code = "EACCES";
            throw error;
          }
          return rm(target, options);
        },
      })),
      /strict owner lock was retained|cleanup failed/i,
    );
    assert.equal(injected, true);
    const lock = JSON.parse(await readFile(path.join(outputDirectory, ".index-build.lock"), "utf8"));
    assert.equal(lock.schema_version, 2);
    assert.match(lock.process_start_identity, /^[a-z][a-z0-9-]*:[A-Za-z0-9._-]+$/u);
    assert.equal(await readFile(path.join(outputDirectory, `.manifest.json.candidate-${lock.owner_token}`), "utf8"), "stranded candidate manifest\n");

    const recovered = await buildIndex(root, miniCorpusBuildOptions({
      outputDirectory: "candidate",
      lockProbeProcess: () => "dead",
    }));
    assert.match(recovered.indexRevision, /^[0-9a-f]{64}$/u);
    assert.equal((await readdir(outputDirectory)).some((name) => name.includes(lock.owner_token)), false);
    assert.equal((await readdir(outputDirectory)).includes(".index-build.lock"), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("schema-3 builds are reproducible and externalize a closed immutable asset tree", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-v12-"));
  try {
    const png = await createMiniCorpus(root);
    const first = await buildIndex(root, miniCorpusBuildOptions({
      outputDirectory: "candidate one",
      sourceMetadata: {
        mql5: { retrieved_at: "2026-01-01T00:00:00Z" },
        mql5book: { retrieved_at: "2026-01-01T00:00:00Z" },
        neuronetworksbook: { retrieved_at: "2026-01-01T00:00:00Z" },
      },
    }));
    const second = await buildIndex(root, miniCorpusBuildOptions({
      outputDirectory: "candidate two",
      sourceMetadata: {
        mql5: { retrieved_at: "2026-07-18T00:00:00Z", http_etag: "fixture-new" },
        mql5book: { retrieved_at: "2026-07-18T00:00:00Z" },
        neuronetworksbook: { retrieved_at: "2026-07-18T00:00:00Z" },
      },
    }));
    assert.equal(first.indexRevision, second.indexRevision);
    assert.equal(first.databaseSha256, second.databaseSha256);

    const manifest = JSON.parse(await readFile(first.manifestPath, "utf8"));
    assert.equal(manifest.index_contract, INDEX_CONTRACT);
    assert.equal(manifest.index_revision, manifest.database.sha256);
    assert.equal(manifest.corpus_revision, manifest.corpus_sha256);
    assert.deepEqual({
      cataloged: manifest.assets.cataloged_count,
      exposed: manifest.assets.exposed_count,
      excluded: manifest.assets.excluded_count,
      occurrences: manifest.assets.occurrence_count,
      exposedOccurrences: manifest.assets.exposed_occurrence_count,
      bytes: manifest.assets.total_bytes,
    }, {
      cataloged: 2, exposed: 1, excluded: 1, occurrences: 3, exposedOccurrences: 2, bytes: png.length * 2,
    });

    const database = new DatabaseSync(first.databasePath, { readOnly: true });
    try {
      assert.equal(database.prepare("SELECT count(*) AS count FROM assets").get().count, 2);
      assert.equal(database.prepare("SELECT count(*) AS count FROM topic_assets").get().count, 3);
      assert.equal(database.prepare("SELECT count(*) AS count FROM assets WHERE exposure='exposed'").get().count, 1);
      assert.equal(database.prepare("SELECT value FROM metadata WHERE key='index_contract'").get().value, INDEX_CONTRACT);
      assert.equal(database.prepare("SELECT count(*) AS count FROM metadata WHERE key IN ('build_timestamp','indexed_at')").get().count, 0);
      const duplicate = database.prepare(`
        SELECT asset_id, count(*) AS count FROM topic_assets GROUP BY asset_id ORDER BY count DESC LIMIT 1
      `).get();
      assert.equal(duplicate.count, 2);
      assert.equal(database.prepare("SELECT canonical_caption FROM assets WHERE exposure='exposed'").get().canonical_caption, "Preferred canonical figure");
    } finally {
      database.close();
    }

    async function externalFiles(directory) {
      const results = [];
      for (const source of await readdir(directory, { withFileTypes: true })) {
        for (const entry of await readdir(path.join(directory, source.name), { withFileTypes: true })) {
          if (entry.isFile()) results.push(path.join(source.name, entry.name));
        }
      }
      return results.sort();
    }
    assert.equal((await externalFiles(first.assetsPath)).length, 2);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});


for (const version of [1, 2, 3, 4]) for (const mode of ["internal", "cli"]) {
  test(`contract v${version} owned output rebuilds with the ${mode} indexer`, async () => {
    const root = await mkdtemp(path.join(tmpdir(), "mql5-contract-rebuild-"));
    try {
      await createMiniCorpus(root);
      const options = miniCorpusBuildOptions({ outputDirectory: "output" });
      await buildIndex(root, options);
      const databasePath = path.join(root, "output", "mql5-docs.sqlite");
      const manifestPath = path.join(root, "output", "manifest.json");
      const original = JSON.parse(await readFile(manifestPath, "utf8"));
      const database = new DatabaseSync(databasePath);
      database.prepare("UPDATE metadata SET value=? WHERE key='index_contract'").run(`mql5-chm-index-v3-assets-v${version}`);
      database.close();
      const bytes = await readFile(databasePath);
      const legacy = { ...original, index_contract: `mql5-chm-index-v3-assets-v${version}`,
        index_revision: createHash("sha256").update(bytes).digest("hex"),
        database: { ...original.database, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") } };
      await writeFile(manifestPath, JSON.stringify(legacy));
      if (mode === "internal") await buildIndex(root, options);
      else {
        const child = spawnSync(process.execPath, ["--disable-warning=ExperimentalWarning",
          fileURLToPath(new URL("../src/indexer.mjs", import.meta.url)), "--root", root,
          "--source-directory", "sources", "--extracted-directory", "extracted", "--output-directory", "output"],
          { encoding: "utf8", timeout: 30_000 });
        assert.equal(child.status, 0, child.stderr);
        JSON.parse(child.stdout);
      }
      const rebuilt = JSON.parse(await readFile(manifestPath, "utf8"));
      assert.equal(rebuilt.index_contract, INDEX_CONTRACT);
      assert.equal(rebuilt.index_revision, original.index_revision);
      assert.equal(rebuilt.assets.catalog_sha256, original.assets.catalog_sha256);
      assert.equal(rebuilt.assets.tree_sha256, original.assets.tree_sha256);
      await buildIndex(root, options);
      assert.equal(JSON.parse(await readFile(manifestPath, "utf8")).index_revision, original.index_revision);
    } finally { await rm(root, { recursive: true, force: true }); }
  });
}
