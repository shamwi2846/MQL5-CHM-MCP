import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { hostname as systemHostname, tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  INDEX_CONTRACT,
  SCHEMA_VERSION,
  acquireBuildLock,
  computeAssetTreeSha256,
  isObviouslySharedOrDevicePath,
  publishIndexBuildTransaction,
  proveLocalWindowsLockStorage,
  recoverIndexBuildTransaction,
  releaseBuildLock,
} from "../src/indexer.mjs";

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

async function exists(target) {
  return stat(target).then(() => true, (error) => error?.code === "ENOENT" ? false : Promise.reject(error));
}

async function writeArtifactSet({ databasePath, manifestPath, assetsPath, label }) {
  const databaseBytes = Buffer.from(`database:${label}\n`, "utf8");
  const assetBytes = Buffer.from(`asset:${label}\n`, "utf8");
  const assetRelativePath = "mql5/asset.bin";
  await mkdir(path.dirname(databasePath), { recursive: true });
  await mkdir(path.join(assetsPath, "mql5"), { recursive: true });
  await writeFile(databasePath, databaseBytes);
  await writeFile(path.join(assetsPath, ...assetRelativePath.split("/")), assetBytes);
  const databaseSha256 = sha256(databaseBytes);
  const assetSha256 = sha256(assetBytes);
  const assetTreeSha256 = computeAssetTreeSha256([{
    storageKey: `assets/${assetRelativePath}`,
    sha256: assetSha256,
    byteCount: assetBytes.length,
  }]);
  const corpusRevision = sha256(Buffer.from(`corpus:${label}`, "utf8"));
  const manifest = {
    schema_version: SCHEMA_VERSION,
    index_contract: INDEX_CONTRACT,
    index_revision: databaseSha256,
    corpus_revision: corpusRevision,
    corpus_sha256: corpusRevision,
    database: { filename: "mql5-docs.sqlite", bytes: databaseBytes.length, sha256: databaseSha256 },
    assets: {
      directory: "assets",
      cataloged_count: 1,
      total_bytes: assetBytes.length,
      tree_sha256: assetTreeSha256,
      catalog_sha256: sha256(Buffer.from(`catalog:${label}`, "utf8")),
    },
  };
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return { databaseSha256, corpusRevision, assetTreeSha256 };
}

async function createCandidate(outputDirectory, token, label) {
  const candidate = {
    databasePath: path.join(outputDirectory, `.mql5-docs.sqlite.candidate-${token}`),
    manifestPath: path.join(outputDirectory, `.manifest.json.candidate-${token}`),
    assetsPath: path.join(outputDirectory, `.assets.candidate-${token}`),
  };
  await writeArtifactSet({ ...candidate, label });
  return candidate;
}

async function createCanonical(outputDirectory, label) {
  const canonical = {
    databasePath: path.join(outputDirectory, "mql5-docs.sqlite"),
    manifestPath: path.join(outputDirectory, "manifest.json"),
    assetsPath: path.join(outputDirectory, "assets"),
  };
  const identity = await writeArtifactSet({ ...canonical, label });
  return { ...canonical, ...identity };
}

async function readCanonicalLabel(outputDirectory) {
  return readFile(path.join(outputDirectory, "mql5-docs.sqlite"), "utf8");
}

async function treeSnapshot(root) {
  const output = [];
  async function visit(directory) {
    for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const target = path.join(directory, entry.name);
      const relative = path.relative(root, target).replaceAll("\\", "/");
      if (entry.isDirectory()) {
        output.push(`d:${relative}`);
        await visit(target);
      } else {
        output.push(`f:${relative}:${sha256(await readFile(target))}`);
      }
    }
  }
  await visit(root);
  return output;
}

async function writeCurrentLock(lockPath, ownerToken, overrides = {}) {
  const lock = {
    schema_version: 1,
    pid: 2_147_483_647,
    hostname: systemHostname(),
    owner_token: ownerToken,
    started_at: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
  await writeFile(lockPath, `${JSON.stringify(lock)}\n`);
  return lock;
}

async function writeIdentityLock(lockPath, ownerToken, processStartIdentity, overrides = {}) {
  const lock = {
    schema_version: 2,
    pid: 2_147_483_647,
    hostname: systemHostname(),
    owner_token: ownerToken,
    process_start_identity: processStartIdentity,
    started_at: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
  await writeFile(lockPath, `${JSON.stringify(lock)}\n`);
  return lock;
}

test("simultaneous index-lock acquirers never observe an incomplete canonical lock", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-lock-atomic-publication-"));
  const processStartIdentity = "test-process-start:atomic-publication";
  try {
    for (let iteration = 0; iteration < 128; iteration += 1) {
      const lockPath = path.join(root, `.index-build-${iteration}.lock`);
      const options = {
        probeProcess: () => "live",
        probeProcessStartIdentity: () => processStartIdentity,
      };
      const outcomes = await Promise.allSettled([
        acquireBuildLock(lockPath, options),
        acquireBuildLock(lockPath, options),
      ]);
      const leases = outcomes
        .filter((outcome) => outcome.status === "fulfilled")
        .map((outcome) => outcome.value);
      const failures = outcomes.filter((outcome) => outcome.status === "rejected");
      assert.equal(leases.length, 1, `iteration ${iteration} must have exactly one lock owner`);
      assert.equal(failures.length, 1, `iteration ${iteration} must have exactly one fenced contender`);
      assert.match(
        failures[0].reason?.message ?? "",
        /active/i,
        `iteration ${iteration} exposed an incomplete canonical lock`,
      );
      await releaseBuildLock(leases[0]);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a zero-byte preparation owned by a live process stays fenced until atomic publication", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-lock-live-preparation-"));
  const lockPath = path.join(root, ".index-build.lock");
  const processStartIdentity = "test-process-start:live-preparation";
  let signalOpened;
  let resumePreparation;
  const opened = new Promise((resolve) => {
    signalOpened = resolve;
  });
  const resume = new Promise((resolve) => {
    resumePreparation = resolve;
  });
  let ownerLease = null;
  let ownerOutcomePromise = null;
  try {
    ownerOutcomePromise = acquireBuildLock(lockPath, {
      probeProcess: () => "live",
      probeProcessStartIdentity: () => processStartIdentity,
      async onCleanupCutPoint(name) {
        if (name !== "lock-preparation:opened") return;
        signalOpened();
        await resume;
      },
    }).then(
      (lease) => ({ lease, error: null }),
      (error) => ({ lease: null, error }),
    );
    await opened;

    assert.equal(await exists(lockPath), false);
    const preparationNames = (await readdir(root))
      .filter((name) => name.startsWith(".index-build.lock.prepare-"));
    assert.equal(preparationNames.length, 1);
    assert.equal((await stat(path.join(root, preparationNames[0]))).size, 0);

    await assert.rejects(
      acquireBuildLock(lockPath, {
        probeProcess: () => "live",
        probeProcessStartIdentity: () => processStartIdentity,
      }),
      /preparation owner.*active/i,
    );
    await assert.rejects(
      acquireBuildLock(lockPath, {
        probeProcess: () => "live",
        probeProcessStartIdentity() {
          throw new Error("synthetic process identity query failure");
        },
      }),
      /preparation owner.*inaccessible/i,
    );
    assert.equal(await exists(path.join(root, preparationNames[0])), true);

    resumePreparation();
    const ownerOutcome = await ownerOutcomePromise;
    assert.equal(ownerOutcome.error, null);
    ownerLease = ownerOutcome.lease;
    const canonicalRaw = await readFile(lockPath, "utf8");
    assert.doesNotThrow(() => JSON.parse(canonicalRaw));
    assert.deepEqual(
      (await readdir(root)).filter((name) => name.includes(".prepare-")),
      [],
    );
    await releaseBuildLock(ownerLease);
    ownerLease = null;
    ownerOutcomePromise = null;
  } finally {
    resumePreparation?.();
    const ownerOutcome = ownerOutcomePromise ? await ownerOutcomePromise : null;
    if (ownerOutcome?.lease && ownerOutcome.lease !== ownerLease) {
      await releaseBuildLock(ownerOutcome.lease).catch(() => {});
    }
    if (ownerLease) await releaseBuildLock(ownerLease).catch(() => {});
    await rm(root, { recursive: true, force: true });
  }
});

test("hard-killed lock preparations are recovered at every atomic publication boundary", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-lock-killed-preparation-"));
  const lockPath = path.join(root, ".index-build.lock");
  const indexerUrl = new URL("../src/indexer.mjs", import.meta.url).href;
  try {
    for (const cutPoint of [
      "lock-preparation:opened",
      "lock-preparation:prepared",
      "lock-preparation:published",
    ]) {
      const childScript = `
        import { acquireBuildLock } from ${JSON.stringify(indexerUrl)};
        await acquireBuildLock(process.env.MQL5_CHM_TEST_LOCK_PATH, {
          onCleanupCutPoint(name) {
            if (name === process.env.MQL5_CHM_TEST_LOCK_CUT_POINT) process.exit(86);
          },
        });
        process.exit(87);
      `;
      const interrupted = spawnSync(
        process.execPath,
        ["--input-type=module", "-e", childScript],
        {
          encoding: "utf8",
          env: {
            ...process.env,
            MQL5_CHM_TEST_LOCK_PATH: lockPath,
            MQL5_CHM_TEST_LOCK_CUT_POINT: cutPoint,
          },
          timeout: 30_000,
          windowsHide: true,
        },
      );
      assert.equal(
        interrupted.status,
        86,
        `${cutPoint} did not stop at the intended boundary\n${interrupted.stdout}\n${interrupted.stderr}`,
      );

      const preparationNames = (await readdir(root))
        .filter((name) => name.startsWith(".index-build.lock.prepare-"));
      assert.equal(preparationNames.length, 1, `${cutPoint} must retain one strict preparation`);
      const preparationPath = path.join(root, preparationNames[0]);
      if (cutPoint === "lock-preparation:opened") {
        assert.equal((await stat(preparationPath)).size, 0);
        assert.equal(await exists(lockPath), false);
        await assert.rejects(
          acquireBuildLock(lockPath, { hostname: `foreign-${systemHostname()}` }),
          /preparation belongs to a foreign host/i,
        );
        assert.equal(await exists(preparationPath), true);
      } else {
        const preparationRaw = await readFile(preparationPath, "utf8");
        assert.doesNotThrow(() => JSON.parse(preparationRaw));
        assert.equal(
          await exists(lockPath),
          cutPoint === "lock-preparation:published",
        );
        if (await exists(lockPath)) {
          assert.equal(await readFile(lockPath, "utf8"), await readFile(preparationPath, "utf8"));
        }
      }

      const recovered = await acquireBuildLock(
        lockPath,
        cutPoint === "lock-preparation:published"
          ? {
            probeProcess: () => "live",
            probeProcessStartIdentity: () => "test-process-start:reused-pid",
          }
          : {},
      );
      assert.deepEqual(
        (await readdir(root)).filter((name) => name.includes(".prepare-")),
        [],
      );
      await releaseBuildLock(recovered);
    }

    const malformedPath = `${lockPath}.prepare-v999-malformed`;
    await writeFile(malformedPath, "untrusted preparation\n", "utf8");
    await assert.rejects(acquireBuildLock(lockPath), /malformed index lock preparation/i);
    assert.equal(await readFile(malformedPath, "utf8"), "untrusted preparation\n");
    await rm(malformedPath, { force: true });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("index lock stays absent until current process identity resolves and a contender remains fenced", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-lock-pending-identity-"));
  const lockPath = path.join(root, ".index-build.lock");
  const processStartIdentity = "test-process-start:pending";
  let signalProbeStarted;
  let resolveProcessStartIdentity;
  let probeResolved = false;
  const probeStarted = new Promise((resolve) => {
    signalProbeStarted = resolve;
  });
  const pendingIdentity = new Promise((resolve) => {
    resolveProcessStartIdentity = resolve;
  });
  let contenderLease = null;
  let delayedOutcomePromise = null;
  try {
    const delayedAcquisition = acquireBuildLock(lockPath, {
      probeProcessStartIdentity(pid) {
        assert.equal(pid, process.pid);
        signalProbeStarted();
        return pendingIdentity;
      },
    });
    delayedOutcomePromise = delayedAcquisition.then(
      (lease) => ({ lease, error: null }),
      (error) => ({ lease: null, error }),
    );

    await probeStarted;
    assert.equal(
      await exists(lockPath),
      false,
      "The canonical lock must not exist while its owner identity is unresolved.",
    );

    contenderLease = await acquireBuildLock(lockPath, {
      probeProcessStartIdentity: () => processStartIdentity,
    });
    const contenderRaw = await readFile(lockPath, "utf8");
    resolveProcessStartIdentity(processStartIdentity);
    probeResolved = true;

    const delayedOutcome = await delayedOutcomePromise;
    assert.equal(delayedOutcome.lease, null);
    assert.match(delayedOutcome.error?.message ?? "", /active/i);
    assert.equal(await readFile(lockPath, "utf8"), contenderRaw);

    await releaseBuildLock(contenderLease);
    contenderLease = null;
    assert.equal(await exists(lockPath), false);
  } finally {
    if (!probeResolved) resolveProcessStartIdentity(processStartIdentity);
    const delayedOutcome = delayedOutcomePromise ? await delayedOutcomePromise : null;
    if (delayedOutcome?.lease) await releaseBuildLock(delayedOutcome.lease).catch(() => {});
    if (contenderLease) await releaseBuildLock(contenderLease).catch(() => {});
    await rm(root, { recursive: true, force: true });
  }
});

test("schema-v2 index locks distinguish a live owner from a reused PID across recovery paths", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-lock-identity-"));
  const lockPath = path.join(root, ".index-build.lock");
  const originalIdentity = "test-process-start:original";
  const replacementIdentity = "test-process-start:replacement";
  const replacementOptions = {
    probeProcess: () => "live",
    probeProcessStartIdentity: () => replacementIdentity,
  };
  try {
    const lease = await acquireBuildLock(lockPath, {
      probeProcessStartIdentity(pid) {
        assert.equal(pid, process.pid);
        return replacementIdentity;
      },
    });
    const created = JSON.parse(await readFile(lockPath, "utf8"));
    assert.deepEqual(
      Object.keys(created).sort(),
      ["hostname", "owner_token", "pid", "process_start_identity", "schema_version", "started_at"],
    );
    assert.equal(created.schema_version, 2);
    assert.equal(created.process_start_identity, replacementIdentity);
    await releaseBuildLock(lease);

    const staleToken = randomUUID();
    await writeIdentityLock(lockPath, staleToken, originalIdentity);
    const reclaimed = await acquireBuildLock(lockPath, replacementOptions);
    assert.notEqual(JSON.parse(await readFile(lockPath, "utf8")).owner_token, staleToken);
    await releaseBuildLock(reclaimed);

    const activeToken = randomUUID();
    const active = await writeIdentityLock(lockPath, activeToken, replacementIdentity);
    await assert.rejects(acquireBuildLock(lockPath, replacementOptions), /active/i);
    assert.equal(await readFile(lockPath, "utf8"), `${JSON.stringify(active)}\n`);
    await rm(lockPath, { force: true });

    const inaccessibleToken = randomUUID();
    const inaccessible = await writeIdentityLock(lockPath, inaccessibleToken, originalIdentity);
    await assert.rejects(
      acquireBuildLock(lockPath, {
        probeProcess: () => "live",
        probeProcessStartIdentity() {
          throw new Error("synthetic identity query failure");
        },
      }),
      /identity|inaccessible|cannot prove/i,
    );
    assert.equal(await readFile(lockPath, "utf8"), `${JSON.stringify(inaccessible)}\n`);
    await rm(lockPath, { force: true });

    const legacyToken = randomUUID();
    const legacy = await writeCurrentLock(lockPath, legacyToken);
    let currentIdentityQueries = 0;
    let legacyOwnerIdentityQueries = 0;
    await assert.rejects(
      acquireBuildLock(lockPath, {
        probeProcess: () => "live",
        probeProcessStartIdentity(pid) {
          if (pid === process.pid) currentIdentityQueries += 1;
          if (pid === legacy.pid) legacyOwnerIdentityQueries += 1;
          return replacementIdentity;
        },
      }),
      /active/i,
    );
    assert.equal(currentIdentityQueries, 1);
    assert.equal(legacyOwnerIdentityQueries, 0);
    assert.equal(await readFile(lockPath, "utf8"), `${JSON.stringify(legacy)}\n`);
    await rm(lockPath, { force: true });

    const releaseToken = randomUUID();
    const releasePath = `${lockPath}.release-${releaseToken}`;
    await writeIdentityLock(releasePath, releaseToken, originalIdentity);
    const recoveredRelease = await acquireBuildLock(lockPath, replacementOptions);
    assert.equal(await exists(releasePath), false);
    await releaseBuildLock(recoveredRelease);

    const activeReleaseToken = randomUUID();
    const activeReleasePath = `${lockPath}.release-${activeReleaseToken}`;
    await writeIdentityLock(activeReleasePath, activeReleaseToken, replacementIdentity);
    await assert.rejects(acquireBuildLock(lockPath, replacementOptions), /release owner.*active/i);
    assert.equal(await exists(activeReleasePath), true);
    await rm(activeReleasePath, { force: true });

    const reclaimToken = randomUUID();
    const reclaimPath = `${lockPath}.reclaim-${reclaimToken}`;
    await writeIdentityLock(reclaimPath, reclaimToken, originalIdentity);
    const recoveredReclaim = await acquireBuildLock(lockPath, replacementOptions);
    assert.equal(await exists(reclaimPath), false);
    await releaseBuildLock(recoveredReclaim);

    const activeReclaimToken = randomUUID();
    const activeReclaimPath = `${lockPath}.reclaim-${activeReclaimToken}`;
    await writeIdentityLock(activeReclaimPath, activeReclaimToken, replacementIdentity);
    await assert.rejects(acquireBuildLock(lockPath, replacementOptions), /reclaim owner.*active/i);
    assert.equal(await exists(activeReclaimPath), true);
    await rm(activeReclaimPath, { force: true });

    await assert.rejects(
      acquireBuildLock(lockPath, {
        probeProcessStartIdentity() {
          throw new Error("synthetic own-identity query failure");
        },
      }),
      /process start identity/i,
    );
    assert.equal(await exists(lockPath), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("direct indexer lock is strict JSON and only reclaims definitely-dead same-host owners", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-lock-"));
  const lockPath = path.join(root, ".index-build.lock");
  try {
    const lease = await acquireBuildLock(lockPath);
    const lock = JSON.parse(await readFile(lockPath, "utf8"));
    assert.deepEqual(
      Object.keys(lock).sort(),
      ["hostname", "owner_token", "pid", "process_start_identity", "schema_version", "started_at"],
    );
    assert.equal(lock.schema_version, 2);
    assert.equal(lock.pid, process.pid);
    assert.equal(lock.hostname, systemHostname());
    assert.match(lock.owner_token, /^[0-9a-f-]{36}$/u);
    assert.match(lock.process_start_identity, /^[a-z][a-z0-9-]*:[A-Za-z0-9._-]+$/u);
    await assert.rejects(acquireBuildLock(lockPath), /active|lock exists/i);
    await releaseBuildLock(lease);

    const releasedOwnerToken = randomUUID();
    const releasePath = `${lockPath}.release-${releasedOwnerToken}`;
    await writeCurrentLock(releasePath, releasedOwnerToken);
    const recoveredRelease = await acquireBuildLock(lockPath, { probeProcess: () => "dead" });
    assert.equal(await exists(releasePath), false);
    await releaseBuildLock(recoveredRelease);

    for (const [name, probeProcess, pattern] of [
      ["live", () => "live", /still active/i],
      ["inaccessible", () => "inaccessible", /inaccessible|cannot prove/i],
    ]) {
      const token = randomUUID();
      const claim = `${lockPath}.release-${token}`;
      await writeCurrentLock(claim, token);
      await assert.rejects(acquireBuildLock(lockPath, { probeProcess }), pattern, name);
      assert.equal(await exists(claim), true, name);
      await rm(claim, { force: true });
    }

    const mismatchedReleaseToken = randomUUID();
    const mismatchedReleasePath = `${lockPath}.release-${mismatchedReleaseToken}`;
    await writeCurrentLock(mismatchedReleasePath, randomUUID());
    await assert.rejects(acquireBuildLock(lockPath, { probeProcess: () => "dead" }), /not bound|preserved/i);
    assert.equal(await exists(mismatchedReleasePath), true);
    await rm(mismatchedReleasePath, { force: true });

    const stale = {
      schema_version: 1,
      pid: 2_147_483_647,
      hostname: systemHostname(),
      owner_token: randomUUID(),
      started_at: "2026-01-01T00:00:00.000Z",
    };
    await writeFile(lockPath, `${JSON.stringify(stale)}\n`);
    const reclaimed = await acquireBuildLock(lockPath, { probeProcess: () => "dead" });
    assert.notEqual(JSON.parse(await readFile(lockPath, "utf8")).owner_token, stale.owner_token);
    await releaseBuildLock(reclaimed);

    await writeFile(lockPath, `${JSON.stringify(stale)}\n`);
    await assert.rejects(
      acquireBuildLock(lockPath, {
        probeProcess: () => "dead",
        onCleanupCutPoint(name) {
          if (name === "dead-owner-lock:claimed") throw new Error("simulated reclaim crash");
        },
      }),
      /simulated reclaim crash/,
    );
    const strandedReclaims = (await readdir(root)).filter((name) => name.startsWith(".index-build.lock.reclaim-"));
    assert.equal(strandedReclaims.length, 1);
    assert.equal(await exists(lockPath), false);
    const recoveredReclaim = await acquireBuildLock(lockPath, { probeProcess: () => "dead" });
    assert.equal((await readdir(root)).some((name) => name.startsWith(".index-build.lock.reclaim-")), false);
    await releaseBuildLock(recoveredReclaim);

    await writeFile(lockPath, `${JSON.stringify(stale)}\n`);
    await assert.rejects(
      acquireBuildLock(lockPath, {
        probeProcess: () => "dead",
        onCleanupCutPoint(name) {
          if (name === "dead-owner-lock:new-lock-created") throw new Error("simulated post-create reclaim crash");
        },
      }),
      /simulated post-create reclaim crash/,
    );
    const pairedReclaims = (await readdir(root)).filter((name) => name.startsWith(".index-build.lock.reclaim-"));
    assert.equal(pairedReclaims.length, 1);
    const pairedCanonical = JSON.parse(await readFile(lockPath, "utf8"));
    assert.equal(pairedReclaims[0], `.index-build.lock.reclaim-${pairedCanonical.owner_token}`);
    const recoveredPair = await acquireBuildLock(lockPath, { probeProcess: () => "dead" });
    assert.equal((await readdir(root)).some((name) => name.startsWith(".index-build.lock.reclaim-")), false);
    await releaseBuildLock(recoveredPair);

    await writeFile(lockPath, `${JSON.stringify(stale)}\n`);
    await assert.rejects(
      acquireBuildLock(lockPath, {
        probeProcess: () => "dead",
        removeReclaimClaim: async () => {
          const error = new Error("synthetic claim sharing violation");
          error.code = "EACCES";
          throw error;
        },
      }),
      /canonical\/reclaim pair was retained|sharing violation/i,
    );
    const unlinkFailureCanonical = JSON.parse(await readFile(lockPath, "utf8"));
    const unlinkFailureClaim = `${lockPath}.reclaim-${unlinkFailureCanonical.owner_token}`;
    assert.equal(await exists(unlinkFailureClaim), true);
    assert.equal((await readdir(root)).filter((name) => /^\.index-build\.lock\.(?:reclaim|release)-/u.test(name)).length, 1);
    const recoveredUnlinkFailure = await acquireBuildLock(lockPath, { probeProcess: () => "dead" });
    assert.equal(await exists(unlinkFailureClaim), false);
    await releaseBuildLock(recoveredUnlinkFailure);

    const pairToken = randomUUID();
    const mismatchedPairClaim = `${lockPath}.reclaim-${pairToken}`;
    await writeCurrentLock(mismatchedPairClaim, randomUUID(), { pid: 111_111 });
    await writeCurrentLock(lockPath, randomUUID(), { pid: 222_222 });
    await assert.rejects(acquireBuildLock(lockPath, { probeProcess: () => "dead" }), /not bound|preserved/i);
    assert.equal(await exists(mismatchedPairClaim), true);
    assert.equal(await exists(lockPath), true);
    await rm(mismatchedPairClaim, { force: true });
    await rm(lockPath, { force: true });

    const livePairToken = randomUUID();
    const livePairClaim = `${lockPath}.reclaim-${livePairToken}`;
    await writeCurrentLock(livePairClaim, randomUUID(), { pid: 111_111 });
    await writeCurrentLock(lockPath, livePairToken, { pid: 222_222 });
    await assert.rejects(
      acquireBuildLock(lockPath, { probeProcess: (pid) => pid === 222_222 ? "live" : "dead" }),
      /canonical.*still active/i,
    );
    assert.equal(await exists(livePairClaim), true);
    assert.equal(await exists(lockPath), true);
    await rm(livePairClaim, { force: true });
    await rm(lockPath, { force: true });

    for (const [name, value, probeProcess, pattern] of [
      ["live reclaim", stale, () => "live", /still active/i],
      ["inaccessible reclaim", stale, () => "inaccessible", /inaccessible|cannot prove/i],
      ["foreign reclaim", { ...stale, hostname: "some-other-host" }, () => "dead", /foreign/i],
      ["malformed reclaim", "{broken", () => "dead", /malformed|JSON/i],
    ]) {
      const strandedPath = `${lockPath}.reclaim-${randomUUID()}`;
      await writeFile(strandedPath, typeof value === "string" ? value : `${JSON.stringify(value)}\n`);
      await assert.rejects(acquireBuildLock(lockPath, { probeProcess }), pattern, name);
      assert.equal(await exists(strandedPath), true, name);
      await rm(strandedPath, { force: true });
    }

    const legacyReclaimPath = `${lockPath}.reclaim-${randomUUID()}`;
    await writeFile(legacyReclaimPath, `${JSON.stringify({ pid: 2_147_483_647, started_at: "2026-01-01T00:00:00.000Z" })}\n`);
    await assert.rejects(
      acquireBuildLock(lockPath, { probeProcess: () => "dead" }),
      /explicit proof|local to this host/i,
    );
    assert.equal(await exists(legacyReclaimPath), true);
    const recoveredLegacyReclaim = await acquireBuildLock(lockPath, {
      probeProcess: () => "dead",
      legacySameHostProof: async (candidate) => candidate === path.resolve(lockPath),
    });
    assert.equal(await exists(legacyReclaimPath), false);
    await releaseBuildLock(recoveredLegacyReclaim);

    for (const [name, value, pattern] of [
      ["live", stale, /active/i],
      ["inaccessible", stale, /inaccessible|cannot prove/i],
      ["foreign", { ...stale, hostname: "some-other-host" }, /foreign/i],
      ["malformed", "{broken", /malformed|JSON/i],
    ]) {
      await writeFile(lockPath, typeof value === "string" ? value : `${JSON.stringify(value)}\n`);
      const probeProcess = name === "live" ? () => "live" : name === "inaccessible" ? () => "inaccessible" : () => "dead";
      await assert.rejects(acquireBuildLock(lockPath, { probeProcess }), pattern, name);
      assert.equal(await readFile(lockPath, "utf8"), typeof value === "string" ? value : `${JSON.stringify(value)}\n`);
      await rm(lockPath, { force: true });
    }

    const offsetTimestampLock = {
      ...stale,
      owner_token: randomUUID(),
      started_at: "2026-01-01T05:00:00.000+05:00",
    };
    await writeFile(lockPath, `${JSON.stringify(offsetTimestampLock)}\n`);
    await assert.rejects(acquireBuildLock(lockPath, { probeProcess: () => "dead" }), /UTC|ending in Z/i);
    assert.equal(await readFile(lockPath, "utf8"), `${JSON.stringify(offsetTimestampLock)}\n`);
    await rm(lockPath, { force: true });

    const legacy = { pid: 2_147_483_647, started_at: "2026-01-01T00:00:00.000Z" };
    await writeFile(lockPath, `${JSON.stringify(legacy)}\n`);
    await assert.rejects(
      acquireBuildLock(lockPath, { probeProcess: () => "dead", legacySameHostProof: true }),
      /explicit proof|local to this host/i,
    );
    assert.equal(await readFile(lockPath, "utf8"), `${JSON.stringify(legacy)}\n`);
    const legacyLease = await acquireBuildLock(lockPath, {
      probeProcess: () => "dead",
      legacySameHostProof: async (candidate) => candidate === path.resolve(lockPath),
    });
    await releaseBuildLock(legacyLease);

    const legacyOffset = { pid: 2_147_483_647, started_at: "2026-01-01T00:00:00.000+00:00" };
    await writeFile(lockPath, `${JSON.stringify(legacyOffset)}\n`);
    await assert.rejects(
      acquireBuildLock(lockPath, { probeProcess: () => "dead", legacySameHostProof: () => true }),
      /UTC|ending in Z/i,
    );
    assert.equal(await readFile(lockPath, "utf8"), `${JSON.stringify(legacyOffset)}\n`);
    await rm(lockPath, { force: true });

    assert.equal(isObviouslySharedOrDevicePath("\\\\server\\share\\.index-build.lock"), true);
    assert.equal(isObviouslySharedOrDevicePath("//server/share/.index-build.lock"), true);
    assert.equal(isObviouslySharedOrDevicePath(lockPath), false);
    assert.equal(await proveLocalWindowsLockStorage("\\\\server\\share\\.index-build.lock", () => true), false);
    assert.equal(await proveLocalWindowsLockStorage("//server/share/.index-build.lock", () => true), false);
    if (process.platform === "win32") {
      let probedRoot = "";
      assert.equal(await proveLocalWindowsLockStorage(lockPath, (rootPath) => {
        probedRoot = rootPath;
        return true;
      }), true);
      assert.match(probedRoot, /^[A-Za-z]:\\$/u);
      assert.equal(await proveLocalWindowsLockStorage(lockPath, () => false), false);
    }

    await writeFile(lockPath, `${JSON.stringify(legacy)}\n`);
    await writeFile(path.join(root, ".index-build-transaction.json"), "{}\n");
    await assert.rejects(
      acquireBuildLock(lockPath, { probeProcess: () => "dead", legacySameHostProof: () => true }),
      /legacy.*debris|ambiguous/i,
    );
    assert.equal(await readFile(lockPath, "utf8"), `${JSON.stringify(legacy)}\n`);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("publication recovery completes the candidate at every durable rename cut point", async () => {
  const cutPoints = [
    "journal",
    "backup:database",
    "backup:manifest",
    "backup:assets",
    "install:database",
    "install:manifest",
    "install:assets",
  ];
  for (const cutPoint of cutPoints) {
    const root = await mkdtemp(path.join(tmpdir(), "mql5-index-publish-"));
    try {
      await createCanonical(root, `old-${cutPoint}`);
      const token = randomUUID();
      const candidate = await createCandidate(root, token, `new-${cutPoint}`);
      await assert.rejects(
        publishIndexBuildTransaction({
          outputDirectory: root,
          ...candidate,
          transactionToken: token,
          onCutPoint(name) {
            if (name === cutPoint) throw new Error(`simulated crash at ${name}`);
          },
        }),
        /simulated crash/,
      );
      assert.equal(await exists(path.join(root, ".index-build-transaction.json")), true, cutPoint);
      assert.deepEqual(await recoverIndexBuildTransaction(root), { action: "committed" }, cutPoint);
      assert.equal(await readCanonicalLabel(root), `database:new-${cutPoint}\n`, cutPoint);
      assert.equal(await exists(path.join(root, ".index-build-transaction.json")), false, cutPoint);
      assert.equal(await exists(path.join(root, `.index-build-transaction.json.tmp-${token}`)), false, cutPoint);
      assert.deepEqual(await recoverIndexBuildTransaction(root), { action: "none" }, cutPoint);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});

test("incomplete candidate restores the complete prior set", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-restore-"));
  try {
    await createCanonical(root, "old");
    const token = randomUUID();
    const candidate = await createCandidate(root, token, "new");
    await assert.rejects(publishIndexBuildTransaction({
      outputDirectory: root,
      ...candidate,
      transactionToken: token,
      onCutPoint(name) {
        if (name === "install:database") throw new Error("crash");
      },
    }), /crash/);
    await rm(candidate.assetsPath, { recursive: true, force: true });
    assert.deepEqual(await recoverIndexBuildTransaction(root), { action: "restored" });
    assert.equal(await readCanonicalLabel(root), "database:old\n");
    assert.equal(await exists(path.join(root, ".index-build-transaction.json")), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("partial first publication is cleared and marked for rebuild", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-first-"));
  try {
    const protectedBytes = Buffer.from("must-survive\n", "utf8");
    await writeFile(path.join(root, "mql5.chm"), protectedBytes);
    await writeFile(path.join(root, "corpus.lock.json"), protectedBytes);
    await writeFile(path.join(root, "unrelated-output.txt"), protectedBytes);
    const token = randomUUID();
    const candidate = await createCandidate(root, token, "first");
    await assert.rejects(publishIndexBuildTransaction({
      outputDirectory: root,
      ...candidate,
      transactionToken: token,
      onCutPoint(name) {
        if (name === "install:database") throw new Error("crash");
      },
    }), /crash/);
    await rm(candidate.assetsPath, { recursive: true, force: true });
    assert.deepEqual(await recoverIndexBuildTransaction(root), { action: "rebuild" });
    for (const name of ["mql5-docs.sqlite", "manifest.json", "assets", ".index-build-transaction.json"]) {
      assert.equal(await exists(path.join(root, name)), false, name);
    }
    for (const name of ["mql5.chm", "corpus.lock.json", "unrelated-output.txt"]) {
      assert.deepEqual(await readFile(path.join(root, name)), protectedBytes, name);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("ambiguous transaction damage fails closed without changing any bytes", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-ambiguous-"));
  try {
    await createCanonical(root, "old");
    const token = randomUUID();
    const candidate = await createCandidate(root, token, "new");
    await assert.rejects(publishIndexBuildTransaction({
      outputDirectory: root,
      ...candidate,
      transactionToken: token,
      onCutPoint(name) {
        if (name === "install:database") throw new Error("crash");
      },
    }), /crash/);
    await rm(candidate.assetsPath, { recursive: true, force: true });
    await rm(path.join(root, `.manifest.json.backup-${token}`), { force: true });
    const before = await treeSnapshot(root);
    await assert.rejects(recoverIndexBuildTransaction(root), /neither|ambiguous|cannot recover/i);
    assert.deepEqual(await treeSnapshot(root), before);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a later artifact conflict is preflighted before any earlier artifact moves", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-preflight-"));
  try {
    await createCanonical(root, "old");
    const token = randomUUID();
    const candidate = await createCandidate(root, token, "new");
    await assert.rejects(publishIndexBuildTransaction({
      outputDirectory: root,
      ...candidate,
      transactionToken: token,
      onCutPoint(name) {
        if (name === "backup:assets") throw new Error("crash");
      },
    }), /crash/);
    const assetBackup = path.join(root, `.assets.backup-${token}`);
    await cp(assetBackup, path.join(root, "assets"), { recursive: true, errorOnExist: true });
    const before = await treeSnapshot(root);
    await assert.rejects(recoverIndexBuildTransaction(root), /ambiguous/i);
    assert.deepEqual(await treeSnapshot(root), before);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("dead-owner pre-publication debris is token-bound, reclaimed, and never becomes a truncated canonical journal", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-prejournal-"));
  try {
    await createCanonical(root, "old");
    const protectedBytes = Buffer.from("unrelated must survive\n", "utf8");
    await writeFile(path.join(root, "mql5.chm"), protectedBytes);
    const token = randomUUID();
    const candidate = await createCandidate(root, token, "abandoned");
    const lockPath = path.join(root, ".index-build.lock");
    await writeCurrentLock(lockPath, token);

    await assert.rejects(publishIndexBuildTransaction({
      outputDirectory: root,
      ...candidate,
      transactionToken: token,
      onCutPoint(name) {
        if (name === "journal:prepared") throw new Error("crash before atomic journal publication");
      },
    }), /crash before atomic journal publication/);

    const journalPath = path.join(root, ".index-build-transaction.json");
    const temporaryPath = `${journalPath}.tmp-${token}`;
    assert.equal(await exists(journalPath), false);
    assert.equal(await exists(temporaryPath), true);
    await writeFile(temporaryPath, "{\"truncated\":", "utf8");
    await writeFile(`${candidate.databasePath}-wal`, "abandoned sqlite sidecar\n");

    const lease = await acquireBuildLock(lockPath, { probeProcess: () => "dead" });
    assert.notEqual(lease.ownerToken, token);
    for (const target of [
      candidate.databasePath,
      `${candidate.databasePath}-wal`,
      candidate.manifestPath,
      candidate.assetsPath,
      temporaryPath,
      path.join(root, `.assets.disposal-candidate-${token}`),
    ]) {
      assert.equal(await exists(target), false, target);
    }
    assert.equal(await readCanonicalLabel(root), "database:old\n");
    assert.deepEqual(await readFile(path.join(root, "mql5.chm")), protectedBytes);
    await releaseBuildLock(lease);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("dead-owner cleanup fails closed for debris not bound to that same-host owner", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-foreign-debris-"));
  try {
    const ownerToken = randomUUID();
    const foreignToken = randomUUID();
    const lockPath = path.join(root, ".index-build.lock");
    await writeCurrentLock(lockPath, ownerToken);
    const foreignCandidate = await createCandidate(root, foreignToken, "foreign");
    const before = await treeSnapshot(root);
    await assert.rejects(
      acquireBuildLock(lockPath, { probeProcess: () => "dead" }),
      /not bound|ambiguous/i,
    );
    assert.deepEqual(await treeSnapshot(root), before);
    assert.equal(await exists(foreignCandidate.assetsPath), true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("live and foreign-host owners retain all token-bound pre-publication debris", async () => {
  for (const ownerKind of ["live", "foreign"]) {
    const root = await mkdtemp(path.join(tmpdir(), `mql5-index-owner-${ownerKind}-`));
    try {
      const token = randomUUID();
      const lockPath = path.join(root, ".index-build.lock");
      await writeCurrentLock(lockPath, token, ownerKind === "foreign" ? { hostname: "another-host" } : {});
      await createCandidate(root, token, ownerKind);
      const before = await treeSnapshot(root);
      await assert.rejects(
        acquireBuildLock(lockPath, { probeProcess: () => ownerKind === "live" ? "live" : "dead" }),
        ownerKind === "live" ? /active/i : /foreign/i,
      );
      assert.deepEqual(await treeSnapshot(root), before);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});

test("canonical transaction journal publication is absent-only", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-journal-absent-"));
  try {
    await createCanonical(root, "old");
    const token = randomUUID();
    const candidate = await createCandidate(root, token, "new");
    const journalPath = path.join(root, ".index-build-transaction.json");
    await writeFile(journalPath, "existing journal bytes\n");
    const before = await treeSnapshot(root);
    await assert.rejects(publishIndexBuildTransaction({
      outputDirectory: root,
      ...candidate,
      transactionToken: token,
    }), /already pending/i);
    assert.deepEqual(await treeSnapshot(root), before);

    await rm(journalPath, { force: true });
    await writeFile(`${journalPath}.tmp-${randomUUID()}`, "foreign temporary\n");
    const debrisBefore = await treeSnapshot(root);
    await assert.rejects(publishIndexBuildTransaction({
      outputDirectory: root,
      ...candidate,
      transactionToken: token,
    }), /ambiguous|unrelated.*debris/i);
    assert.deepEqual(await treeSnapshot(root), debrisBefore);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("commit cleanup resumes after every recursive backup-assets disposal cut point", async () => {
  for (const cutPoint of ["dispose:backup:assets:renamed", "dispose:backup:assets:removed"]) {
    const root = await mkdtemp(path.join(tmpdir(), "mql5-index-dispose-commit-"));
    try {
      await createCanonical(root, `old-${cutPoint}`);
      const token = randomUUID();
      const candidate = await createCandidate(root, token, `new-${cutPoint}`);
      await assert.rejects(publishIndexBuildTransaction({
        outputDirectory: root,
        ...candidate,
        transactionToken: token,
        onCutPoint(name) {
          if (name === cutPoint) throw new Error(`cleanup crash at ${name}`);
        },
      }), /cleanup crash/);
      const disposal = path.join(root, `.assets.disposal-backup-${token}`);
      if (cutPoint.endsWith(":renamed")) {
        assert.equal(await exists(disposal), true);
        await rm(path.join(disposal, "mql5", "asset.bin"), { force: true });
      }
      assert.equal(await exists(path.join(root, ".index-build-transaction.json")), true);
      assert.deepEqual(await recoverIndexBuildTransaction(root), { action: "committed" });
      assert.equal(await readCanonicalLabel(root), `database:new-${cutPoint}\n`);
      assert.equal(await exists(disposal), false);
      assert.equal(await exists(path.join(root, ".index-build-transaction.json")), false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});

test("a dead recovery custodian can hand an older strict journal to the next custodian", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-recovery-custodian-"));
  const lockPath = path.join(root, ".index-build.lock");
  try {
    await createCanonical(root, "old-custodian");
    const originalToken = randomUUID();
    const candidate = await createCandidate(root, originalToken, "new-custodian");
    await assert.rejects(publishIndexBuildTransaction({
      outputDirectory: root,
      ...candidate,
      transactionToken: originalToken,
      onCutPoint(name) {
        if (name === "dispose:backup:assets:renamed") throw new Error("original owner crash");
      },
    }), /original owner crash/);
    await writeCurrentLock(lockPath, originalToken);

    const successor = await acquireBuildLock(lockPath, { probeProcess: () => "dead" });
    assert.notEqual(successor.ownerToken, originalToken);
    await assert.rejects(recoverIndexBuildTransaction(root, {
      onCutPoint(name) {
        if (name === "dispose:backup:assets:removed") throw new Error("successor recovery crash");
      },
    }), /successor recovery crash/);
    await successor.handle.close();
    assert.equal(await exists(lockPath), true);
    assert.equal(await exists(path.join(root, ".index-build-transaction.json")), true);

    const finalCustodian = await acquireBuildLock(lockPath, { probeProcess: () => "dead" });
    assert.deepEqual(await recoverIndexBuildTransaction(root), { action: "committed" });
    assert.equal(await readCanonicalLabel(root), "database:new-custodian\n");
    assert.equal(await exists(path.join(root, ".index-build-transaction.json")), false);
    await releaseBuildLock(finalCustodian);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("rollback cleanup resumes after target and candidate asset-disposal crashes", async () => {
  for (const role of ["target", "candidate"]) {
    const root = await mkdtemp(path.join(tmpdir(), `mql5-index-dispose-rollback-${role}-`));
    try {
      await createCanonical(root, `old-${role}`);
      const token = randomUUID();
      const candidate = await createCandidate(root, token, `new-${role}`);
      const publicationCutPoint = role === "target" ? "install:assets" : "install:database";
      await assert.rejects(publishIndexBuildTransaction({
        outputDirectory: root,
        ...candidate,
        transactionToken: token,
        onCutPoint(name) {
          if (name === publicationCutPoint) throw new Error("publication crash");
        },
      }), /publication crash/);
      const missingManifest = role === "target"
        ? path.join(root, "manifest.json")
        : candidate.manifestPath;
      await rm(missingManifest, { force: true });
      const cleanupCutPoint = `dispose:${role}:assets:renamed`;
      await assert.rejects(
        recoverIndexBuildTransaction(root, {
          onCutPoint(name) {
            if (name === cleanupCutPoint) throw new Error("recursive cleanup crash");
          },
        }),
        /recursive cleanup crash/,
      );
      const disposal = path.join(root, `.assets.disposal-${role}-${token}`);
      assert.equal(await exists(disposal), true);
      await rm(path.join(disposal, "mql5", "asset.bin"), { force: true });
      assert.equal(await exists(path.join(root, ".index-build-transaction.json")), true);
      assert.deepEqual(await recoverIndexBuildTransaction(root), { action: "restored" });
      assert.equal(await readCanonicalLabel(root), `database:old-${role}\n`);
      assert.equal(await exists(disposal), false);
      assert.equal(await exists(path.join(root, ".index-build-transaction.json")), false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});
