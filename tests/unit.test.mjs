import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import iconv from "iconv-lite";

import {
  decodeHtml,
  detectHtmlEncoding,
  createSchema,
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
  const indexRevision = "a".repeat(64);
  const cursor = encodeCursor({ indexRevision, topicId, offset: 500 });
  assert.deepEqual(decodeCursor(cursor), { indexRevision, topicId, sectionId: null, offset: 500 });
  assert.throws(() => decodeCursor(`${cursor.slice(0, -1)}0`), /cursor/i);
  assert.throws(() => encodeCursor({ topicId, offset: 500 }), /cursor/i);

  const legacyBody = Buffer.from(JSON.stringify({ v: 1, t: topicId, s: null, o: 500 }), "utf8").toString("base64url");
  const legacyTag = createHash("sha256")
    .update("mql5-chm-read-cursor-v1\0")
    .update(legacyBody)
    .digest("hex")
    .slice(0, 24);
  assert.throws(() => decodeCursor(`${legacyBody}.${legacyTag}`), /cursor/i);
});

test("text continuation preserves supplementary Unicode at UTF-16 boundaries", () => {
  const database = new DatabaseSync(":memory:");
  const projectRoot = mkdtempSync(join(tmpdir(), "mql5-unicode-cursor-"));
  const topicId = makeTopicId("mql5", "unicode-cursor.htm");
  const content = `${"x".repeat(499)}😀${"y".repeat(700)}`;
  try {
    createSchema(database);
    database.prepare(`
      INSERT INTO sources(source, chm_filename, chm_sha256, chm_bytes, topic_count, section_count)
      VALUES('mql5', 'mql5.chm', ?, 1, 1, 0)
    `).run("b".repeat(64));
    database.prepare(`
      INSERT INTO topics(topic_id, source, internal_path, title, normalized_title, breadcrumb, signature, content_sha256, content, content_length)
      VALUES(?, 'mql5', 'unicode-cursor.htm', 'Unicode Cursor', 'unicode cursor', 'Unicode Cursor', '', ?, ?, ?)
    `).run(topicId, createHash("sha256").update(content, "utf8").digest("hex"), content, content.length);
    const source = (filename) => ({ filename, sha256: "b".repeat(64) });
    const unicodeService = new Mql5ChmSearchService(database, {
      projectRoot,
      databaseHash: "c".repeat(64),
      activePointer: { active_revision: "c".repeat(64), previous_revision: null, activated_at: "2026-01-01T00:00:00.000Z" },
      manifest: {
        schema_version: 2,
        corpus_sha256: "a".repeat(64),
        sources: {
          mql5: source("mql5.chm"),
          mql5book: source("mql5book.chm"),
          neuronetworksbook: source("neuronetworksbook.chm"),
        },
      },
    });
    const parts = [];
    let cursor = null;
    do {
      const page = unicodeService.read({
        topic_id: topicId,
        ...(cursor ? { cursor } : {}),
        max_chars: 500,
        include_related: false,
        include_images: false,
      });
      assert.doesNotMatch(page.text, /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u);
      parts.push(page.text);
      cursor = page.next_cursor;
    } while (cursor);
    assert.equal(parts.join(""), content);

    const focusContent = `${"x".repeat(499)}😀${"y".repeat(99)}needle${"z".repeat(700)}`;
    database.prepare(`
      UPDATE topics SET content_sha256=?, content=?, content_length=? WHERE topic_id=?
    `).run(createHash("sha256").update(focusContent, "utf8").digest("hex"), focusContent, focusContent.length, topicId);
    const focused = unicodeService.read({
      topic_id: topicId,
      focus: "needle",
      max_chars: 500,
      include_related: false,
      include_images: false,
    });
    assert.equal(focused.start_offset, 499);
    assert.ok(focused.text.startsWith("😀"));
    assert.match(focused.text, /needle/u);
    assert.doesNotMatch(focused.text, /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u);
  } finally {
    database.close();
    rmSync(projectRoot, { recursive: true, force: true });
  }
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
