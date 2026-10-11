import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { readFile } from "node:fs/promises";
import path from "node:path";

export async function main({ root }) {
  const server = new Server({ name: "benchmark-fixture", version: "1.0.0" }, { capabilities: { tools: {} } });
  const failure = await readFile(path.join(root, "fault.txt"), "utf8");
  let searches = 0, batches = 0;
  const search = identifier => ({ query: identifier, source: "mql5", count: 1, index_sha256: "fixture-index", corpus_revision: "fixture-corpus", results: [{ id: identifier, title: identifier, match_kind: "exact" }], online_check: { recommended: false, reason: null, official_search_query: null } });
  const reply = structuredContent => ({ structuredContent, content: [{ type: "text", text: JSON.stringify(structuredContent) }] });
  server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
    if (params.name === "mql5_chm_status") {
      if (failure === "status-error") return { isError: true, content: [{ type: "text", text: "controlled status error" }] };
      return reply({ corpus_revision: "fixture-corpus", index_revision: "fixture-index" });
    }
    // Identifier measurements request limit 1; the frozen quality matrix uses
    // limit 8 or the read/image interfaces. Malformed structured entries remain
    // protocol-valid so the real CLI exercises its grading failure path.
    if (failure.startsWith("quality-") && (params.name === "mql5_chm_read" || params.name === "mql5_chm_read_image" || params.arguments.limit === 8)) {
      if (failure === "quality-tool-error") return { isError: true, content: [{ type: "text", text: "controlled quality error" }] };
      if (params.name === "mql5_chm_read_image") return { structuredContent: {}, content: [{ type: "text", text: "missing image" }] };
      if (params.name === "mql5_chm_read") return reply({ images: failure === "quality-null-entry" ? [null] : {}, image_count: 1 });
      return reply({ query: params.arguments.query, source: params.arguments.source, count: 1, results: failure === "quality-null-entry" ? [null] : {} });
    }
    let measuredMode;
    let value;
    if (params.name === "mql5_chm_search") {
      searches++;
      measuredMode = searches === 2 ? "sequential" : searches === 3 ? "parallel" : null;
      value = search(params.arguments.query);
    } else if (params.name === "mql5_chm_lookup_identifiers") {
      batches++;
      measuredMode = batches === 2 ? "batch" : null;
      value = { source: "mql5", limit: params.arguments.limit, count: params.arguments.identifiers.length, result_count: params.arguments.identifiers.length, corpus_revision: "fixture-corpus", index_sha256: "fixture-index", lookups: params.arguments.identifiers.map(identifier => { const individual = search(identifier); return { identifier, match_status: "exact", count: 1, results: individual.results, online_check: individual.online_check }; }) };
    } else throw new Error("Unexpected fixture tool");
    if (failure === `${measuredMode}-error`) return { isError: true, content: [{ type: "text", text: "controlled measured error" }] };
    if (failure === `${measuredMode}-metadata`) {
      const target = measuredMode === "batch" ? value.lookups[0] : value;
      target.results = [{ id: "changed", title: "changed" }];
    }
    if (failure === `${measuredMode}-revision`) value.index_sha256 = "different-index";
    if (failure === `${measuredMode}-count`) value.count = 0;
    if (failure === "batch-match-status" && measuredMode === "batch") value.lookups[0].match_status = "none";
    return reply(value);
  });
  await server.connect(new StdioServerTransport());
}
