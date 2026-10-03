import assert from "node:assert/strict";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createMcpServer } from "../src/server.mjs";
import { parseContract, validateAdvertisedTools, validateResponse, assertExactPassage } from "../scripts/Test-SkillCompatibility.mjs";

// Minimal consumer commitments for isolated validator regression tests. The
// cross-repository job loads the complete contract from the actual skill.
const contract = parseContract({
  schema_version: 1,
  server_name: "mql5-chm",
  tools: {
    mql5_chm_status: { required_arguments: [], outputs: { index_sha256: "sha256" } },
    mql5_chm_search: { required_arguments: ["query"], bounds: { limit: { minimum: 1, maximum: 8 } }, outputs: { "results[].citation.corpus_revision": "sha256" } },
    mql5_chm_read: { required_arguments: ["topic_id"], bounds: { max_chars: { minimum: 500, maximum: 8000 } }, outputs: { next_cursor: "nullable_string" } },
    mql5_chm_read_image: { required_arguments: ["asset_id"], outputs: { sha256: "sha256" } },
  },
});

test("skill compatibility rejects tool, input, annotation and output schema drift", async () => {
  const server = createMcpServer({});
  const client = new Client({ name: "compatibility-regression", version: "1.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  try {
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    const listed = await client.listTools();
    validateAdvertisedTools(contract, listed, client.getServerVersion().name);
    for (const mutate of [
      (value) => { value.tools = value.tools.filter((tool) => tool.name !== "mql5_chm_read"); },
      (value) => { value.tools[0].annotations.readOnlyHint = false; },
      (value) => { value.tools[0].inputSchema.required.push("new_required_input"); },
      (value) => { value.tools.find((tool) => tool.name === "mql5_chm_search").inputSchema.properties.limit.maximum = 7; },
      (value) => { value.tools.find((tool) => tool.name === "mql5_chm_search").outputSchema.properties.results.items.properties.citation.required = []; },
      (value) => { value.tools.find((tool) => tool.name === "mql5_chm_status").outputSchema.properties.index_sha256.type = "integer"; },
      (value) => { value.tools.find((tool) => tool.name === "mql5_chm_read").outputSchema.properties.focus_match = { type: "string", enum: ["approximate", "none"] }; },
    ]) {
      const changed = structuredClone(listed);
      mutate(changed);
      assert.throws(() => validateAdvertisedTools(contract, changed, "mql5-chm"));
    }
    assert.throws(() => validateAdvertisedTools(contract, listed, "renamed-server"), /identity/u);
    const additive = structuredClone(listed);
    additive.tools.push({ name: "future_optional_tool" });
    additive.tools.find((tool) => tool.name === "mql5_chm_search").inputSchema.properties.limit.maximum = 16;
    assert.doesNotThrow(() => validateAdvertisedTools(contract, additive, "mql5-chm"));
  } finally { await client.close(); await server.close(); }
});

test("skill compatibility rejects missing or malformed runtime commitments", () => {
  const result = { structuredContent: { index_sha256: "a".repeat(64) }, content: [{ type: "text", text: "status" }] };
  validateResponse(contract, "mql5_chm_status", result);
  for (const changed of [
    { ...result, isError: true },
    { ...result, structuredContent: {} },
    { ...result, structuredContent: { index_sha256: "invalid" } },
    { ...result, content: [{ type: "image" }] },
  ]) assert.throws(() => validateResponse(contract, "mql5_chm_status", changed));
  assert.throws(() => parseContract({ ...contract, schema_version: 99 }));
});

test("skill compatibility requires complete identifier proof inside the passage", () => {
  const read = (text, focus = "exact") => ({ structuredContent: { focus_match: focus }, content: [{ type: "text", text }] });
  assertExactPassage(read("RequestedToken(argument)"), "RequestedToken");
  for (const response of [
    read("RequestedTokenSuffix"), read("_RequestedToken"), read("éRequestedToken"),
    read("Unrelated passage\n\nSource: RequestedToken"), read("RequestedToken", "approximate"),
  ]) assert.throws(() => assertExactPassage(response, "RequestedToken"));
});

test("optional batch contract permits old servers and enforces new server array/output bounds",async()=>{
  const optional=parseContract({...contract,optional_tools:{mql5_chm_lookup_identifiers:{required_arguments:["identifiers"],array_bounds:{identifiers:{minimum:1,maximum:16}},bounds:{limit:{minimum:1,maximum:3}},outputs:{"lookups[].results[].citation.corpus_revision":"sha256"}}}});
  const server=createMcpServer({});
  const client=new Client({name:"optional-batch-contract",version:"1.0.0"});
  const [a,b]=InMemoryTransport.createLinkedPair();
  try {
    await server.connect(b);await client.connect(a);
    const listed=await client.listTools();
    validateAdvertisedTools(optional,listed,"mql5-chm");
    const old=structuredClone(listed);old.tools=old.tools.filter(x=>x.name!=="mql5_chm_lookup_identifiers");
    assert.doesNotThrow(()=>validateAdvertisedTools(optional,old,"mql5-chm"));
    for(const change of [tool=>{tool.inputSchema.properties.identifiers.maxItems=15;},tool=>{delete tool.inputSchema.properties.identifiers.maxItems;},tool=>{delete tool.outputSchema.properties.lookups.items.properties.results.items.properties.citation.properties.corpus_revision;}]) {
      const altered=structuredClone(listed);change(altered.tools.find(x=>x.name==="mql5_chm_lookup_identifiers"));
      assert.throws(()=>validateAdvertisedTools(optional,altered,"mql5-chm"));
    }
    assert.throws(()=>parseContract({...contract,optional_tools:{mql5_chm_status:contract.tools.mql5_chm_status}}));
  }finally{await client.close();await server.close();}
});
