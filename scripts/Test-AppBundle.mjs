import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverPath = path.join(root, "app", "server.mjs");
const smokePath = path.join(root, "scripts", "Smoke-Test-McpServer.mjs");
const packageMetadata = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
const active = JSON.parse(readFileSync(path.join(root, "data", "active.json"), "utf8"));
if (!/^[0-9a-f]{64}$/u.test(active.active_revision)) {
  throw new Error("Active corpus pointer does not contain a lowercase SHA-256 revision.");
}
const manifest = JSON.parse(
  readFileSync(path.join(root, "revisions", active.active_revision, "manifest.json"), "utf8"),
);

function runChecked(label, arguments_, options = {}) {
  const result = spawnSync(process.execPath, arguments_, {
    cwd: root,
    env: { ...process.env, ...options.env },
    stdio: "inherit",
    timeout: options.timeout,
    windowsHide: true,
  });
  if (result.error) throw result.error;
  if (result.signal) throw new Error(`${label} terminated by signal ${result.signal}.`);
  if (result.status !== 0) {
    throw new Error(`${label} failed with exit code ${result.status ?? "unknown"}.`);
  }
}

runChecked(
  "Raw app MCP smoke test",
  [
    smokePath,
    "--server", serverPath,
    "--timeout-ms", "30000",
    "--expected-server-version", packageMetadata.version,
    "--expected-active-revision", active.active_revision,
    "--expected-index-revision", manifest.index_revision,
    "--expected-corpus-revision", manifest.corpus_revision,
    "--expected-schema-version", String(manifest.schema_version),
  ],
  { timeout: 45_000 },
);

runChecked(
  "Final app MCP suite",
  ["--test", "--test-concurrency=1", "tests/mcp.test.mjs"],
  {
    env: { MQL5_CHM_TEST_SERVER: serverPath },
    timeout: 300_000,
  },
);
