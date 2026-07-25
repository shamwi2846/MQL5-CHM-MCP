import {
  lstat,
  mkdir,
  mkdtemp,
  open,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(scriptDir, "..");
const buildRoot = path.join(root, "build");
const productionApp = path.join(root, "app");
const transactionRoot = path.join(buildRoot, ".bundle-publish-transactions");
const globalClaimPath = path.join(buildRoot, ".bundle-publish-claim");
const expectedBundleNames = new Set(["indexer.mjs", "server.mjs"]);
const journalVersion = 1;
const claimVersion = 2;
const injectedExitCode = 86;

function parseArguments(argv) {
  const result = { outdir: "app", metafile: "build/esbuild-meta.json" };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--outdir" || argument === "--metafile") {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) throw new Error(`${argument} requires one relative path.`);
      result[argument === "--outdir" ? "outdir" : "metafile"] = value;
      index += 1;
      continue;
    }
    throw new Error(`Unknown build argument: ${argument}`);
  }
  return result;
}

function normalizedPath(value) {
  const resolved = path.resolve(value);
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

function isSamePath(left, right) {
  return normalizedPath(left) === normalizedPath(right);
}

function isStrictDescendant(parent, child) {
  const relative = path.relative(parent, child);
  return Boolean(relative)
    && relative !== ".."
    && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative);
}

function hasExactKeys(value, expectedKeys) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const actualKeys = Object.keys(value).sort();
  const sortedExpectedKeys = [...expectedKeys].sort();
  return actualKeys.length === expectedKeys.length
    && actualKeys.every((key, index) => key === sortedExpectedKeys[index]);
}

function assertExactKeys(value, expectedKeys, label) {
  if (!hasExactKeys(value, expectedKeys)) {
    throw new Error(`${label} has an invalid shape.`);
  }
}

function projectRelative(target) {
  const relative = path.relative(root, target);
  if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`Transaction path is not confined to the project root: ${target}`);
  }
  return relative.split(path.sep).join("/");
}

function canonicalProjectRelative(target) {
  const relative = projectRelative(target);
  return process.platform === "win32" ? relative.toLowerCase() : relative;
}

function publicationKey(appDir, metaPath) {
  return createHash("sha256")
    .update(`${canonicalProjectRelative(appDir)}\0${canonicalProjectRelative(metaPath)}`)
    .digest("hex");
}

function backupPaths(record) {
  return {
    appBackup: path.join(
      path.dirname(record.appDir),
      `.${path.basename(record.appDir)}.backup-${record.transaction}`,
    ),
    metaBackup: path.join(
      path.dirname(record.metaPath),
      `.${path.basename(record.metaPath)}.backup-${record.transaction}`,
    ),
  };
}

function isInternalPublicationPath(target) {
  if (isSamePath(target, transactionRoot) || isStrictDescendant(transactionRoot, target)) {
    return true;
  }
  const relative = path.relative(buildRoot, target);
  if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`)) return false;
  const [firstSegment] = relative.split(path.sep);
  return /^\.bundle-publish-claim(?:$|[.-])/u.test(firstSegment);
}

function resolveConfined(relativePath, label) {
  if (path.isAbsolute(relativePath)) throw new Error(`${label} must be relative to the project root.`);
  const resolved = path.resolve(root, relativePath);
  if (!isStrictDescendant(root, resolved)) {
    throw new Error(`${label} must be a child of the project root.`);
  }
  return resolved;
}

async function lstatIfPresent(target) {
  try {
    return await lstat(target);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function assertNoReparseAncestors(target, label) {
  const resolved = path.resolve(target);
  const { root: volumeRoot } = path.parse(resolved);
  const segments = path.relative(volumeRoot, resolved).split(path.sep).filter(Boolean);
  let current = volumeRoot;
  for (const segment of segments) {
    current = path.join(current, segment);
    const entry = await lstatIfPresent(current);
    if (!entry) break;
    if (entry.isSymbolicLink()) {
      throw new Error(`${label} traverses a symbolic link or junction: ${current}`);
    }
  }
}

async function assertNoReparseTree(target, label) {
  const entry = await lstatIfPresent(target);
  if (!entry) return;
  if (entry.isSymbolicLink()) {
    throw new Error(`${label} contains a symbolic link or junction: ${target}`);
  }
  if (entry.isFile()) return;
  if (!entry.isDirectory()) {
    throw new Error(`${label} contains a special filesystem entry: ${target}`);
  }
  const children = await readdir(target);
  for (const child of children) {
    await assertNoReparseTree(path.join(target, child), label);
  }
}

function assertBuildPathPolicy(appDir, metaPath) {
  if (!isSamePath(appDir, productionApp) && !isStrictDescendant(buildRoot, appDir)) {
    throw new Error("--outdir must be the production app directory or a generated descendant of build.");
  }
  if (isInternalPublicationPath(appDir)) {
    throw new Error("--outdir must be outside the internal publication state.");
  }
  if (!isStrictDescendant(buildRoot, metaPath)) {
    throw new Error("--metafile must be a generated file beneath build.");
  }
  if (isInternalPublicationPath(metaPath)) {
    throw new Error("--metafile must be outside the internal publication state.");
  }
  if (isSamePath(metaPath, appDir) || isStrictDescendant(appDir, metaPath)) {
    throw new Error("--metafile must be outside the bundle output directory.");
  }
  if (path.extname(metaPath).toLowerCase() !== ".json") {
    throw new Error("--metafile must name a JSON file.");
  }
}

async function validateBuildPlan(outdirArgument, metafileArgument) {
  const appDir = resolveConfined(outdirArgument, "--outdir");
  const metaPath = resolveConfined(metafileArgument, "--metafile");

  assertBuildPathPolicy(appDir, metaPath);

  for (const [target, label] of [
    [root, "project root"],
    [buildRoot, "build root"],
    [path.join(root, "src", "server.mjs"), "server entry point"],
    [path.join(root, "src", "indexer.mjs"), "indexer entry point"],
    [appDir, "--outdir"],
    [metaPath, "--metafile"],
  ]) {
    await assertNoReparseAncestors(target, label);
  }

  await assertNotNestedInsideExistingBundleOutput(appDir, "--outdir");
  await assertNotNestedInsideExistingBundleOutput(metaPath, "--metafile");

  const metadataEntry = await lstatIfPresent(metaPath);
  if (metadataEntry && !metadataEntry.isFile()) {
    throw new Error("--metafile must not replace a directory or special filesystem entry.");
  }
  await validateExistingBundleDirectory(appDir);
  return { appDir, metaPath };
}

async function containsOwnedBundlePair(target) {
  const entry = await lstatIfPresent(target);
  if (!entry?.isDirectory()) return false;
  const children = await readdir(target, { withFileTypes: true });
  const ownedFiles = new Set(
    children
      .filter((child) => child.isFile() && expectedBundleNames.has(child.name))
      .map((child) => child.name),
  );
  return ownedFiles.size === expectedBundleNames.size;
}

async function assertNotNestedInsideExistingBundleOutput(target, label) {
  let ancestor = path.dirname(target);
  while (isSamePath(ancestor, buildRoot) || isStrictDescendant(buildRoot, ancestor)) {
    if (await containsOwnedBundlePair(ancestor)) {
      throw new Error(`${label} must not be nested inside an existing bundle output: ${ancestor}`);
    }
    if (isSamePath(ancestor, buildRoot)) return;
    ancestor = path.dirname(ancestor);
  }
}

async function validateExistingBundleDirectory(appDir) {
  const entry = await lstatIfPresent(appDir);
  if (!entry) return;
  if (!entry.isDirectory()) throw new Error("--outdir must be a directory when it already exists.");
  const children = await readdir(appDir, { withFileTypes: true });
  for (const child of children) {
    if (!child.isFile() || !expectedBundleNames.has(child.name)) {
      throw new Error(`--outdir contains an unowned entry and will not be replaced: ${child.name}`);
    }
  }
}

async function fileManifest(target, label) {
  const entry = await lstatIfPresent(target);
  if (!entry) return null;
  if (!entry.isFile()) throw new Error(`${label} must be a regular file.`);
  const content = await readFile(target);
  return {
    size: content.length,
    sha256: createHash("sha256").update(content).digest("hex"),
  };
}

async function directoryManifest(target, label) {
  const entry = await lstatIfPresent(target);
  if (!entry) return null;
  if (!entry.isDirectory()) throw new Error(`${label} must be a directory.`);
  const children = await readdir(target, { withFileTypes: true });
  const files = {};
  for (const child of children.sort((left, right) => left.name.localeCompare(right.name, "en"))) {
    if (!child.isFile() || !expectedBundleNames.has(child.name)) {
      throw new Error(`${label} contains an unowned entry: ${child.name}`);
    }
    files[child.name] = await fileManifest(path.join(target, child.name), `${label}/${child.name}`);
  }
  return { files };
}

function validateFileManifest(manifest, label) {
  assertExactKeys(manifest, ["sha256", "size"], label);
  if (!Number.isSafeInteger(manifest.size) || manifest.size < 0) {
    throw new Error(`${label} has an invalid size.`);
  }
  if (typeof manifest.sha256 !== "string" || !/^[a-f0-9]{64}$/u.test(manifest.sha256)) {
    throw new Error(`${label} has an invalid SHA-256 digest.`);
  }
}

function validateDirectoryManifest(manifest, label, requireComplete = false) {
  assertExactKeys(manifest, ["files"], label);
  if (!manifest.files || typeof manifest.files !== "object" || Array.isArray(manifest.files)) {
    throw new Error(`${label}.files must be an object.`);
  }
  const names = Object.keys(manifest.files);
  if (names.some((name) => !expectedBundleNames.has(name))) {
    throw new Error(`${label} names an unexpected bundle file.`);
  }
  if (requireComplete
      && (names.length !== expectedBundleNames.size
        || [...expectedBundleNames].some((name) => !names.includes(name)))) {
    throw new Error(`${label} must describe both generated bundles.`);
  }
  for (const name of names) validateFileManifest(manifest.files[name], `${label}.files.${name}`);
}

function sameFileManifest(left, right) {
  return Boolean(left)
    && Boolean(right)
    && left.size === right.size
    && left.sha256 === right.sha256;
}

function sameDirectoryManifest(left, right) {
  if (!left || !right) return false;
  const leftNames = Object.keys(left.files).sort();
  const rightNames = Object.keys(right.files).sort();
  return leftNames.length === rightNames.length
    && leftNames.every((name, index) => (
      name === rightNames[index] && sameFileManifest(left.files[name], right.files[name])
    ));
}

function directoryManifestIsOwnedSubset(actual, expected) {
  if (!actual || !expected) return false;
  return Object.entries(actual.files).every(
    ([name, manifest]) => expected.files[name] && sameFileManifest(manifest, expected.files[name]),
  );
}

async function writeDurableNewFile(target, payload, label) {
  let handle;
  let completed = false;
  try {
    handle = await open(target, "wx");
    await handle.writeFile(`${JSON.stringify(payload, null, 2)}\n`, "utf8");
    await handle.sync();
    completed = true;
  } catch (error) {
    if (error?.code === "EEXIST") {
      throw new Error(`${label} already exists.`);
    }
    throw error;
  } finally {
    if (handle) await handle.close();
    if (handle && !completed) {
      try {
        await rm(target, { force: true });
      } catch {
        // Preserve the original write failure. The private incomplete file is never published.
      }
    }
  }
}

async function readOwnedJson(target, label) {
  const entry = await lstatIfPresent(target);
  if (!entry) return null;
  if (!entry.isFile()) throw new Error(`${label} is not a regular file.`);
  try {
    return JSON.parse(await readFile(target, "utf8"));
  } catch (error) {
    throw new Error(`${label} is not valid JSON; publication recovery stopped without changing outputs.`, {
      cause: error,
    });
  }
}

function validateClaimOwner(owner, label) {
  assertExactKeys(owner, ["pid", "processStartToken", "transaction", "version"], label);
  if (owner.version !== claimVersion
      || !Number.isSafeInteger(owner.pid)
      || owner.pid <= 0
      || owner.pid > 2_147_483_647
      || typeof owner.processStartToken !== "string"
      || !(process.platform === "win32"
        ? /^win32-filetime:[1-9][0-9]{0,18}$/u
        : /^pid:[1-9][0-9]{0,15}$/u).test(owner.processStartToken)
      || typeof owner.transaction !== "string"
      || !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/iu
        .test(owner.transaction)) {
    throw new Error(`${label} is invalid.`);
  }
}

async function readClaimOwner(claimPath, label) {
  await assertNoReparseAncestors(claimPath, label);
  const entry = await lstatIfPresent(claimPath);
  if (!entry) return null;
  if (!entry.isDirectory()) throw new Error(`${label} must be a directory.`);
  const ownerPath = path.join(claimPath, "owner.json");
  await assertNoReparseAncestors(ownerPath, `${label} owner`);
  const owner = await readOwnedJson(ownerPath, `${label} owner`);
  if (!owner) throw new Error(`${label} has no owner record.`);
  validateClaimOwner(owner, `${label} owner`);
  return owner;
}

function mutexHolderScript(mutexName, ownerPid) {
  const hangOnRelease = process.env.MQL5_CHM_BUILD_TEST_MUTEX_HANG_ON_RELEASE === "1";
  if (hangOnRelease && process.env.MQL5_CHM_BUILD_TEST_MODE !== "1") {
    throw new Error("Mutex-holder hang injection is available only in regression tests.");
  }
  return [
    "$ErrorActionPreference = 'Stop'",
    "function Get-ProcessStartToken([int]$TargetPid) {",
    "  $target = [System.Diagnostics.Process]::GetProcessById($TargetPid)",
    "  try {",
    "    return $target.StartTime.ToFileTimeUtc().ToString([System.Globalization.CultureInfo]::InvariantCulture)",
    "  }",
    "  finally { $target.Dispose() }",
    "}",
    `$mutex = [System.Threading.Mutex]::new($false, '${mutexName.replaceAll("'", "''")}')`,
    "$acquired = $false",
    "try {",
    "  try { $acquired = $mutex.WaitOne(1000) }",
    "  catch [System.Threading.AbandonedMutexException] { $acquired = $true }",
    "  if (-not $acquired) {",
    "    [Console]::Out.WriteLine('BUSY')",
    "    [Console]::Out.Flush()",
    "    exit 73",
    "  }",
    "  try { $ownerStartToken = Get-ProcessStartToken -TargetPid " + ownerPid + " }",
    "  catch {",
    "    [Console]::Out.WriteLine('OWNER_QUERY_ERROR')",
    "    [Console]::Out.Flush()",
    "    exit 74",
    "  }",
    "  [Console]::Out.WriteLine('READY:' + $ownerStartToken)",
    "  [Console]::Out.Flush()",
    "  while ($true) {",
    "    $command = [Console]::In.ReadLine()",
    "    if ($null -eq $command -or $command -eq 'RELEASE') { break }",
    "    if ($command -notmatch '^QUERY:([1-9][0-9]{0,9})$') {",
    "      [Console]::Out.WriteLine('PROTOCOL_ERROR')",
    "      [Console]::Out.Flush()",
    "      continue",
    "    }",
    "    $targetPid = [int]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)",
    "    try {",
    "      $startToken = Get-ProcessStartToken -TargetPid $targetPid",
    "      [Console]::Out.WriteLine('PROCESS:' + $targetPid + ':' + $startToken)",
    "    }",
    "    catch [System.ArgumentException] {",
    "      [Console]::Out.WriteLine('MISSING:' + $targetPid)",
    "    }",
    "    catch {",
    "      [Console]::Out.WriteLine('QUERY_ERROR:' + $targetPid)",
    "    }",
    "    [Console]::Out.Flush()",
    "  }",
    ...(hangOnRelease ? ["  Start-Sleep -Seconds 30"] : []),
    "}",
    "finally {",
    "  if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }",
    "  $mutex.Dispose()",
    "}",
  ].join("\r\n");
}

function mutexHolderHasExited(holder) {
  return !Number.isSafeInteger(holder.child?.pid)
    || holder.child.exitCode !== null
    || holder.child.signalCode !== null
    || !holder.alive;
}

async function waitForMutexHolderExit(holder, timeoutMs) {
  if (mutexHolderHasExited(holder)) return true;
  return new Promise((resolvePromise) => {
    let settled = false;
    const finish = (exited) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      holder.child.removeListener("exit", onExit);
      resolvePromise(exited);
    };
    const onExit = () => finish(true);
    const timeout = setTimeout(() => finish(false), timeoutMs);
    holder.child.once("exit", onExit);
  });
}

async function terminateAndReapMutexHolder(holder) {
  const child = holder.child;
  if (!child || !Number.isSafeInteger(child.pid)) {
    holder.alive = false;
    return;
  }
  const pid = child.pid;
  if (await waitForMutexHolderExit(holder, 0)) return;
  try {
    child.stdin.destroy();
  } catch {
    // Continue to process termination.
  }
  try {
    child.kill();
  } catch {
    // Confirm exit below and escalate once if needed.
  }
  if (await waitForMutexHolderExit(holder, 3_000)) return;
  try {
    child.kill("SIGKILL");
  } catch {
    // The bounded confirmation below owns the final result.
  }
  if (await waitForMutexHolderExit(holder, 2_000)) return;
  throw new Error(
    `Could not terminate and reap global publication mutex holder PID ${pid}; it may still own the mutex.`,
  );
}

async function throwAfterMutexHolderTermination(holder, error) {
  try {
    await terminateAndReapMutexHolder(holder);
  } catch (terminationError) {
    throw new AggregateError(
      [error, terminationError],
      `Global publication mutex failure; surviving holder PID ${holder.child?.pid ?? "unknown"}.`,
    );
  }
  throw error;
}

async function requestMutexHolder(holder, command, timeoutMs = 10_000) {
  if (!holder.child || !holder.alive) {
    throw new Error("Global publication mutex holder is not available for a process query.");
  }
  return new Promise((resolvePromise, rejectPromise) => {
    let stdout = "";
    let settled = false;
    const finish = (error, response) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      holder.child.stdout.removeListener("data", onData);
      holder.child.removeListener("exit", onExit);
      holder.child.removeListener("error", onError);
      if (error) rejectPromise(error);
      else resolvePromise(response);
    };
    const onData = (chunk) => {
      stdout += chunk;
      const newline = stdout.indexOf("\n");
      if (newline >= 0) finish(null, stdout.slice(0, newline).trim());
    };
    const onExit = (code) => finish(new Error(
      `Global publication mutex holder exited during a process query (code ${code}). ${holder.stderr}`
        .trim(),
    ));
    const onError = (error) => finish(new Error(
      "Global publication mutex holder failed during a process query.",
      { cause: error },
    ));
    const timeout = setTimeout(() => finish(new Error(
      "Timed out querying process identity through the global publication mutex holder.",
    )), timeoutMs);
    holder.child.stdout.on("data", onData);
    holder.child.once("exit", onExit);
    holder.child.once("error", onError);
    try {
      holder.child.stdin.write(`${command}\r\n`, "utf8", (error) => {
        if (error) {
          finish(new Error("Could not query process identity through the global publication mutex holder.", {
            cause: error,
          }));
        }
      });
    } catch (error) {
      finish(new Error("Could not query process identity through the global publication mutex holder.", {
        cause: error,
      }));
    }
  });
}

async function processStartTokenForPid(holder, pid) {
  if (process.platform !== "win32") {
    return processIsAlive(pid) ? `pid:${pid}` : null;
  }
  const response = await requestMutexHolder(holder, `QUERY:${pid}`);
  if (response === `MISSING:${pid}`) return null;
  const expectedPrefix = `PROCESS:${pid}:`;
  if (response.startsWith(expectedPrefix)) {
    const fileTime = response.slice(expectedPrefix.length);
    if (/^[1-9][0-9]{0,18}$/u.test(fileTime)) {
      return `win32-filetime:${fileTime}`;
    }
  }
  if (response === `QUERY_ERROR:${pid}`) {
    throw new Error(`Could not verify the start identity of running process ${pid}.`);
  }
  throw new Error(`Unexpected process identity response from the mutex holder: ${response}`);
}

async function acquireOsPublicationMutex() {
  if (process.platform !== "win32") {
    return {
      child: null,
      alive: true,
      stderr: "",
      processStartToken: `pid:${process.pid}`,
    };
  }
  const systemRoot = process.env.SystemRoot;
  if (!systemRoot || !path.isAbsolute(systemRoot)) {
    throw new Error("SystemRoot must identify the absolute Windows installation directory.");
  }
  const powershellPath = path.join(
    path.resolve(systemRoot),
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  );
  await assertNoReparseAncestors(powershellPath, "Windows PowerShell mutex holder");
  const powershellEntry = await lstatIfPresent(powershellPath);
  if (!powershellEntry?.isFile()) {
    throw new Error("The system Windows PowerShell mutex holder is not a regular file.");
  }
  const rootIdentity = await stat(root, { bigint: true });
  if (typeof rootIdentity.dev !== "bigint"
      || typeof rootIdentity.ino !== "bigint"
      || rootIdentity.dev <= 0n
      || rootIdentity.ino <= 0n) {
    throw new Error("The project root has no valid physical filesystem identity for mutex scoping.");
  }
  const identityHash = createHash("sha256")
    .update(`${rootIdentity.dev.toString(16)}:${rootIdentity.ino.toString(16)}`)
    .digest("hex")
    .slice(0, 32);
  const script = mutexHolderScript(
    `Global\\MQL5-CHM-MCP-build-${identityHash}`,
    process.pid,
  );
  const encoded = Buffer.from(script, "utf16le").toString("base64");
  const child = spawn(powershellPath, [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-EncodedCommand",
    encoded,
  ], {
    cwd: root,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  const holder = { child, alive: true, stderr: "" };
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    holder.stderr += chunk;
  });
  const onHolderError = (error) => {
    holder.processError = error;
  };
  child.on("error", onHolderError);
  child.once("exit", () => {
    holder.alive = false;
    child.removeListener("error", onHolderError);
  });

  try {
    await new Promise((resolvePromise, rejectPromise) => {
      let stdout = "";
      let settled = false;
      const finish = (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        child.stdout.removeListener("data", onData);
        child.removeListener("error", onError);
        child.removeListener("exit", onExit);
        if (error) rejectPromise(error);
        else resolvePromise();
      };
      const onError = (error) => finish(
        new Error("Could not start the global publication mutex holder.", { cause: error }),
      );
      const onData = (chunk) => {
        if (settled) return;
        stdout += chunk;
        const newline = stdout.indexOf("\n");
        if (newline < 0) return;
        const status = stdout.slice(0, newline).trim();
        const readyMatch = /^READY:([1-9][0-9]{0,18})$/u.exec(status);
        if (readyMatch) {
          holder.processStartToken = `win32-filetime:${readyMatch[1]}`;
          finish(null);
          return;
        }
        finish(new Error(
          status === "BUSY"
            ? "Another live process owns the global publication mutex."
            : `Unexpected global publication mutex response: ${status}`,
        ));
      };
      const onExit = (code) => finish(
        new Error(
          `Global publication mutex holder exited before acquisition (code ${code}). ${holder.stderr}`.trim(),
        ),
      );
      const timeout = setTimeout(() => finish(
        new Error("Timed out acquiring the global publication mutex."),
      ), 10_000);
      child.once("error", onError);
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", onData);
      child.once("exit", onExit);
    });
  } catch (error) {
    await throwAfterMutexHolderTermination(holder, error);
  }
  return holder;
}

async function releaseOsPublicationMutex(holder) {
  if (!holder.child) {
    holder.alive = false;
    return;
  }
  const releaseTimeoutMs = process.env.MQL5_CHM_BUILD_TEST_MUTEX_HANG_ON_RELEASE === "1"
    ? 500
    : 10_000;
  try {
    if (!holder.alive) {
      throw new Error(`Global publication mutex holder exited unexpectedly. ${holder.stderr}`.trim());
    }
    holder.child.stdin.end();
    if (!(await waitForMutexHolderExit(holder, releaseTimeoutMs))) {
      throw new Error("Timed out releasing the global publication mutex.");
    }
    if (holder.child.exitCode !== 0) {
      throw new Error(
        `Global publication mutex holder failed during release (code ${holder.child.exitCode}). ${holder.stderr}`
          .trim(),
      );
    }
  } catch (error) {
    await throwAfterMutexHolderTermination(holder, error);
  }
}

async function assertOwnGlobalClaim(claim) {
  if (!claim.mutex.alive) {
    throw new Error("Global publication mutex ownership was lost.");
  }
  const owner = await readClaimOwner(globalClaimPath, "Global publication claim");
  if (!owner
      || owner.pid !== process.pid
      || owner.processStartToken !== claim.processStartToken
      || owner.transaction !== claim.transaction) {
    throw new Error("Global publication claim ownership changed unexpectedly.");
  }
}

async function cleanupClaimResidue() {
  const children = await readdir(buildRoot, { withFileTypes: true });
  for (const child of children) {
    if (!/^\.bundle-publish-claim\.(?:candidate|quarantine|released)-[a-f0-9-]+$/iu
      .test(child.name)) {
      continue;
    }
    const residuePath = path.join(buildRoot, child.name);
    if (!child.isDirectory()) {
      throw new Error(`Publication claim residue is not a directory: ${child.name}`);
    }
    await assertNoReparseAncestors(residuePath, `Publication claim residue ${child.name}`);
    await assertNoReparseTree(residuePath, `Publication claim residue ${child.name}`);
    await rm(residuePath, { recursive: true, force: true });
  }
}

async function writePrivateClaimOwner(candidatePath, owner) {
  const temporaryPath = path.join(candidatePath, `.owner-${randomUUID()}.json`);
  const ownerPath = path.join(candidatePath, "owner.json");
  try {
    await writeDurableNewFile(
      temporaryPath,
      owner,
      "Private global publication claim owner",
    );
    injectHardExitAtClaimWrite("owner-temp-synced");
    if (await lstatIfPresent(ownerPath)) {
      throw new Error("Private global publication claim owner already exists.");
    }
    await rename(temporaryPath, ownerPath);
    injectHardExitAtClaimWrite("owner-published");
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

async function acquireGlobalPublicationClaim() {
  const mutex = await acquireOsPublicationMutex();
  try {
    await assertNoReparseAncestors(globalClaimPath, "global publication claim");
    for (;;) {
      const existingOwner = await readClaimOwner(globalClaimPath, "Global publication claim");
      if (existingOwner) {
        const observedStartToken = await processStartTokenForPid(mutex, existingOwner.pid);
        if (observedStartToken === existingOwner.processStartToken) {
          throw new Error(
            `Global publication claim is still owned by its original running process ${existingOwner.pid}.`,
          );
        }
        const quarantinePath = path.join(
          buildRoot,
          `.bundle-publish-claim.quarantine-${existingOwner.transaction}-${randomUUID()}`,
        );
        if (await lstatIfPresent(quarantinePath)) {
          throw new Error(`Stale publication claim quarantine already exists: ${quarantinePath}`);
        }
        await rename(globalClaimPath, quarantinePath);
        const quarantinedOwner = await readClaimOwner(
          quarantinePath,
          "Quarantined global publication claim",
        );
        if (quarantinedOwner.transaction !== existingOwner.transaction
            || quarantinedOwner.pid !== existingOwner.pid
            || quarantinedOwner.processStartToken !== existingOwner.processStartToken) {
          throw new Error("Quarantined publication claim generation did not match the stale owner.");
        }
        continue;
      }

      const transaction = randomUUID();
      const candidatePath = path.join(
        buildRoot,
        `.bundle-publish-claim.candidate-${transaction}`,
      );
      await mkdir(candidatePath);
      const owner = {
        version: claimVersion,
        transaction,
        pid: process.pid,
        processStartToken: mutex.processStartToken,
      };
      try {
        await writePrivateClaimOwner(candidatePath, owner);
        if (await lstatIfPresent(globalClaimPath)) continue;
        try {
          await rename(candidatePath, globalClaimPath);
        } catch (error) {
          if (await lstatIfPresent(globalClaimPath)) continue;
          throw error;
        }
      } finally {
        if (await lstatIfPresent(candidatePath)) {
          await rm(candidatePath, { recursive: true, force: true });
        }
      }
      const claim = {
        path: globalClaimPath,
        transaction,
        processStartToken: mutex.processStartToken,
        mutex,
      };
      await assertOwnGlobalClaim(claim);
      await cleanupClaimResidue();
      return claim;
    }
  } catch (error) {
    try {
      await releaseOsPublicationMutex(mutex);
    } catch (releaseError) {
      throw new AggregateError(
        [error, releaseError],
        "Global publication claim acquisition and mutex release both failed.",
      );
    }
    throw error;
  }
}

async function releaseGlobalPublicationClaim(claim) {
  let releaseError = null;
  try {
    await assertOwnGlobalClaim(claim);
    const releasedPath = path.join(
      buildRoot,
      `.bundle-publish-claim.released-${claim.transaction}`,
    );
    if (await lstatIfPresent(releasedPath)) {
      throw new Error(`Publication claim release path already exists: ${releasedPath}`);
    }
    await rename(globalClaimPath, releasedPath);
    await rm(releasedPath, { recursive: true, force: true });
  } catch (error) {
    releaseError = error;
  }
  try {
    await releaseOsPublicationMutex(claim.mutex);
  } catch (error) {
    if (releaseError) {
      throw new AggregateError([releaseError, error], "Global publication claim release failed.");
    }
    throw error;
  }
  if (releaseError) throw releaseError;
}

async function writeDurableAtomicOwned(
  target,
  payload,
  label,
  claim,
  { beforeRename, afterRename, appDir, metaPath },
) {
  await assertOwnGlobalClaim(claim);
  await assertNoReparseAncestors(target, label);
  if (await lstatIfPresent(target)) {
    throw new Error(`${label} already exists; recovery must complete before publication.`);
  }
  const temporaryPath = path.join(claim.path, `.atomic-write-${randomUUID()}.json`);
  try {
    await writeDurableNewFile(temporaryPath, payload, `${label} private temporary file`);
    injectHardExitAtAtomicWrite(beforeRename, appDir, metaPath);
    if (await lstatIfPresent(target)) {
      throw new Error(`${label} appeared before its atomic publication.`);
    }
    await rename(temporaryPath, target);
    injectHardExitAtAtomicWrite(afterRename, appDir, metaPath);
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

function journalPaths(key) {
  return {
    journalPath: path.join(transactionRoot, `${key}.json`),
    commitPath: path.join(transactionRoot, `${key}.commit.json`),
  };
}

function resolveJournalRecord(rawRecord, journalName) {
  assertExactKeys(rawRecord, [
    "appPath",
    "candidateApp",
    "candidateMeta",
    "candidateRoot",
    "metaPath",
    "originalApp",
    "originalMeta",
    "pid",
    "transaction",
    "version",
  ], `Publication journal ${journalName}`);
  if (rawRecord.version !== journalVersion) {
    throw new Error(`Publication journal ${journalName} has an unsupported version.`);
  }
  if (typeof rawRecord.transaction !== "string"
      || !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/iu
        .test(rawRecord.transaction)) {
    throw new Error(`Publication journal ${journalName} has an invalid transaction identifier.`);
  }
  if (!Number.isSafeInteger(rawRecord.pid) || rawRecord.pid <= 0) {
    throw new Error(`Publication journal ${journalName} has an invalid process identifier.`);
  }
  if (typeof rawRecord.appPath !== "string"
      || typeof rawRecord.metaPath !== "string"
      || typeof rawRecord.candidateRoot !== "string") {
    throw new Error(`Publication journal ${journalName} contains a non-string path.`);
  }

  const appDir = resolveConfined(rawRecord.appPath, "journal app path");
  const metaPath = resolveConfined(rawRecord.metaPath, "journal metadata path");
  const candidateRoot = resolveConfined(rawRecord.candidateRoot, "journal candidate root");
  assertBuildPathPolicy(appDir, metaPath);
  if (!isSamePath(path.dirname(candidateRoot), globalClaimPath)
      || !/^\.bundle-build-[A-Za-z0-9]+$/u.test(path.basename(candidateRoot))) {
    throw new Error(`Publication journal ${journalName} has an invalid candidate root.`);
  }

  const key = publicationKey(appDir, metaPath);
  if (journalName !== `${key}.json`) {
    throw new Error(`Publication journal ${journalName} does not own its declared output paths.`);
  }
  if (rawRecord.originalApp !== null) {
    validateDirectoryManifest(rawRecord.originalApp, `${journalName}.originalApp`);
  }
  if (rawRecord.originalMeta !== null) {
    validateFileManifest(rawRecord.originalMeta, `${journalName}.originalMeta`);
  }
  validateDirectoryManifest(rawRecord.candidateApp, `${journalName}.candidateApp`, true);
  validateFileManifest(rawRecord.candidateMeta, `${journalName}.candidateMeta`);

  return {
    ...rawRecord,
    appDir,
    metaRelativePath: rawRecord.metaPath,
    metaPath,
    candidateRootPath: rawRecord.candidateRoot,
    candidateRoot,
    key,
    ...journalPaths(key),
  };
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code !== "ESRCH";
  }
}

async function validateCandidateRoot(record) {
  const entry = await lstatIfPresent(record.candidateRoot);
  if (!entry) return;
  if (!entry.isDirectory()) throw new Error("Recorded candidate root is not a directory.");
  const children = await readdir(record.candidateRoot, { withFileTypes: true });
  for (const child of children) {
    if (child.name === "app" && child.isDirectory()) {
      const manifest = await directoryManifest(path.join(record.candidateRoot, "app"), "candidate app residue");
      if (!directoryManifestIsOwnedSubset(manifest, record.candidateApp)) {
        throw new Error("Candidate app residue no longer matches the transaction ownership record.");
      }
      continue;
    }
    if (child.name === "esbuild-meta.json" && child.isFile()) {
      const manifest = await fileManifest(
        path.join(record.candidateRoot, "esbuild-meta.json"),
        "candidate metadata residue",
      );
      if (!sameFileManifest(manifest, record.candidateMeta)) {
        throw new Error("Candidate metadata residue no longer matches the transaction ownership record.");
      }
      continue;
    }
    throw new Error(`Recorded candidate root contains an unowned entry: ${child.name}`);
  }
}

async function validateCandidate(appDir, metaPath) {
  const children = await readdir(appDir, { withFileTypes: true });
  const names = new Set(children.map((entry) => entry.name));
  if (children.length !== expectedBundleNames.size
      || children.some((entry) => !entry.isFile() || !expectedBundleNames.has(entry.name))) {
    throw new Error("Candidate bundle output does not contain exactly server.mjs and indexer.mjs.");
  }
  for (const name of expectedBundleNames) {
    if (!names.has(name) || (await stat(path.join(appDir, name))).size === 0) {
      throw new Error(`Candidate bundle is missing or empty: ${name}`);
    }
  }
  JSON.parse(await readFile(metaPath, "utf8"));
}

async function inspectRecoveryState(record) {
  const { appBackup, metaBackup } = backupPaths(record);
  return {
    appTarget: await directoryManifest(record.appDir, "recorded app output"),
    appBackup: await directoryManifest(appBackup, "recorded app backup"),
    metaTarget: await fileManifest(record.metaPath, "recorded metadata output"),
    metaBackup: await fileManifest(metaBackup, "recorded metadata backup"),
    appBackupPath: appBackup,
    metaBackupPath: metaBackup,
  };
}

function assertRollbackDirectoryState(target, backup, original, candidate) {
  if (original) {
    if (!backup) {
      if (!sameDirectoryManifest(target, original)) {
        throw new Error("App output changed after publication was interrupted; recovery stopped.");
      }
      return;
    }
    if (!sameDirectoryManifest(backup, original)) {
      throw new Error("App backup does not match the publication ownership record.");
    }
    if (target
        && !directoryManifestIsOwnedSubset(target, candidate)
        && !directoryManifestIsOwnedSubset(target, original)) {
      throw new Error("App output contains data not owned by the interrupted publication.");
    }
    return;
  }
  if (backup) throw new Error("An unexpected app backup exists for a previously absent output.");
  if (target && !directoryManifestIsOwnedSubset(target, candidate)) {
    throw new Error("App output contains data not owned by the interrupted publication.");
  }
}

function assertRollbackFileState(target, backup, original, candidate) {
  if (original) {
    if (!backup) {
      if (!sameFileManifest(target, original)) {
        throw new Error("Metadata output changed after publication was interrupted; recovery stopped.");
      }
      return;
    }
    if (!sameFileManifest(backup, original)) {
      throw new Error("Metadata backup does not match the publication ownership record.");
    }
    if (target && !sameFileManifest(target, candidate) && !sameFileManifest(target, original)) {
      throw new Error("Metadata output contains data not owned by the interrupted publication.");
    }
    return;
  }
  if (backup) throw new Error("An unexpected metadata backup exists for a previously absent output.");
  if (target && !sameFileManifest(target, candidate)) {
    throw new Error("Metadata output contains data not owned by the interrupted publication.");
  }
}

async function rollbackPublication(record) {
  const state = await inspectRecoveryState(record);
  await validateCandidateRoot(record);
  assertRollbackDirectoryState(
    state.appTarget,
    state.appBackup,
    record.originalApp,
    record.candidateApp,
  );
  assertRollbackFileState(
    state.metaTarget,
    state.metaBackup,
    record.originalMeta,
    record.candidateMeta,
  );

  if (record.originalApp) {
    if (state.appBackup) {
      if (state.appTarget) await rm(record.appDir, { recursive: true, force: true });
      await rename(state.appBackupPath, record.appDir);
    }
  } else if (state.appTarget) {
    await rm(record.appDir, { recursive: true, force: true });
  }

  if (record.originalMeta) {
    if (state.metaBackup) {
      if (state.metaTarget) await rm(record.metaPath, { force: true });
      await rename(state.metaBackupPath, record.metaPath);
    }
  } else if (state.metaTarget) {
    await rm(record.metaPath, { force: true });
  }

  const restoredApp = await directoryManifest(record.appDir, "restored app output");
  const restoredMeta = await fileManifest(record.metaPath, "restored metadata output");
  if (record.originalApp
    ? !sameDirectoryManifest(restoredApp, record.originalApp)
    : restoredApp !== null) {
    throw new Error("App output could not be restored to its pre-publication state.");
  }
  if (record.originalMeta
    ? !sameFileManifest(restoredMeta, record.originalMeta)
    : restoredMeta !== null) {
    throw new Error("Metadata output could not be restored to its pre-publication state.");
  }

  await rm(record.candidateRoot, { recursive: true, force: true });
  await rm(record.journalPath, { force: true });
}

async function assertPublishedCandidate(record) {
  if (!sameDirectoryManifest(
    await directoryManifest(record.appDir, "published app output"),
    record.candidateApp,
  ) || !sameFileManifest(
    await fileManifest(record.metaPath, "published metadata output"),
    record.candidateMeta,
  )) {
    throw new Error("Published outputs no longer match the complete candidate ownership record.");
  }
  await validateCandidate(record.appDir, record.metaPath);
}

async function finalizeCommittedPublication(record) {
  const state = await inspectRecoveryState(record);
  await validateCandidateRoot(record);
  await assertPublishedCandidate(record);
  if (record.originalApp) {
    if (state.appBackup
        && !directoryManifestIsOwnedSubset(state.appBackup, record.originalApp)) {
      throw new Error("Committed app backup contains data not owned by the transaction.");
    }
  } else if (state.appBackup) {
    throw new Error("Committed publication has an unexpected app backup.");
  }
  if (record.originalMeta) {
    if (state.metaBackup && !sameFileManifest(state.metaBackup, record.originalMeta)) {
      throw new Error("Committed metadata backup contains data not owned by the transaction.");
    }
  } else if (state.metaBackup) {
    throw new Error("Committed publication has an unexpected metadata backup.");
  }

  await rm(state.appBackupPath, { recursive: true, force: true });
  await rm(state.metaBackupPath, { force: true });
  await rm(record.candidateRoot, { recursive: true, force: true });
  await assertPublishedCandidate(record);
  await rm(record.journalPath, { force: true });
  await rm(record.commitPath, { force: true });
}

function validateCommitMarker(marker, record) {
  assertExactKeys(marker, ["key", "transaction", "version"], "Publication commit marker");
  if (marker.version !== journalVersion
      || marker.key !== record.key
      || marker.transaction !== record.transaction) {
    throw new Error("Publication commit marker does not match its ownership journal.");
  }
}

async function recoverPublication(record) {
  const { appBackup, metaBackup } = backupPaths(record);
  for (const [target, label] of [
    [record.appDir, "recorded app output"],
    [record.metaPath, "recorded metadata output"],
    [record.candidateRoot, "recorded candidate root"],
    [appBackup, "recorded app backup"],
    [metaBackup, "recorded metadata backup"],
    [record.journalPath, "recorded publication journal"],
    [record.commitPath, "recorded publication commit marker"],
  ]) {
    await assertNoReparseAncestors(target, label);
  }
  const marker = await readOwnedJson(record.commitPath, "Publication commit marker");
  if (marker) {
    validateCommitMarker(marker, record);
    await finalizeCommittedPublication(record);
    return;
  }
  await rollbackPublication(record);
}

async function recoverInterruptedPublications() {
  await assertNoReparseAncestors(transactionRoot, "publication transaction store");
  await mkdir(transactionRoot, { recursive: true });
  await assertNoReparseAncestors(transactionRoot, "publication transaction store");
  const storeEntry = await lstat(transactionRoot);
  if (!storeEntry.isDirectory()) {
    throw new Error("Publication transaction store must be a directory.");
  }

  const children = await readdir(transactionRoot, { withFileTypes: true });
  for (const child of children) {
    if (!child.isFile()
        || (!/^[a-f0-9]{64}\.json$/u.test(child.name)
          && !/^[a-f0-9]{64}\.commit\.json$/u.test(child.name))) {
      throw new Error(`Publication transaction store contains an unowned entry: ${child.name}`);
    }
  }

  const journalNames = children
    .map((child) => child.name)
    .filter((name) => /^[a-f0-9]{64}\.json$/u.test(name))
    .sort();
  for (const journalName of journalNames) {
    const journalPath = path.join(transactionRoot, journalName);
    const rawRecord = await readOwnedJson(journalPath, `Publication journal ${journalName}`);
    const record = resolveJournalRecord(rawRecord, journalName);
    await recoverPublication(record);
  }

  const remaining = await readdir(transactionRoot, { withFileTypes: true });
  for (const child of remaining) {
    if (!/^[a-f0-9]{64}\.commit\.json$/u.test(child.name)) continue;
    const markerPath = path.join(transactionRoot, child.name);
    const marker = await readOwnedJson(markerPath, `Orphan publication commit marker ${child.name}`);
    assertExactKeys(marker, ["key", "transaction", "version"], "Orphan publication commit marker");
    if (marker.version !== journalVersion
        || `${marker.key}.commit.json` !== child.name
        || typeof marker.transaction !== "string") {
      throw new Error(`Orphan publication commit marker ${child.name} is invalid.`);
    }
    await rm(markerPath, { force: true });
  }
}

function injectHardExitAfterRename(cutPoint, appDir, metaPath) {
  const requestedCutPoint = process.env.MQL5_CHM_BUILD_TEST_EXIT_AFTER_RENAME;
  if (!requestedCutPoint || requestedCutPoint !== cutPoint) return;
  const regressionRoot = path.join(buildRoot, "build-script-regression");
  if (process.env.MQL5_CHM_BUILD_TEST_MODE !== "1"
      || !isStrictDescendant(regressionRoot, appDir)
      || !isStrictDescendant(regressionRoot, metaPath)) {
    throw new Error("Build fault injection is confined to the build-script regression directory.");
  }
  process.exit(injectedExitCode);
}

function injectHardExitAtAtomicWrite(cutPoint, appDir, metaPath) {
  const requestedCutPoint = process.env.MQL5_CHM_BUILD_TEST_EXIT_AT_ATOMIC_WRITE;
  if (!requestedCutPoint || requestedCutPoint !== cutPoint) return;
  const regressionRoot = path.join(buildRoot, "build-script-regression");
  if (process.env.MQL5_CHM_BUILD_TEST_MODE !== "1"
      || !isStrictDescendant(regressionRoot, appDir)
      || !isStrictDescendant(regressionRoot, metaPath)) {
    throw new Error("Build fault injection is confined to the build-script regression directory.");
  }
  process.exit(injectedExitCode);
}

function injectHardExitAtClaimWrite(cutPoint) {
  const requestedCutPoint = process.env.MQL5_CHM_BUILD_TEST_EXIT_AT_CLAIM_WRITE;
  if (!requestedCutPoint || requestedCutPoint !== cutPoint) return;
  if (process.env.MQL5_CHM_BUILD_TEST_MODE !== "1") {
    throw new Error("Build claim fault injection is available only in regression tests.");
  }
  process.exit(injectedExitCode);
}

async function holdGlobalClaimForTest() {
  const rawDelay = process.env.MQL5_CHM_BUILD_TEST_HOLD_CLAIM_MS;
  if (!rawDelay) return;
  const delay = Number(rawDelay);
  if (process.env.MQL5_CHM_BUILD_TEST_MODE !== "1"
      || !Number.isSafeInteger(delay)
      || delay < 1
      || delay > 10_000) {
    throw new Error("Build claim hold injection requires a test delay from 1 to 10000 ms.");
  }
  await new Promise((resolvePromise) => {
    setTimeout(resolvePromise, delay);
  });
}

async function createPublicationRecord({ candidateRoot, candidateApp, candidateMeta, appDir, metaPath }) {
  const transaction = randomUUID();
  const key = publicationKey(appDir, metaPath);
  const record = {
    version: journalVersion,
    transaction,
    pid: process.pid,
    appPath: projectRelative(appDir),
    metaPath: projectRelative(metaPath),
    candidateRoot: projectRelative(candidateRoot),
    originalApp: await directoryManifest(appDir, "existing app output"),
    originalMeta: await fileManifest(metaPath, "existing metadata output"),
    candidateApp: await directoryManifest(candidateApp, "candidate app output"),
    candidateMeta: await fileManifest(candidateMeta, "candidate metadata output"),
  };
  validateDirectoryManifest(record.candidateApp, "candidate app ownership record", true);
  validateFileManifest(record.candidateMeta, "candidate metadata ownership record");
  return resolveJournalRecord(record, `${key}.json`);
}

async function publishCandidate({
  candidateRoot,
  candidateApp,
  candidateMeta,
  appDir,
  metaPath,
  onJournalCreated,
  claim,
}) {
  await mkdir(path.dirname(appDir), { recursive: true });
  await mkdir(path.dirname(metaPath), { recursive: true });
  await assertNoReparseAncestors(appDir, "--outdir");
  await assertNoReparseAncestors(metaPath, "--metafile");
  await validateExistingBundleDirectory(appDir);

  const record = await createPublicationRecord({
    candidateRoot,
    candidateApp,
    candidateMeta,
    appDir,
    metaPath,
  });
  const { appBackup, metaBackup } = backupPaths(record);
  if (await lstatIfPresent(appBackup)) {
    throw new Error(`Refusing to replace an existing app backup: ${appBackup}`);
  }
  if (await lstatIfPresent(metaBackup)) {
    throw new Error(`Refusing to replace an existing metadata backup: ${metaBackup}`);
  }
  const appEntry = await lstatIfPresent(appDir);
  const metaEntry = await lstatIfPresent(metaPath);
  await writeDurableAtomicOwned(record.journalPath, {
    version: record.version,
    transaction: record.transaction,
    pid: record.pid,
    appPath: record.appPath,
    metaPath: record.metaRelativePath,
    candidateRoot: record.candidateRootPath,
    originalApp: record.originalApp,
    originalMeta: record.originalMeta,
    candidateApp: record.candidateApp,
    candidateMeta: record.candidateMeta,
  }, "Publication journal", claim, {
    beforeRename: "journal-temp-synced",
    afterRename: "journal-published",
    appDir,
    metaPath,
  });
  onJournalCreated();

  try {
    if (metaEntry) {
      await rename(metaPath, metaBackup);
      injectHardExitAfterRename("metadata-backed-up", appDir, metaPath);
      if (!sameFileManifest(
        await fileManifest(metaBackup, "new metadata backup"),
        record.originalMeta,
      )) {
        throw new Error("Metadata changed before it could be backed up safely.");
      }
    }
    if (appEntry) {
      await rename(appDir, appBackup);
      injectHardExitAfterRename("app-backed-up", appDir, metaPath);
      if (!sameDirectoryManifest(
        await directoryManifest(appBackup, "new app backup"),
        record.originalApp,
      )) {
        throw new Error("App output changed before it could be backed up safely.");
      }
    }
    await rename(candidateApp, appDir);
    injectHardExitAfterRename("app-installed", appDir, metaPath);
    await rename(candidateMeta, metaPath);
    injectHardExitAfterRename("metadata-installed", appDir, metaPath);
    await validateCandidate(appDir, metaPath);
    if (!sameDirectoryManifest(
      await directoryManifest(appDir, "published app output"),
      record.candidateApp,
    ) || !sameFileManifest(
      await fileManifest(metaPath, "published metadata output"),
      record.candidateMeta,
    )) {
      throw new Error("Published outputs do not match the validated candidate ownership record.");
    }
    await writeDurableAtomicOwned(record.commitPath, {
      version: journalVersion,
      key: record.key,
      transaction: record.transaction,
    }, "Publication commit marker", claim, {
      beforeRename: "commit-temp-synced",
      afterRename: "commit-published",
      appDir,
      metaPath,
    });
  } catch (error) {
    try {
      await rollbackPublication(record);
    } catch (recoveryError) {
      throw new AggregateError(
        [error, recoveryError],
        `Bundle publication failed and automatic recovery was incomplete. Preserved backups: ${appBackup}; ${metaBackup}`,
      );
    }
    throw error;
  }

  try {
    await finalizeCommittedPublication(record);
  } catch (error) {
    try {
      await assertPublishedCandidate(record);
    } catch (validationError) {
      throw new AggregateError(
        [error, validationError],
        "Bundle publication cleanup failed and the published outputs could not be revalidated.",
      );
    }
    process.stderr.write(
      `Warning: published bundles but deferred transaction cleanup to the next build: ${error.message}\n`,
    );
  }
}

const arguments_ = parseArguments(process.argv.slice(2));
await assertNoReparseAncestors(buildRoot, "build root");
await mkdir(buildRoot, { recursive: true });
const globalClaim = await acquireGlobalPublicationClaim();
try {
  await holdGlobalClaimForTest();
  await recoverInterruptedPublications();
  const plan = await validateBuildPlan(arguments_.outdir, arguments_.metafile);
  const candidateRoot = await mkdtemp(path.join(globalClaim.path, ".bundle-build-"));
  const candidateApp = path.join(candidateRoot, "app");
  const candidateMeta = path.join(candidateRoot, "esbuild-meta.json");
  let ownsPublicationJournal = false;

  try {
    await mkdir(candidateApp, { recursive: true });
    const result = await build({
      entryPoints: {
        server: path.join(root, "src", "server.mjs"),
        indexer: path.join(root, "src", "indexer.mjs"),
      },
      outdir: candidateApp,
      entryNames: "[name]",
      outExtension: { ".js": ".mjs" },
      bundle: true,
      platform: "node",
      format: "esm",
      target: "node24.17",
      treeShaking: true,
      minify: false,
      sourcemap: false,
      banner: {
        js: 'import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);',
      },
      legalComments: "external",
      metafile: true,
      logLevel: "info",
    });
    await writeFile(candidateMeta, `${JSON.stringify(result.metafile, null, 2)}\n`, "utf8");
    await validateCandidate(candidateApp, candidateMeta);
    await publishCandidate({
      candidateRoot,
      candidateApp,
      candidateMeta,
      ...plan,
      claim: globalClaim,
      onJournalCreated() {
        ownsPublicationJournal = true;
      },
    });
  } finally {
    const transactionKey = publicationKey(plan.appDir, plan.metaPath);
    const { journalPath } = journalPaths(transactionKey);
    if (!ownsPublicationJournal || !(await lstatIfPresent(journalPath))) {
      await rm(candidateRoot, { recursive: true, force: true });
    }
  }
} finally {
  await releaseGlobalPublicationClaim(globalClaim);
}
