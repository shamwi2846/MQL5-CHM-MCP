import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import iconv from "iconv-lite";

import {
  decodeHtml,
  detectHtmlEncoding,
  makeSectionId,
  makeTopicId,
  normalizeInternalPath,
  parseHtmlTopic,
} from "../src/indexer.mjs";
import {
  Mql5ChmSearchService,
  buildFtsQuery,
  decodeCursor,
  encodeCursor,
  makeSnippet,
  trigramSimilarity,
} from "../src/search-service.mjs";

test("legacy CHM encodings are detected and decoded", () => {
  const html = '<meta http-equiv="Content-Type" content="text/html; charset=Windows-1252"><div id="help">Caf\u00e9 \u2014 test</div>';
  const encoded = iconv.encode(html, "windows-1252");
  assert.equal(detectHtmlEncoding(encoded), "windows-1252");
  assert.match(decodeHtml(encoded), /Caf\u00e9 \u2014 test/);
});

test("stable IDs reject traversal and remain deterministic", () => {
  assert.equal(normalizeInternalPath("/Trading/OrderSend.htm#top"), "Trading/OrderSend.htm");
  assert.throws(() => normalizeInternalPath("../secret.htm"), /Unsafe CHM internal path/);
  const first = makeTopicId("mql5", "OrderSend.htm");
  const second = makeTopicId("mql5", "ordersend.htm");
  assert.equal(first, second);
  assert.match(first, /^mql5:[0-9a-f]{24}$/);
  assert.equal(makeSectionId(first, 2), `${first}:s002`);
});

test("HTML parsing keeps code layout, signature, breadcrumbs, and sections", () => {
  const topic = parseHtmlTopic(
    `<!doctype html><html><head><title>ExampleFn</title><meta name="keywords" content="ExampleFn, sample"></head>
    <body><div class="nav">MQL5 Reference / Test / ExampleFn</div><div id="help">
    <p class="p_H1">ExampleFn</p><p>Does the example work.</p>
    <p class="p_CodeExample">bool&nbsp;&nbsp;ExampleFn(<br>&nbsp;&nbsp;int value<br>);</p>
    <p class="p_BoldTitles">Return Value</p><p>True on success.</p></div></body></html>`,
    { source: "mql5", internalPath: "examplefn.htm" },
  );
  assert.equal(topic.title, "ExampleFn");
  assert.match(topic.signature, /bool\s+ExampleFn\(/);
  assert.match(topic.content, /int value\n\);/);
  assert.ok(topic.sections.some((section) => /Return Value/i.test(section.heading)));
  assert.ok(topic.aliases.includes("sample"));
});

test("FTS input is tokenized instead of accepting raw syntax", () => {
  assert.equal(buildFtsQuery('OnTick OR * "bad"'), '"ontick"* AND "or"* AND "bad"*');
  assert.ok(trigramSimilarity("PositonSelectByTiket", "PositionSelectByTicket") > 0.7);
  assert.ok(makeSnippet("x".repeat(2_000), "x", 500).length <= 500);
});

test("opaque cursors round-trip and reject tampering", () => {
  const topicId = "mql5:0123456789abcdef01234567";
  const cursor = encodeCursor({ topicId, offset: 500 });
  assert.deepEqual(decodeCursor(cursor), { topicId, sectionId: null, offset: 500 });
  assert.throws(() => decodeCursor(`${cursor.slice(0, -1)}0`), /cursor/i);
});

test("malformed optional update status never disables MCP status", () => {
  const projectRoot = mkdtempSync(join(tmpdir(), "mql5-chm-status-"));
  try {
    const maintenance = join(projectRoot, "maintenance");
    mkdirSync(maintenance);
    const revision = "a".repeat(64);
    const source = (filename) => ({
      filename,
      sha256: "b".repeat(64),
      bytes: 1,
      http_last_modified: null,
      http_etag: null,
      retrieved_at: "2026-01-01T00:00:00.000Z",
      topic_count: 1,
      section_count: 1,
    });
    const service = new Mql5ChmSearchService(
      { close() {} },
      {
        projectRoot,
        databaseHash: "c".repeat(64),
        activePointer: { active_revision: revision, previous_revision: null, activated_at: "2026-01-01T00:00:00.000Z" },
        manifest: {
          corpus_sha256: revision,
          indexed_at: "2026-01-01T00:00:00.000Z",
          build_timestamp: "2026-01-01T00:00:00.000Z",
          total_topic_count: 3,
          total_section_count: 3,
          topic_link_count: 0,
          resolved_topic_link_count: 0,
          unresolved_topic_link_count: 0,
          sources: {
            mql5: source("mql5.chm"),
            mql5book: source("mql5book.chm"),
            neuronetworksbook: source("neuronetworksbook.chm"),
          },
        },
      },
    );
    for (const invalid of [
      "{",
      JSON.stringify({ schema_version: 1, unexpected: true }),
      JSON.stringify({ schema_version: 99 }),
    ]) {
      writeFileSync(join(maintenance, "update-status.json"), invalid, "utf8");
      assert.equal(service.status().update_check, null);
    }
    service.close();
  } finally {
    rmSync(projectRoot, { recursive: true, force: true });
  }
});
