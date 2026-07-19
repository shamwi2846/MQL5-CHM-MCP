import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";

const OUTPUT_NAMES = Object.freeze({
  manifest: "bundled-node-dependencies.json",
  notices: "BUNDLED-NODE-NOTICES.txt",
  thirdParty: "THIRD-PARTY-NOTICES.md",
});
const NOTICE_FILE_PATTERN = /^(?:license|licence|copying|notice)(?:[._-].*)?$/iu;

function fail(message) {
  throw new Error(message);
}

function compareText(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function parseArguments(arguments_) {
  let mode = null;
  let projectRoot = process.cwd();
  let metafile = null;
  let metafileLabel = null;
  let outputDirectory = null;
  let overrides = null;

  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--write" || argument === "--check") {
      if (mode !== null) fail("Specify exactly one of --write or --check.");
      mode = argument.slice(2);
      continue;
    }
    if (!["--project-root", "--metafile", "--metafile-label", "--output-dir", "--overrides"].includes(argument)) {
      fail(`Unknown argument: ${argument}`);
    }
    const value = arguments_[index + 1];
    if (value === undefined || value.startsWith("--")) fail(`${argument} requires a path.`);
    index += 1;
    if (argument === "--project-root") projectRoot = path.resolve(process.cwd(), value);
    if (argument === "--metafile") metafile = path.resolve(process.cwd(), value);
    if (argument === "--metafile-label") metafileLabel = value;
    if (argument === "--output-dir") outputDirectory = path.resolve(process.cwd(), value);
    if (argument === "--overrides") overrides = path.resolve(process.cwd(), value);
  }

  if (mode === null) fail("Specify exactly one of --write or --check.");
  if (metafile === null) fail("--metafile is required.");
  projectRoot = path.resolve(projectRoot);
  outputDirectory ??= path.join(projectRoot, "licenses");
  if (metafileLabel === null) {
    metafileLabel = relativeWithin(projectRoot, metafile, "esbuild metafile");
  } else {
    metafileLabel = metafileLabel.replaceAll("\\", "/");
    if (
      metafileLabel.length === 0 || metafileLabel.startsWith("/") || /^[A-Za-z]:/u.test(metafileLabel) ||
      metafileLabel.split("/").some((part) => part === "" || part === "." || part === "..") ||
      path.posix.normalize(metafileLabel) !== metafileLabel
    ) {
      fail("--metafile-label must be a normalized project-relative logical path.");
    }
  }
  const defaultOverrides = path.join(outputDirectory, "bundled-node-notice-overrides.json");
  if (overrides === null && existsSync(defaultOverrides)) overrides = defaultOverrides;
  return {
    mode,
    projectRoot,
    metafile: path.resolve(metafile),
    metafileLabel,
    outputDirectory: path.resolve(outputDirectory),
    overrides: overrides === null ? null : path.resolve(overrides),
  };
}

function relativeWithin(root, target, description) {
  const relative = path.relative(root, target);
  if (relative === "" && description !== "project root") return "";
  if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${description} must stay within the project root: ${target}`);
  }
  return relative.split(path.sep).join("/");
}

function readJson(target, description) {
  let text;
  try {
    text = readFileSync(target, "utf8");
  } catch (error) {
    fail(`Unable to read ${description} '${target}': ${error.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    fail(`Invalid ${description} '${target}': ${error.message}`);
  }
}

function requireObject(value, description) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    fail(`${description} must be a JSON object.`);
  }
  return value;
}

function requireString(value, description) {
  if (typeof value !== "string" || value.length === 0) fail(`${description} must be a non-empty string.`);
  return value;
}

function normalizeNoticeText(text, source) {
  if (text.includes("\0")) fail(`Notice source '${source}' contains a NUL byte.`);
  const normalized = text
    .replace(/^\uFEFF/u, "")
    .replace(/\r\n?/gu, "\n")
    .replace(/[ \t]+$/gmu, "")
    .trimEnd();
  if (normalized.length === 0) fail(`Notice source '${source}' is empty.`);
  return `${normalized}\n`;
}

function sha256(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function readOverrides(options) {
  if (options.overrides === null) return new Map();
  relativeWithin(options.projectRoot, options.overrides, "override manifest");
  const document = requireObject(readJson(options.overrides, "override manifest"), "Override manifest");
  if (document.schema_version !== 1) fail("Override manifest schema_version must be 1.");
  if (!Array.isArray(document.overrides)) fail("Override manifest overrides must be an array.");

  const result = new Map();
  for (const [index, raw] of document.overrides.entries()) {
    const entry = requireObject(raw, `Override ${index}`);
    const name = requireString(entry.name, `Override ${index} name`);
    const version = requireString(entry.version, `Override ${index} version`);
    const instance = requireString(entry.instance, `Override ${index} instance`).replaceAll("\\", "/");
    const noticeFile = requireString(entry.notice_file, `Override ${index} notice_file`);
    if (path.isAbsolute(instance) || instance === ".." || instance.startsWith("../")) {
      fail(`Override ${index} instance must be a project-relative package path.`);
    }
    const key = `${name}\0${version}\0${instance}`;
    if (result.has(key)) fail(`Duplicate override for ${name}@${version} at ${instance}.`);
    const noticePath = path.resolve(options.projectRoot, ...noticeFile.replaceAll("\\", "/").split("/"));
    const noticeSource = relativeWithin(options.projectRoot, noticePath, `Override notice for ${name}@${version}`);
    if (!existsSync(noticePath) || !statSync(noticePath).isFile()) {
      fail(`Override notice file does not exist: ${noticeSource}`);
    }
    result.set(key, {
      name,
      version,
      instance,
      license: entry.license === undefined ? null : requireString(entry.license, `Override ${index} license`),
      noticePath,
      noticeSource,
      used: false,
    });
  }
  return result;
}

function packageKey(name, version, instance) {
  return `${name}\0${version}\0${instance}`;
}

function packageNameFromLockInstance(instance) {
  const parts = instance.split("/");
  const nodeModulesIndex = parts.lastIndexOf("node_modules");
  if (nodeModulesIndex < 0) return null;
  const packageParts = parts.slice(nodeModulesIndex + 1);
  if (
    packageParts.length === 1 &&
    packageParts[0].length > 0 &&
    !packageParts[0].startsWith("@")
  ) {
    return packageParts[0];
  }
  if (
    packageParts.length === 2 &&
    /^@[^/]+$/u.test(packageParts[0]) &&
    packageParts[1].length > 0
  ) {
    return `${packageParts[0]}/${packageParts[1]}`;
  }
  fail(`package-lock.json contains an invalid package instance path: ${instance}`);
}

function readLockedPackageInstances(projectRoot) {
  const lockPath = path.join(projectRoot, "package-lock.json");
  const lock = requireObject(readJson(lockPath, "package lock"), "Package lock");
  if (!Number.isSafeInteger(lock.lockfileVersion) || lock.lockfileVersion < 2) {
    fail("package-lock.json lockfileVersion must be an integer of at least 2.");
  }
  const rawPackages = requireObject(lock.packages, "package-lock.json packages");
  requireObject(rawPackages[""], "package-lock.json root package");

  const instances = new Map();
  const caseInsensitiveOwners = new Map();
  for (const [instance, rawEntry] of Object.entries(rawPackages)) {
    if (instance !== "" && (
      instance.includes("\\") ||
      instance.startsWith("/") ||
      /^[A-Za-z]:/u.test(instance) ||
      instance.split("/").some((part) => part === "" || part === "." || part === "..") ||
      path.posix.normalize(instance) !== instance
    )) {
      fail(`package-lock.json contains an invalid package instance path: ${instance}`);
    }

    const inferredName = instance === "" ? null : packageNameFromLockInstance(instance);
    const foldedInstance = instance.toLocaleLowerCase("en-US");
    const previousOwner = caseInsensitiveOwners.get(foldedInstance);
    if (previousOwner !== undefined && previousOwner !== instance) {
      fail(
        `package-lock.json contains ambiguous package instances '${previousOwner}' and '${instance}'.`,
      );
    }
    caseInsensitiveOwners.set(foldedInstance, instance);

    const entry = requireObject(rawEntry, `package-lock.json package '${instance}'`);
    instances.set(instance, { instance, inferredName, entry });
  }
  return instances;
}

function bindPackageInstanceToLock(lockedInstances, resolved, inputName) {
  const name = requireString(resolved.packageJson.name, `Package name for ${resolved.instance}`);
  const version = requireString(resolved.packageJson.version, `Package version for ${resolved.instance}`);
  const instanceLabel = resolved.instance === "" ? "<root>" : resolved.instance;
  const locked = lockedInstances.get(resolved.instance);
  if (locked === undefined) {
    fail(
      `Bundled input '${inputName}' resolves to ${instanceLabel}, which has no exact package-lock.json packages entry.`,
    );
  }
  if (locked.entry.link === true) {
    fail(
      `package-lock.json package '${instanceLabel}' is a link and has no exact locked package identity.`,
    );
  }
  const lockedName = locked.entry.name === undefined
    ? requireString(locked.inferredName, `package-lock.json name for '${instanceLabel}'`)
    : requireString(locked.entry.name, `package-lock.json name for '${instanceLabel}'`);
  const lockedVersion = requireString(
    locked.entry.version,
    `package-lock.json version for '${instanceLabel}'`,
  );
  if (lockedName !== name) {
    fail(
      `package-lock.json name mismatch for ${instanceLabel}: locked '${lockedName}', installed '${name}'.`,
    );
  }
  if (lockedVersion !== version) {
    fail(
      `package-lock.json version mismatch for ${instanceLabel}: locked '${lockedVersion}', installed '${version}'.`,
    );
  }
  return { name, version };
}

function findPackageInstance(projectRoot, inputPath, inputName) {
  const relativeInput = relativeWithin(projectRoot, inputPath, `Metafile input '${inputName}'`);
  if (!existsSync(inputPath)) fail(`Bundled input does not exist: ${relativeInput}`);

  let directory = statSync(inputPath).isDirectory() ? inputPath : path.dirname(inputPath);
  while (true) {
    const packageJsonPath = path.join(directory, "package.json");
    if (existsSync(packageJsonPath) && statSync(packageJsonPath).isFile()) {
      const packageJson = requireObject(readJson(packageJsonPath, "package metadata"), "Package metadata");
      if (
        typeof packageJson.name === "string" && packageJson.name.length > 0 &&
        typeof packageJson.version === "string" && packageJson.version.length > 0
      ) {
        const instance = relativeWithin(projectRoot, directory, `Package root for '${inputName}'`);
        return { root: directory, instance, packageJson };
      }
    }
    if (directory === projectRoot) break;
    const parent = path.dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  fail(`Unable to resolve bundled input '${inputName}' to a named package instance.`);
}

function discoverContributors(options) {
  relativeWithin(options.projectRoot, options.metafile, "esbuild metafile");
  const metafile = requireObject(readJson(options.metafile, "esbuild metafile"), "Esbuild metafile");
  const outputs = requireObject(metafile.outputs, "Esbuild metafile outputs");
  const lockedInstances = readLockedPackageInstances(options.projectRoot);
  const packages = new Map();
  const bundleOwners = new Map();

  for (const [outputName, rawOutput] of Object.entries(outputs).sort(([left], [right]) => compareText(left, right))) {
    const output = requireObject(rawOutput, `Metafile output '${outputName}'`);
    const inputs = requireObject(output.inputs ?? {}, `Metafile output '${outputName}' inputs`);
    const bundleName = path.posix.basename(outputName.replaceAll("\\", "/"));
    if (bundleName.length === 0) fail(`Metafile output has no file name: ${outputName}`);
    const previousOutput = bundleOwners.get(bundleName);
    if (previousOutput !== undefined && previousOutput !== outputName) {
      fail(`Metafile contains duplicate bundle basename '${bundleName}'.`);
    }
    bundleOwners.set(bundleName, outputName);

    for (const [inputName, rawContribution] of Object.entries(inputs).sort(([left], [right]) => compareText(left, right))) {
      const contribution = requireObject(rawContribution, `Contribution for '${inputName}'`);
      const bytes = contribution.bytesInOutput ?? 0;
      if (!Number.isSafeInteger(bytes) || bytes < 0) {
        fail(`bytesInOutput for '${inputName}' in '${outputName}' must be a non-negative safe integer.`);
      }
      if (bytes === 0) continue;
      const inputPath = path.isAbsolute(inputName)
        ? path.resolve(inputName)
        : path.resolve(options.projectRoot, ...inputName.replaceAll("\\", "/").split("/"));
      const resolved = findPackageInstance(options.projectRoot, inputPath, inputName);
      const { name, version } = bindPackageInstanceToLock(lockedInstances, resolved, inputName);
      if (!resolved.instance.split("/").includes("node_modules")) continue;
      let record = packages.get(resolved.instance);
      if (record === undefined) {
        record = {
          name,
          version,
          instance: resolved.instance,
          root: resolved.root,
          packageJson: resolved.packageJson,
          bundles: new Map(),
        };
        packages.set(resolved.instance, record);
      } else if (record.name !== name || record.version !== version) {
        fail(`Package identity changed while reading ${resolved.instance}.`);
      }
      record.bundles.set(bundleName, (record.bundles.get(bundleName) ?? 0) + bytes);
    }
  }

  return [...packages.values()].sort((left, right) =>
    compareText(left.name, right.name) ||
    compareText(left.version, right.version) ||
    compareText(left.instance, right.instance));
}

function collectNotices(options, contributors, overrides) {
  const packages = [];
  const noticeBodies = new Map();

  for (const contributor of contributors) {
    const licenseFiles = readdirSync(contributor.root, { withFileTypes: true })
      .filter((entry) => entry.isFile() && NOTICE_FILE_PATTERN.test(entry.name))
      .map((entry) => entry.name)
      .sort(compareText);
    const key = packageKey(contributor.name, contributor.version, contributor.instance);
    const override = overrides.get(key);
    let license = typeof contributor.packageJson.license === "string" && contributor.packageJson.license.length > 0
      ? contributor.packageJson.license
      : null;
    let sources;

    if (licenseFiles.length > 0) {
      sources = licenseFiles.map((fileName) => ({
        path: path.join(contributor.root, fileName),
        source: relativeWithin(options.projectRoot, path.join(contributor.root, fileName), "Package notice"),
        override: false,
      }));
    } else if (override !== undefined) {
      override.used = true;
      license = override.license ?? license;
      sources = [{ path: override.noticePath, source: override.noticeSource, override: true }];
    } else {
      fail(
        `${contributor.name}@${contributor.version} at ${contributor.instance} has no root license or notice file; ` +
        "add an exact-instance checked-in override.",
      );
    }
    if (license === null) {
      fail(`${contributor.name}@${contributor.version} at ${contributor.instance} has no license expression.`);
    }

    const notices = sources.map((source) => {
      const text = normalizeNoticeText(readFileSync(source.path, "utf8"), source.source);
      const manifestNotice = { source: source.source, sha256: sha256(text) };
      if (source.override) manifestNotice.override = true;
      noticeBodies.set(`${key}\0${source.source}`, text);
      return manifestNotice;
    });
    packages.push({
      name: contributor.name,
      version: contributor.version,
      instance: contributor.instance,
      license,
      bundles: [...contributor.bundles.entries()]
        .sort(([left], [right]) => compareText(left, right))
        .map(([name, bytes]) => ({ name, bytes_in_output: bytes })),
      notices,
    });
  }

  const unused = [...overrides.values()].filter((entry) => !entry.used);
  if (unused.length > 0) {
    const entry = unused[0];
    fail(`Unused notice override for ${entry.name}@${entry.version} at ${entry.instance}.`);
  }
  return { packages, noticeBodies };
}

function renderManifest(options, packages) {
  return `${JSON.stringify({
    schema_version: 1,
    metafile: options.metafileLabel,
    package_count: packages.length,
    packages,
  }, null, 2)}\n`;
}

function renderNotices(options, packages, noticeBodies) {
  const lines = [
    "Bundled Node Dependency Notices",
    "================================",
    "",
    `Generated deterministically from ${options.metafileLabel}.`,
    "Only package instances contributing nonzero bytes to a distributed JavaScript bundle are included.",
    "Do not edit this file directly.",
    "",
  ];
  for (const entry of packages) {
    lines.push(
      "================================================================================",
      `Package: ${entry.name}`,
      `Version: ${entry.version}`,
      `Instance: ${entry.instance}`,
      `License: ${entry.license}`,
      `Bundles: ${entry.bundles.map((bundle) => `${bundle.name} (${bundle.bytes_in_output} bytes)`).join(", ")}`,
      `Notice sources: ${entry.notices.map((notice) => notice.source).join(", ")}`,
      "================================================================================",
      "",
    );
    for (const notice of entry.notices) {
      lines.push(`----- ${notice.source} -----`, "");
      const key = `${packageKey(entry.name, entry.version, entry.instance)}\0${notice.source}`;
      lines.push(noticeBodies.get(key).trimEnd(), "");
    }
  }
  return `${lines.join("\n").trimEnd()}\n`;
}

function markdownCode(value) {
  return `\`${String(value).replaceAll("`", "\\`").replaceAll("|", "\\|")}\``;
}

function renderThirdParty(options, packages) {
  const lines = [
    "# Third-Party Notices",
    "",
    "This private portable package contains the following third-party software. Full license texts are retained in this directory.",
    "",
    "## Bundled JavaScript dependencies",
    "",
    `This table is generated from ${markdownCode(options.metafileLabel)}. It includes only package instances contributing nonzero bytes to a distributed bundle. Complete texts are in ${markdownCode(OUTPUT_NAMES.notices)}.`,
    "",
    "| Package | Version | Instance | Bundles | License |",
    "|---|---:|---|---|---|",
  ];
  for (const entry of packages) {
    lines.push(
      `| ${markdownCode(entry.name)} | ${markdownCode(entry.version)} | ${markdownCode(entry.instance)} | ` +
      `${entry.bundles.map((bundle) => markdownCode(bundle.name)).join(", ")} | ${markdownCode(entry.license)} |`,
    );
  }
  lines.push(
    "",
    "The machine-readable inventory, exact package-instance paths, bundle byte contributions, notice sources, and normalized notice hashes are in `bundled-node-dependencies.json`.",
    "",
    "## Other packaged third-party components",
    "",
    "| Component | Use | License text |",
    "|---|---|---|",
    "| Node.js | Bundled JavaScript runtime, including its bundled third-party notices | `NODE-LICENSE.txt` |",
    "| esbuild | Build-time JavaScript bundler | `ESBUILD-LICENSE.txt` |",
    "| SQLite / FTS5 | Included with the bundled Node.js runtime | Included in `NODE-LICENSE.txt` |",
    "| 7-Zip | Command-line CHM extraction fallback | `7ZIP-LICENSE.txt` |",
    "",
    "The three CHM documentation files are user-supplied local MetaQuotes documentation and are included only for the user's personal transfer between computers. This project does not define a public redistribution workflow for them.",
    "",
    "7-Zip source code and licensing information are available from <https://www.7-zip.org/>.",
    "",
  );
  return lines.join("\n");
}

function expectedOutputs(options) {
  const overrides = readOverrides(options);
  const contributors = discoverContributors(options);
  const { packages, noticeBodies } = collectNotices(options, contributors, overrides);
  return {
    packages,
    files: new Map([
      [OUTPUT_NAMES.manifest, Buffer.from(renderManifest(options, packages), "utf8")],
      [OUTPUT_NAMES.notices, Buffer.from(renderNotices(options, packages, noticeBodies), "utf8")],
      [OUTPUT_NAMES.thirdParty, Buffer.from(renderThirdParty(options, packages), "utf8")],
    ]),
  };
}

function writeOutputs(options, files) {
  mkdirSync(options.outputDirectory, { recursive: true });
  for (const [name, content] of files) writeFileSync(path.join(options.outputDirectory, name), content);
}

function checkOutputs(options, files) {
  for (const [name, expected] of files) {
    const target = path.join(options.outputDirectory, name);
    if (!existsSync(target) || !statSync(target).isFile()) fail(`Generated output is missing: ${target}`);
    const actual = readFileSync(target);
    if (!actual.equals(expected)) fail(`Generated output does not match generated content: ${target}`);
  }
}

try {
  const options = parseArguments(process.argv.slice(2));
  relativeWithin(options.projectRoot, options.projectRoot, "project root");
  relativeWithin(options.projectRoot, options.outputDirectory, "output directory");
  const { packages, files } = expectedOutputs(options);
  if (options.mode === "write") writeOutputs(options, files);
  else checkOutputs(options, files);
  const verb = options.mode === "write" ? "Wrote" : "Verified";
  process.stdout.write(`${verb} notices for ${packages.length} bundled package instances.\n`);
} catch (error) {
  process.stderr.write(`Generate-BundledNotices: ${error.message}\n`);
  process.exitCode = 1;
}
