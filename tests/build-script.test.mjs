import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const buildScript = path.join(projectRoot, "scripts", "build.mjs");
const testRoot = path.join(projectRoot, "build", "build-script-regression");

function runBuild(...arguments_) {
  return spawnSync(process.execPath, [buildScript, ...arguments_], {
    cwd: projectRoot,
    encoding: "utf8",
    windowsHide: true,
  });
}

function removeGenerated(target) {
  rmSync(target, { recursive: true, force: true });
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

test("the normal test workflow builds and exercises a candidate before production publication", () => {
  const packageJson = JSON.parse(readFileSync(path.join(projectRoot, "package.json"), "utf8"));
  assert.equal(packageJson.scripts.pretest, "npm run build:candidate");
  assert.match(
    readFileSync(path.join(projectRoot, "tests", "mcp.test.mjs"), "utf8"),
    /build["'],\s*["']candidate-v12["'],\s*["']app["'],\s*["']server\.mjs["']/u,
  );
});
