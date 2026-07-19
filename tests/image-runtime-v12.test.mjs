import assert from "node:assert/strict";
import test from "node:test";
import jpegCodec from "jpeg-js";
import { deflateSync } from "node:zlib";

import {
  decodeImageCursor,
  encodeImageCursor,
  inspectRasterImage,
  makeRuntimeAssetId,
} from "../src/search-service.mjs";

const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function apngFromPng(source) {
  const type = Buffer.from("acTL", "ascii");
  const data = Buffer.alloc(8);
  data.writeUInt32BE(1, 0);
  const chunk = Buffer.alloc(20);
  chunk.writeUInt32BE(data.length, 0);
  type.copy(chunk, 4);
  data.copy(chunk, 8);
  chunk.writeUInt32BE(crc32(Buffer.concat([type, data])), 16);
  return Buffer.concat([source.subarray(0, 33), chunk, source.subarray(33)]);
}

function pngWithoutImageData(source) {
  const chunks = [source.subarray(0, 8)];
  let offset = 8;
  while (offset < source.length) {
    const length = source.readUInt32BE(offset);
    const end = offset + 12 + length;
    if (source.subarray(offset + 4, offset + 8).toString("ascii") !== "IDAT") chunks.push(source.subarray(offset, end));
    offset = end;
  }
  return Buffer.concat(chunks);
}

function withInvalidPngBitDepth(source) {
  const copy = Buffer.from(source);
  copy[24] = 3;
  const typeAndData = copy.subarray(12, 29);
  copy.writeUInt32BE(crc32(typeAndData), 29);
  return copy;
}

function pngChunk(type, data = Buffer.alloc(0)) {
  const typeBytes = Buffer.from(type, "ascii");
  const chunk = Buffer.alloc(12 + data.length);
  chunk.writeUInt32BE(data.length, 0);
  typeBytes.copy(chunk, 4);
  data.copy(chunk, 8);
  chunk.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])), 8 + data.length);
  return chunk;
}

function makeCustomPng({ width = 1, height = 1, bitDepth = 8, colorType = 6, raw = Buffer.from([0, 0, 0, 0, 0]), extra = [] } = {}) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = bitDepth;
  header[9] = colorType;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", header),
    ...extra,
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND"),
  ]);
}

test("stable asset IDs case-fold normalized CHM paths", () => {
  const lower = makeRuntimeAssetId("mql5", "images/object.png");
  const mixed = makeRuntimeAssetId("mql5", "Images/Object.PNG");
  assert.equal(lower, mixed);
  assert.match(lower, /^mql5:asset:[0-9a-f]{24}$/);
});

test("runtime raster inspection accepts static PNG/JPEG and rejects unsafe payloads", () => {
  assert.deepEqual(inspectRasterImage(png), { mime: "image/png", width: 1, height: 1 });

  const malformedJpeg = Buffer.from([
    0xff, 0xd8,
    0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00,
    0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00,
    0x00, 0xff, 0xd9,
  ]);
  const jpeg = jpegCodec.encode({ width: 1, height: 1, data: Buffer.from([0x20, 0x40, 0x60, 0xff]) }, 90).data;
  assert.deepEqual(inspectRasterImage(jpeg), { mime: "image/jpeg", width: 1, height: 1 });
  assert.throws(() => inspectRasterImage(malformedJpeg), /JPEG/i);
  assert.throws(() => inspectRasterImage(png.subarray(0, 40)), /PNG/i);
  assert.throws(() => inspectRasterImage(pngWithoutImageData(png)), /PNG/i);
  assert.throws(() => inspectRasterImage(withInvalidPngBitDepth(png)), /PNG/i);
  assert.throws(() => inspectRasterImage(makeCustomPng({ raw: Buffer.from([5, 0, 0, 0, 0]) })), /filter/i);
  assert.throws(() => inspectRasterImage(makeCustomPng({ colorType: 3, raw: Buffer.from([0, 0]) })), /palette/i);
  assert.throws(() => inspectRasterImage(makeCustomPng({ extra: [pngChunk("ABCD")] })), /critical/i);
  assert.throws(() => inspectRasterImage(makeCustomPng({ extra: [pngChunk("abca")] })), /chunk type/i);
  assert.throws(() => inspectRasterImage(makeCustomPng({ width: 4_097, raw: Buffer.from([0]) })), /dimension|pixel/i);
  assert.throws(() => inspectRasterImage(Buffer.concat([png, Buffer.from("trailing")])), /terminator|PNG/i);
  assert.throws(() => inspectRasterImage(apngFromPng(png)), /APNG/i);
  assert.throws(() => inspectRasterImage(Buffer.from("<svg><script/></svg>")), /Unsupported/i);
});

test("image cursors bind index, topic, section, and offset", () => {
  const indexRevision = "a".repeat(64);
  const topicId = `mql5:${"b".repeat(24)}`;
  const sectionId = `${topicId}:s004`;
  const cursor = encodeImageCursor({ indexRevision, topicId, sectionId, offset: 8 });
  assert.deepEqual(decodeImageCursor(cursor), { indexRevision, topicId, sectionId, offset: 8 });
  assert.throws(() => decodeImageCursor(`${cursor.slice(0, -1)}0`), /cursor/i);
  assert.throws(
    () => encodeImageCursor({ indexRevision, topicId: "../topic", sectionId: null, offset: 0 }),
    /invalid/i,
  );
});
