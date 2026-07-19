import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(scriptDir, "..");
const buildRoot = path.join(root, "build");
const productionApp = path.join(root, "app");
const expectedBundleNames = new Set(["indexer.mjs", "server.mjs"]);

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

async function validateBuildPlan(outdirArgument, metafileArgument) {
  const appDir = resolveConfined(outdirArgument, "--outdir");
  const metaPath = resolveConfined(metafileArgument, "--metafile");

  if (!isSamePath(appDir, productionApp) && !isStrictDescendant(buildRoot, appDir)) {
    throw new Error("--outdir must be the production app directory or a generated descendant of build.");
  }
  if (!isStrictDescendant(buildRoot, metaPath)) {
    throw new Error("--metafile must be a generated file beneath build.");
  }
  if (isSamePath(metaPath, appDir) || isStrictDescendant(appDir, metaPath)) {
    throw new Error("--metafile must be outside the bundle output directory.");
  }
  if (path.extname(metaPath).toLowerCase() !== ".json") {
    throw new Error("--metafile must name a JSON file.");
  }

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

  const metadataEntry = await lstatIfPresent(metaPath);
  if (metadataEntry && !metadataEntry.isFile()) {
    throw new Error("--metafile must not replace a directory or special filesystem entry.");
  }
  await validateExistingBundleDirectory(appDir);
  return { appDir, metaPath };
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

async function publishCandidate({ candidateApp, candidateMeta, appDir, metaPath }) {
  await mkdir(path.dirname(appDir), { recursive: true });
  await mkdir(path.dirname(metaPath), { recursive: true });
  await assertNoReparseAncestors(appDir, "--outdir");
  await assertNoReparseAncestors(metaPath, "--metafile");
  await validateExistingBundleDirectory(appDir);

  const transaction = randomUUID();
  const appBackup = path.join(path.dirname(appDir), `.${path.basename(appDir)}.backup-${transaction}`);
  const metaBackup = path.join(path.dirname(metaPath), `.${path.basename(metaPath)}.backup-${transaction}`);
  const appEntry = await lstatIfPresent(appDir);
  const metaEntry = await lstatIfPresent(metaPath);
  let appBackedUp = false;
  let metaBackedUp = false;
  let appInstalled = false;
  let metaInstalled = false;

  try {
    if (metaEntry) {
      await rename(metaPath, metaBackup);
      metaBackedUp = true;
    }
    if (appEntry) {
      await rename(appDir, appBackup);
      appBackedUp = true;
    }
    await rename(candidateApp, appDir);
    appInstalled = true;
    await rename(candidateMeta, metaPath);
    metaInstalled = true;
    await validateCandidate(appDir, metaPath);
  } catch (error) {
    const recoveryErrors = [];
    if (metaInstalled) {
      try { await rm(metaPath, { force: true }); } catch (recoveryError) { recoveryErrors.push(recoveryError); }
    }
    if (appInstalled) {
      try { await rm(appDir, { recursive: true, force: true }); } catch (recoveryError) { recoveryErrors.push(recoveryError); }
    }
    if (appBackedUp) {
      try { await rename(appBackup, appDir); } catch (recoveryError) { recoveryErrors.push(recoveryError); }
    }
    if (metaBackedUp) {
      try { await rename(metaBackup, metaPath); } catch (recoveryError) { recoveryErrors.push(recoveryError); }
    }
    if (recoveryErrors.length > 0) {
      throw new AggregateError(
        [error, ...recoveryErrors],
        `Bundle publication failed and automatic recovery was incomplete. Preserved backups: ${appBackup}; ${metaBackup}`,
      );
    }
    throw error;
  }

  for (const backup of [appBackup, metaBackup]) {
    try {
      await rm(backup, { recursive: true, force: true });
    } catch (error) {
      process.stderr.write(`Warning: published bundles but could not remove backup ${backup}: ${error.message}\n`);
    }
  }
}

const arguments_ = parseArguments(process.argv.slice(2));
const plan = await validateBuildPlan(arguments_.outdir, arguments_.metafile);
await mkdir(buildRoot, { recursive: true });
const candidateRoot = await mkdtemp(path.join(buildRoot, ".bundle-build-"));
const candidateApp = path.join(candidateRoot, "app");
const candidateMeta = path.join(candidateRoot, "esbuild-meta.json");

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
  await publishCandidate({ candidateApp, candidateMeta, ...plan });
} finally {
  await rm(candidateRoot, { recursive: true, force: true });
}
