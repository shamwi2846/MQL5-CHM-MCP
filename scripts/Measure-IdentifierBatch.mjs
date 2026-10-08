import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { median } from "./IdentifierBenchmarkStatistics.mjs";
import { measureQuality } from "./DocumentationQualityBenchmark.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const names = ["OnTick", "CopyBuffer", "PositionSelectByTicket", "OrderSend", "SymbolInfoDouble", "IndicatorRelease", "SYMBOL_VOLUME_STEP", "BarsCalculated", "OnInit", "OnDeinit", "SymbolInfoInteger", "AccountInfoDouble", "CopyRates", "iMA", "OnTikk", "zzzz_nonexistent_7391"];
const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");
const options = { packageRoot: repository, serverPath: path.join(repository, "build/candidate-v12/app/server.mjs"), samples: 9, report: null, qualityCases: null, qualityOutput: null };
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i], value = process.argv[i+1];
  assert.ok(value && !value.startsWith("--"), `${key} requires a value`);
  if (key === "--package-root") options.packageRoot = path.resolve(value);
  else if (key === "--server-path") options.serverPath = path.resolve(value);
  else if (key === "--quality-cases") options.qualityCases = path.resolve(value);
  else if (key === "--quality-output") options.qualityOutput = path.resolve(value);
  else if (key === "--report") options.report = path.resolve(value);
  else if (key === "--samples") { options.samples = Number(value); assert.ok(Number.isInteger(options.samples) && options.samples >= 3 && options.samples <= 21, "samples must be an integer from 3 to 21"); }
  else throw new Error(`Unknown option ${key}`);
}
assert.equal(Boolean(options.qualityCases), Boolean(options.qualityOutput), "Select both --quality-cases and --quality-output");
const bootstrap = `import { main } from ${JSON.stringify(pathToFileURL(options.serverPath).href)}; await main({ root: ${JSON.stringify(options.packageRoot)} });`;
const transport = new StdioClientTransport({ command: process.execPath, args: ["--input-type=module", "--eval", bootstrap], cwd: options.packageRoot, stderr: "pipe" });
const client = new Client({ name: "mql5-identifier-batch-benchmark", version: "1.0.0" });
let diagnostic = "";
transport.stderr?.on("data", bytes => { diagnostic = (diagnostic + bytes.toString("utf8")).slice(-4096); });
const measurements = [];
const beforeBundle = sha256(await readFile(options.serverPath));
const beforePointer = sha256(await readFile(path.join(options.packageRoot, "data/active.json")));
try {
  await client.connect(transport);
  const statusResult = await client.callTool({ name: "mql5_chm_status", arguments: {} });
  assert.notEqual(statusResult.isError, true, "Status lookup returned a tool error");
  const status = statusResult.structuredContent;
  assert.ok(status?.corpus_revision && status?.index_revision, "Status lookup is missing revision metadata");
  for (const size of [1,4,8,16]) {
    const identifiers = names.slice(0,size);
    const sequential = async () => {
      const results = [];
      for (const query of identifiers) results.push(await client.callTool({ name: "mql5_chm_search", arguments: { query, source: "mql5", limit: 1, expand: false } }));
      return results;
    };
    const parallel = () => Promise.all(identifiers.map(query => client.callTool({ name: "mql5_chm_search", arguments: { query, source: "mql5", limit: 1, expand: false } })));
    const batch = () => client.callTool({ name: "mql5_chm_lookup_identifiers", arguments: { identifiers, source: "mql5", limit: 1 } });
    const reference = await sequential(), combined = await batch();
    const validateIndividual = (result, expected, context, identifier) => {
      assert.notEqual(result?.isError, true, `${context} returned a tool error`);
      assert.ok(result?.structuredContent, `${context} is missing structured content`);
      assert.ok(Array.isArray(result.structuredContent.results), `${context} is missing search results`);
      const content = result.structuredContent;
      assert.equal(content.query, identifier, `${context} query changed`);
      assert.equal(content.source, "mql5", `${context} source changed`);
      assert.equal(content.corpus_revision, status.corpus_revision, `${context} corpus revision changed`);
      assert.equal(content.index_sha256, status.index_revision, `${context} index revision changed`);
      assert.equal(content.count, content.results.length, `${context} result count is inconsistent`);
      assert.ok(content.results.length <= 1, `${context} exceeded the requested result limit`);
      assert.ok(content.online_check && typeof content.online_check === "object", `${context} is missing freshness metadata`);
      for (const entry of content.results) assert.ok(["exact", "fts", "expanded", "fuzzy"].includes(entry.match_kind), `${context} has an invalid match kind`);
      if (expected) {
        assert.deepEqual(result.structuredContent.results, expected.structuredContent.results, `${context} result metadata changed`);
        assert.deepEqual(result.structuredContent.online_check, expected.structuredContent.online_check, `${context} freshness metadata changed`);
      }
    };
    const validateBatch = (result, context) => {
      assert.notEqual(result?.isError, true, `${context} returned a tool error`);
      const content = result?.structuredContent;
      assert.ok(Array.isArray(content?.lookups), `${context} is missing lookups`);
      assert.deepEqual(content.lookups.map(lookup=>lookup.identifier), identifiers, `${context} identifier order changed`);
      assert.equal(content.corpus_revision, status.corpus_revision, `${context} corpus revision changed`);
      assert.equal(content.index_sha256, status.index_revision, `${context} index revision changed`);
      assert.equal(content.source, "mql5", `${context} source changed`);
      assert.equal(content.limit, 1, `${context} result limit changed`);
      assert.equal(content.count, identifiers.length, `${context} lookup count is inconsistent`);
      assert.equal(content.result_count, reference.reduce((total, item) => total + item.structuredContent.results.length, 0), `${context} total result count is inconsistent`);
      for (const [i,lookup] of content.lookups.entries()) {
        const expected = reference[i].structuredContent;
        assert.equal(lookup.count, expected.results.length, `${context} per-identifier result count is inconsistent`);
        const matchStatus = expected.results.some(entry => entry.match_kind === "exact") ? "exact" : expected.results.length ? "non_exact" : "none";
        assert.equal(lookup.match_status, matchStatus, `${context} match status changed`);
        assert.deepEqual(lookup.results, reference[i].structuredContent.results, `${context} result metadata changed`);
        assert.deepEqual(lookup.online_check, reference[i].structuredContent.online_check, `${context} freshness metadata changed`);
      }
    };
    for (const [i,result] of reference.entries()) validateIndividual(result, null, `Warm search ${identifiers[i]}`, identifiers[i]);
    validateBatch(combined, "Warm batch");
    const samples = { sequential: [], parallel: [], batch: [] }, sizes = {};
    for (let run = 0; run < options.samples; run++) {
      const order = run%2 ? ["batch","parallel","sequential"] : ["sequential","parallel","batch"];
      for (const mode of order) {
        const started = performance.now();
        const result = await ({ sequential,parallel,batch }[mode])();
        const elapsed = performance.now()-started;
        if (mode === "batch") validateBatch(result, `Measured ${mode} sample ${run+1}`);
        else {
          assert.equal(result.length, reference.length, `Measured ${mode} result count changed`);
          for (const [i,item] of result.entries()) validateIndividual(item, reference[i], `Measured ${mode} sample ${run+1}: ${identifiers[i]}`, identifiers[i]);
        }
        samples[mode].push(elapsed);
        sizes[mode] = Buffer.byteLength(JSON.stringify(result),"utf8");
      }
    }
    measurements.push({ identifiers: size, requests: { sequential: size, parallel: size, batch: 1 }, median_ms: Object.fromEntries(Object.entries(samples).map(([mode,values])=>[mode,Number(median(values).toFixed(3))])), response_bytes: sizes, response_byte_reduction_percent: Number(((1-sizes.batch/sizes.sequential)*100).toFixed(2)), result_metadata_equal: true });
  }
  if (options.qualityCases) {
    const input = await readFile(options.qualityCases);
    assert.ok(input.length <= 2 * 1024 * 1024, "Quality case file exceeds the supported limit");
    const quality = await measureQuality(client, JSON.parse(input.toString("utf8").replace(/^\uFEFF/u, "")));
    quality.artifact_integrity = { server_unchanged: sha256(await readFile(options.serverPath)) === beforeBundle, pointer_unchanged: sha256(await readFile(path.join(options.packageRoot, "data/active.json"))) === beforePointer };
    if (!quality.artifact_integrity.server_unchanged || !quality.artifact_integrity.pointer_unchanged) { quality.status = "failed"; quality.issues = ["Measured server or active pointer changed"]; }
    Object.assign(quality, { case_manifest_sha256: sha256(input), server_sha256: beforeBundle, server_version: client.getServerVersion(), package_root: options.packageRoot });
    await writeFile(options.qualityOutput, `${JSON.stringify(quality,null,2)}\n`, { flag: "wx" });
    assert.equal(quality.status, "passed", "Documentation quality cases failed; retained full evidence in quality output");
  }
  assert.equal(sha256(await readFile(options.serverPath)),beforeBundle,"Server bytes changed during measurement");
  assert.equal(sha256(await readFile(path.join(options.packageRoot,"data/active.json"))),beforePointer,"Active pointer changed during measurement");
  const record = { schema_version: 1, status: "passed", measured_utc: new Date().toISOString(), server_version: client.getServerVersion(), node_version: process.version, server_path: options.serverPath, server_sha256: beforeBundle, package_root: options.packageRoot, corpus_revision: status.corpus_revision, index_revision: status.index_revision, samples_per_mode: options.samples, measurements, scope: "Warm local stdio round trips; same process and queries, alternating mode order. JSON-serialized MCP result bytes exclude request envelopes, SDK framing and assistant scheduling. Queries remain synchronous. Timing is descriptive, not a CI performance threshold or universal speed claim." };
  if (options.report) await writeFile(options.report,`${JSON.stringify(record,null,2)}\n`,{flag:"wx"});
  process.stdout.write(`${JSON.stringify(record,null,2)}\n`);
} catch (error) { throw new Error(`Identifier benchmark failed: ${error.message}\n${diagnostic}`,{cause:error}); }
finally { await client.close(); }
