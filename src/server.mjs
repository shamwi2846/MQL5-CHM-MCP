import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ErrorCode, McpError } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { Mql5ChmError, createSearchService } from "./search-service.mjs";

const MODULE_PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const TOOL_ANNOTATIONS = Object.freeze({
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
});

const sha256Schema = z.string().regex(/^[0-9a-f]{64}$/);
const nullableTextSchema = z.string().nullable();
const sourceSchema = z.enum(["all", "mql5", "mql5book", "neuronetworksbook"]);
const corpusSourceSchema = z.enum(["mql5", "mql5book", "neuronetworksbook"]);
const topicIdSchema = z
  .string()
  .regex(/^(mql5|mql5book|neuronetworksbook):[0-9a-f]{24}$/, "Invalid stable topic ID");
const sectionIdSchema = z
  .string()
  .regex(/^(mql5|mql5book|neuronetworksbook):[0-9a-f]{24}:s\d{3}$/, "Invalid stable section ID");
const assetIdSchema = z
  .string()
  .regex(/^(mql5|mql5book|neuronetworksbook):asset:[0-9a-f]{24}$/, "Invalid stable asset ID");

function closedEmptyInputSchema() {
  const schema = z.strictObject({}).default({});
  const definition = schema?._zod?.def;
  if (
    !definition ||
    definition.type !== "default" ||
    !Reflect.defineProperty(definition, "shape", {
      value: {},
      enumerable: false,
      configurable: false,
      writable: false,
    })
  ) {
    throw new Error("The pinned MCP SDK/Zod empty-input schema compatibility guard failed.");
  }
  return schema;
}

const statusInputSchema = closedEmptyInputSchema();

function installInvalidToolRequestMapping(server) {
  const handlers = server?.server?._requestHandlers;
  const original = handlers instanceof Map ? handlers.get("tools/call") : null;
  if (typeof original !== "function") {
    throw new Error("The pinned MCP SDK tools/call compatibility guard failed.");
  }
  handlers.set("tools/call", async (request, extra) => {
    try {
      return await original(request, extra);
    } catch (error) {
      if (
        error instanceof z.ZodError ||
        error?.name === "ZodError" ||
        error?.name === "$ZodError"
      ) {
        throw new McpError(ErrorCode.InvalidParams, "Invalid tools/call parameters.");
      }
      throw error;
    }
  });
}

const citationSchema = z.object({
  source_file: z.string().min(1),
  title: z.string(),
  breadcrumb: z.string(),
  topic_id: topicIdSchema,
  section_id: sectionIdSchema.nullable(),
  source_revision: sha256Schema,
  corpus_revision: sha256Schema,
  index_revision: sha256Schema,
});
const relatedTopicSchema = z.object({
  topic_id: topicIdSchema,
  source: corpusSourceSchema,
  title: z.string(),
  breadcrumb: z.string(),
  relationship: z.enum(["see-also", "inline", "same-title"]),
  source_revision: sha256Schema,
  citation: citationSchema,
});
const imageReferenceSchema = z.object({
  asset_id: assetIdSchema,
  contextual_caption: z.string().max(500),
  mime_type: z.enum(["image/png", "image/jpeg"]),
  width: z.number().int().positive().max(4_096),
  height: z.number().int().positive().max(4_096),
  bytes: z.number().int().positive().max(2 * 1024 * 1024),
  section_id: sectionIdSchema,
  occurrence_count: z.number().int().positive(),
  citation: citationSchema,
});
const searchResultSchema = z.object({
  topic_id: topicIdSchema,
  section_id: sectionIdSchema.nullable(),
  source: corpusSourceSchema,
  title: z.string(),
  breadcrumb: z.string(),
  signature: z.string(),
  source_revision: sha256Schema,
  match_kind: z.enum(["exact", "fts", "expanded", "fuzzy"]),
  matched_terms: z.array(z.string()).max(12),
  citation: citationSchema,
});
const onlineCheckSchema = z.object({
  recommended: z.boolean(),
  reason: z.enum(["current-information-requested", "no-local-match", "fuzzy-only", "newer-revision-available"]).nullable(),
  official_search_query: nullableTextSchema,
});

function citationFooter(citation) {
  return `Source: ${citation.source_file} | ${citation.title} | ${citation.section_id ?? citation.topic_id} | source ${citation.source_revision.slice(0, 12)}`;
}

// The signature is printed on its own lines, so drop its exact flattened copy
// from the snippet. Only a verbatim match is removed; otherwise the snippet is kept.
function snippetWithoutSignature(snippet, signature) {
  if (!snippet || !signature) return snippet;
  const flattened = signature.replace(/\s+/gu, " ").trim();
  if (flattened.length < 12) return snippet;
  const index = snippet.indexOf(flattened);
  if (index < 0) return snippet;
  return `${snippet.slice(0, index).trimEnd()} ${snippet.slice(index + flattened.length).trimStart()}`.trim();
}

function searchText(result) {
  if (result.results.length === 0) {
    const suffix = result.online_check?.recommended && result.online_check.official_search_query
      ? `\nOfficial check suggested: ${result.online_check.official_search_query}`
      : "";
    return `No local MQL5 CHM topics matched “${result.query}”.${suffix}`;
  }
  const entries = result.results.map((entry, index) => {
    const lines = [`${index + 1}. ${entry.title} [${entry.match_kind}]`];
    if (entry.signature) lines.push(entry.signature);
    const snippet = snippetWithoutSignature(entry.snippet, entry.signature);
    if (snippet) lines.push(snippet);
    lines.push(citationFooter(entry.citation));
    return lines.join("\n");
  });
  if (result.online_check?.recommended && result.online_check.official_search_query) {
    entries.push(`Official check suggested: ${result.online_check.official_search_query}`);
  }
  return entries.join("\n\n");
}

function conciseSearchOutput(result) {
  return {
    query: result.query,
    source: result.source,
    count: result.count,
    index_sha256: result.index_sha256,
    corpus_revision: result.corpus_revision,
    online_check: result.online_check,
    results: result.results.map(({ snippet: _snippet, ...metadata }) => metadata),
  };
}

function batchText(result) {
  const lines = [`Identifier lookup: ${result.count} names, up to ${result.limit} results each.`, `Corpus: ${result.corpus_revision} | Index: ${result.index_sha256}`];
  for (const [index, lookup] of result.lookups.entries()) {
    lines.push(`${index + 1}. ${lookup.identifier} [${lookup.match_status}]`);
    for (const entry of lookup.results) lines.push(`  ${entry.title} [${entry.match_kind}] | ${citationFooter(entry.citation)}`);
    if (lookup.online_check.recommended) lines.push(`  Official check suggested: ${lookup.online_check.official_search_query}`);
  }
  return lines.join("\n");
}

function conciseBatchOutput(result) {
  return { ...result, lookups: result.lookups.map((lookup) => ({
    ...lookup, results: lookup.results.map(({ snippet: _snippet, ...metadata }) => metadata),
  })) };
}

function readText(result) {
  if (result.image_continuation) {
    return `Continued image references for ${result.title}. No documentation passage was repeated.\n\n${citationFooter(result.citation)}`;
  }
  const passage = result.text.replace(/\s+$/u, "");
  const focusNotice = result.focus_match === "none"
    ? "No match for the requested focus. Showing the selected documentation.\n\n"
    : result.focus_match === "approximate" ? "Approximate focus match. Verify the requested identifier in the passage.\n\n" : "";
  return `${focusNotice}${passage}\n\n${citationFooter(result.citation)}`;
}

function conciseReadOutput(result) {
  const { text: _text, ...metadata } = result;
  return metadata;
}

function statusText(result) {
  const totals = result.totals ?? {};
  const topics = totals.topics ?? result.topic_count ?? "unknown";
  const sections = totals.sections ?? result.section_count ?? "unknown";
  const lines = [
    `Active MQL5 CHM revision: ${result.active_revision}`,
    `Index: ${result.index_sha256}`,
    `Corpus: ${topics} topics, ${sections} sections.`,
    result.asset_support_available
      ? `Images: ${result.assets.exposed} technical assets available (${result.assets.exposed_occurrences} topic occurrences).`
      : "Images: unavailable for this legacy revision.",
  ];
  if (result.update_check) {
    lines.push(`Last update check: ${result.update_check.status} at ${result.update_check.checked_at}`);
  } else {
    lines.push("Last update check: none.");
  }
  return lines.join("\n");
}

function toolFailure(error) {
  const code = error instanceof Mql5ChmError ? error.code : "INTERNAL_ERROR";
  const message = error instanceof Mql5ChmError ? error.message : "The local documentation request failed.";
  process.stderr.write(`[mql5-chm] ${code}: ${message}\n`);
  return {
    isError: true,
    content: [{ type: "text", text: `${code}: ${message}` }],
  };
}

export function createMcpServer(service) {
  const server = new McpServer(
    { name: "mql5-chm", version: "1.3.11" },
    { capabilities: { tools: {} } },
  );

  server.registerTool(
    "mql5_chm_search",
    {
      title: "Search local MQL5 CHM documentation",
      description:
        "Search the verified offline MQL5 reference, MQL5 book, and neural-networks book. Exact API names outrank bounded MQL5-aware expansions and typo fallback. The limit input must be an integer from 1 to 8 and must not exceed 8. In answers, name each exact returned title, include citation.topic_id, and state citation.corpus_revision or citation.index_revision once per answer when findings share that revision.",
      inputSchema: z.strictObject({
        query: z.string().trim().min(1).max(200).describe("API name or documentation question"),
        source: sourceSchema.optional().default("all").describe("CHM corpus filter"),
        limit: z.number().int().min(1).max(8).optional().default(3)
          .describe("Number of ranked results; integer from 1 to 8 and must not exceed 8"),
        expand: z.boolean().optional().default(true).describe("Use bounded MQL5-aware query expansion"),
        require_current: z.boolean().optional().default(false).describe("Recommend an official-domain check"),
      }),
      outputSchema: {
        query: z.string(),
        source: sourceSchema,
        count: z.number().int().min(0).max(8),
        index_sha256: sha256Schema,
        corpus_revision: sha256Schema,
        online_check: onlineCheckSchema,
        results: z.array(searchResultSchema).max(8),
      },
      annotations: TOOL_ANNOTATIONS,
    },
    async (input) => {
      try {
        const result = service.search(input);
        return {
          content: [{ type: "text", text: searchText(result) }],
          structuredContent: conciseSearchOutput(result),
        };
      } catch (error) {
        return toolFailure(error);
      }
    },
  );

  server.registerTool(
    "mql5_chm_lookup_identifiers",
    {
      title: "Look up a bounded batch of MQL5 identifiers",
      description: "Look up 1 to 16 ASCII API or constant names in input order, including duplicates, using existing search rankings with expansion disabled. Default source is mql5; limit is 1 to 3 per identifier (default 1). Each name retains its own exact, non_exact or none search status, candidates, advisory check and citations. An exact search match is a lookup result: read and verify the complete identifier in the cited passage before asserting an API fact. The tool returns metadata, not documentation passages or images.",
      inputSchema: z.strictObject({
        identifiers: z.array(z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/u)).min(1).max(16)
          .describe("1 to 16 ASCII identifier names, each 1 to 128 characters; order and duplicates are preserved"),
        source: sourceSchema.optional().default("mql5"),
        limit: z.number().int().min(1).max(3).optional().default(1).describe("Maximum results per identifier, integer from 1 to 3"),
        require_current: z.boolean().optional().default(false),
      }),
      outputSchema: {
        source: sourceSchema,
        limit: z.number().int().min(1).max(3),
        count: z.number().int().min(1).max(16),
        result_count: z.number().int().min(0).max(48),
        index_sha256: sha256Schema,
        corpus_revision: sha256Schema,
        lookups: z.array(z.object({
          identifier: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/u),
          match_status: z.enum(["exact", "non_exact", "none"]),
          count: z.number().int().min(0).max(3),
          online_check: onlineCheckSchema,
          results: z.array(searchResultSchema).max(3),
        })).min(1).max(16),
      },
      annotations: TOOL_ANNOTATIONS,
    },
    async (input) => {
      try {
        const result = service.lookupIdentifiers(input);
        return { content: [{ type: "text", text: batchText(result) }], structuredContent: conciseBatchOutput(result) };
      } catch (error) { return toolFailure(error); }
    },
  );

  server.registerTool(
    "mql5_chm_read",
    {
      title: "Read local MQL5 CHM documentation",
      description:
        "Read a bounded passage from a stable topic ID. Optionally select a section or focus and include bounded related-topic metadata. For text-only work pass include_related:false and include_images:false. To continue, pass the returned next_cursor as cursor (or next_image_cursor as image_cursor) with the same topic_id and section_id; cursors expire when the server restarts. The max_chars input must be an integer from 500 to 8000 and must not exceed 8000. In answers, name the exact returned section_heading when present (otherwise title), include citation.topic_id and citation.section_id when relevant, and state citation.corpus_revision or citation.index_revision once per answer when findings share that revision.",
      inputSchema: z.strictObject({
        topic_id: topicIdSchema.describe("Stable topic ID returned by mql5_chm_search"),
        section_id: sectionIdSchema.optional().describe("Optional stable section ID from search"),
        focus: z.string().trim().min(1).max(200).optional().describe("Passage-selection query"),
        cursor: z.string().min(10).max(2_048).optional().describe("Opaque next_cursor from an earlier read of the same topic_id and section_id"),
        max_chars: z.number().int().min(500).max(8_000).optional().default(4_000)
          .describe("Maximum passage length; integer from 500 to 8000 and must not exceed 8000"),
        include_related: z.boolean().optional().default(true),
        related_limit: z.number().int().min(0).max(5).optional().default(3),
        include_images: z.boolean().optional().default(true).describe("Include bounded technical-image references when available"),
        image_limit: z.number().int().min(1).max(8).optional().default(5),
        image_cursor: z.string().min(10).max(2_048).optional().describe("Opaque next_image_cursor from an earlier read of the same topic_id and section_id"),
      }),
      outputSchema: {
        topic_id: topicIdSchema,
        section_id: sectionIdSchema.nullable(),
        source: corpusSourceSchema,
        title: z.string(),
        breadcrumb: z.string(),
        signature: z.string(),
        section_heading: nullableTextSchema,
        focus_match: z.enum(["exact", "approximate", "none"]).nullable().optional(),
        start_offset: z.number().int().nonnegative(),
        end_offset: z.number().int().nonnegative(),
        topic_start_offset: z.number().int().nonnegative(),
        topic_end_offset: z.number().int().nonnegative(),
        total_chars: z.number().int().nonnegative(),
        returned_chars: z.number().int().nonnegative().max(8_000),
        index_sha256: sha256Schema,
        corpus_revision: sha256Schema,
        source_revision: sha256Schema,
        next_cursor: z.string().nullable(),
        citation: citationSchema,
        related: z.array(relatedTopicSchema).max(5),
        images: z.array(imageReferenceSchema).max(8),
        image_count: z.number().int().nonnegative(),
        next_image_cursor: z.string().nullable(),
        image_continuation: z.boolean(),
      },
      annotations: TOOL_ANNOTATIONS,
    },
    async (input) => {
      try {
        const result = service.read(input);
        return {
          content: [{ type: "text", text: readText(result) }],
          structuredContent: conciseReadOutput(result),
        };
      } catch (error) {
        return toolFailure(error);
      }
    },
  );

  server.registerTool(
    "mql5_chm_read_image",
    {
      title: "Read one local MQL5 CHM technical image",
      description:
        "Return exactly one verified original PNG or JPEG by stable asset ID. Paths, URLs, batches, resizing, and variants are not accepted.",
      inputSchema: z.strictObject({
        asset_id: assetIdSchema.describe("Stable asset ID returned by mql5_chm_read"),
      }),
      outputSchema: {
        asset_id: assetIdSchema,
        source: corpusSourceSchema,
        canonical_caption: z.string().max(500),
        mime_type: z.enum(["image/png", "image/jpeg"]),
        bytes: z.number().int().positive().max(2 * 1024 * 1024),
        width: z.number().int().positive().max(4_096),
        height: z.number().int().positive().max(4_096),
        sha256: sha256Schema,
        association_count: z.number().int().positive(),
        primary_topic_citation: citationSchema,
        source_revision: sha256Schema,
        corpus_revision: sha256Schema,
        index_revision: sha256Schema,
      },
      annotations: TOOL_ANNOTATIONS,
    },
    async (input) => {
      try {
        const result = service.readImage(input);
        return {
          content: [{ type: "image", data: result.data, mimeType: result.metadata.mime_type }],
          structuredContent: result.metadata,
        };
      } catch (error) {
        return toolFailure(error);
      }
    },
  );

  server.registerTool(
    "mql5_chm_status",
    {
      title: "Show local MQL5 CHM documentation status",
      description:
        "Report the active verified corpus and index revisions, source metadata, counts, and the last validated manual update check.",
      // SDK 1.29.0 otherwise replaces this default-wrapped strict object with
      // an open empty schema in tools/list. The guarded shape marker preserves
      // both omitted-argument defaulting and additionalProperties: false.
      inputSchema: statusInputSchema,
      outputSchema: {
        schema_version: z.number().int().positive(),
        active_revision: sha256Schema,
        index_revision: sha256Schema,
        previous_revision: sha256Schema.nullable(),
        activated_at: z.string(),
        corpus_revision: sha256Schema,
        index_sha256: sha256Schema,
        indexed_at: z.string(),
        build_timestamp: z.string(),
        totals: z.object({
          topics: z.number().int().nonnegative(),
          sections: z.number().int().nonnegative(),
          topic_links: z.number().int().nonnegative(),
          resolved_topic_links: z.number().int().nonnegative(),
          unresolved_topic_links: z.number().int().nonnegative(),
        }),
        asset_support_available: z.boolean(),
        assets: z.object({
          available: z.boolean(),
          cataloged: z.number().int().nonnegative(),
          exposed: z.number().int().nonnegative(),
          excluded: z.number().int().nonnegative(),
          occurrences: z.number().int().nonnegative(),
          exposed_occurrences: z.number().int().nonnegative(),
          bytes: z.number().int().nonnegative(),
          by_source: z.record(corpusSourceSchema, z.object({
            cataloged: z.number().int().nonnegative(),
            exposed: z.number().int().nonnegative(),
            excluded: z.number().int().nonnegative(),
            occurrences: z.number().int().nonnegative(),
            exposed_occurrences: z.number().int().nonnegative(),
            bytes: z.number().int().nonnegative(),
          })),
        }),
        sources: z.array(
          z.object({
            source: corpusSourceSchema,
            filename: z.string().min(1),
            sha256: sha256Schema,
            bytes: z.number().int().positive(),
            http_last_modified: nullableTextSchema,
            http_etag: nullableTextSchema,
            retrieved_at: nullableTextSchema,
            topic_count: z.number().int().nonnegative(),
            section_count: z.number().int().nonnegative(),
            asset_count: z.number().int().nonnegative(),
            exposed_asset_count: z.number().int().nonnegative(),
            excluded_asset_count: z.number().int().nonnegative(),
            asset_occurrence_count: z.number().int().nonnegative(),
            exposed_asset_occurrence_count: z.number().int().nonnegative(),
            asset_bytes: z.number().int().nonnegative(),
          }),
        ).length(3),
        update_check: z
          .union([z.object({
            schema_version: z.literal(1),
            checked_at: z.string(),
            status: z.enum(["up-to-date", "different-revision-available", "check-unavailable"]),
            active_revision: sha256Schema,
            candidate_revision: sha256Schema.nullable(),
            message: z.string(),
          }), z.object({
            schema_version: z.literal(2),
            checked_at: z.string(),
            status: z.enum(["up-to-date", "different-revision-available", "check-unavailable"]),
            active_revision: sha256Schema,
            active_corpus_revision: sha256Schema,
            candidate_revision: sha256Schema.nullable(),
            candidate_corpus_revision: sha256Schema.nullable(),
            message: z.string(),
          })])
          .nullable(),
      },
      annotations: TOOL_ANNOTATIONS,
    },
    async () => {
      try {
        const result = service.status();
        return {
          content: [{ type: "text", text: statusText(result) }],
          structuredContent: result,
        };
      } catch (error) {
        return toolFailure(error);
      }
    },
  );

  // SDK 1.29.0 otherwise maps outer tools/call schema failures to -32603.
  // The pinned, guarded wrapper preserves the protocol's -32602 contract.
  installInvalidToolRequestMapping(server);
  return server;
}

export async function main({ root = MODULE_PROJECT_ROOT } = {}) {
  let service;
  let server;
  try {
    service = await createSearchService({ root });
    server = createMcpServer(service);
    const transport = new StdioServerTransport();
    await server.connect(transport);
    process.stderr.write("[mql5-chm] verified read-only stdio server ready.\n");
  } catch (error) {
    const code = error instanceof Mql5ChmError ? error.code : "STARTUP_FAILED";
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`[mql5-chm] ${code}: ${message}\n`);
    try {
      await server?.close();
    } catch {
      // Preserve the startup failure.
    }
    service?.close();
    process.exitCode = 1;
  }
}

function isDirectInvocation() {
  if (!process.argv[1]) return false;
  const current = resolve(fileURLToPath(import.meta.url));
  const invoked = resolve(process.argv[1]);
  return process.platform === "win32" ? current.toLowerCase() === invoked.toLowerCase() : current === invoked;
}

if (isDirectInvocation()) {
  await main();
}
