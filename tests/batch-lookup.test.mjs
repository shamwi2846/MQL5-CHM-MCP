import assert from "node:assert/strict";
import test from "node:test";
import { readFile, rm } from "node:fs/promises";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createMcpServer } from "../src/server.mjs";
import { buildFtsQuery, createSearchService, keyedTrigramSimilarity, trigramKey, trigramSimilarity } from "../src/search-service.mjs";
import { buildFixture } from "./helpers/runtime-fixture.mjs";

const exact = "Mql5CompatibilityToken";
const absent = "zzzz_nonexistent_7391";
async function fixture(t) {
  const value = await buildFixture({ compatibilityTopics: true });
  const service = await createSearchService({ root: value.root });
  t.after(async () => { service.close(); await rm(value.root, { recursive: true, force: true }); });
  return { ...value, service };
}

test("batch service preserves order, duplicates, rankings and separate citation commitments", async t => {
  const { root, service } = await fixture(t);
  const pointer = path.join(root, "data/active.json");
  const before = await readFile(pointer);
  const identifiers = [exact, exact.slice(0, -1), absent, exact];
  const batch = service.lookupIdentifiers({ identifiers });
  assert.equal(batch.source, "mql5"); assert.equal(batch.limit, 1);
  assert.deepEqual(batch.lookups.map(x => x.identifier), identifiers);
  assert.deepEqual(batch.lookups.map(x => x.match_status), ["exact", "non_exact", "none", "exact"]);
  for (const [i, lookup] of batch.lookups.entries()) {
    const single = service.search({ query: identifiers[i], source: "mql5", limit: 1, expand: false });
    assert.deepEqual(lookup.results, single.results);
    assert.deepEqual(lookup.online_check, single.online_check);
    for (const entry of lookup.results) {
      assert.equal(entry.citation.topic_id, entry.topic_id);
      assert.equal(entry.citation.corpus_revision, batch.corpus_revision);
      assert.equal(entry.citation.index_revision, batch.index_sha256);
    }
  }
  assert.equal(batch.result_count, batch.lookups.reduce((n,x) => n+x.count,0));
  assert.deepEqual(await readFile(pointer), before);

  // Duplicate names keep their own output entries but are searched once.
  const queries = [];
  const search = service.search.bind(service);
  service.search = (input) => { queries.push(input.query); return search(input); };
  try {
    const repeated = service.lookupIdentifiers({ identifiers: [absent, absent, absent, exact] });
    assert.deepEqual(repeated.lookups.map(x => x.identifier), [absent, absent, absent, exact]);
    assert.deepEqual(queries, [absent, exact]);
  } finally { delete service.search; }
});

test("exact title and alias lookups probe their indexes instead of scanning topics", async t => {
  const { service } = await fixture(t);
  const prepared = new Set();
  const prepare = service.database.prepare.bind(service.database);
  service.database.prepare = (sql) => { prepared.add(sql); return prepare(sql); };
  try {
    for (const source of ["mql5", "all", "mql5book"]) {
      service.search({ query: exact, source, limit: 3 });
      service.search({ query: "moving average trailing stop", source, limit: 5 });
    }
  } finally { delete service.database.prepare; }
  const exactStatements = [...prepared].filter(sql => sql.includes("normalized_alias=?"));
  // Main exact lookup, expansion exact lookup and corpus-expansion seeds, each per source shape.
  for (const marker of ["exact_kind", "0.0 AS rank", "LIMIT 4"]) {
    assert.ok(exactStatements.some(sql => sql.includes(marker)), `missing exact statement ${marker}`);
  }
  for (const sql of exactStatements) {
    const plan = service.database.prepare(`EXPLAIN QUERY PLAN ${sql}`).all().map(row => row.detail);
    const detail = plan.join("\n");
    assert.ok(plan.some(line => /^SEARCH t USING (?:INDEX sqlite_autoindex_topics_1|PRIMARY KEY) \(topic_id=\?\)$/u.test(line)), detail);
    assert.ok(plan.some(line => line.includes("topics_source_title_idx (source=? AND normalized_title=?)")), detail);
    assert.ok(plan.some(line => line.includes("aliases_normalized_idx (normalized_alias=?)")), detail);
    assert.ok(!plan.some(line => /^SCAN t\b/u.test(line) || /^SEARCH t USING INDEX topics_source_title_idx \(source=\?\)$/u.test(line)), detail);
  }
});

test("prepared trigram keys reproduce trigramSimilarity exactly", () => {
  const values = ["", " ", "OrderSend", "ordersend", "OrderSnd", "order_send", "Order", "ChatID", "ChartID", "1.5.2 Droout", "1.5.2 Dropout",
    "Café crème", "CAFE CREME", "ß", "ﬁle", "İstanbul", "日本語 ドキュメント", "a", "ab", "abc", "abcd", "x".repeat(200), "TRADE_RETCODE_DONE", "trade retcode done"];
  for (const left of values) for (const right of values) {
    assert.equal(keyedTrigramSimilarity(trigramKey(left), trigramKey(right)), trigramSimilarity(left, right), `${left} | ${right}`);
  }
});

test("typo fallback results are stable across sources and repeated searches", async t => {
  const { service } = await fixture(t);
  for (const source of ["all", "mql5", "mql5book", "neuronetworksbook"]) {
    const first = service.search({ query: exact.slice(0, 6) + exact.slice(7), source, limit: 3 });
    const again = service.search({ query: exact.slice(0, 6) + exact.slice(7), source, limit: 3 });
    assert.deepEqual(again, first);
    assert.ok(first.results.every(entry => source === "all" || entry.source === source));
  }
});

test("batch service rejects malformed complete requests before the first query", async t => {
  const { service } = await fixture(t);
  let calls = 0; service.search = () => { calls++; throw new Error("Unexpected query"); };
  const badNames = ["", " OnTick", "OnTick ", "OnTick  X", "OnTick\tX", "OnTick\n", "OnTick\r\n", "OnTick\0", "OnTick()", "Order-Properties", "OnTick*", "\"OnTick\"", "1 OnTick", "../file", "éName", "A".repeat(129), `${"A".repeat(64)} ${"B".repeat(64)}`, 42, null];
  const bad = [null, [], {}, { identifiers: [] }, { identifiers: Array(17).fill(exact) }, { identifiers: Array(1) },
    ...badNames.map(name => ({ identifiers: [exact, name] })),
    ...[0,4,1.5,true,"1",null,NaN].map(limit => ({ identifiers: [exact],limit })),
    { identifiers:[exact],source:"mt4" },{identifiers:[exact],require_current:1},{identifiers:[exact],expand:false},{identifiers:[exact],path:"secret"}];
  for (const input of bad) assert.throws(() => service.lookupIdentifiers(input), error => error.code === "INVALID_ARGUMENT");
  assert.equal(calls, 0);
});

test("batch titles are exact only on a whole title or alias and are matched literally", async t => {
  const { service } = await fixture(t);
  const batch = service.lookupIdentifiers({ identifiers: ["mql5 topic 7", "mql5 TOPIC 7", `${exact} values`, "OnTick OR X", "mql5 topic 999999", exact], limit: 3 });
  assert.deepEqual(batch.lookups.map(x => x.identifier), ["mql5 topic 7", "mql5 TOPIC 7", `${exact} values`, "OnTick OR X", "mql5 topic 999999", exact]);
  const [title, titleCase, phrase, operators, absentTitle, identifier] = batch.lookups;
  assert.equal(title.match_status, "exact");
  assert.equal(title.results[0].title, "mql5 topic 7");
  assert.equal(titleCase.match_status, "exact", "titles match case-insensitively like single searches");
  // A plain search extracts the CamelCase token and reports it exact; the batch
  // must not, because the whole name is not a title or alias.
  assert.ok(service.search({ query: `${exact} values`, source: "mql5", limit: 3, expand: false }).results.some(x => x.match_kind === "exact"));
  assert.notEqual(phrase.match_status, "exact");
  assert.ok(phrase.results.every(x => x.match_kind !== "exact"));
  assert.notEqual(operators.match_status, "exact");
  // Every word reaches FTS5 as a quoted literal, so OR/AND/NOT cannot act as operators.
  assert.match(buildFtsQuery("OnTick OR X"), /^"[^"]+"\*( AND "[^"]+"\*)*$/u);
  assert.deepEqual(operators.results, service.search({ query: "OnTick OR X", source: "mql5", limit: 3, expand: false }, { wholeNameExact: true }).results);
  assert.notEqual(absentTitle.match_status, "exact");
  assert.equal(identifier.match_status, "exact");
  // Space-free identifiers keep exactly the single-search result.
  assert.deepEqual(identifier.results, service.search({ query: exact, source: "mql5", limit: 3, expand: false }).results);
});

test("batch service accepts maximum bounds, preserves advisory checks and filters each source", async t => {
  const { service } = await fixture(t);
  const batch = service.lookupIdentifiers({ identifiers: Array(16).fill(exact), limit:3,require_current:true });
  assert.equal(batch.count,16); assert.ok(batch.result_count<=48);
  for (const lookup of batch.lookups) {
    assert.ok(lookup.results.length<=3);
    assert.equal(lookup.online_check.reason,"current-information-requested");
    assert.ok(lookup.results.every(x=>x.source==="mql5"));
  }
  const filtered = service.lookupIdentifiers({identifiers:[exact],source:"mql5book"});
  assert.equal(filtered.lookups[0].match_status,"none");
  assert.ok(service.lookupIdentifiers({identifiers:["A".repeat(128)]}).lookups.length===1);
  service.close();
  assert.throws(()=>service.lookupIdentifiers({identifiers:[exact]}),error=>error.code==="SERVICE_CLOSED");
});

test("batch MCP schema and transport enforce bounds and omit document snippets", async t => {
  const { service }=await fixture(t);
  const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
  const server=createMcpServer(service);
  const client=new Client({name:"batch-transport-test",version:"1.0.0"});
  t.after(async()=>{await client.close();await server.close();});
  await server.connect(serverTransport); await client.connect(clientTransport);
  const tool=(await client.listTools()).tools.find(x=>x.name==="mql5_chm_lookup_identifiers");
  assert.deepEqual(tool.inputSchema.required,["identifiers"]);
  assert.equal(tool.inputSchema.additionalProperties,false);
  assert.equal(tool.inputSchema.properties.identifiers.minItems,1);
  assert.equal(tool.inputSchema.properties.identifiers.maxItems,16);
  assert.equal(tool.inputSchema.properties.limit.maximum,3);
  assert.equal(tool.outputSchema.properties.lookups.maxItems,16);
  assert.equal(tool.outputSchema.properties.lookups.items.properties.results.maxItems,3);
  assert.equal(tool.annotations.readOnlyHint,true);
  const response=await client.callTool({name:tool.name,arguments:{identifiers:[exact,absent]}});
  assert.notEqual(response.isError,true);
  assert.deepEqual(response.structuredContent.lookups.map(x=>x.match_status),["exact","none"]);
  assert.ok(response.content[0].text.includes(exact));
  assert.ok(response.content[0].text.includes(response.structuredContent.corpus_revision));
  assert.equal(Object.hasOwn(response.structuredContent.lookups[0].results[0],"snippet"),false);
  assert.equal(Object.hasOwn(response.structuredContent.lookups[0].results[0],"text"),false);
  // Titles pass the input schema and their echo passes the output schema.
  const titled=await client.callTool({name:tool.name,arguments:{identifiers:["mql5 topic 7",exact,"OnTick OR X"]}});
  assert.notEqual(titled.isError,true,JSON.stringify(titled.content));
  assert.deepEqual(titled.structuredContent.lookups.map(x=>[x.identifier,x.match_status]),[["mql5 topic 7","exact"],[exact,"exact"],["OnTick OR X","none"]]);
  for(const args of [{identifiers:[]},{identifiers:Array(17).fill(exact)},{identifiers:[exact],limit:4},{identifiers:[exact],limit:1.2},{identifiers:[exact,"Bad(Name"]},{identifiers:[exact],extra:true}]) {
    assert.equal((await client.callTool({name:tool.name,arguments:args})).isError,true);
  }
});

test("batch MCP fails the request on a query error without returning a successful partial batch",async t=>{
  const [a,b]=InMemoryTransport.createLinkedPair();
  const server=createMcpServer({lookupIdentifiers(){throw new Error("private_fixture_diagnostic");}});
  const client=new Client({name:"batch-failure",version:"1.0.0"});
  t.after(async()=>{await client.close();await server.close();});
  await server.connect(b);await client.connect(a);
  const response=await client.callTool({name:"mql5_chm_lookup_identifiers",arguments:{identifiers:[exact,absent]}});
  assert.equal(response.isError,true);assert.equal(response.structuredContent,undefined);
  assert.ok(!response.content[0].text.includes("private_fixture_diagnostic"));
});
