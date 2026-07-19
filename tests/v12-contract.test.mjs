import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import * as indexer from "../src/indexer.mjs";
import { createMcpServer } from "../src/server.mjs";

test("v1.2 schema contract includes deterministic asset catalog tables", () => {
  assert.equal(indexer.SCHEMA_VERSION, 3);
  assert.equal(typeof indexer.makeAssetId, "function");
  assert.equal(typeof indexer.inspectRasterAsset, "function");

  const database = new DatabaseSync(":memory:");
  try {
    indexer.createSchema(database);
    const tables = new Set(
      database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all().map((row) => row.name),
    );
    assert.ok(tables.has("assets"), "schema 3 must contain assets");
    assert.ok(tables.has("topic_assets"), "schema 3 must contain topic_assets");
    assert.equal(Number(database.prepare("PRAGMA user_version").get().user_version), 3);
  } finally {
    database.close();
  }
});

test("v1.2 MCP contract lists the bounded single-image tool", async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const server = createMcpServer({
    search() { throw new Error("unused"); },
    read() { throw new Error("unused"); },
    readImage() { throw new Error("unused"); },
    status() { throw new Error("unused"); },
  });
  const client = new Client({ name: "mql5-chm-v12-contract", version: "1.2.0" });
  try {
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    const listed = await client.listTools();
    assert.deepEqual(
      listed.tools.map((tool) => tool.name).sort(),
      ["mql5_chm_read", "mql5_chm_read_image", "mql5_chm_search", "mql5_chm_status"],
    );
  } finally {
    await client.close();
    await server.close();
  }
});
