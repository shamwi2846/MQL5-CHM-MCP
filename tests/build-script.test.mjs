import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const buildScript = path.join(projectRoot, "scripts", "build.mjs");
const testRoot = path.join(projectRoot, "build", "build-script-regression");
const transactionRoot = path.join(projectRoot, "build", ".bundle-publish-transactions");
const globalClaimPath = path.join(projectRoot, "build", ".bundle-publish-claim");

function runBuild(...arguments_) {
  return spawnSync(process.execPath, [buildScript, ...arguments_], {
    cwd: projectRoot,
    encoding: "utf8",
    windowsHide: true,
  });
}

function runBuildWithEnvironment(environment, ...arguments_) {
  return spawnSync(process.execPath, [buildScript, ...arguments_], {
    cwd: projectRoot,
    encoding: "utf8",
    windowsHide: true,
    env: { ...process.env, ...environment },
  });
}

function spawnBuildWithEnvironment(environment, ...arguments_) {
  return spawn(process.execPath, [buildScript, ...arguments_], {
    cwd: projectRoot,
    windowsHide: true,
    env: { ...process.env, ...environment },
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function windowsProcessStartToken(pid) {
  const systemRoot = process.env.SystemRoot;
  assert.ok(systemRoot && path.isAbsolute(systemRoot), "SystemRoot must be an absolute path");
  const powershellPath = path.join(
    path.resolve(systemRoot),
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  );
  assert.equal(existsSync(powershellPath), true, "trusted System32 Windows PowerShell must exist");
  const script = [
    "$ErrorActionPreference = 'Stop'",
    `$target = [System.Diagnostics.Process]::GetProcessById(${pid})`,
    "try {",
    "  [Console]::Out.Write($target.StartTime.ToFileTimeUtc().ToString([System.Globalization.CultureInfo]::InvariantCulture))",
    "}",
    "finally { $target.Dispose() }",
  ].join("\r\n");
  const result = spawnSync(powershellPath, [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-EncodedCommand",
    Buffer.from(script, "utf16le").toString("base64"),
  ], {
    cwd: projectRoot,
    encoding: "utf8",
    timeout: 5_000,
    windowsHide: true,
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.signal, null, result.stderr);
  assert.equal(result.status, 0, result.stderr);
  const fileTime = result.stdout.trim();
  assert.match(fileTime, /^[1-9][0-9]{0,18}$/u);
  return `win32-filetime:${fileTime}`;
}

function removeGenerated(target) {
  rmSync(target, { recursive: true, force: true });
}

function expectedJournalPath(output, metadata) {
  const canonicalRelative = (target) => {
    const relative = path.relative(projectRoot, target).split(path.sep).join("/");
    return process.platform === "win32" ? relative.toLowerCase() : relative;
  };
  const key = createHash("sha256")
    .update(`${canonicalRelative(output)}\0${canonicalRelative(metadata)}`)
    .digest("hex");
  return path.join(transactionRoot, `${key}.json`);
}

function findJournalForOutput(output) {
  if (!existsSync(transactionRoot)) return null;
  const normalizedOutput = path.resolve(output).toLowerCase();
  for (const name of readdirSync(transactionRoot)) {
    if (!/^[a-f0-9]{64}\.json$/u.test(name)) continue;
    const journalPath = path.join(transactionRoot, name);
    const record = JSON.parse(readFileSync(journalPath, "utf8"));
    if (path.resolve(projectRoot, record.appPath).toLowerCase() === normalizedOutput) {
      return {
        journalPath,
        commitPath: journalPath.replace(/\.json$/u, ".commit.json"),
        candidateRoot: path.resolve(projectRoot, record.candidateRoot),
        appBackup: path.join(
          path.dirname(output),
          `.${path.basename(output)}.backup-${record.transaction}`,
        ),
        metaBackup: path.join(
          path.dirname(path.resolve(projectRoot, record.metaPath)),
          `.${path.basename(record.metaPath)}.backup-${record.transaction}`,
        ),
      };
    }
  }
  return null;
}

function assertTransactionResidueRemoved(transaction) {
  assert.equal(existsSync(transaction.journalPath), false, "publication journal must be removed");
  assert.equal(existsSync(transaction.commitPath), false, "publication commit marker must be removed");
  assert.equal(existsSync(transaction.candidateRoot), false, "candidate residue must be removed");
  assert.equal(existsSync(transaction.appBackup), false, "app backup must be removed");
  assert.equal(existsSync(transaction.metaBackup), false, "metadata backup must be removed");
}

function removeTransactionResidue(transaction) {
  if (!transaction) return;
  removeGenerated(transaction.candidateRoot);
  removeGenerated(transaction.appBackup);
  removeGenerated(transaction.metaBackup);
  removeGenerated(transaction.commitPath);
  removeGenerated(transaction.journalPath);
}

async function waitForClaimOwner(pid, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const owner = JSON.parse(readFileSync(path.join(globalClaimPath, "owner.json"), "utf8"));
      if (owner.pid === pid) return owner;
    } catch {
      // The owner directory is published atomically; retry while its process starts.
    }
    await delay(25);
  }
  throw new Error(`Timed out waiting for global publication claim owned by process ${pid}.`);
}

function assertNoGlobalClaimResidue() {
  const residues = readdirSync(path.join(projectRoot, "build"))
    .filter((name) => name.startsWith(".bundle-publish-claim"));
  assert.deepEqual(residues, [], `global publication claim residue remains: ${residues.join(", ")}`);
}

test("build rejects protected data output before creating files", () => {
  const output = path.join(projectRoot, "data", "build-script-regression-output");
  const metadata = path.join(testRoot, "protected-output-meta.json");
  removeGenerated(output);
  removeGenerated(testRoot);
  try {
    const result = runBuild(
      "--outdir", "data/build-script-regression-output",
      "--metafile", "build/build-script-regression/protected-output-meta.json",
    );
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.equal(existsSync(output), false, "a rejected protected output must remain untouched");
    assert.equal(existsSync(metadata), false, "rejection must happen before metadata is written");
  } finally {
    removeGenerated(output);
    removeGenerated(testRoot);
  }
});

test("build reserves its internal publication state", () => {
  const metadataInsideStore = path.join(transactionRoot, "caller-meta.json");
  removeGenerated(testRoot);
  removeGenerated(metadataInsideStore);
  try {
    const outputResult = runBuild(
      "--outdir", "build/.bundle-publish-transactions",
      "--metafile", "build/build-script-regression/reserved-output-meta.json",
    );
    assert.notEqual(outputResult.status, 0, `${outputResult.stdout}\n${outputResult.stderr}`);
    assert.match(outputResult.stderr, /internal publication state/u);
    assert.equal(existsSync(path.join(transactionRoot, "server.mjs")), false);
    assert.equal(existsSync(path.join(transactionRoot, "indexer.mjs")), false);

    const metadataResult = runBuild(
      "--outdir", "build/build-script-regression/reserved-meta-app",
      "--metafile", "build/.bundle-publish-transactions/caller-meta.json",
    );
    assert.notEqual(metadataResult.status, 0, `${metadataResult.stdout}\n${metadataResult.stderr}`);
    assert.match(metadataResult.stderr, /internal publication state/u);
    assert.equal(existsSync(metadataInsideStore), false);

    const claimResult = runBuild(
      "--outdir", "build/.bundle-publish-claim/caller-app",
      "--metafile", "build/build-script-regression/reserved-claim-meta.json",
    );
    assert.notEqual(claimResult.status, 0, `${claimResult.stdout}\n${claimResult.stderr}`);
    assert.match(claimResult.stderr, /internal publication state/u);
  } finally {
    removeGenerated(metadataInsideStore);
    removeGenerated(testRoot);
  }
});

test("a live global claim serializes recovery and publication", async () => {
  const firstOutput = path.join(testRoot, "live-claim-first-app");
  const firstMetadata = path.join(testRoot, "live-claim-first-meta.json");
  const secondOutput = path.join(testRoot, "live-claim-second-app");
  const secondMetadata = path.join(testRoot, "live-claim-second-meta.json");
  removeGenerated(testRoot);
  const first = spawnBuildWithEnvironment(
    {
      MQL5_CHM_BUILD_TEST_MODE: "1",
      MQL5_CHM_BUILD_TEST_HOLD_CLAIM_MS: "3000",
    },
    "--outdir", path.relative(projectRoot, firstOutput),
    "--metafile", path.relative(projectRoot, firstMetadata),
  );
  let firstStdout = "";
  let firstStderr = "";
  first.stdout.setEncoding("utf8");
  first.stderr.setEncoding("utf8");
  first.stdout.on("data", (chunk) => {
    firstStdout += chunk;
  });
  first.stderr.on("data", (chunk) => {
    firstStderr += chunk;
  });
  try {
    const owner = await waitForClaimOwner(first.pid);
    assert.equal(owner.pid, first.pid);
    assert.match(
      owner.processStartToken,
      /^win32-filetime:[1-9][0-9]{0,18}$/u,
      "a live claim must record the owning process start identity",
    );

    const refused = runBuild(
      "--outdir", path.relative(projectRoot, secondOutput),
      "--metafile", path.relative(projectRoot, secondMetadata),
    );
    assert.notEqual(refused.status, 0, `${refused.stdout}\n${refused.stderr}`);
    assert.match(refused.stderr, /Another live process owns the global publication mutex/u);
    assert.equal(existsSync(secondOutput), false);
    assert.equal(existsSync(secondMetadata), false);
    assert.equal(
      JSON.parse(readFileSync(path.join(globalClaimPath, "owner.json"), "utf8")).pid,
      first.pid,
      "a refused contender must not replace the live owner generation",
    );

    const [code, signal] = await once(first, "exit");
    assert.equal(signal, null, firstStderr);
    assert.equal(code, 0, `${firstStdout}\n${firstStderr}`);
    assert.ok(readFileSync(path.join(firstOutput, "server.mjs")).length > 1000);
    assert.ok(readFileSync(path.join(firstOutput, "indexer.mjs")).length > 1000);
    assert.doesNotThrow(() => JSON.parse(readFileSync(firstMetadata, "utf8")));
    assertNoGlobalClaimResidue();
  } finally {
    if (first.exitCode === null && first.signalCode === null) {
      first.kill();
      await once(first, "exit");
    }
    if (existsSync(globalClaimPath)) {
      runBuild(
        "--outdir", "data/rejected-after-live-claim-cleanup",
        "--metafile", "build/build-script-regression/rejected-after-live-claim-cleanup.json",
      );
    }
    removeGenerated(testRoot);
  }
});

test("a stale claim naming a reused live PID is reclaimed by process start identity", (context) => {
  if (process.platform !== "win32") {
    context.skip("Windows process start identity is the supported publication boundary.");
    return;
  }
  const output = path.join(testRoot, "reused-pid-app");
  const metadata = path.join(testRoot, "reused-pid-meta.json");
  removeGenerated(testRoot);
  assertNoGlobalClaimResidue();
  mkdirSync(globalClaimPath);
  writeFileSync(
    path.join(globalClaimPath, "owner.json"),
    `${JSON.stringify({
      version: 2,
      transaction: "00000000-0000-4000-8000-000000000001",
      pid: process.pid,
      processStartToken: "win32-filetime:1",
    }, null, 2)}\n`,
    "utf8",
  );
  try {
    const result = runBuild(
      "--outdir", path.relative(projectRoot, output),
      "--metafile", path.relative(projectRoot, metadata),
    );
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.ok(readFileSync(path.join(output, "server.mjs")).length > 1000);
    assert.ok(readFileSync(path.join(output, "indexer.mjs")).length > 1000);
    assert.doesNotThrow(() => JSON.parse(readFileSync(metadata, "utf8")));
    assertNoGlobalClaimResidue();
  } finally {
    removeGenerated(globalClaimPath);
    removeGenerated(testRoot);
  }
});

test("a manually planted claim matching a live process start identity remains fenced", (context) => {
  if (process.platform !== "win32") {
    context.skip("Windows process start identity is the supported publication boundary.");
    return;
  }
  const output = path.join(testRoot, "matching-live-owner-app");
  const metadata = path.join(testRoot, "matching-live-owner-meta.json");
  const owner = {
    version: 2,
    transaction: "00000000-0000-4000-8000-000000000002",
    pid: process.pid,
    processStartToken: windowsProcessStartToken(process.pid),
  };
  removeGenerated(testRoot);
  assertNoGlobalClaimResidue();
  mkdirSync(globalClaimPath);
  writeFileSync(
    path.join(globalClaimPath, "owner.json"),
    `${JSON.stringify(owner, null, 2)}\n`,
    "utf8",
  );
  try {
    const result = runBuild(
      "--outdir", path.relative(projectRoot, output),
      "--metafile", path.relative(projectRoot, metadata),
    );
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /still owned by its original running process/u);
    assert.equal(existsSync(output), false);
    assert.equal(existsSync(metadata), false);
    assert.deepEqual(
      JSON.parse(readFileSync(path.join(globalClaimPath, "owner.json"), "utf8")),
      owner,
      "a matching live owner must not be quarantined or replaced",
    );
    const claimEntries = readdirSync(path.join(projectRoot, "build"))
      .filter((name) => name.startsWith(".bundle-publish-claim"));
    assert.deepEqual(claimEntries, [".bundle-publish-claim"]);
  } finally {
    removeGenerated(globalClaimPath);
    removeGenerated(testRoot);
  }
});

test("a wedged mutex holder is terminated and reaped before failure returns", () => {
  const firstOutput = path.join(testRoot, "wedged-holder-first-app");
  const firstMetadata = path.join(testRoot, "wedged-holder-first-meta.json");
  const secondOutput = path.join(testRoot, "wedged-holder-second-app");
  const secondMetadata = path.join(testRoot, "wedged-holder-second-meta.json");
  removeGenerated(testRoot);
  try {
    const wedged = runBuildWithEnvironment(
      {
        MQL5_CHM_BUILD_TEST_MODE: "1",
        MQL5_CHM_BUILD_TEST_MUTEX_HANG_ON_RELEASE: "1",
      },
      "--outdir", path.relative(projectRoot, firstOutput),
      "--metafile", path.relative(projectRoot, firstMetadata),
    );
    assert.notEqual(wedged.status, 0, `${wedged.stdout}\n${wedged.stderr}`);
    assert.match(wedged.stderr, /Timed out releasing the global publication mutex/u);
    assert.ok(readFileSync(path.join(firstOutput, "server.mjs")).length > 1000);
    assert.ok(readFileSync(path.join(firstOutput, "indexer.mjs")).length > 1000);
    assert.doesNotThrow(() => JSON.parse(readFileSync(firstMetadata, "utf8")));
    assertNoGlobalClaimResidue();

    const reacquired = runBuild(
      "--outdir", path.relative(projectRoot, secondOutput),
      "--metafile", path.relative(projectRoot, secondMetadata),
    );
    assert.equal(reacquired.status, 0, `${reacquired.stdout}\n${reacquired.stderr}`);
    assert.ok(readFileSync(path.join(secondOutput, "server.mjs")).length > 1000);
    assert.ok(readFileSync(path.join(secondOutput, "indexer.mjs")).length > 1000);
    assert.doesNotThrow(() => JSON.parse(readFileSync(secondMetadata, "utf8")));
    assertNoGlobalClaimResidue();
  } finally {
    removeGenerated(testRoot);
  }
});

test("failed metadata publication preserves an existing bundle pair", () => {
  const output = path.join(testRoot, "existing-app");
  const metadataDirectory = path.join(testRoot, "metadata-is-a-directory");
  removeGenerated(testRoot);
  mkdirSync(output, { recursive: true });
  mkdirSync(metadataDirectory, { recursive: true });
  writeFileSync(path.join(output, "server.mjs"), "known-good-server\n", "utf8");
  writeFileSync(path.join(output, "indexer.mjs"), "known-good-indexer\n", "utf8");
  try {
    const result = runBuild(
      "--outdir", "build/build-script-regression/existing-app",
      "--metafile", "build/build-script-regression/metadata-is-a-directory",
    );
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.equal(readFileSync(path.join(output, "server.mjs"), "utf8"), "known-good-server\n");
    assert.equal(readFileSync(path.join(output, "indexer.mjs"), "utf8"), "known-good-indexer\n");
  } finally {
    removeGenerated(testRoot);
  }
});

test("build refuses to replace an output directory containing an unowned file", () => {
  const output = path.join(testRoot, "unowned-app");
  const sentinel = path.join(output, "keep-me.txt");
  removeGenerated(testRoot);
  mkdirSync(output, { recursive: true });
  writeFileSync(sentinel, "user-owned\n", "utf8");
  try {
    const result = runBuild(
      "--outdir", "build/build-script-regression/unowned-app",
      "--metafile", "build/build-script-regression/unowned-meta.json",
    );
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.equal(readFileSync(sentinel, "utf8"), "user-owned\n");
    assert.equal(existsSync(path.join(output, "server.mjs")), false);
    assert.equal(existsSync(path.join(output, "indexer.mjs")), false);
  } finally {
    removeGenerated(testRoot);
  }
});

test("build rejects an outdir nested inside an existing owned bundle tree", () => {
  const ownedBundle = path.join(testRoot, "owned-parent-app");
  const nestedOutput = path.join(ownedBundle, "nested-app");
  const metadata = path.join(testRoot, "nested-owned-parent-meta.json");
  removeGenerated(testRoot);
  mkdirSync(ownedBundle, { recursive: true });
  writeFileSync(path.join(ownedBundle, "server.mjs"), "owned-server\n", "utf8");
  writeFileSync(path.join(ownedBundle, "indexer.mjs"), "owned-indexer\n", "utf8");
  try {
    const result = runBuild(
      "--outdir", path.relative(projectRoot, nestedOutput),
      "--metafile", path.relative(projectRoot, metadata),
    );
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /nested inside an existing bundle output/u);
    assert.equal(readFileSync(path.join(ownedBundle, "server.mjs"), "utf8"), "owned-server\n");
    assert.equal(readFileSync(path.join(ownedBundle, "indexer.mjs"), "utf8"), "owned-indexer\n");
    assert.equal(existsSync(nestedOutput), false);
    assert.equal(existsSync(metadata), false);
  } finally {
    removeGenerated(testRoot);
  }
});

test("build rejects a metafile nested inside an existing owned bundle tree", () => {
  const ownedBundle = path.join(testRoot, "owned-metadata-parent-app");
  const output = path.join(testRoot, "metadata-nesting-output");
  const nestedMetadata = path.join(ownedBundle, "nested-meta.json");
  removeGenerated(testRoot);
  mkdirSync(ownedBundle, { recursive: true });
  writeFileSync(path.join(ownedBundle, "server.mjs"), "owned-server\n", "utf8");
  writeFileSync(path.join(ownedBundle, "indexer.mjs"), "owned-indexer\n", "utf8");
  try {
    const result = runBuild(
      "--outdir", path.relative(projectRoot, output),
      "--metafile", path.relative(projectRoot, nestedMetadata),
    );
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /nested inside an existing bundle output/u);
    assert.equal(readFileSync(path.join(ownedBundle, "server.mjs"), "utf8"), "owned-server\n");
    assert.equal(readFileSync(path.join(ownedBundle, "indexer.mjs"), "utf8"), "owned-indexer\n");
    assert.equal(existsSync(output), false);
    assert.equal(existsSync(nestedMetadata), false);
  } finally {
    removeGenerated(testRoot);
  }
});

test("build rejects nesting beneath a bundle pair that also has an unowned entry", () => {
  const ownedBundle = path.join(testRoot, "owned-parent-with-extra");
  const nestedOutput = path.join(ownedBundle, "nested-app");
  const metadata = path.join(testRoot, "nested-owned-parent-with-extra-meta.json");
  removeGenerated(testRoot);
  mkdirSync(ownedBundle, { recursive: true });
  writeFileSync(path.join(ownedBundle, "server.mjs"), "owned-server\n", "utf8");
  writeFileSync(path.join(ownedBundle, "indexer.mjs"), "owned-indexer\n", "utf8");
  writeFileSync(path.join(ownedBundle, "keep-me.txt"), "unowned\n", "utf8");
  try {
    const result = runBuild(
      "--outdir", path.relative(projectRoot, nestedOutput),
      "--metafile", path.relative(projectRoot, metadata),
    );
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /nested inside an existing bundle output/u);
    assert.equal(readFileSync(path.join(ownedBundle, "server.mjs"), "utf8"), "owned-server\n");
    assert.equal(readFileSync(path.join(ownedBundle, "indexer.mjs"), "utf8"), "owned-indexer\n");
    assert.equal(readFileSync(path.join(ownedBundle, "keep-me.txt"), "utf8"), "unowned\n");
    assert.equal(existsSync(nestedOutput), false);
    assert.equal(existsSync(metadata), false);
  } finally {
    removeGenerated(testRoot);
  }
});

test("build rejects a nested junction before writing outside the project", (context) => {
  if (process.platform !== "win32") {
    context.skip("Windows junction behavior is the supported deployment boundary.");
    return;
  }
  const external = mkdtempSync(path.join(os.tmpdir(), "mql5-build-junction-"));
  const junctionParent = path.join(testRoot, "junction-parent");
  const junction = path.join(junctionParent, "escape");
  removeGenerated(testRoot);
  mkdirSync(junctionParent, { recursive: true });
  try {
    symlinkSync(external, junction, "junction");
    const result = runBuild(
      "--outdir", "build/build-script-regression/junction-parent/escape/app",
      "--metafile", "build/build-script-regression/junction-meta.json",
    );
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.equal(existsSync(path.join(external, "app")), false, "junction target must remain untouched");
  } finally {
    if (existsSync(junction)) unlinkSync(junction);
    removeGenerated(testRoot);
    removeGenerated(external);
  }
});

test("build publishes one complete bundle pair and metadata in generated build space", () => {
  const output = path.join(testRoot, "success-app");
  const metadata = path.join(testRoot, "success-meta.json");
  removeGenerated(testRoot);
  try {
    const result = runBuild(
      "--outdir", "build/build-script-regression/success-app",
      "--metafile", "build/build-script-regression/success-meta.json",
    );
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.ok(readFileSync(path.join(output, "server.mjs")).length > 1000);
    assert.ok(readFileSync(path.join(output, "indexer.mjs")).length > 1000);
    assert.doesNotThrow(() => JSON.parse(readFileSync(metadata, "utf8")));
  } finally {
    removeGenerated(testRoot);
  }
});

test("hard termination at every publication rename is recovered before the next build plan", () => {
  const cutPoints = [
    "metadata-backed-up",
    "app-backed-up",
    "app-installed",
    "metadata-installed",
  ];
  const testTransactions = [];
  removeGenerated(testRoot);
  try {
    for (const cutPoint of cutPoints) {
      const output = path.join(testRoot, `recovery-${cutPoint}-app`);
      const metadata = path.join(testRoot, `recovery-${cutPoint}-meta.json`);
      mkdirSync(output, { recursive: true });
      writeFileSync(path.join(output, "server.mjs"), `known-good-server-${cutPoint}\n`, "utf8");
      writeFileSync(path.join(output, "indexer.mjs"), `known-good-indexer-${cutPoint}\n`, "utf8");
      writeFileSync(metadata, `{"knownGood":"${cutPoint}"}\n`, "utf8");

      const buildArguments = [
        "--outdir", path.relative(projectRoot, output),
        "--metafile", path.relative(projectRoot, metadata),
      ];
      const interrupted = runBuildWithEnvironment(
        {
          MQL5_CHM_BUILD_TEST_MODE: "1",
          MQL5_CHM_BUILD_TEST_EXIT_AFTER_RENAME: cutPoint,
        },
        ...buildArguments,
      );
      assert.equal(
        interrupted.status,
        86,
        `expected an injected hard exit after ${cutPoint}\n${interrupted.stdout}\n${interrupted.stderr}`,
      );
      const transaction = findJournalForOutput(output);
      assert.ok(transaction, `hard exit after ${cutPoint} must preserve a recovery journal`);
      assert.equal(
        transaction.journalPath,
        expectedJournalPath(output, metadata),
        "journal identity must depend only on canonical project-relative targets",
      );
      testTransactions.push(transaction);
      if (cutPoint === "metadata-backed-up") {
        const reusedPidRecord = JSON.parse(readFileSync(transaction.journalPath, "utf8"));
        reusedPidRecord.pid = process.pid;
        writeFileSync(
          transaction.journalPath,
          `${JSON.stringify(reusedPidRecord, null, 2)}\n`,
          "utf8",
        );
      }

      const recoveryProbe = runBuild(
        "--outdir", `data/rejected-after-${cutPoint}`,
        "--metafile", `build/build-script-regression/rejected-after-${cutPoint}.json`,
      );
      assert.notEqual(recoveryProbe.status, 0, `${recoveryProbe.stdout}\n${recoveryProbe.stderr}`);
      assert.equal(
        readFileSync(path.join(output, "server.mjs"), "utf8"),
        `known-good-server-${cutPoint}\n`,
      );
      assert.equal(
        readFileSync(path.join(output, "indexer.mjs"), "utf8"),
        `known-good-indexer-${cutPoint}\n`,
      );
      assert.equal(readFileSync(metadata, "utf8"), `{"knownGood":"${cutPoint}"}\n`);
      assertTransactionResidueRemoved(transaction);

      const completed = runBuild(...buildArguments);
      assert.equal(completed.status, 0, `${completed.stdout}\n${completed.stderr}`);
      assert.ok(readFileSync(path.join(output, "server.mjs")).length > 1000);
      assert.ok(readFileSync(path.join(output, "indexer.mjs")).length > 1000);
      assert.doesNotThrow(() => JSON.parse(readFileSync(metadata, "utf8")));
      assert.equal(findJournalForOutput(output), null, "completed publication must not leave a journal");
    }
  } finally {
    for (const transaction of testTransactions) removeTransactionResidue(transaction);
    removeGenerated(testRoot);
  }
});

test("atomic ownership writes expose only absent or complete JSON after hard termination", () => {
  const cutPoints = [
    { name: "journal-temp-synced", journal: false, commit: false, committed: false },
    { name: "journal-published", journal: true, commit: false, committed: false },
    { name: "commit-temp-synced", journal: true, commit: false, committed: false },
    { name: "commit-published", journal: true, commit: true, committed: true },
  ];
  const testTransactions = [];
  removeGenerated(testRoot);
  try {
    for (const cutPoint of cutPoints) {
      const output = path.join(testRoot, `atomic-${cutPoint.name}-app`);
      const metadata = path.join(testRoot, `atomic-${cutPoint.name}-meta.json`);
      mkdirSync(output, { recursive: true });
      writeFileSync(path.join(output, "server.mjs"), `known-good-server-${cutPoint.name}\n`, "utf8");
      writeFileSync(path.join(output, "indexer.mjs"), `known-good-indexer-${cutPoint.name}\n`, "utf8");
      writeFileSync(metadata, `{"knownGood":"${cutPoint.name}"}\n`, "utf8");
      const interrupted = runBuildWithEnvironment(
        {
          MQL5_CHM_BUILD_TEST_MODE: "1",
          MQL5_CHM_BUILD_TEST_EXIT_AT_ATOMIC_WRITE: cutPoint.name,
        },
        "--outdir", path.relative(projectRoot, output),
        "--metafile", path.relative(projectRoot, metadata),
      );
      assert.equal(interrupted.status, 86, `${interrupted.stdout}\n${interrupted.stderr}`);

      assert.doesNotThrow(
        () => JSON.parse(readFileSync(path.join(globalClaimPath, "owner.json"), "utf8")),
        "the globally visible claim owner must always be complete JSON",
      );
      for (const name of readdirSync(globalClaimPath).filter((entry) => entry.endsWith(".json"))) {
        assert.doesNotThrow(
          () => JSON.parse(readFileSync(path.join(globalClaimPath, name), "utf8")),
          `private atomic-write residue must be complete JSON: ${name}`,
        );
      }

      const transaction = findJournalForOutput(output);
      assert.equal(
        Boolean(transaction),
        cutPoint.journal,
        `${cutPoint.name} exposed an unexpected final journal state`,
      );
      if (transaction) {
        testTransactions.push(transaction);
        assert.doesNotThrow(() => JSON.parse(readFileSync(transaction.journalPath, "utf8")));
        assert.equal(existsSync(transaction.commitPath), cutPoint.commit);
        if (cutPoint.commit) {
          assert.doesNotThrow(() => JSON.parse(readFileSync(transaction.commitPath, "utf8")));
        }
      }

      const recoveryProbe = runBuild(
        "--outdir", `data/rejected-after-${cutPoint.name}`,
        "--metafile", `build/build-script-regression/rejected-after-${cutPoint.name}.json`,
      );
      assert.notEqual(recoveryProbe.status, 0, `${recoveryProbe.stdout}\n${recoveryProbe.stderr}`);
      if (cutPoint.committed) {
        assert.ok(readFileSync(path.join(output, "server.mjs")).length > 1000);
        assert.ok(readFileSync(path.join(output, "indexer.mjs")).length > 1000);
        assert.doesNotThrow(() => JSON.parse(readFileSync(metadata, "utf8")));
      } else {
        assert.equal(
          readFileSync(path.join(output, "server.mjs"), "utf8"),
          `known-good-server-${cutPoint.name}\n`,
        );
        assert.equal(
          readFileSync(path.join(output, "indexer.mjs"), "utf8"),
          `known-good-indexer-${cutPoint.name}\n`,
        );
        assert.equal(readFileSync(metadata, "utf8"), `{"knownGood":"${cutPoint.name}"}\n`);
      }
      if (transaction) assertTransactionResidueRemoved(transaction);
      assertNoGlobalClaimResidue();
      assert.deepEqual(readdirSync(transactionRoot), []);
    }
  } finally {
    if (existsSync(globalClaimPath)) {
      runBuild(
        "--outdir", "data/rejected-after-atomic-write-cleanup",
        "--metafile", "build/build-script-regression/rejected-after-atomic-write-cleanup.json",
      );
    }
    for (const transaction of testTransactions) removeTransactionResidue(transaction);
    removeGenerated(testRoot);
  }
});

test("atomic claim preparation and partial cleanup residues are reclaimable", () => {
  const testResidues = [];
  removeGenerated(testRoot);
  try {
    for (const cutPoint of ["owner-temp-synced", "owner-published"]) {
      const output = path.join(testRoot, `claim-${cutPoint}-app`);
      const metadata = path.join(testRoot, `claim-${cutPoint}-meta.json`);
      const interrupted = runBuildWithEnvironment(
        {
          MQL5_CHM_BUILD_TEST_MODE: "1",
          MQL5_CHM_BUILD_TEST_EXIT_AT_CLAIM_WRITE: cutPoint,
        },
        "--outdir", path.relative(projectRoot, output),
        "--metafile", path.relative(projectRoot, metadata),
      );
      assert.equal(interrupted.status, 86, `${interrupted.stdout}\n${interrupted.stderr}`);
      assert.equal(
        existsSync(globalClaimPath),
        false,
        "an incomplete private claim must never become the global owner",
      );
      const residues = readdirSync(path.join(projectRoot, "build"))
        .filter((name) => name.startsWith(".bundle-publish-claim.candidate-"));
      assert.equal(residues.length, 1, `unexpected private claim residues: ${residues.join(", ")}`);
      const residuePath = path.join(projectRoot, "build", residues[0]);
      testResidues.push(residuePath);
      for (const name of readdirSync(residuePath).filter((entry) => entry.endsWith(".json"))) {
        assert.doesNotThrow(
          () => JSON.parse(readFileSync(path.join(residuePath, name), "utf8")),
          `private claim residue must be complete JSON: ${name}`,
        );
      }

      if (cutPoint === "owner-published") {
        removeGenerated(path.join(residuePath, "owner.json"));
        writeFileSync(path.join(residuePath, "partial-cleanup.txt"), "owned residue\n", "utf8");
      }
      const recoveryProbe = runBuild(
        "--outdir", `data/rejected-after-${cutPoint}`,
        "--metafile", `build/build-script-regression/rejected-after-${cutPoint}.json`,
      );
      assert.notEqual(recoveryProbe.status, 0, `${recoveryProbe.stdout}\n${recoveryProbe.stderr}`);
      assert.equal(existsSync(output), false);
      assert.equal(existsSync(metadata), false);
      assertNoGlobalClaimResidue();
    }
  } finally {
    for (const residuePath of testResidues) removeGenerated(residuePath);
    removeGenerated(testRoot);
  }
});

test("interrupted first publication removes only its owned new outputs", () => {
  const testTransactions = [];
  removeGenerated(testRoot);
  try {
    for (const cutPoint of ["app-installed", "metadata-installed"]) {
      const output = path.join(testRoot, `first-${cutPoint}-app`);
      const metadata = path.join(testRoot, `first-${cutPoint}-meta.json`);
      const buildArguments = [
        "--outdir", path.relative(projectRoot, output),
        "--metafile", path.relative(projectRoot, metadata),
      ];
      const interrupted = runBuildWithEnvironment(
        {
          MQL5_CHM_BUILD_TEST_MODE: "1",
          MQL5_CHM_BUILD_TEST_EXIT_AFTER_RENAME: cutPoint,
        },
        ...buildArguments,
      );
      assert.equal(interrupted.status, 86, `${interrupted.stdout}\n${interrupted.stderr}`);
      const transaction = findJournalForOutput(output);
      assert.ok(transaction, `hard exit after ${cutPoint} must preserve a recovery journal`);
      testTransactions.push(transaction);

      const recoveryProbe = runBuild(
        "--outdir", `data/rejected-after-first-${cutPoint}`,
        "--metafile", `build/build-script-regression/rejected-after-first-${cutPoint}.json`,
      );
      assert.notEqual(recoveryProbe.status, 0, `${recoveryProbe.stdout}\n${recoveryProbe.stderr}`);
      assert.equal(existsSync(output), false, "recovery must remove the transaction-owned new app");
      assert.equal(
        existsSync(metadata),
        false,
        "recovery must remove the transaction-owned new metadata",
      );
      assertTransactionResidueRemoved(transaction);
    }
  } finally {
    for (const transaction of testTransactions) removeTransactionResidue(transaction);
    removeGenerated(testRoot);
  }
});

test("recovery refuses a junction inserted at an interrupted output", (context) => {
  if (process.platform !== "win32") {
    context.skip("Windows junction behavior is the supported deployment boundary.");
    return;
  }
  const output = path.join(testRoot, "recovery-junction-app");
  const metadata = path.join(testRoot, "recovery-junction-meta.json");
  const external = mkdtempSync(path.join(os.tmpdir(), "mql5-build-recovery-junction-"));
  const externalSentinel = path.join(external, "keep-me.txt");
  let transaction = null;
  let junctionInstalled = false;
  removeGenerated(testRoot);
  mkdirSync(output, { recursive: true });
  writeFileSync(path.join(output, "server.mjs"), "known-good-server\n", "utf8");
  writeFileSync(path.join(output, "indexer.mjs"), "known-good-indexer\n", "utf8");
  writeFileSync(metadata, "{\"knownGood\":true}\n", "utf8");
  writeFileSync(externalSentinel, "external-user-data\n", "utf8");
  const buildArguments = [
    "--outdir", path.relative(projectRoot, output),
    "--metafile", path.relative(projectRoot, metadata),
  ];
  try {
    const interrupted = runBuildWithEnvironment(
      {
        MQL5_CHM_BUILD_TEST_MODE: "1",
        MQL5_CHM_BUILD_TEST_EXIT_AFTER_RENAME: "app-backed-up",
      },
      ...buildArguments,
    );
    assert.equal(interrupted.status, 86, `${interrupted.stdout}\n${interrupted.stderr}`);
    transaction = findJournalForOutput(output);
    assert.ok(transaction, "interrupted publication must preserve a recovery journal");

    symlinkSync(external, output, "junction");
    junctionInstalled = true;
    const refused = runBuild(
      "--outdir", "data/rejected-after-recovery-junction",
      "--metafile", "build/build-script-regression/rejected-after-recovery-junction.json",
    );
    assert.notEqual(refused.status, 0, `${refused.stdout}\n${refused.stderr}`);
    assert.match(refused.stderr, /symbolic link or junction/u);
    assert.equal(readFileSync(externalSentinel, "utf8"), "external-user-data\n");
    assert.equal(existsSync(path.join(external, "server.mjs")), false);
    assert.equal(existsSync(path.join(external, "indexer.mjs")), false);
    assert.equal(existsSync(transaction.journalPath), true, "failed recovery must retain its journal");

    unlinkSync(output);
    junctionInstalled = false;
    const recovered = runBuild(
      "--outdir", "data/rejected-after-recovery-junction",
      "--metafile", "build/build-script-regression/rejected-after-recovery-junction.json",
    );
    assert.notEqual(recovered.status, 0, `${recovered.stdout}\n${recovered.stderr}`);
    assert.equal(readFileSync(path.join(output, "server.mjs"), "utf8"), "known-good-server\n");
    assert.equal(readFileSync(path.join(output, "indexer.mjs"), "utf8"), "known-good-indexer\n");
    assert.equal(readFileSync(metadata, "utf8"), "{\"knownGood\":true}\n");
    assertTransactionResidueRemoved(transaction);
  } finally {
    if (junctionInstalled && existsSync(output)) unlinkSync(output);
    if (transaction && existsSync(transaction.journalPath)) {
      runBuild(
        "--outdir", "data/rejected-after-recovery-junction-cleanup",
        "--metafile", "build/build-script-regression/rejected-after-recovery-junction-cleanup.json",
      );
    }
    removeTransactionResidue(transaction);
    removeGenerated(testRoot);
    removeGenerated(external);
  }
});

test("recovery preserves an unowned file inserted after interruption", () => {
  const output = path.join(testRoot, "recovery-unowned-app");
  const metadata = path.join(testRoot, "recovery-unowned-meta.json");
  let transaction = null;
  removeGenerated(testRoot);
  mkdirSync(output, { recursive: true });
  writeFileSync(path.join(output, "server.mjs"), "known-good-server\n", "utf8");
  writeFileSync(path.join(output, "indexer.mjs"), "known-good-indexer\n", "utf8");
  writeFileSync(metadata, "{\"knownGood\":true}\n", "utf8");
  const buildArguments = [
    "--outdir", path.relative(projectRoot, output),
    "--metafile", path.relative(projectRoot, metadata),
  ];
  try {
    const interrupted = runBuildWithEnvironment(
      {
        MQL5_CHM_BUILD_TEST_MODE: "1",
        MQL5_CHM_BUILD_TEST_EXIT_AFTER_RENAME: "app-backed-up",
      },
      ...buildArguments,
    );
    assert.equal(interrupted.status, 86, `${interrupted.stdout}\n${interrupted.stderr}`);
    transaction = findJournalForOutput(output);
    assert.ok(transaction, "interrupted publication must preserve a recovery journal");

    mkdirSync(output);
    const sentinel = path.join(output, "keep-me.txt");
    writeFileSync(sentinel, "user-owned\n", "utf8");
    const refused = runBuild(
      "--outdir", "data/rejected-after-unowned-recovery",
      "--metafile", "build/build-script-regression/rejected-after-unowned-recovery.json",
    );
    assert.notEqual(refused.status, 0, `${refused.stdout}\n${refused.stderr}`);
    assert.match(refused.stderr, /unowned entry: keep-me\.txt/u);
    assert.equal(readFileSync(sentinel, "utf8"), "user-owned\n");
    assert.equal(existsSync(transaction.journalPath), true, "failed recovery must retain its journal");

    removeGenerated(output);
    const recovered = runBuild(
      "--outdir", "data/rejected-after-unowned-recovery",
      "--metafile", "build/build-script-regression/rejected-after-unowned-recovery.json",
    );
    assert.notEqual(recovered.status, 0, `${recovered.stdout}\n${recovered.stderr}`);
    assert.equal(readFileSync(path.join(output, "server.mjs"), "utf8"), "known-good-server\n");
    assert.equal(readFileSync(path.join(output, "indexer.mjs"), "utf8"), "known-good-indexer\n");
    assert.equal(readFileSync(metadata, "utf8"), "{\"knownGood\":true}\n");
    assertTransactionResidueRemoved(transaction);
  } finally {
    if (transaction && existsSync(transaction.journalPath)) {
      removeGenerated(output);
      runBuild(
        "--outdir", "data/rejected-after-unowned-recovery-cleanup",
        "--metafile", "build/build-script-regression/rejected-after-unowned-recovery-cleanup.json",
      );
    }
    removeTransactionResidue(transaction);
    removeGenerated(testRoot);
  }
});

test("the normal test workflow builds and exercises a candidate before production publication", () => {
  const packageJson = JSON.parse(readFileSync(path.join(projectRoot, "package.json"), "utf8"));
  assert.equal(packageJson.scripts["pretest:fast"], "npm run build:candidate");
  assert.equal(packageJson.scripts.test, "npm run test:fast");
  assert.match(
    readFileSync(path.join(projectRoot, "tests", "mcp.test.mjs"), "utf8"),
    /build["'],\s*["']candidate-v12["'],\s*["']app["'],\s*["']server\.mjs["']/u,
  );
});

test("tracked production bundles exactly match the current candidate build", () => {
  for (const fileName of ["server.mjs", "indexer.mjs"]) {
    assert.deepEqual(
      readFileSync(path.join(projectRoot, "app", fileName)),
      readFileSync(path.join(projectRoot, "build", "candidate-v12", "app", fileName)),
      `${fileName} is stale; run the checked-in build script before packaging`,
    );
  }
});
