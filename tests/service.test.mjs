import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test, { after, before } from "node:test";
import { fileURLToPath } from "node:url";

import * as searchServiceModule from "../src/search-service.mjs";

const { SUPPORTED_INDEX_CONTRACT, createSearchService, encodeCursor } = searchServiceModule;

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
let service;

async function databaseHash() {
  const active = JSON.parse(await readFile(path.join(root, "data", "active.json"), "utf8"));
  const databasePath = path.join(root, "revisions", active.active_revision, "mql5-docs.sqlite");
  return createHash("sha256").update(await readFile(databasePath)).digest("hex");
}

before(async () => {
  service = await createSearchService({ root });
});

after(() => service?.close());

test("exact API names rank the MQL5 reference first", () => {
  for (const query of ["OnTick", "PositionSelectByTicket", "OrderSend", "CopyBuffer"]) {
    const result = service.search({ query, source: "all", limit: 3 });
    assert.equal(result.results[0].title, query);
    assert.equal(result.results[0].source, "mql5");
    assert.ok(result.results[0].snippet.length <= 500);
  }
});

test("runtime accepts the current and rollback-compatible schema-3 index contracts", () => {
  assert.equal(SUPPORTED_INDEX_CONTRACT, "mql5-chm-index-v3-assets-v3");
  assert.equal(searchServiceModule.isSupportedIndexContract("mql5-chm-index-v3-assets-v2"), true);
  assert.equal(searchServiceModule.isSupportedIndexContract("mql5-chm-index-v3-assets-v1"), true);
  assert.equal(searchServiceModule.isSupportedIndexContract("mql5-chm-index-v3-assets-v999"), false);
});

test("topic content validation uses JavaScript UTF-16 lengths", () => {
  const topic = {
    content: "A😀B",
    content_length: 4,
    content_sha256: "a".repeat(64),
  };
  assert.equal(searchServiceModule.hasInvalidTopicContentRows([topic]), false);
  assert.equal(searchServiceModule.hasInvalidTopicContentRows([{ ...topic, content_length: 3 }]), true);
});

test("source filters and typo recovery work", () => {
  const neural = service.search({ query: "activation function", source: "neuronetworksbook", limit: 3 });
  assert.equal(neural.results[0].source, "neuronetworksbook");
  const typo = service.search({ query: "PositonSelectByTiket", source: "all", limit: 3 });
  assert.equal(typo.results[0].title, "PositionSelectByTicket");

  const shortApiTypo = service.search({ query: "ChatID", source: "all", limit: 3, expand: false });
  assert.ok(shortApiTypo.results.some((entry) => entry.title === "ChartID"));

  const neuralTypo = service.search({ query: "Droout", source: "all", limit: 3, expand: false });
  assert.equal(neuralTypo.results[0].source, "neuronetworksbook");
  assert.match(neuralTypo.results[0].title, /Dropout$/u);

  const bookTypo = service.search({ query: "Data inut", source: "all", limit: 3, expand: false });
  assert.equal(bookTypo.results[0].source, "mql5book");
  assert.equal(bookTypo.results[0].title, "1.8 Data input");
});

test("search tie-breakers are independent of the host's default locale", () => {
  const input = { query: "custom indicatr", source: "all", limit: 8, expand: false };
  const baseline = service.search(input).results.map((entry) => entry.topic_id);
  const localeCompareDescriptor = Object.getOwnPropertyDescriptor(String.prototype, "localeCompare");
  try {
    Object.defineProperty(String.prototype, "localeCompare", {
      ...localeCompareDescriptor,
      value(other) {
        const left = String(this);
        const right = String(other);
        return left < right ? 1 : left > right ? -1 : 0;
      },
    });
    const hostileLocale = service.search(input).results.map((entry) => entry.topic_id);
    assert.deepEqual(hostileLocale, baseline);
  } finally {
    Object.defineProperty(String.prototype, "localeCompare", localeCompareDescriptor);
  }
});

test("v1.1 expansions, citations, and official-check guidance are bounded", () => {
  for (const [query, expectedTitle] of [
    ["trade opening", "OrderSend"],
    ["open a trade", "OrderSend"],
    ["position tickets", "PositionSelectByTicket"],
    ["position by ticket", "PositionSelectByTicket"],
    ["indicator buffers", "CopyBuffer"],
    ["indicator buffer values", "CopyBuffer"],
  ]) {
    const result = service.search({ query, limit: 3, expand: true });
    const expanded = result.results.find((entry) => entry.title === expectedTitle);
    assert.ok(expanded, `${query} should include ${expectedTitle}`);
    assert.equal(expanded.match_kind, "expanded");
    assert.ok(expanded.matched_terms.length <= 12);
    assert.match(expanded.source_revision, /^[0-9a-f]{64}$/);
    assert.equal(expanded.citation.topic_id, expanded.topic_id);
    assert.ok(expanded.snippet.length <= 500);
  }

  const hedging = service.search({ query: "hedging account mode", limit: 3, expand: true });
  assert.match(hedging.results.map((entry) => entry.title).join("\n"), /hedging|Account Properties/i);
  const neural = service.search({ query: "neural network activation function", limit: 3, expand: true });
  assert.equal(neural.results[0].source, "neuronetworksbook");

  const disabled = service.search({ query: "open a trade", limit: 8, expand: false });
  assert.equal(disabled.results.some((entry) => entry.match_kind === "expanded"), false);

  const weighted = service.search({ query: "trade opening", limit: 8, expand: true });
  const orderSendIndex = weighted.results.findIndex((entry) => entry.title === "OrderSend");
  assert.ok(orderSendIndex > 0, "lower-weight expansion must not displace the top original FTS match");
  assert.ok(
    weighted.results.slice(orderSendIndex + 1).some((entry) => entry.match_kind === "fts"),
    "weighted expansion should enrich results without using a fixed end-of-list stage",
  );
  assert.equal(service.search({ query: "OnTick", require_current: true }).online_check.reason, "current-information-requested");
  assert.equal(service.search({ query: "OnTikk" }).online_check.reason, "fuzzy-only");
  assert.equal(service.search({ query: "zzzz-no-such-topic-7391" }).online_check.reason, "no-local-match");

  const unicodeQuery = `${"A".repeat(15)}😀${"B".repeat(183)}`;
  const officialSearchQuery = service.search({ query: unicodeQuery, require_current: true }).online_check.official_search_query;
  const unpairedSurrogate = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u;
  assert.ok(officialSearchQuery.length <= 500);
  assert.doesNotMatch(officialSearchQuery, unpairedSurrogate);
});

test("status and related topics expose the active verified revision", () => {
  const status = service.status();
  assert.ok([2, 3].includes(status.schema_version));
  assert.equal(status.index_revision, status.index_sha256);
  assert.match(status.index_sha256, /^[0-9a-f]{64}$/);
  assert.equal(status.totals.topics, 4_827);
  assert.equal(status.totals.sections, 16_261);
  assert.equal(status.totals.topic_links, 20_769);
  assert.equal(status.sources.length, 3);
  assert.equal(status.sources.reduce((sum, source) => sum + source.topic_count, 0), 4_827);
  assert.equal(status.asset_support_available, status.schema_version === 3);
  if (status.schema_version === 3) {
    assert.equal(status.assets.cataloged, 798);
    assert.equal(status.assets.exposed, 787);
    assert.equal(status.assets.excluded, 11);
    assert.equal(status.assets.occurrences, 828);
    assert.equal(status.assets.exposed_occurrences, 811);
    assert.equal(status.assets.bytes, 11_652_126);
  } else {
    assert.equal(status.assets.available, false);
    assert.throws(
      () => service.readImage({ asset_id: `mql5:asset:${"0".repeat(24)}` }),
      (error) => error?.code === "ASSET_CATALOG_UNAVAILABLE",
    );
  }

  const hit = service.search({ query: "OnTick", source: "mql5", limit: 1 }).results[0];
  const read = service.read({ topic_id: hit.topic_id, max_chars: 500, include_related: true, related_limit: 5 });
  assert.ok(read.related.length > 0 && read.related.length <= 5);
  const priorities = { "see-also": 0, inline: 1, "same-title": 2 };
  for (let index = 1; index < read.related.length; index += 1) {
    assert.ok(priorities[read.related[index - 1].relationship] <= priorities[read.related[index].relationship]);
  }
  assert.equal(read.citation.source_file, "mql5.chm");
  assert.ok(Array.isArray(read.images));
  assert.equal(read.next_image_cursor, null);
  assert.deepEqual(service.read({ topic_id: hit.topic_id, max_chars: 500, include_related: false }).related, []);
});

test("raw FTS syntax is harmless", () => {
  const result = service.search({ query: "OnTick OR *", source: "all", limit: 3 });
  assert.ok(result.count > 0);
  assert.ok(result.count <= 3);
});

test("read supports focus and opaque continuation", () => {
  const hit = service.search({ query: "PositionSelectByTicket", source: "mql5", limit: 1 }).results[0];
  const focused = service.read({ topic_id: hit.topic_id, focus: "Return Value", max_chars: 500 });
  assert.match(focused.text, /Return Value/i);
  assert.ok(focused.returned_chars <= 500);

  const first = service.read({ topic_id: hit.topic_id, max_chars: 500 });
  assert.ok(first.next_cursor);
  const second = service.read({ topic_id: hit.topic_id, cursor: first.next_cursor, max_chars: 500 });
  assert.ok(second.start_offset > first.start_offset);

  const otherHit = service.search({ query: "OrderSend", source: "mql5", limit: 1 }).results[0];
  assert.throws(
    () => service.read({ topic_id: otherHit.topic_id, cursor: first.next_cursor, max_chars: 500 }),
    (error) => error?.code === "INVALID_CURSOR" && /different topic/i.test(error.message),
  );

  const sections = service.database.prepare(
    "SELECT section_id FROM sections WHERE topic_id=? ORDER BY section_id LIMIT 2",
  ).all(hit.topic_id);
  assert.equal(sections.length, 2);
  const sectionCursor = encodeCursor({
    indexRevision: service.indexSha256,
    topicId: hit.topic_id,
    sectionId: sections[0].section_id,
    offset: 0,
  });
  assert.throws(
    () => service.read({ topic_id: hit.topic_id, section_id: sections[1].section_id, cursor: sectionCursor, max_chars: 500 }),
    (error) => error?.code === "INVALID_CURSOR" && /different section/i.test(error.message),
  );

  const staleCursor = encodeCursor({
    indexRevision: "f".repeat(64),
    topicId: hit.topic_id,
    offset: first.returned_chars,
  });
  assert.throws(
    () => service.read({ topic_id: hit.topic_id, cursor: staleCursor, max_chars: 500 }),
    (error) => error?.code === "INVALID_CURSOR" && /different index revision/i.test(error.message),
  );
  const missingTopicId = `${hit.topic_id.slice(0, -1)}${hit.topic_id.endsWith("0") ? "1" : "0"}`;
  assert.equal(service.database.prepare("SELECT 1 FROM topics WHERE topic_id=?").get(missingTopicId), undefined);
  assert.throws(
    () => service.read({ topic_id: missingTopicId, cursor: staleCursor, max_chars: 500 }),
    (error) => error?.code === "INVALID_CURSOR" && /different index revision/i.test(error.message),
  );
});

test("service handlers enforce bounds and stable IDs", () => {
  assert.throws(() => service.search({ query: "", limit: 3 }), /query/i);
  assert.throws(() => service.search({ query: "x".repeat(201), limit: 3 }), /query/i);
  assert.throws(() => service.search({ query: "OnTick", limit: 9 }), /limit/i);
  assert.throws(() => service.search({ query: "OnTick", limit: 10 }), /limit/i);
  for (const input of [
    { query: "OnTick", source: null },
    { query: "OnTick", limit: null },
    { query: "OnTick", expand: null },
    { query: "OnTick", require_current: null },
    { query: "OnTick", unexpected: true },
  ]) {
    assert.throws(
      () => service.search(input),
      (error) => error?.code === "INVALID_ARGUMENT",
      JSON.stringify(input),
    );
  }
  const hit = service.search({ query: "OnTick", limit: 1 }).results[0];
  assert.throws(() => service.read({ topic_id: hit.topic_id, max_chars: 12_000 }), /max_chars/i);
  assert.throws(() => service.read({ topic_id: hit.topic_id, cursor: "" }), /cursor/i);
  assert.throws(() => service.read({ topic_id: "..\\secret" }), /topic_id/i);
  for (const input of [
    { topic_id: hit.topic_id, max_chars: null },
    { topic_id: hit.topic_id, include_related: null },
    { topic_id: hit.topic_id, related_limit: null },
    { topic_id: hit.topic_id, include_images: null },
    { topic_id: hit.topic_id, image_limit: null },
    { topic_id: hit.topic_id, unexpected: true },
  ]) {
    assert.throws(
      () => service.read(input),
      (error) => error?.code === "INVALID_ARGUMENT",
      JSON.stringify(input),
    );
  }
});

test("database is read-only and unchanged by calls", async () => {
  const beforeHash = await databaseHash();
  assert.throws(() => service.database.exec("CREATE TABLE forbidden_write(value TEXT)"), /readonly|read-only/i);
  service.search({ query: "ACCOUNT_MARGIN_MODE_RETAIL_HEDGING", limit: 3 });
  const afterHash = await databaseHash();
  assert.equal(afterHash, beforeHash);
});
