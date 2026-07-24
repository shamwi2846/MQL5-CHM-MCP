import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function text(relativePath) {
  return readFile(path.join(root, relativePath), "utf8");
}

function workflowSteps(workflow) {
  const lines = workflow.split(/\r?\n/u);
  const steps = [];
  for (let index = 0; index < lines.length; index += 1) {
    const start = /^(\s*)-\s+\S/u.exec(lines[index]);
    if (!start) continue;
    const indentation = start[1].length;
    let end = index + 1;
    while (end < lines.length) {
      if (lines[end].trim() === "") {
        end += 1;
        continue;
      }
      const nextIndentation = /^\s*/u.exec(lines[end])[0].length;
      if (nextIndentation <= indentation) break;
      end += 1;
    }
    steps.push(lines.slice(index, end).join("\n"));
    index = end - 1;
  }
  return steps;
}

function yamlScalar(value) {
  let result = value.trim();
  if (
    result.length >= 2
    && ((result.startsWith("'") && result.endsWith("'"))
      || (result.startsWith("\"") && result.endsWith("\"")))
  ) {
    result = result.slice(1, -1);
  }
  return result;
}

function actionStepUses(step) {
  const lines = step.split(/\r?\n/u);
  const stepIndentation = /^(\s*)-/u.exec(lines[0])?.[1].length;
  assert.notEqual(stepIndentation, undefined, "invalid workflow step fixture");
  const propertyIndentation = stepIndentation + 2;
  for (let index = 0; index < lines.length; index += 1) {
    const indentation = /^\s*/u.exec(lines[index])[0].length;
    if (index > 0 && indentation !== propertyIndentation) continue;
    const entry = index === 0
      ? /^\s*-\s+(?:uses|'uses'|"uses"):\s*(.*?)\s*$/u.exec(lines[index])
      : /^\s*(?:uses|'uses'|"uses"):\s*(.*?)\s*$/u.exec(lines[index]);
    if (entry) return yamlScalar(entry[1]);
  }
  return undefined;
}

function actionSteps(workflow, actionPrefix) {
  const normalizedPrefix = actionPrefix.toLowerCase();
  return workflowSteps(workflow)
    .filter((step) => actionStepUses(step)?.toLowerCase().startsWith(normalizedPrefix));
}

function verifiedActionSteps(workflow, actionPrefix, context = "workflow") {
  const steps = actionSteps(workflow, actionPrefix);
  const lexicalMentions = workflow.toLowerCase().split(actionPrefix.toLowerCase()).length - 1;
  assert.equal(
    steps.length,
    lexicalMentions,
    `${context} contains an ${actionPrefix} reference in unsupported YAML syntax`,
  );
  return steps;
}

function actionStepInputs(step) {
  const lines = step.split(/\r?\n/u);
  const stepIndentation = /^(\s*)-/u.exec(lines[0])?.[1].length;
  assert.notEqual(stepIndentation, undefined, "invalid workflow step fixture");
  const propertyIndentation = stepIndentation + 2;
  const withIndex = lines.findIndex((line) => {
    const match = /^(\s*)(?:with|'with'|"with"):\s*$/u.exec(line);
    return match && match[1].length === propertyIndentation;
  });
  if (withIndex < 0) return new Map();

  const inputs = new Map();
  for (let index = withIndex + 1; index < lines.length; index += 1) {
    if (lines[index].trim() === "") continue;
    const indentation = /^\s*/u.exec(lines[index])[0].length;
    if (indentation <= propertyIndentation) break;
    if (indentation !== propertyIndentation + 2) continue;
    const entry = /^\s*([A-Za-z0-9_-]+|'[^']+'|"[^"]+"):\s*(.*?)\s*$/u.exec(lines[index]);
    if (!entry) continue;
    inputs.set(yamlScalar(entry[1]), yamlScalar(entry[2]));
  }
  return inputs;
}

function actionStepBlockInputLines(step, inputName) {
  const lines = step.split(/\r?\n/u);
  for (let index = 0; index < lines.length; index += 1) {
    const entry = /^(\s*)([A-Za-z0-9_-]+):\s*\|\s*$/u.exec(lines[index]);
    if (!entry || entry[2] !== inputName) continue;
    const indentation = entry[1].length;
    const values = [];
    for (let valueIndex = index + 1; valueIndex < lines.length; valueIndex += 1) {
      if (lines[valueIndex].trim() === "") continue;
      const valueIndentation = /^\s*/u.exec(lines[valueIndex])[0].length;
      if (valueIndentation <= indentation) break;
      values.push(lines[valueIndex].slice(indentation + 2));
    }
    return values;
  }
  return undefined;
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

test("workflow action inspection covers concise and quoted YAML forms", () => {
  const workflow = `
jobs:
  probe:
    steps:
      - uses: 'actions/checkout@v7'
        with:
          'persist-credentials': 'false'
      - name: Quoted action and inputs
        "uses": "actions/setup-node@v7"
        "with":
          "cache": "npm"
      - name: Environment values are not action inputs
        uses: actions/setup-node@v7
        env:
          cache: npm
`;
  const checkoutSteps = verifiedActionSteps(workflow, "actions/checkout@", "parser fixture");
  assert.equal(checkoutSteps.length, 1);
  assert.equal(actionStepUses(checkoutSteps[0]), "actions/checkout@v7");
  assert.equal(actionStepInputs(checkoutSteps[0]).get("persist-credentials"), "false");

  const setupNodeSteps = verifiedActionSteps(workflow, "actions/setup-node@", "parser fixture");
  assert.equal(setupNodeSteps.length, 2);
  assert.equal(actionStepInputs(setupNodeSteps[0]).get("cache"), "npm");
  assert.equal(actionStepInputs(setupNodeSteps[1]).has("cache"), false);
  assert.equal(
    verifiedActionSteps(
      "steps:\n  - uses: Actions/Checkout@v7\n",
      "actions/checkout@",
      "mixed-case fixture",
    ).length,
    1,
  );

  for (const unsupported of [
    "steps:\n  - uses: 'actions/checkout@v4' # trailing comment\n",
    "steps:\n  - { uses: actions/checkout@v4 }\n",
  ]) {
    assert.throws(
      () => verifiedActionSteps(unsupported, "actions/checkout@", "unsupported fixture"),
      /unsupported YAML syntax/u,
    );
  }
});

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
  const setupNodeSteps = verifiedActionSteps(workflow, "actions/setup-node@", "Windows CI");
  assert.match(workflow, /\bpull_request\s*:/u);
  assert.equal(setupNodeSteps.length, 1);
  const setupNodeInputs = actionStepInputs(setupNodeSteps[0]);
  assert.equal(actionStepUses(setupNodeSteps[0]), "actions/setup-node@v7");
  assert.equal(setupNodeInputs.get("node-version"), "24.17.0");
  assert.equal(setupNodeInputs.get("cache"), "npm");
  assert.match(workflow, /npm run test:fast/u);
  assert.match(workflow, /\bpwsh\b/u);
  assert.match(workflow, /\bpowershell(?:\.exe)?\b/u);
});

test("GitHub workflows never persist checkout credentials", async () => {
  const workflowFiles = (await readdir(path.join(root, ".github", "workflows"), { withFileTypes: true }))
    .filter((entry) => entry.isFile() && /\.ya?ml$/iu.test(entry.name))
    .map((entry) => `.github/workflows/${entry.name}`)
    .sort();
  assert.ok(workflowFiles.length > 0, "repository has no GitHub workflows");
  let checkoutCount = 0;
  for (const relativePath of workflowFiles) {
    const workflow = await text(relativePath);
    const checkoutSteps = verifiedActionSteps(workflow, "actions/checkout@", relativePath);
    checkoutCount += checkoutSteps.length;
    for (const checkoutStep of checkoutSteps) {
      assert.equal(actionStepUses(checkoutStep), "actions/checkout@v7");
      assert.equal(
        actionStepInputs(checkoutStep).get("persist-credentials"),
        "false",
        `${relativePath} must disable persisted credentials on every checkout`,
      );
    }
  }
  assert.ok(checkoutCount > 0, "repository workflows contain no checkout steps");
});

test("release validation runs full suites under PowerShell 7 and Windows PowerShell 5.1", async () => {
  const workflow = await text(".github/workflows/release-validation.yml");
  const setupNodeSteps = verifiedActionSteps(workflow, "actions/setup-node@", "release validation");
  assert.match(workflow, /tags:[\s\S]*v\*/u);
  assert.equal(setupNodeSteps.length, 1);
  const setupNodeInputs = actionStepInputs(setupNodeSteps[0]);
  assert.equal(actionStepUses(setupNodeSteps[0]), "actions/setup-node@v7");
  assert.equal(setupNodeInputs.get("node-version"), "24.17.0");
  assert.equal(setupNodeInputs.get("package-manager-cache"), "false");
  assert.equal(setupNodeInputs.has("cache"), false);
  const nodeBindingStep = workflowSteps(workflow)
    .find((step) => step.includes("Bind MCP subprocess tests to setup-node"));
  assert.ok(nodeBindingStep, "release validation does not bind subprocess tests to setup-node");
  assert.match(
    nodeBindingStep,
    /\$nodeCommand\s*=\s*Get-Command node\.exe[\s\S]*\|\s*\n\s*Select-Object -First 1/u,
  );
  assert.match(nodeBindingStep, /\$nodePath\s*=\s*\[string\]\$nodeCommand\.Source/u);
  assert.match(workflow, /npm run test:release/u);
  assert.match(workflow, /Package-Portable\.ps1/u);
  assert.match(workflow, /SHA-256|sha256|Get-FileHash/u);
});

test("release packaging tests select one Node application on multi-install Windows runners", async () => {
  const script = await text("scripts/Test-PackagingRepairs.ps1");
  assert.match(
    script,
    /\$nodeCommand\s*=\s*Get-Command node\.exe -CommandType Application -ErrorAction Stop\s*\|\s*\n\s*Select-Object -First 1/u,
  );
  assert.match(script, /return \[string\]\$nodeCommand\.Source/u);
  assert.match(script, /\$visibleNodeCommands\.Count -ge 2/u);
  assert.match(script, /\$selectedNodeFixture -is \[string\]/u);
  assert.match(script, /Test-PinnedNodeRuntimePair -NodePath \$selectedNodeFixture/u);
});

test("release validation retains the exact verified ZIP and sidecar", async () => {
  const workflow = await text(".github/workflows/release-validation.yml");
  const buildIndex = workflow.indexOf("Build the portable package twice and compare SHA-256");
  const uploadIndex = workflow.indexOf("Retain verified release assets");
  assert.ok(buildIndex >= 0 && uploadIndex > buildIndex, "release assets are not retained after validation");

  const uploadSteps = verifiedActionSteps(workflow, "actions/upload-artifact@", "release validation");
  assert.equal(uploadSteps.length, 1);
  assert.equal(actionStepUses(uploadSteps[0]), "actions/upload-artifact@v7");
  const uploadInputs = actionStepInputs(uploadSteps[0]);
  assert.equal(uploadInputs.get("name"), "mql5-chm-mcp-release-${{ github.sha }}");
  assert.equal(uploadInputs.get("if-no-files-found"), "error");
  assert.equal(uploadInputs.get("retention-days"), "7");
  assert.equal(uploadInputs.get("compression-level"), "0");
  assert.deepEqual(actionStepBlockInputLines(uploadSteps[0], "path"), [
    "build/release-proof-first/mql5-chm-mcp-windows-x64.zip",
    "build/release-proof-first/mql5-chm-mcp-windows-x64.zip.manifest.json",
  ]);
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
