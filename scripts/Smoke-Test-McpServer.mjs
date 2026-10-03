import { spawn } from "node:child_process";
import { once } from "node:events";
import { stat } from "node:fs/promises";
import path from "node:path";

const SHA256 = /^[0-9a-f]{64}$/u;
const EXPECTED_TOOLS = Object.freeze([
  "mql5_chm_lookup_identifiers",
  "mql5_chm_read",
  "mql5_chm_read_image",
  "mql5_chm_search",
  "mql5_chm_status",
]);
const EXPECTED_ANNOTATIONS = Object.freeze({
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
});
const MAX_STDOUT_LINE_BYTES = 1024 * 1024;
const MAX_STDERR_BYTES = 64 * 1024;

function parseArguments(arguments_) {
  const values = new Map();
  for (let index = 0; index < arguments_.length; index += 2) {
    const name = arguments_[index];
    const value = arguments_[index + 1];
    if (!name?.startsWith("--") || value === undefined || value.startsWith("--")) {
      throw new Error(`Expected --name value arguments; invalid argument at position ${index + 1}.`);
    }
    if (values.has(name)) throw new Error(`Duplicate argument: ${name}`);
    values.set(name, value);
  }
  const required = [
    "--server",
    "--timeout-ms",
    "--expected-server-version",
    "--expected-active-revision",
    "--expected-index-revision",
    "--expected-corpus-revision",
    "--expected-schema-version",
  ];
  for (const name of required) {
    if (!values.has(name)) throw new Error(`Missing required argument: ${name}`);
  }
  for (const name of values.keys()) {
    if (!required.includes(name)) throw new Error(`Unknown argument: ${name}`);
  }

  const server = path.resolve(values.get("--server"));
  const timeoutMs = Number(values.get("--timeout-ms"));
  const schemaVersion = Number(values.get("--expected-schema-version"));
  const serverVersion = values.get("--expected-server-version");
  const revisions = {
    active: values.get("--expected-active-revision"),
    index: values.get("--expected-index-revision"),
    corpus: values.get("--expected-corpus-revision"),
  };
  if (!Number.isInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 120_000) {
    throw new Error("--timeout-ms must be an integer from 100 through 120000.");
  }
  if (!Number.isInteger(schemaVersion) || schemaVersion < 1) {
    throw new Error("--expected-schema-version must be a positive integer.");
  }
  if (
    serverVersion.length < 1
    || serverVersion.length > 100
    || /[\u0000-\u0020\u007f]/u.test(serverVersion)
  ) {
    throw new Error("--expected-server-version must be 1 through 100 non-whitespace printable characters.");
  }
  for (const [name, value] of Object.entries(revisions)) {
    if (!SHA256.test(value)) throw new Error(`Expected ${name} revision must be lowercase SHA-256.`);
  }
  return { server, timeoutMs, schemaVersion, serverVersion, revisions };
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function withStderrTail(error, stderrText) {
  const tail = stderrText
    .trim()
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/gu, "\uFFFD");
  if (!tail) return error instanceof Error ? error : new Error(String(error));
  return new Error(`${errorMessage(error)}\nMCP server stderr tail:\n${tail}`);
}

function assertPlainObject(value, context) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${context} is not an object.`);
  }
  return value;
}

function assertInitialize(result, expectedServerVersion) {
  const value = assertPlainObject(result, "initialize result");
  if (value.protocolVersion !== "2025-11-25") {
    throw new Error(`initialize negotiated unexpected protocol version: ${value.protocolVersion}`);
  }
  if (value.serverInfo?.name !== "mql5-chm") {
    throw new Error(`initialize returned unexpected server name: ${value.serverInfo?.name}`);
  }
  if (value.serverInfo?.version !== expectedServerVersion) {
    throw new Error(
      `initialize returned unexpected server version: ${value.serverInfo?.version}; expected ${expectedServerVersion}`,
    );
  }
  if (!value.capabilities || !Object.prototype.hasOwnProperty.call(value.capabilities, "tools")) {
    throw new Error("initialize did not advertise tools capability.");
  }
}

function assertTools(result) {
  const value = assertPlainObject(result, "tools/list result");
  if (!Array.isArray(value.tools)) throw new Error("tools/list result does not contain a tools array.");
  const names = value.tools.map((tool) => tool?.name);
  const unique = new Set(names);
  if (unique.size !== names.length) throw new Error("tools/list returned a duplicate tool name.");
  const sorted = [...names].sort();
  if (JSON.stringify(sorted) !== JSON.stringify(EXPECTED_TOOLS)) {
    throw new Error(`tools/list did not return the exact read-only tool set: ${sorted.join(", ")}`);
  }
  for (const tool of value.tools) {
    const annotations = assertPlainObject(tool.annotations, `${tool.name} annotations`);
    const actualKeys = Object.keys(annotations).sort();
    const expectedKeys = Object.keys(EXPECTED_ANNOTATIONS).sort();
    if (
      JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)
      || expectedKeys.some((key) => annotations[key] !== EXPECTED_ANNOTATIONS[key])
    ) {
      throw new Error(`tools/list returned unsafe or incomplete annotations for ${tool.name}.`);
    }
  }
}

function assertStatus(result, expected) {
  const value = assertPlainObject(result, "mql5_chm_status result");
  if (value.isError === true) throw new Error("mql5_chm_status returned an MCP tool error.");
  const status = assertPlainObject(value.structuredContent, "mql5_chm_status structuredContent");
  if (status.schema_version !== expected.schemaVersion) {
    throw new Error(`mql5_chm_status schema version mismatch: ${status.schema_version}`);
  }
  if (status.active_revision !== expected.revisions.active) {
    throw new Error("mql5_chm_status active revision does not match the prevalidated package.");
  }
  if (status.index_revision !== expected.revisions.index || status.index_sha256 !== expected.revisions.index) {
    throw new Error("mql5_chm_status index revision does not match the prevalidated package.");
  }
  if (status.corpus_revision !== expected.revisions.corpus) {
    throw new Error("mql5_chm_status corpus revision does not match the prevalidated package.");
  }
}

async function stopChild(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  let exitPromise = once(child, "exit").then(() => true);
  child.stdin.end();
  let exited = await Promise.race([
    exitPromise,
    new Promise((resolve) => setTimeout(() => resolve(false), 250)),
  ]);
  if (exited || child.exitCode !== null || child.signalCode !== null) return;
  child.kill();
  exited = await Promise.race([
    exitPromise,
    new Promise((resolve) => setTimeout(() => resolve(false), 1_000)),
  ]);
  if (exited || child.exitCode !== null || child.signalCode !== null) return;
  exitPromise = once(child, "exit");
  child.kill("SIGKILL");
  await Promise.race([
    exitPromise,
    new Promise((_, reject) => setTimeout(
      () => reject(new Error("MCP server did not terminate after forced shutdown.")),
      2_000,
    )),
  ]);
}

async function waitForChildClose(closePromise) {
  let timer;
  try {
    const closed = await Promise.race([
      closePromise.then(() => true),
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(false), 2_000);
      }),
    ]);
    if (!closed) throw new Error("MCP server stdio did not close after shutdown.");
  } finally {
    clearTimeout(timer);
  }
}

async function runSmoke(options) {
  const serverInfo = await stat(options.server);
  if (!serverInfo.isFile()) throw new Error(`Server entry point is not a file: ${options.server}`);

  const environment = { ...process.env };
  delete environment.MQL5_CHM_MCP_ROOT;
  const child = spawn(process.execPath, [options.server], {
    env: environment,
    shell: false,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  const childClosed = new Promise((resolve) => child.once("close", resolve));

  let stdoutBuffer = Buffer.alloc(0);
  let stderrText = "";
  let terminalError = null;
  let completed = false;
  let rejectTerminal;
  const terminal = new Promise((_, reject) => { rejectTerminal = reject; });
  const pending = new Map();
  let nextId = 1;

  const fail = (error) => {
    if (terminalError !== null || completed) return;
    terminalError = error instanceof Error ? error : new Error(String(error));
    rejectTerminal(terminalError);
  };

  child.on("error", fail);
  child.on("exit", (code, signal) => {
    if (!completed && terminalError === null) {
      fail(new Error(`MCP server exited before smoke completion (code=${code}, signal=${signal}).`));
    }
  });
  child.stdin.on("error", fail);
  child.stderr.on("data", (chunk) => {
    stderrText = `${stderrText}${chunk.toString("utf8")}`;
    if (Buffer.byteLength(stderrText, "utf8") > MAX_STDERR_BYTES) {
      stderrText = Buffer.from(stderrText, "utf8").subarray(-MAX_STDERR_BYTES).toString("utf8");
    }
  });
  child.stdout.on("data", (chunk) => {
    stdoutBuffer = Buffer.concat([stdoutBuffer, chunk]);
    while (true) {
      const newline = stdoutBuffer.indexOf(0x0a);
      if (newline < 0) {
        if (stdoutBuffer.length > MAX_STDOUT_LINE_BYTES) {
          fail(new Error("MCP server emitted an oversized JSON-RPC line."));
        }
        break;
      }
      if (newline > MAX_STDOUT_LINE_BYTES) {
        fail(new Error("MCP server emitted an oversized JSON-RPC line."));
        return;
      }
      const line = stdoutBuffer.subarray(0, newline).toString("utf8").replace(/\r$/u, "");
      stdoutBuffer = stdoutBuffer.subarray(newline + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch (error) {
        fail(new Error(`MCP server emitted malformed JSON-RPC: ${errorMessage(error)}`));
        return;
      }
      if (
        message === null
        || typeof message !== "object"
        || Array.isArray(message)
        || message.jsonrpc !== "2.0"
      ) {
        fail(new Error("MCP server response is not a JSON-RPC 2.0 object."));
        return;
      }
      const waiter = pending.get(message.id);
      if (!waiter) {
        fail(new Error(`MCP server returned an unexpected JSON-RPC response id: ${message.id}`));
        return;
      }
      pending.delete(message.id);
      if (message.error) waiter.reject(new Error(`MCP ${waiter.method} failed: ${JSON.stringify(message.error)}`));
      else waiter.resolve(message.result);
    }
  });

  const deadline = setTimeout(
    () => fail(new Error(`MCP server smoke test timed out after its ${options.timeoutMs}ms deadline.`)),
    options.timeoutMs,
  );
  const request = (method, params) => {
    const id = nextId++;
    const response = new Promise((resolve, reject) => pending.set(id, { method, resolve, reject }));
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return Promise.race([response, terminal]);
  };
  const notify = (method, params) => {
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  };

  let smokeFailure = null;
  let cleanupFailure = null;
  try {
    const initialized = await request("initialize", {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: { name: "mql5-chm-installer-smoke", version: options.serverVersion },
    });
    assertInitialize(initialized, options.serverVersion);
    notify("notifications/initialized", {});
    assertTools(await request("tools/list", {}));
    assertStatus(
      await request("tools/call", { name: "mql5_chm_status", arguments: {} }),
      options,
    );
    completed = true;
  } catch (error) {
    fail(error);
    smokeFailure = terminalError ?? (error instanceof Error ? error : new Error(String(error)));
  } finally {
    clearTimeout(deadline);
    for (const waiter of pending.values()) waiter.reject(new Error("MCP smoke test ended."));
    pending.clear();
    try {
      await stopChild(child);
    } catch (error) {
      cleanupFailure = error instanceof Error ? error : new Error(String(error));
    }
    try {
      await waitForChildClose(childClosed);
    } catch (error) {
      const closeFailure = error instanceof Error ? error : new Error(String(error));
      cleanupFailure = cleanupFailure === null
        ? closeFailure
        : new AggregateError(
          [cleanupFailure, closeFailure],
          `${errorMessage(cleanupFailure)} ${errorMessage(closeFailure)}`,
        );
    }
  }

  if (smokeFailure !== null) {
    if (cleanupFailure !== null) {
      smokeFailure = new AggregateError(
        [smokeFailure, cleanupFailure],
        `${errorMessage(smokeFailure)} Cleanup also failed: ${errorMessage(cleanupFailure)}`,
      );
    }
    throw withStderrTail(smokeFailure, stderrText);
  }
  if (cleanupFailure !== null) throw withStderrTail(cleanupFailure, stderrText);
}

try {
  const options = parseArguments(process.argv.slice(2));
  await runSmoke(options);
  process.stdout.write("Verified MCP initialize, tools/list, and mql5_chm_status.\n");
} catch (error) {
  process.stderr.write(`MCP server smoke test failed: ${errorMessage(error)}\n`);
  process.exitCode = 1;
}
