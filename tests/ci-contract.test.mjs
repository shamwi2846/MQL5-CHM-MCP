import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function text(relativePath) {
  return readFile(path.join(root, relativePath), "utf8");
}

async function runReleaseVersionCheck({
  packageVersion = "1.2.3",
  lockVersion = packageVersion,
  rootLockVersion = lockVersion,
  refType = "tag",
  refName = `v${packageVersion}`,
} = {}) {
  const fixture = await mkdtemp(path.join(tmpdir(), "mql5-chm-release-version-"));
  const packageJson = path.join(fixture, "package.json");
  const packageLock = path.join(fixture, "package-lock.json");
  await writeFile(packageJson, `${JSON.stringify({ name: "fixture", version: packageVersion })}\n`, "utf8");
  await writeFile(packageLock, `${JSON.stringify({
    name: "fixture",
    version: lockVersion,
    lockfileVersion: 3,
    packages: { "": { name: "fixture", version: rootLockVersion } },
  })}\n`, "utf8");
  try {
    return spawnSync(
      "pwsh",
      [
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", path.join(root, "scripts", "Test-ReleaseVersion.ps1"),
        "-PackageJsonPath", packageJson,
        "-PackageLockPath", packageLock,
        "-RefType", refType,
        "-RefName", refName,
      ],
      { encoding: "utf8", windowsHide: true },
    );
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
}

test("package scripts expose explicit fast, maintenance, and release suites", async () => {
  const packageJson = JSON.parse(await text("package.json"));
  for (const name of ["test:fast", "test:maintenance", "test:release"]) {
    assert.equal(typeof packageJson.scripts[name], "string", `missing npm script ${name}`);
  }
  assert.match(packageJson.scripts.test, /test:fast/u);
  assert.match(packageJson.scripts["test:fast"], /tests\/mcp\.test\.mjs/u);
  assert.match(packageJson.scripts["test:fast"], /portable stdio MCP/u);
  assert.match(packageJson.scripts["test:corpus"], /portable stdio MCP/u);
  assert.match(packageJson.scripts["test:corpus"], /tests\/mcp\.test\.mjs/u);
  assert.match(packageJson.scripts["test:release"], /test:app-mcp/u);
  assert.match(packageJson.scripts["test:release"], /test:release:windows-powershell/u);
  assert.match(packageJson.scripts["test:release"], /test:prepare-corpus/u);
});

test("Windows CI runs the fast suite on pull requests with the pinned toolchain", async () => {
  const workflow = await text(".github/workflows/windows-ci.yml");
  assert.match(workflow, /\bpull_request\s*:/u);
  assert.match(workflow, /node-version:\s*["']?24\.17\.0/u);
  assert.match(workflow, /npm run test:fast/u);
  assert.match(workflow, /\bpwsh\b/u);
  assert.match(workflow, /\bpowershell(?:\.exe)?\b/u);
});

test("GitHub workflows never persist checkout credentials", async () => {
  for (const relativePath of [
    ".github/workflows/windows-ci.yml",
    ".github/workflows/release-validation.yml",
    ".github/workflows/documentation-freshness.yml",
  ]) {
    const workflow = await text(relativePath);
    assert.match(
      workflow,
      /uses:\s*actions\/checkout@v4\s+with:\s+persist-credentials:\s*false/u,
      `${relativePath} must disable persisted checkout credentials`,
    );
  }
});

test("release validation runs full suites under PowerShell 7 and Windows PowerShell 5.1", async () => {
  const workflow = await text(".github/workflows/release-validation.yml");
  assert.match(workflow, /tags:[\s\S]*v\*/u);
  assert.match(workflow, /npm run test:release/u);
  assert.match(workflow, /Package-Portable\.ps1/u);
  assert.match(workflow, /SHA-256|sha256|Get-FileHash/u);
});

test("release validation binds tag and lockfile versions before downloading a corpus fixture", async () => {
  const workflow = await text(".github/workflows/release-validation.yml");
  const versionGate = workflow.indexOf("Test-ReleaseVersion.ps1");
  const fixtureDownload = workflow.indexOf("Restore a verified corpus fixture");
  assert.ok(versionGate >= 0, "release workflow has no package/tag version gate");
  assert.ok(fixtureDownload > versionGate, "release workflow downloads before validating its release identity");

  const matching = await runReleaseVersionCheck();
  assert.equal(matching.status, 0, matching.stderr || matching.stdout);

  for (const refName of ["v1.2.4", "release-1.2.3"]) {
    const mismatch = await runReleaseVersionCheck({ refName });
    assert.notEqual(mismatch.status, 0, `release identity accepted tag ${refName}`);
    assert.match(`${mismatch.stderr}\n${mismatch.stdout}`, /tag|version/i);
  }

  const staleLock = await runReleaseVersionCheck({ lockVersion: "1.2.2", rootLockVersion: "1.2.2" });
  assert.notEqual(staleLock.status, 0, "release identity accepted a stale package-lock version");
  assert.match(`${staleLock.stderr}\n${staleLock.stdout}`, /package-lock|lockfile|version/i);

  for (const packageVersion of ["01.2.3", "1.2.3-01", "1.2.3-alpha..1"]) {
    const malformed = await runReleaseVersionCheck({ packageVersion });
    assert.notEqual(malformed.status, 0, `release identity accepted malformed SemVer ${packageVersion}`);
    assert.match(`${malformed.stderr}\n${malformed.stdout}`, /release version|semver|version/i);
  }

  const mixedCaseRefType = await runReleaseVersionCheck({
    refType: "TAG",
    refName: "definitely-wrong",
  });
  assert.notEqual(mixedCaseRefType.status, 0, "release identity bypassed tag binding for mixed-case ref type");
});

test("release validation rejects a prior-release corpus stale for the current source definition", async () => {
  const workflow = await text(".github/workflows/release-validation.yml");
  const fixtureRestore = workflow.indexOf("Restore a verified corpus fixture");
  const corpusGate = workflow.indexOf("Assert-ManifestAndCorpus");
  const releaseSuite = workflow.indexOf("npm run test:release");
  assert.ok(fixtureRestore >= 0, "release workflow has no corpus fixture restore step");
  assert.ok(corpusGate > fixtureRestore, "release workflow does not validate the restored corpus");
  assert.ok(releaseSuite > corpusGate, "release workflow tests before binding the restored corpus to current sources");
  assert.match(workflow, /Assert-ManifestAndCorpus[^\r\n]*-RequireCurrentSources/u);
  assert.match(workflow, /Assert-ManifestAndCorpus[^\r\n]*-RequireCurrentPolicy/u);
  assert.match(workflow, /Assert-PortableZipSidecar/u);

  const packageScript = await text("scripts/Package-Portable.ps1");
  assert.match(packageScript, /Assert-Revision[^\r\n]*-RequireCurrentPolicy/gu);
});

test("release validation treats a downloaded release as corpus data, never executable runtime", async () => {
  const workflow = await text(".github/workflows/release-validation.yml");
  const fixtureRestore = workflow.indexOf("Restore a verified corpus fixture");
  const corpusGate = workflow.indexOf("Bind the restored corpus to the current release definition");
  const releaseSuite = workflow.indexOf("npm run test:release");
  const trustedNodeBinding = workflow.indexOf("MQL5_CHM_TEST_NODE=");
  assert.ok(fixtureRestore >= 0 && corpusGate > fixtureRestore, "release fixture restore block is missing");
  const restoreBlock = workflow.slice(fixtureRestore, corpusGate);
  assert.match(
    restoreBlock,
    /foreach\s*\(\$directory\s+in\s+@\('data','revisions'\)\)/u,
    "release fixture restore is not limited to data and revisions",
  );
  assert.doesNotMatch(
    restoreBlock,
    /@\([^)]*(?:runtime|maintenance)|Join-Path\s+\$packageRoots\[0\]\.FullName\s+['"](?:runtime|maintenance)['"]/iu,
    "release fixture can restore executable runtime or mutable maintenance state",
  );
  assert.match(restoreBlock, /maintenance[^\r\n]*\r?\n[\s\S]*?\.update\.lock/u);
  assert.ok(
    trustedNodeBinding >= 0 && trustedNodeBinding < releaseSuite,
    "release tests are not bound to setup-node before execution",
  );
  assert.match(workflow, /MQL5_CHM_TEST_NODE=\$nodePath[\s\S]*GITHUB_ENV/u);
});

test("release validation accepts an explicitly reviewed current corpus fixture", async () => {
  const workflow = await text(".github/workflows/release-validation.yml");
  assert.match(workflow, /corpus_fixture_release\s*:/u);
  assert.match(workflow, /CORPUS_FIXTURE_RELEASE:\s*\$\{\{\s*inputs\.corpus_fixture_release\s*\}\}/u);
  assert.match(workflow, /gh release view \$requestedFixture/u);
  assert.match(workflow, /gh release download \$fixtureTag/u);
});

test("the real app-bundle gate uses package.json version in the raw installer smoke", async () => {
  const appBundleGate = await text("scripts/Test-AppBundle.mjs");
  assert.match(appBundleGate, /package\.json/u);
  assert.match(appBundleGate, /Smoke-Test-McpServer\.mjs/u);
  assert.match(appBundleGate, /--expected-server-version/u);
});

test("pinned upstream license bytes survive a fresh Windows checkout", async () => {
  const attributes = await text(".gitattributes");
  assert.match(attributes, /^licenses\/\*\.txt text eol=crlf$/mu);
  assert.match(attributes, /^licenses\/\*\*\/\*\.txt text eol=crlf$/mu);
  assert.match(attributes, /^licenses\/BUNDLED-NODE-NOTICES\.txt text eol=lf$/mu);

  for (const expected of [
    {
      relativePath: "licenses/7ZIP-LICENSE.txt",
      bytes: 6031,
      sha256: "519ac0a4bded9c18ea02e0afb71f663d8c47373bd9facd3ac96a79f51d77765d",
    },
    {
      relativePath: "licenses/NODE-LICENSE.txt",
      bytes: 159872,
      sha256: "8efdacdc1cfa3460aeb7fe98e3c54337b971d5da70e6eee292b73b981acb220c",
    },
  ]) {
    const bytes = await readFile(path.join(root, expected.relativePath));
    assert.equal(bytes.length, expected.bytes, `${expected.relativePath} checkout byte count changed`);
    assert.equal(
      createHash("sha256").update(bytes).digest("hex"),
      expected.sha256,
      `${expected.relativePath} checkout hash changed`,
    );
  }
});

test("weekly freshness automation is read-only and never stages an update", async () => {
  const workflow = await text(".github/workflows/documentation-freshness.yml");
  assert.match(workflow, /\bschedule\s*:/u);
  assert.match(workflow, /Compare-OfficialDocumentationHashes\.ps1/u);
  assert.match(workflow, /contents:\s*read/u);
  assert.doesNotMatch(
    workflow,
    /Update-Documentation|Set-UpdateStatus|git\s+push|release\s+(?:create|upload)|contents:\s*write/iu,
  );
});
