import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "scripts", "Smoke-Test-McpServer.mjs");
const packageMetadata = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
const expected = Object.freeze({
  active: "a".repeat(64),
  index: "b".repeat(64),
  corpus: "c".repeat(64),
  schema: 3,
  serverVersion: packageMetadata.version,
});

const fakeServerSource = String.raw`
import { appendFileSync, writeFileSync } from "node:fs";

const mode = process.env.MQL5_CHM_FAKE_MODE ?? "success";
const logPath = process.env.MQL5_CHM_FAKE_LOG;
let buffer = "";

function log(value) {
  if (logPath) appendFileSync(logPath, JSON.stringify(value) + "\n", "utf8");
}

function send(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

function sendInitialize(value) {
  if (mode !== "oversized-line") {
    send(value);
    return;
  }
  const payload = JSON.stringify({
    ...value,
    result: {
      ...value.result,
      padding: "x".repeat((1024 * 1024) + 512),
    },
  }) + "\n";
  const split = (1024 * 1024) - 128;
  process.stdout.write(payload.slice(0, split), () => {
    setTimeout(() => process.stdout.write(payload.slice(split)), 10);
  });
}

log({ event: "started", inheritedRoot: process.env.MQL5_CHM_MCP_ROOT ?? null });
if (mode === "startup-failure") {
  process.stderr.write("specific server startup failure\n", () => process.exit(2));
}
if (mode === "buffered-stderr-exit") {
  const marker = "buffered shutdown diagnostic";
  writeFileSync(2, "x".repeat(128 * 1024) + marker + "\n");
  process.exit(2);
}
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  while (true) {
    const newline = buffer.indexOf("\n");
    if (newline < 0) break;
    const line = buffer.slice(0, newline).replace(/\r$/, "");
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    log({ event: "message", method: message.method, id: message.id ?? null });
    if (mode === "silent") continue;
    if (message.method === "initialize") {
      sendInitialize({
        jsonrpc: mode === "invalid-jsonrpc" ? "1.0" : "2.0",
        id: message.id,
        result: {
          protocolVersion: "2025-11-25",
          capabilities: { tools: {} },
          serverInfo: {
            name: "mql5-chm",
            version: mode === "wrong-server-version" ? "9.9.9" : "${expected.serverVersion}",
          },
        },
      });
      continue;
    }
    if (message.method === "tools/list") {
      const annotations = {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      };
      let names = ["mql5_chm_read", "mql5_chm_read_image", "mql5_chm_search", "mql5_chm_status"];
      if (mode === "missing-tool") names = names.filter((name) => name !== "mql5_chm_status");
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: { tools: names.map((name) => ({ name, annotations, inputSchema: { type: "object" } })) },
      });
      continue;
    }
    if (message.method === "tools/call") {
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: {
          content: [{ type: "text", text: "status" }],
          structuredContent: {
            schema_version: 3,
            active_revision: "${expected.active}",
            index_revision: mode === "wrong-revision" ? "${"d".repeat(64)}" : "${expected.index}",
            index_sha256: "${expected.index}",
            corpus_revision: "${expected.corpus}",
          },
        },
      });
    }
  }
});
`;

async function runSmoke(mode, timeoutMs = 1_000) {
  const fixture = await mkdtemp(path.join(tmpdir(), "mql5-chm-install-smoke-"));
  try {
    const server = path.join(fixture, "fake-server.mjs");
    const log = path.join(fixture, "messages.jsonl");
    await writeFile(server, fakeServerSource, "utf8");
    const started = Date.now();
    const result = spawnSync(
      process.execPath,
      [
        helper,
        "--server", server,
        "--timeout-ms", String(timeoutMs),
        "--expected-active-revision", expected.active,
        "--expected-index-revision", expected.index,
        "--expected-corpus-revision", expected.corpus,
        "--expected-schema-version", String(expected.schema),
        "--expected-server-version", expected.serverVersion,
      ],
      {
        cwd: fixture,
        encoding: "utf8",
        env: {
          ...process.env,
          MQL5_CHM_FAKE_MODE: mode,
          MQL5_CHM_FAKE_LOG: log,
          MQL5_CHM_MCP_ROOT: path.join(fixture, "must-not-be-inherited"),
        },
        timeout: 10_000,
        windowsHide: true,
      },
    );
    let events = [];
    try {
      events = (await readFile(log, "utf8"))
        .trim()
        .split(/\r?\n/u)
        .filter(Boolean)
        .map((line) => JSON.parse(line));
    } catch {
      // A missing helper is the expected red state before implementation.
    }
    return { ...result, elapsedMs: Date.now() - started, events };
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

test("installer smoke performs the strict MCP handshake without a root override", async () => {
  const result = await runSmoke("success");
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.equal(result.events[0].inheritedRoot, null);
  assert.deepEqual(
    result.events.filter((entry) => entry.event === "message").map((entry) => entry.method),
    ["initialize", "notifications/initialized", "tools/list", "tools/call"],
  );
});

test("installer smoke rejects an incomplete tool list and revision mismatch", async () => {
  const missingTool = await runSmoke("missing-tool");
  assert.notEqual(missingTool.status, 0);
  assert.match(`${missingTool.stderr}\n${missingTool.stdout}`, /tools\/list|mql5_chm_status/i);

  const wrongRevision = await runSmoke("wrong-revision");
  assert.notEqual(wrongRevision.status, 0);
  assert.match(`${wrongRevision.stderr}\n${wrongRevision.stdout}`, /index revision/i);
});

test("installer smoke requires an explicit expected server version", () => {
  const result = spawnSync(
    process.execPath,
    [
      helper,
      "--server", helper,
      "--timeout-ms", "1000",
      "--expected-active-revision", expected.active,
      "--expected-index-revision", expected.index,
      "--expected-corpus-revision", expected.corpus,
      "--expected-schema-version", String(expected.schema),
    ],
    { cwd: root, encoding: "utf8", windowsHide: true },
  );
  assert.notEqual(result.status, 0);
  assert.match(`${result.stderr}\n${result.stdout}`, /Missing required argument: --expected-server-version/u);
});

test("installer smoke binds initialize serverInfo.version to package.json", async () => {
  const wrongVersion = await runSmoke("wrong-server-version");
  assert.notEqual(wrongVersion.status, 0);
  assert.match(`${wrongVersion.stderr}\n${wrongVersion.stdout}`, /server version|9\.9\.9/i);
});

test("installer smoke enforces its deadline and terminates a silent server", async () => {
  const result = await runSmoke("silent", 200);
  assert.notEqual(result.status, 0);
  assert.ok(result.elapsedMs < 5_000, `smoke timeout took ${result.elapsedMs}ms`);
  assert.match(`${result.stderr}\n${result.stdout}`, /deadline|timed out/i);
});

test("installer smoke rejects an oversized complete JSON-RPC line", async () => {
  const result = await runSmoke("oversized-line");
  assert.notEqual(result.status, 0);
  assert.match(`${result.stderr}\n${result.stdout}`, /oversized JSON-RPC line/i);
});

test("installer smoke requires a JSON-RPC 2.0 response envelope", async () => {
  const result = await runSmoke("invalid-jsonrpc");
  assert.notEqual(result.status, 0);
  assert.match(`${result.stderr}\n${result.stdout}`, /JSON-RPC 2\.0|jsonrpc/i);
});

test("installer smoke preserves a bounded server stderr diagnostic", async () => {
  const result = await runSmoke("startup-failure");
  assert.notEqual(result.status, 0);
  assert.match(`${result.stderr}\n${result.stdout}`, /specific server startup failure/i);
});

test("installer smoke drains buffered stderr from an immediately exiting server", async () => {
  const result = await runSmoke("buffered-stderr-exit");
  assert.notEqual(result.status, 0);
  assert.match(`${result.stderr}\n${result.stdout}`, /buffered shutdown diagnostic/i);
});

test("Install-Codex runs the smoke gate before registration", async () => {
  const source = await readFile(path.join(root, "scripts", "Install-Codex.ps1"), "utf8");
  const smoke = source.indexOf("Smoke-Test-McpServer.mjs");
  const registration = source.indexOf("Install-CodexMql5ChmRegistration");
  assert.ok(smoke >= 0, "installer does not invoke the MCP smoke helper");
  assert.ok(registration > smoke, "installer can register before the MCP smoke gate");
  assert.match(
    source,
    /\$packageManifest\s*=\s*Read-JsonFile[\s\S]*?package\.json[\s\S]*?\$expectedServerVersion\s*=\s*\[string\]\(Get-RequiredJsonProperty\s+\$packageManifest\s+'version'\s+'package manifest'\)/u,
    "installer does not derive the expected server version from package.json",
  );
  assert.match(source, /'--expected-server-version'\s*,\s*\$expectedServerVersion/u);
  assert.doesNotMatch(source, /'--expected-server-version'\s*,\s*'\d/u);
});

test("portable packages carry checksum-bound version metadata for installation", async () => {
  const packager = await readFile(path.join(root, "scripts", "Package-Portable.ps1"), "utf8");
  const common = await readFile(path.join(root, "scripts", "Common.ps1"), "utf8");
  const rootFiles = packager.match(/^\$rootFiles\s*=\s*@\([\s\S]*?^\)$/mu)?.[0];
  const requiredFiles = common.match(/^\s*\$required\s*=\s*@\([\s\S]*?^\s*\)$/mu)?.[0];
  assert.match(rootFiles ?? "", /^\s*'package\.json',?\s*$/mu);
  assert.match(requiredFiles ?? "", /^\s*'package\.json',?\s*$/mu);
});
