import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverPath = path.join(root, "app", "server.mjs");
const result = spawnSync(
  process.execPath,
  ["--test", "--test-concurrency=1", "tests/mcp.test.mjs"],
  {
    cwd: root,
    env: { ...process.env, MQL5_CHM_TEST_SERVER: serverPath },
    stdio: "inherit",
    timeout: 300_000,
  },
);

if (result.error) throw result.error;
if (result.signal) throw new Error(`Final app MCP suite terminated by signal ${result.signal}.`);
if (result.status !== 0) process.exitCode = result.status ?? 1;
