import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { z } from "zod";
import { buildFixture } from "../tests/helpers/runtime-fixture.mjs";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const valueTypes = ["string", "nullable_string", "integer", "array", "sha256", "topic_id", "nullable_section_id", "asset_id"];
const toolContract = z.strictObject({
  required_arguments: z.array(z.string().min(1)),
  outputs: z.record(z.string().min(1), z.enum(valueTypes)),
  bounds: z.record(z.string(), z.strictObject({ minimum: z.number().int(), maximum: z.number().int() })).optional(),
  enums: z.record(z.string(), z.array(z.string()).min(1)).optional(),
});
const contractSchema = z.strictObject({
  schema_version: z.literal(1),
  server_name: z.string().min(1),
  tools: z.record(z.string().regex(/^mql5_chm_[a-z_]+$/u), toolContract),
});
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function parseContract(value) {
  const contract = contractSchema.parse(value);
  assert.deepEqual(Object.keys(contract.tools).sort(), ["mql5_chm_read", "mql5_chm_read_image", "mql5_chm_search", "mql5_chm_status"]);
  for (const tool of Object.values(contract.tools)) {
    assert.ok(Object.keys(tool.outputs).length > 0, "Tool has no consumer output commitments");
    assert.equal(new Set(tool.required_arguments).size, tool.required_arguments.length);
    for (const [field, bound] of Object.entries(tool.bounds ?? {})) {
      assert.ok(bound.minimum <= bound.maximum, `Inverted input bounds: ${field}`);
    }
  }
  return contract;
}

function types(schema) {
  if (Array.isArray(schema?.anyOf)) return schema.anyOf.flatMap(types);
  return Array.isArray(schema?.type) ? schema.type : [schema?.type];
}

function advertisedField(schema, field) {
  for (const component of field.split(".")) {
    const array = component.endsWith("[]");
    const name = array ? component.slice(0, -2) : component;
    assert.ok(schema?.required?.includes(name), `Producer no longer requires output ${field}`);
    schema = schema.properties?.[name];
    assert.ok(schema, `Producer removed output ${field}`);
    if (array) {
      assert.ok(types(schema).includes("array"), `Producer changed array output ${field}`);
      schema = schema.items;
    }
  }
  return schema;
}

export function validateAdvertisedTools(contract, listed, serverName) {
  assert.equal(serverName, contract.server_name, "Server identity differs from the skill dependency");
  const names = listed.tools.map((tool) => tool.name);
  assert.equal(new Set(names).size, names.length, "Duplicate tool names");
  for (const [name, required] of Object.entries(contract.tools)) {
    const tool = listed.tools.find((entry) => entry.name === name);
    assert.ok(tool, `Skill-required tool is missing: ${name}`);
    assert.deepEqual(tool.annotations, { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false });
    assert.deepEqual([...(tool.inputSchema.required ?? [])].sort(), [...required.required_arguments].sort(), `${name} required inputs changed`);
    assert.equal(tool.inputSchema.additionalProperties, false, `${name} input contract is open`);
    for (const [field, bound] of Object.entries(required.bounds ?? {})) {
      const actual = tool.inputSchema.properties?.[field];
      assert.ok(types(actual).includes("integer"), `${name}.${field} is not an integer`);
      assert.ok(Number.isSafeInteger(actual.minimum) && Number.isSafeInteger(actual.maximum));
      assert.ok(actual.minimum <= bound.minimum && actual.maximum >= bound.maximum, `${name}.${field} no longer accepts the skill's input range`);
    }
    for (const [field, values] of Object.entries(required.enums ?? {})) {
      for (const value of values) assert.ok(tool.inputSchema.properties?.[field]?.enum?.includes(value), `${name}.${field} removed ${value}`);
    }
    for (const [field, kind] of Object.entries(required.outputs)) {
      const schema = advertisedField(tool.outputSchema, field);
      const expected = kind === "integer" || kind === "array" ? kind : "string";
      assert.ok(types(schema).includes(expected), `${name}.${field} changed output type`);
      if (kind.startsWith("nullable_")) assert.ok(types(schema).includes("null"), `${name}.${field} no longer accepts null`);
    }
  }
  const search = listed.tools.find((tool) => tool.name === "mql5_chm_search");
  assert.ok(types(search.inputSchema.properties.expand).includes("boolean"), "Exact-search expand flag is missing");
  const read = listed.tools.find((tool) => tool.name === "mql5_chm_read");
  const focus = read.outputSchema.properties.focus_match;
  const focusValues = focus?.enum ?? focus?.anyOf?.flatMap((entry) => entry.enum ?? []);
  for (const value of ["exact", "approximate", "none"]) assert.ok(focusValues?.includes(value), `focus_match removed ${value}`);
}

function checkValue(value, kind, field) {
  if (kind.startsWith("nullable_") && value === null) return;
  const patterns = {
    sha256: /^[0-9a-f]{64}$/u,
    topic_id: /^(mql5|mql5book|neuronetworksbook):[0-9a-f]{24}$/u,
    nullable_section_id: /^(mql5|mql5book|neuronetworksbook):[0-9a-f]{24}:s\d{3}$/u,
    asset_id: /^(mql5|mql5book|neuronetworksbook):asset:[0-9a-f]{24}$/u,
  };
  if (kind === "integer") assert.ok(Number.isSafeInteger(value) && value >= 0, `Invalid integer ${field}`);
  else if (kind === "array") assert.ok(Array.isArray(value), `Invalid array ${field}`);
  else {
    assert.equal(typeof value, "string", `Invalid string ${field}`);
    if (patterns[kind]) assert.match(value, patterns[kind], `Invalid identifier/hash ${field}`);
  }
}

export function validateResponse(contract, name, result) {
  assert.notEqual(result.isError, true, `${name} returned an error: ${result.content?.[0]?.text}`);
  const data = result.structuredContent;
  assert.ok(data && typeof data === "object", `${name} omitted structuredContent`);
  for (const [field, kind] of Object.entries(contract.tools[name].outputs)) {
    const visit = (current, components) => {
      if (components.length === 0) return checkValue(current, kind, field);
      const component = components[0];
      const array = component.endsWith("[]");
      const key = array ? component.slice(0, -2) : component;
      assert.ok(current && Object.hasOwn(current, key), `Missing response field ${name}.${field}`);
      if (array) {
        assert.ok(Array.isArray(current[key]), `Invalid response array ${name}.${field}`);
        for (const item of current[key]) visit(item, components.slice(1));
      } else visit(current[key], components.slice(1));
    };
    visit(data, field.split("."));
  }
  assert.ok(result.content?.length > 0, `${name} omitted native content`);
  assert.ok(result.content.every((entry) => entry.type === (name === "mql5_chm_read_image" ? "image" : "text")));
  return data;
}

export function assertExactPassage(result, identifier) {
  assert.equal(result.structuredContent.focus_match, "exact", "Identifier focus is not exact");
  const escaped = identifier.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  assert.match(result.content[0].text.split("\n\nSource:")[0], new RegExp(`(?<![\\p{L}\\p{N}_])${escaped}(?![\\p{L}\\p{N}_])`, "u"), "Exact focus did not return a complete identifier token");
}

async function artifactHashes(root) {
  const activePath = path.join(root, "data", "active.json");
  const active = JSON.parse(await readFile(activePath, "utf8"));
  assert.match(active.active_revision, /^[0-9a-f]{64}$/u);
  const files = [activePath];
  const visit = async (directory) => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      assert.equal(entry.isSymbolicLink(), false, "Compatibility corpus contains a reparse point");
      if (entry.isDirectory()) await visit(file);
      else if (entry.isFile()) files.push(file);
    }
  };
  await visit(path.join(root, "revisions", active.active_revision));
  return Object.fromEntries(await Promise.all(files.sort().map(async (file) => [file, hash(await readFile(file))])));
}

function gitCommit(root) {
  try { return execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); }
  catch { return null; }
}

export async function runCompatibility({ skillRoot, pythonPath, serverPath = path.join(repositoryRoot, "build", "candidate-v12", "app", "server.mjs"), packageRoot = null }) {
  skillRoot = path.resolve(skillRoot);
  serverPath = path.resolve(serverPath);
  const skillFiles = ["SKILL.md", "agents/openai.yaml", "references/mcp-contract.json"];
  const inputs = Object.fromEntries(await Promise.all(skillFiles.map(async (file) => [file, await readFile(path.join(skillRoot, file))])));
  const beforeSkill = Object.fromEntries(skillFiles.map((file) => [file, hash(inputs[file])]));
  const contract = parseContract(JSON.parse(inputs[skillFiles[2]].toString("utf8")));
  assert.ok(pythonPath && path.isAbsolute(pythonPath), "An absolute --python path with PyYAML is required");
  const metadata = JSON.parse(execFileSync(pythonPath, ["-c", "import json, sys, yaml; print(json.dumps(yaml.safe_load(sys.stdin.buffer.read())))"], { input: inputs["agents/openai.yaml"], encoding: "utf8" }));
  assert.deepEqual(metadata?.dependencies?.tools?.map(({ type, value }) => ({ type, value })), [{ type: "mcp", value: contract.server_name }], "Skill metadata does not declare the MCP contract dependency");
  const beforeServer = hash(await readFile(serverPath));
  const fixture = packageRoot ? null : await buildFixture({ compatibilityTopics: true });
  const root = fixture?.root ?? path.resolve(packageRoot);
  const identifier = fixture ? "Mql5CompatibilityToken" : "OnTester";
  const missing = fixture ? "Mql5CompatibilityAbsent" : "OnTesterCompatibilityMissing";
  let beforeCorpus;
  const checks = [];
  const bootstrap = `import { main } from ${JSON.stringify(pathToFileURL(serverPath).href)}; await main({ root: ${JSON.stringify(root)} });`;
  const transport = new StdioClientTransport({ command: process.execPath, args: ["--input-type=module", "--eval", bootstrap], cwd: root, stderr: "pipe", env: { ...process.env, MQL5_CHM_MCP_ROOT: path.join(root, "unused-ambient-root") } });
  const client = new Client({ name: "mql5-coding-compatibility", version: "1.0.0" });
  let diagnostic = "";
  transport.stderr?.on("data", (bytes) => { diagnostic = (diagnostic + bytes.toString("utf8")).slice(-32768); });
  const call = async (name, args) => {
    const response = await client.callTool({ name, arguments: args });
    validateResponse(contract, name, response);
    return response;
  };
  let serverVersion;
  let verifiedCorpusRevision;
  try {
    beforeCorpus = await artifactHashes(root);
    await client.connect(transport);
    serverVersion = client.getServerVersion();
    const listed = await client.listTools();
    validateAdvertisedTools(contract, listed, serverVersion.name);
    checks.push("server_identity_and_advertised_contract");
    const status = (await call("mql5_chm_status", {})).structuredContent;
    verifiedCorpusRevision = status.corpus_revision;
    assert.equal(status.index_revision, status.index_sha256);
    checks.push("status_revision_fields");
    const search = (await call("mql5_chm_search", { query: identifier, source: "mql5", expand: false, limit: 1 })).structuredContent;
    assert.equal(search.count, 1);
    const entry = search.results[0];
    assert.equal(entry.match_kind, "exact");
    assert.equal(entry.title, identifier);
    assert.equal(entry.source, "mql5");
    assert.equal(entry.citation.topic_id, entry.topic_id);
    assert.equal(entry.citation.corpus_revision, status.corpus_revision);
    assert.equal(entry.citation.index_revision, status.index_sha256);
    checks.push("exact_identifier_search_and_citation");
    const read = await call("mql5_chm_read", { topic_id: entry.topic_id, focus: identifier, max_chars: 500 });
    assertExactPassage(read, identifier);
    assert.ok(read.structuredContent.returned_chars <= 500);
    assert.equal(read.structuredContent.citation.topic_id, entry.topic_id);
    assert.equal(read.structuredContent.citation.corpus_revision, status.corpus_revision);
    assert.equal(read.structuredContent.citation.index_revision, status.index_sha256);
    checks.push("bounded_exact_read_and_citation");
    if (fixture) assert.ok(read.structuredContent.next_cursor, "Long fixture passage lost its continuation cursor");
    if (read.structuredContent.next_cursor) {
      const continued = await call("mql5_chm_read", { topic_id: entry.topic_id, cursor: read.structuredContent.next_cursor, max_chars: 500 });
      assert.equal(continued.structuredContent.start_offset, read.structuredContent.end_offset);
      checks.push("opaque_passage_cursor");
    }
    const approximate = await call("mql5_chm_read", { topic_id: entry.topic_id, focus: missing, max_chars: 500 });
    assert.notEqual(approximate.structuredContent.focus_match, "exact");
    const typo = (await call("mql5_chm_search", { query: identifier.slice(0, -1), source: "mql5", expand: false, limit: 1 })).structuredContent;
    assert.ok(typo.results.every((item) => item.match_kind !== "exact"));
    checks.push("prefix_and_typo_are_not_identifier_proof");
    if (fixture) {
      const filtered = (await call("mql5_chm_search", { query: "mql5book image fixture", source: "mql5", expand: false, limit: 1 })).structuredContent;
      assert.equal(filtered.count, 0);
      checks.push("reference_source_filter");
    }
    const imageRead = fixture ? read : await call("mql5_chm_read", { topic_id: (await call("mql5_chm_search", { query: "ENUM_OBJECT", source: "mql5", expand: false, limit: 1 })).structuredContent.results[0].topic_id, max_chars: 500 });
    assert.ok(imageRead.structuredContent.images.length > 0);
    const image = await call("mql5_chm_read_image", { asset_id: imageRead.structuredContent.images[0].asset_id });
    const bytes = Buffer.from(image.content[0].data, "base64");
    assert.equal(bytes.length, image.structuredContent.bytes);
    assert.equal(hash(bytes), image.structuredContent.sha256);
    assert.equal(image.content[0].mimeType, image.structuredContent.mime_type);
    checks.push("native_image_and_integrity_fields");
    for (const [name, args] of [
      ["mql5_chm_search", { query: identifier, limit: listed.tools.find((tool) => tool.name === "mql5_chm_search").inputSchema.properties.limit.maximum + 1 }],
      ["mql5_chm_read", { topic_id: entry.topic_id, max_chars: listed.tools.find((tool) => tool.name === "mql5_chm_read").inputSchema.properties.max_chars.minimum - 1 }],
      ["mql5_chm_read", { topic_id: `mql5:${"0".repeat(24)}` }],
      ["mql5_chm_status", { unexpected: true }],
    ]) assert.equal((await client.callTool({ name, arguments: args })).isError, true, `${name} accepted invalid input`);
    checks.push("invalid_requests_fail_closed");
  } catch (error) {
    throw new Error(`MCP/skill compatibility failed: ${error.message}\n${diagnostic}`, { cause: error });
  } finally {
    try {
      await client.close();
    } finally {
      if (fixture) {
        try {
          if (beforeCorpus) assert.deepEqual(await artifactHashes(root), beforeCorpus, "Read-only compatibility calls changed the corpus");
        } finally {
          const relative = path.relative(tmpdir(), root);
          assert.ok(!relative.startsWith("..") && !path.isAbsolute(relative) && path.basename(root).startsWith("mql5-chm-v12-runtime-"));
          await rm(root, { recursive: true, force: true });
        }
      }
    }
  }
  if (!fixture) assert.deepEqual(await artifactHashes(root), beforeCorpus, "Read-only compatibility calls changed the installed corpus");
  for (const file of skillFiles) assert.equal(hash(await readFile(path.join(skillRoot, file))), beforeSkill[file], "Skill changed during compatibility validation");
  assert.equal(hash(await readFile(serverPath)), beforeServer, "Server bundle changed during compatibility validation");
  checks.push("read_only_artifacts_unchanged");
  return { schema_version: 1, status: "passed", mode: fixture ? "synthetic_corpus" : "installed_corpus", verified_utc: new Date().toISOString(), mcp_checkout_commit: gitCommit(repositoryRoot), skill_checkout_commit: gitCommit(path.resolve(skillRoot, "../..")), server_version: serverVersion, server_path: serverPath, server_sha256: beforeServer, skill_root: skillRoot, skill_files_sha256: beforeSkill, metadata_dependency_verified: true, corpus_revision: verifiedCorpusRevision, checks };
}

async function cli() {
  const options = {};
  let reportPath = null;
  for (let i = 2; i < process.argv.length; i += 2) {
    const key = process.argv[i];
    const value = process.argv[i + 1];
    assert.ok(value && !value.startsWith("--"), `${key} requires a path`);
    if (key === "--skill-root") options.skillRoot = value;
    else if (key === "--python") options.pythonPath = value;
    else if (key === "--server-path") options.serverPath = value;
    else if (key === "--package-root") options.packageRoot = value;
    else if (key === "--report") reportPath = path.resolve(value);
    else throw new Error(`Unknown argument ${key}`);
  }
  assert.ok(options.skillRoot, "--skill-root is required");
  const result = await runCompatibility(options);
  if (reportPath) await writeFile(reportPath, `${JSON.stringify(result, null, 2)}\n`, { flag: "wx" });
  console.log(`MQL5_SKILL_COMPATIBILITY_PASS checks=${result.checks.length} mcp=${result.mcp_checkout_commit ?? "installed"} skill=${result.skill_checkout_commit ?? "installed"}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  cli().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
