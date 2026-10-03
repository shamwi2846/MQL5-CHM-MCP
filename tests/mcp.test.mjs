import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { lstat, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CallToolResultSchema, ErrorCode } from "@modelcontextprotocol/sdk/types.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const packageRoot = path.resolve(process.env.MQL5_CHM_TEST_ROOT ?? root);
const nodePath = path.resolve(process.env.MQL5_CHM_TEST_NODE ?? path.join(root, "runtime", "node.exe"));
const serverPath = path.resolve(
  process.env.MQL5_CHM_TEST_SERVER ?? path.join(root, "build", "candidate-v12", "app", "server.mjs"),
);
const directServerInvocation = process.env.MQL5_CHM_TEST_DIRECT_SERVER === "1";

async function activeArtifactHashes() {
  const activePath = path.join(packageRoot, "data", "active.json");
  const active = JSON.parse(await readFile(activePath, "utf8"));
  const revisionRoot = path.join(packageRoot, "revisions", active.active_revision);
  const files = [activePath];
  const visit = async (directory) => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const pathname = path.join(directory, entry.name);
      const info = await lstat(pathname);
      assert.equal(info.isSymbolicLink(), false, `immutable revision contains a reparse point: ${pathname}`);
      if (entry.isDirectory()) await visit(pathname);
      else if (entry.isFile()) files.push(pathname);
    }
  };
  await visit(revisionRoot);
  files.sort();
  return Object.fromEntries(
    await Promise.all(
      files.map(async (file) => [file, createHash("sha256").update(await readFile(file)).digest("hex")]),
    ),
  );
}

test("portable stdio MCP resists ambient root redirection and calls the four v1.2 read-only tools", async () => {
  const beforeHashes = await activeArtifactHashes();
  const bootstrap = [
    `import { main } from ${JSON.stringify(pathToFileURL(serverPath).href)};`,
    `await main({ root: ${JSON.stringify(packageRoot)} });`,
  ].join("\n");
  const transport = new StdioClientTransport({
    command: nodePath,
    args: directServerInvocation
      ? [serverPath]
      : ["--input-type=module", "--eval", bootstrap],
    cwd: packageRoot,
    env: {
      ...process.env,
      MQL5_CHM_MCP_ROOT: path.join(packageRoot, "hostile-ambient-root-that-must-not-be-used"),
    },
  });
  const client = new Client({ name: "mql5-chm-test", version: "1.2.0" });
  try {
    await client.connect(transport);
    const listed = await client.listTools();
    assert.deepEqual(
      listed.tools.map((tool) => tool.name).sort(),
      ["mql5_chm_lookup_identifiers", "mql5_chm_read", "mql5_chm_read_image", "mql5_chm_search", "mql5_chm_status"],
    );
    for (const tool of listed.tools) {
      assert.deepEqual(tool.annotations, {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      });
    }
    const searchTool = listed.tools.find((tool) => tool.name === "mql5_chm_search");
    assert.equal(searchTool.inputSchema.properties.expand.default, true);
    assert.equal(searchTool.inputSchema.properties.require_current.default, false);
    assert.equal(searchTool.inputSchema.properties.limit.minimum, 1);
    assert.equal(searchTool.inputSchema.properties.limit.maximum, 8);
    assert.equal(searchTool.inputSchema.properties.limit.default, 3);
    assert.match(searchTool.inputSchema.properties.limit.description, /integer from 1 to 8/i);
    assert.match(searchTool.inputSchema.properties.limit.description, /must not exceed 8/i);
    assert.match(searchTool.description, /exact returned title/i);
    assert.match(searchTool.description, /citation\.topic_id/);
    assert.match(searchTool.description, /citation\.corpus_revision/);
    assert.match(searchTool.description, /citation\.index_revision/);
    assert.match(searchTool.description, /once per answer/i);
    const readTool = listed.tools.find((tool) => tool.name === "mql5_chm_read");
    assert.equal(readTool.inputSchema.properties.max_chars.minimum, 500);
    assert.equal(readTool.inputSchema.properties.max_chars.maximum, 8_000);
    assert.equal(readTool.inputSchema.properties.max_chars.default, 4_000);
    assert.match(readTool.inputSchema.properties.max_chars.description, /integer from 500 to 8000/i);
    assert.match(readTool.inputSchema.properties.max_chars.description, /must not exceed 8000/i);
    assert.match(readTool.description, /exact returned section_heading/i);
    assert.match(readTool.description, /otherwise title/i);
    assert.match(readTool.description, /citation\.topic_id/);
    assert.match(readTool.description, /citation\.corpus_revision/);
    assert.match(readTool.description, /citation\.index_revision/);
    assert.match(readTool.description, /once per answer/i);
    assert.equal(readTool.inputSchema.properties.include_related.default, true);
    assert.equal(readTool.inputSchema.properties.related_limit.default, 3);
    assert.equal(readTool.inputSchema.properties.related_limit.maximum, 5);
    assert.equal(readTool.inputSchema.properties.include_images.default, true);
    assert.equal(readTool.inputSchema.properties.image_limit.default, 5);
    assert.equal(readTool.inputSchema.properties.image_limit.maximum, 8);
    const imageTool = listed.tools.find((tool) => tool.name === "mql5_chm_read_image");
    assert.deepEqual(imageTool.inputSchema.required, ["asset_id"]);
    assert.equal(imageTool.inputSchema.additionalProperties, false);
    const statusTool = listed.tools.find((tool) => tool.name === "mql5_chm_status");
    assert.deepEqual(statusTool.inputSchema.required ?? [], []);
    assert.equal(statusTool.inputSchema.additionalProperties, false);

    const batch = await client.callTool({
      name: "mql5_chm_lookup_identifiers",
      arguments: { identifiers: ["PositionSelectByTicket", "OnTick", "zzzz_nonexistent_7391"], source: "mql5", limit: 1 },
    });
    assert.equal(batch.isError, undefined);
    assert.deepEqual(batch.structuredContent.lookups.map(entry=>entry.match_status), ["exact", "exact", "none"]);
    assert.equal(batch.structuredContent.count,3);
    for (const lookup of batch.structuredContent.lookups) {
      assert.ok(lookup.results.length<=1);
      for (const hit of lookup.results) {
        assert.equal(hit.citation.corpus_revision,batch.structuredContent.corpus_revision);
        assert.equal(hit.citation.index_revision,batch.structuredContent.index_sha256);
      }
    }
    assert.equal((await client.callTool({name:"mql5_chm_lookup_identifiers",arguments:{identifiers:Array(17).fill("OnTick")}})).isError,true);

    const search = await client.callTool({
      name: "mql5_chm_search",
      arguments: {
        query: "PositionSelectByTicket",
        source: "all",
        limit: 1,
        expand: true,
        require_current: true,
      },
    });
    assert.equal(search.isError, undefined);
    assert.equal(search.structuredContent.count, 1);
    assert.equal(search.structuredContent.results[0].title, "PositionSelectByTicket");
    assert.equal(search.structuredContent.results[0].match_kind, "exact");
    assert.match(search.structuredContent.results[0].source_revision, /^[0-9a-f]{64}$/);
    const searchResult = search.structuredContent.results[0];
    assert.equal(searchResult.citation.source_file, "mql5.chm");
    assert.equal(searchResult.citation.title, searchResult.title);
    assert.equal(searchResult.citation.topic_id, searchResult.topic_id);
    assert.equal(searchResult.citation.section_id, searchResult.section_id);
    assert.equal(searchResult.citation.source_revision, searchResult.source_revision);
    assert.equal(searchResult.citation.corpus_revision, search.structuredContent.corpus_revision);
    assert.equal(searchResult.citation.index_revision, search.structuredContent.index_sha256);
    assert.equal(search.structuredContent.online_check.recommended, true);
    assert.match(search.structuredContent.online_check.official_search_query, /^site:mql5\.com\/en\//);
    assert.equal(JSON.stringify(search.structuredContent).includes("asset_id"), false);
    assert.ok(search.content.every((entry) => entry.type === "text"));

    const read = await client.callTool({
      name: "mql5_chm_read",
      arguments: {
        topic_id: search.structuredContent.results[0].topic_id,
        focus: "Return Value",
        max_chars: 500,
        include_related: true,
        related_limit: 2,
      },
    });
    assert.equal(read.isError, undefined);
    assert.match(read.content[0].text, /Return Value/i);
    assert.ok(read.structuredContent.returned_chars <= 500);
    assert.equal(Object.hasOwn(read.structuredContent, "text"), false);
    assert.ok(read.structuredContent.related.length <= 2);
    assert.equal((read.content[0].text.match(/^Source: /gmu) ?? []).length, 1);
    assert.match(read.structuredContent.section_heading, /Return Value/i);
    assert.equal(read.structuredContent.title, searchResult.title);
    assert.equal(read.structuredContent.citation.source_file, searchResult.citation.source_file);
    assert.equal(read.structuredContent.citation.title, read.structuredContent.title);
    assert.equal(read.structuredContent.citation.topic_id, read.structuredContent.topic_id);
    assert.equal(read.structuredContent.citation.section_id, read.structuredContent.section_id);
    assert.equal(read.structuredContent.citation.source_revision, read.structuredContent.source_revision);
    assert.equal(read.structuredContent.citation.corpus_revision, read.structuredContent.corpus_revision);
    assert.equal(read.structuredContent.citation.index_revision, read.structuredContent.index_sha256);

    const imageTopicSearch = await client.callTool({
      name: "mql5_chm_search",
      arguments: { query: "ENUM_OBJECT", source: "mql5", limit: 1 },
    });
    const imageTopic = await client.callTool({
      name: "mql5_chm_read",
      arguments: {
        topic_id: imageTopicSearch.structuredContent.results[0].topic_id,
        max_chars: 500,
        include_images: true,
        image_limit: 8,
      },
    });
    assert.equal(imageTopic.isError, undefined);
    assert.equal(imageTopic.structuredContent.image_count, 44);
    assert.equal(imageTopic.structuredContent.images.length, 8);
    assert.ok(imageTopic.structuredContent.next_image_cursor);
    assert.equal(JSON.stringify(imageTopic.structuredContent).includes('"data"'), false);
    assert.ok(imageTopic.content.every((entry) => entry.type === "text"));

    const imageContinuation = await client.callTool({
      name: "mql5_chm_read",
      arguments: {
        topic_id: imageTopic.structuredContent.topic_id,
        image_cursor: imageTopic.structuredContent.next_image_cursor,
        image_limit: 8,
      },
    });
    assert.equal(imageContinuation.structuredContent.image_continuation, true);
    assert.equal(imageContinuation.structuredContent.images.length, 8);
    assert.match(imageContinuation.content[0].text, /No documentation passage was repeated/i);
    const reachableAssetIds = new Set(imageTopic.structuredContent.images.map((entry) => entry.asset_id));
    let reachableEntryCount = imageTopic.structuredContent.images.length;
    let imagePage = imageContinuation;
    while (true) {
      reachableEntryCount += imagePage.structuredContent.images.length;
      for (const entry of imagePage.structuredContent.images) reachableAssetIds.add(entry.asset_id);
      assert.match(imagePage.content[0].text, /No documentation passage was repeated/i);
      const cursor = imagePage.structuredContent.next_image_cursor;
      if (!cursor) break;
      imagePage = await client.callTool({
        name: "mql5_chm_read",
        arguments: { topic_id: imageTopic.structuredContent.topic_id, image_cursor: cursor, image_limit: 8 },
      });
      assert.equal(imagePage.isError, undefined);
      assert.equal(imagePage.structuredContent.image_continuation, true);
    }
    assert.equal(reachableAssetIds.size, 44);
    assert.equal(reachableEntryCount, 44);

    const image = await client.callTool({
      name: "mql5_chm_read_image",
      arguments: { asset_id: imageTopic.structuredContent.images[0].asset_id },
    });
    assert.equal(image.isError, undefined);
    assert.equal(image.content.length, 1);
    assert.equal(image.content[0].type, "image");
    const decoded = Buffer.from(image.content[0].data, "base64");
    assert.equal(decoded.length, image.structuredContent.bytes);
    assert.equal(createHash("sha256").update(decoded).digest("hex"), image.structuredContent.sha256);
    assert.equal(image.content[0].mimeType, image.structuredContent.mime_type);
    assert.equal(Object.hasOwn(image.structuredContent, "data"), false);

    const pinnedOfficialImage = await client.callTool({
      name: "mql5_chm_read_image",
      arguments: { asset_id: "neuronetworksbook:asset:c423124a24f3d31dd295a3bb" },
    });
    assert.equal(pinnedOfficialImage.isError, undefined);
    assert.equal(pinnedOfficialImage.content.length, 1);
    const pinnedBytes = Buffer.from(pinnedOfficialImage.content[0].data, "base64");
    assert.equal(pinnedBytes.length, 23_807);
    assert.equal(
      createHash("sha256").update(pinnedBytes).digest("hex"),
      "04d0d664766a185021ab8aa26eb657fa58860a1113f5d4cb844ee674e5fee8f0",
    );

    const copyrightId = `mql5:asset:${createHash("sha256").update("copyright.gif").digest("hex").slice(0, 24)}`;
    const blocked = await client.callTool({ name: "mql5_chm_read_image", arguments: { asset_id: copyrightId } });
    assert.equal(blocked.isError, true);
    assert.match(blocked.content[0].text, /ASSET_NOT_AVAILABLE/);

    const extraArgument = await client.callTool({
      name: "mql5_chm_read_image",
      arguments: { asset_id: imageTopic.structuredContent.images[0].asset_id, path: "forbidden" },
    });
    assert.equal(extraArgument.isError, true);

    const statusWithoutArguments = await client.callTool({ name: "mql5_chm_status" });
    assert.equal(statusWithoutArguments.isError, undefined);
    assert.match(statusWithoutArguments.structuredContent.active_revision, /^[0-9a-f]{64}$/u);
    const status = await client.callTool({ name: "mql5_chm_status", arguments: {} });
    assert.equal(status.isError, undefined);
    assert.match(status.structuredContent.active_revision, /^[0-9a-f]{64}$/);
    assert.match(status.structuredContent.index_sha256, /^[0-9a-f]{64}$/);
    assert.equal(status.structuredContent.totals.topics, 4_827);
    assert.equal(status.structuredContent.sources.length, 3);
    assert.equal(status.structuredContent.schema_version, 3);
    assert.equal(status.structuredContent.asset_support_available, true);
    assert.equal(status.structuredContent.assets.cataloged, 798);
    assert.equal(status.structuredContent.assets.exposed, 787);
    assert.equal(status.structuredContent.assets.excluded, 11);
    assert.equal(status.structuredContent.assets.occurrences, 828);
    assert.equal(status.structuredContent.assets.exposed_occurrences, 811);
    assert.equal(status.structuredContent.assets.bytes, 11_652_126);
    for (const invalidArguments of [null, []]) {
      await assert.rejects(
        () => client.request(
          {
            method: "tools/call",
            params: { name: "mql5_chm_status", arguments: invalidArguments },
          },
          CallToolResultSchema,
        ),
        (error) => error?.code === ErrorCode.InvalidParams,
      );
    }

    const concurrentCalls = await Promise.all(
      Array.from({ length: 4 }, (_, index) => [
        client.callTool({ name: "mql5_chm_search", arguments: { query: index % 2 ? "OnTick" : "CopyBuffer", limit: 1 } }),
        client.callTool({ name: "mql5_chm_read", arguments: { topic_id: search.structuredContent.results[0].topic_id, max_chars: 500 } }),
        client.callTool({ name: "mql5_chm_status", arguments: {} }),
        client.callTool({ name: "mql5_chm_read_image", arguments: { asset_id: imageTopic.structuredContent.images[0].asset_id } }),
      ]).flat(),
    );
    assert.equal(concurrentCalls.length, 16);
    assert.ok(concurrentCalls.every((result) => result.isError === undefined));
    for (const result of concurrentCalls.filter((entry) => entry.content[0]?.type === "image")) {
      const bytes = Buffer.from(result.content[0].data, "base64");
      assert.equal(createHash("sha256").update(bytes).digest("hex"), result.structuredContent.sha256);
    }

    const invalidLimit = await client.callTool({
      name: "mql5_chm_search",
      arguments: { query: "PositionSelectByTicket", limit: 10 },
    });
    assert.equal(invalidLimit.isError, true);
    assert.equal(invalidLimit.structuredContent, undefined);

    const invalidMaxChars = await client.callTool({
      name: "mql5_chm_read",
      arguments: { topic_id: searchResult.topic_id, max_chars: 12_000 },
    });
    assert.equal(invalidMaxChars.isError, true);
    assert.equal(invalidMaxChars.structuredContent, undefined);

    const multipleInvalid = await client.callTool({
      name: "mql5_chm_search",
      arguments: { query: "", limit: 99 },
    });
    assert.equal(multipleInvalid.isError, true);
  } finally {
    await client.close();
  }
  assert.deepEqual(await activeArtifactHashes(), beforeHashes);
});

test("runtime source has no network, process-spawn, or write capability", async () => {
  const source = `${await readFile(path.join(root, "src", "server.mjs"), "utf8")}\n${await readFile(
    path.join(root, "src", "search-service.mjs"),
    "utf8",
  )}`;
  for (const forbidden of [
    "node:child_process",
    "node:http",
    "node:https",
    "node:net",
    "writeFile",
    "appendFile",
    "unlink",
    "rmSync",
    "rename",
  ]) {
    assert.equal(source.includes(forbidden), false, `runtime source contains forbidden capability: ${forbidden}`);
  }
});
