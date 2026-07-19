import assert from "node:assert/strict";
import test from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { createMcpServer } from "../src/server.mjs";

const sourceRevision = "a".repeat(64);
const corpusRevision = "b".repeat(64);
const indexRevision = "c".repeat(64);
const topicId = `mql5:${"1".repeat(24)}`;
const relatedTopicId = `mql5book:${"2".repeat(24)}`;
const assetId = `mql5:asset:${"3".repeat(24)}`;

function citation(id = topicId, sourceFile = "mql5.chm", title = "PositionSelectByTicket") {
  return {
    source_file: sourceFile,
    title,
    breadcrumb: `Reference > ${title}`,
    topic_id: id,
    section_id: null,
    source_revision: sourceRevision,
    corpus_revision: corpusRevision,
    index_revision: indexRevision,
  };
}

const fakeService = {
  search(input) {
    return {
      query: input.query,
      source: input.source,
      count: 1,
      index_sha256: indexRevision,
      corpus_revision: corpusRevision,
      online_check: {
        recommended: input.require_current,
        reason: input.require_current ? "current-information-requested" : null,
        official_search_query: input.require_current
          ? `site:mql5.com/en/docs "${input.query}"`
          : null,
      },
      results: [{
        topic_id: topicId,
        section_id: null,
        source: "mql5",
        title: "PositionSelectByTicket",
        breadcrumb: "Reference > PositionSelectByTicket",
        signature: "bool PositionSelectByTicket(ulong ticket)",
        source_revision: sourceRevision,
        match_kind: "exact",
        matched_terms: ["positionselectbyticket"],
        citation: citation(),
        snippet: "Selects an open position by ticket.",
      }],
    };
  },
  read() {
    return {
      topic_id: topicId,
      section_id: null,
      source: "mql5",
      title: "PositionSelectByTicket",
      breadcrumb: "Reference > PositionSelectByTicket",
      signature: "bool PositionSelectByTicket(ulong ticket)",
      section_heading: null,
      start_offset: 0,
      end_offset: 24,
      topic_start_offset: 0,
      topic_end_offset: 24,
      total_chars: 24,
      returned_chars: 24,
      index_sha256: indexRevision,
      corpus_revision: corpusRevision,
      source_revision: sourceRevision,
      next_cursor: null,
      citation: citation(),
      related: [{
        topic_id: relatedTopicId,
        source: "mql5book",
        title: "Position selection",
        breadcrumb: "AlgoBook > Position selection",
        relationship: "see-also",
        source_revision: sourceRevision,
        citation: citation(relatedTopicId, "mql5book.chm", "Position selection"),
      }],
      images: [{
        asset_id: assetId,
        contextual_caption: "Object type icon",
        mime_type: "image/png",
        width: 16,
        height: 16,
        bytes: 68,
        section_id: `${topicId}:s000`,
        occurrence_count: 1,
        citation: { ...citation(), section_id: `${topicId}:s000` },
      }],
      image_count: 1,
      next_image_cursor: null,
      image_continuation: false,
      text: "Return Value\nReturns true.",
    };
  },
  readImage() {
    return {
      data: Buffer.from("verified-image").toString("base64"),
      metadata: {
        asset_id: assetId,
        source: "mql5",
        canonical_caption: "Object type icon",
        mime_type: "image/png",
        bytes: 68,
        width: 16,
        height: 16,
        sha256: sourceRevision,
        association_count: 1,
        primary_topic_citation: citation(),
        source_revision: sourceRevision,
        corpus_revision: corpusRevision,
        index_revision: indexRevision,
      },
    };
  },
  status() {
    return {
      schema_version: 3,
      active_revision: corpusRevision,
      index_revision: indexRevision,
      previous_revision: null,
      activated_at: "2026-07-17T00:00:00.000Z",
      corpus_revision: corpusRevision,
      index_sha256: indexRevision,
      indexed_at: "2026-07-17T00:00:00.000Z",
      build_timestamp: "2026-07-17T00:00:00.000Z",
      totals: {
        topics: 4_827,
        sections: 16_261,
        topic_links: 20_769,
        resolved_topic_links: 20_769,
        unresolved_topic_links: 0,
      },
      asset_support_available: true,
      assets: {
        available: true,
        cataloged: 798,
        exposed: 787,
        excluded: 11,
        occurrences: 828,
        exposed_occurrences: 811,
        bytes: 11_652_126,
        by_source: Object.fromEntries(["mql5", "mql5book", "neuronetworksbook"].map((source) => [source, {
          cataloged: source === "mql5" ? 640 : source === "mql5book" ? 86 : 72,
          exposed: source === "mql5" ? 637 : source === "mql5book" ? 81 : 69,
          excluded: source === "mql5" ? 3 : source === "mql5book" ? 5 : 3,
          occurrences: source === "mql5" ? 660 : source === "mql5book" ? 90 : 78,
          exposed_occurrences: source === "mql5" ? 655 : source === "mql5book" ? 82 : 74,
          bytes: source === "mql5" ? 8_000_000 : source === "mql5book" ? 2_000_000 : 1_652_126,
        }])),
      },
      sources: ["mql5", "mql5book", "neuronetworksbook"].map((source) => ({
        source,
        filename: `${source}.chm`,
        sha256: sourceRevision,
        bytes: 1_000,
        http_last_modified: null,
        http_etag: null,
        retrieved_at: "2026-07-17T00:00:00.000Z",
        topic_count: source === "mql5" ? 4_134 : source === "mql5book" ? 581 : 112,
        section_count: source === "mql5" ? 14_921 : source === "mql5book" ? 1_176 : 164,
        asset_count: 1,
        exposed_asset_count: 1,
        excluded_asset_count: 0,
        asset_occurrence_count: 1,
        exposed_asset_occurrence_count: 1,
        asset_bytes: 68,
      })),
      update_check: null,
    };
  },
};

test("source MCP exposes v1.2 schemas and keeps text and image bytes in separate content fields", async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const server = createMcpServer(fakeService);
  const client = new Client({ name: "mql5-chm-source-test", version: "1.1.0" });
  try {
    await server.connect(serverTransport);
    await client.connect(clientTransport);

    const listed = await client.listTools();
    assert.deepEqual(
      listed.tools.map((tool) => tool.name).sort(),
      ["mql5_chm_read", "mql5_chm_read_image", "mql5_chm_search", "mql5_chm_status"],
    );
    for (const tool of listed.tools) {
      assert.deepEqual(tool.annotations, {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      });
    }
    const imageTool = listed.tools.find((tool) => tool.name === "mql5_chm_read_image");
    assert.equal(imageTool.inputSchema.additionalProperties, false);
    assert.deepEqual(imageTool.inputSchema.required, ["asset_id"]);

    const search = await client.callTool({
      name: "mql5_chm_search",
      arguments: { query: "PositionSelectByTicket", require_current: true },
    });
    assert.equal(search.isError, undefined);
    assert.equal(Object.hasOwn(search.structuredContent.results[0], "snippet"), false);
    assert.equal(search.structuredContent.results[0].match_kind, "exact");

    const read = await client.callTool({ name: "mql5_chm_read", arguments: { topic_id: topicId } });
    assert.equal(read.isError, undefined);
    assert.equal(Object.hasOwn(read.structuredContent, "text"), false);
    assert.equal((read.content[0].text.match(/^Source: /gmu) ?? []).length, 1);
    assert.equal(read.structuredContent.related[0].relationship, "see-also");
    assert.equal(read.structuredContent.images[0].asset_id, assetId);
    assert.equal(JSON.stringify(read.structuredContent).includes("verified-image"), false);

    const image = await client.callTool({ name: "mql5_chm_read_image", arguments: { asset_id: assetId } });
    assert.equal(image.isError, undefined);
    assert.equal(image.content.length, 1);
    assert.equal(image.content[0].type, "image");
    assert.equal(image.content[0].mimeType, "image/png");
    assert.equal(Object.hasOwn(image.structuredContent, "data"), false);
    const extraArgument = await client.callTool({
      name: "mql5_chm_read_image",
      arguments: { asset_id: assetId, path: "secret.png" },
    });
    assert.equal(extraArgument.isError, true);
    assert.match(extraArgument.content[0].text, /Invalid arguments|unrecognized|validation/i);

    const status = await client.callTool({ name: "mql5_chm_status", arguments: {} });
    assert.equal(status.isError, undefined);
    assert.equal(status.structuredContent.totals.topics, 4_827);
  } finally {
    await client.close();
    await server.close();
  }
});
