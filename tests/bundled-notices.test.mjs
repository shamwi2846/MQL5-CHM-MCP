import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const generator = path.join(projectRoot, "scripts", "Generate-BundledNotices.mjs");

function writeJson(target, value) {
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function writePackage(root, relativeRoot, { name, version, license, licenseFile, licenseText }) {
  const packageRoot = path.join(root, ...relativeRoot.split("/"));
  mkdirSync(packageRoot, { recursive: true });
  writeJson(path.join(packageRoot, "package.json"), { name, version, license });
  writeFileSync(path.join(packageRoot, "index.js"), "export default true;\n", "utf8");
  if (licenseFile) writeFileSync(path.join(packageRoot, licenseFile), licenseText, "utf8");
}

function writeLockfile(root, packageEntries) {
  writeJson(path.join(root, "package-lock.json"), {
    name: "notice-fixture",
    version: "1.0.0",
    lockfileVersion: 3,
    requires: true,
    packages: {
      "": {
        name: "notice-fixture",
        version: "1.0.0",
      },
      ...packageEntries,
    },
  });
}

function runGenerator(root, mode, ...extraArguments) {
  return spawnSync(
    process.execPath,
    [
      generator,
      mode,
      "--project-root", root,
      "--metafile", path.join(root, "build", "meta.json"),
      "--output-dir", path.join(root, "licenses"),
      ...extraArguments,
    ],
    { cwd: root, encoding: "utf8", windowsHide: true, timeout: 300_000 },
  );
}

function createRoot() {
  const root = mkdtempSync(path.join(os.tmpdir(), "mql5-bundled-notices-"));
  writeJson(path.join(root, "package.json"), {
    name: "notice-fixture",
    version: "1.0.0",
    private: true,
  });
  mkdirSync(path.join(root, "src"), { recursive: true });
  writeFileSync(path.join(root, "src", "entry.js"), "export default true;\n", "utf8");
  return root;
}

test("write/check preserves nested package instances and exact bundle contributions", () => {
  const root = createRoot();
  try {
    writePackage(root, "node_modules/alpha", {
      name: "alpha",
      version: "1.0.0",
      license: "MIT",
      licenseFile: "LICENSE",
      licenseText: "alpha one\r\n",
    });
    writePackage(root, "node_modules/host/node_modules/alpha", {
      name: "alpha",
      version: "2.0.0",
      license: "Apache-2.0",
      licenseFile: "LICENSE.txt",
      licenseText: "alpha two\n",
    });
    writePackage(root, "node_modules/ignored", {
      name: "ignored",
      version: "9.0.0",
      license: "MIT",
    });
    writeLockfile(root, {
      "node_modules/alpha": {
        version: "1.0.0",
        resolved: "https://registry.npmjs.org/alpha/-/alpha-1.0.0.tgz",
        integrity: "sha512-fixture-alpha-one",
        license: "MIT",
      },
      "node_modules/host": {
        version: "5.0.0",
        resolved: "https://registry.npmjs.org/host/-/host-5.0.0.tgz",
        integrity: "sha512-fixture-host",
        dependencies: { alpha: "2.0.0" },
      },
      "node_modules/host/node_modules/alpha": {
        version: "2.0.0",
        resolved: "https://registry.npmjs.org/alpha/-/alpha-2.0.0.tgz",
        integrity: "sha512-fixture-alpha-two",
        license: "Apache-2.0",
      },
      "node_modules/ignored": {
        version: "9.0.0",
        resolved: "https://registry.npmjs.org/ignored/-/ignored-9.0.0.tgz",
        integrity: "sha512-fixture-ignored",
        license: "MIT",
      },
    });
    writeJson(path.join(root, "build", "meta.json"), {
      outputs: {
        "build/app/server.mjs": {
          inputs: {
            "src/entry.js": { bytesInOutput: 20 },
            "node_modules/alpha/index.js": { bytesInOutput: 7 },
            "node_modules/host/node_modules/alpha/index.js": { bytesInOutput: 3 },
            "node_modules/ignored/index.js": { bytesInOutput: 0 },
          },
        },
        "build/app/indexer.mjs": {
          inputs: {
            "node_modules/alpha/index.js": { bytesInOutput: 2 },
          },
        },
      },
    });

    const written = runGenerator(root, "--write");
    assert.equal(written.status, 0, `${written.stdout}\n${written.stderr}`);

    const manifestPath = path.join(root, "licenses", "bundled-node-dependencies.json");
    const noticesPath = path.join(root, "licenses", "BUNDLED-NODE-NOTICES.txt");
    const thirdPartyPath = path.join(root, "licenses", "THIRD-PARTY-NOTICES.md");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    assert.equal(manifest.schema_version, 1);
    assert.equal(manifest.metafile, "build/meta.json");
    assert.deepEqual(
      manifest.packages.map(({ name, version, instance, bundles }) => ({ name, version, instance, bundles })),
      [
        {
          name: "alpha",
          version: "1.0.0",
          instance: "node_modules/alpha",
          bundles: [
            { name: "indexer.mjs", bytes_in_output: 2 },
            { name: "server.mjs", bytes_in_output: 7 },
          ],
        },
        {
          name: "alpha",
          version: "2.0.0",
          instance: "node_modules/host/node_modules/alpha",
          bundles: [{ name: "server.mjs", bytes_in_output: 3 }],
        },
      ],
    );
    assert.doesNotMatch(JSON.stringify(manifest), /ignored/u);
    assert.match(readFileSync(noticesPath, "utf8"), /alpha one\n/u);
    assert.match(readFileSync(noticesPath, "utf8"), /alpha two\n/u);
    assert.match(readFileSync(thirdPartyPath, "utf8"), /node_modules\/host\/node_modules\/alpha/u);

    const original = [manifestPath, noticesPath, thirdPartyPath].map((target) => readFileSync(target));
    const checked = runGenerator(root, "--check");
    assert.equal(checked.status, 0, `${checked.stdout}\n${checked.stderr}`);

    const candidateMetafile = path.join(root, "build", "candidate-random", "meta.json");
    mkdirSync(path.dirname(candidateMetafile), { recursive: true });
    writeFileSync(candidateMetafile, readFileSync(path.join(root, "build", "meta.json")));
    const candidateChecked = spawnSync(
      process.execPath,
      [
        generator,
        "--check",
        "--project-root", root,
        "--metafile", candidateMetafile,
        "--metafile-label", "build/meta.json",
        "--output-dir", path.join(root, "licenses"),
      ],
      { cwd: root, encoding: "utf8", windowsHide: true, timeout: 300_000 },
    );
    assert.equal(candidateChecked.status, 0, `${candidateChecked.stdout}\n${candidateChecked.stderr}`);

    const rewritten = runGenerator(root, "--write");
    assert.equal(rewritten.status, 0, `${rewritten.stdout}\n${rewritten.stderr}`);
    assert.deepEqual(
      [manifestPath, noticesPath, thirdPartyPath].map((target) => readFileSync(target)),
      original,
      "a second write must be byte-identical",
    );

    writeFileSync(noticesPath, `${readFileSync(noticesPath, "utf8")}x`, "utf8");
    const drifted = runGenerator(root, "--check");
    assert.notEqual(drifted.status, 0);
    assert.match(drifted.stderr, /does not match generated content/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("missing notice text fails unless an exact checked-in override is supplied", () => {
  const root = createRoot();
  try {
    writePackage(root, "node_modules/beta", {
      name: "beta",
      version: "3.0.0",
      license: "MIT",
    });
    writeLockfile(root, {
      "node_modules/beta": {
        version: "3.0.0",
        resolved: "https://registry.npmjs.org/beta/-/beta-3.0.0.tgz",
        integrity: "sha512-fixture-beta",
        license: "MIT",
      },
    });
    writeJson(path.join(root, "build", "meta.json"), {
      outputs: {
        "build/app/server.mjs": {
          inputs: { "node_modules/beta/index.js": { bytesInOutput: 5 } },
        },
      },
    });

    const rejected = runGenerator(root, "--write");
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /has no root license or notice file/u);

    const overrideText = path.join(root, "licenses", "overrides", "beta-3.0.0.txt");
    mkdirSync(path.dirname(overrideText), { recursive: true });
    writeFileSync(overrideText, "explicit beta notice\n", "utf8");
    const overrides = path.join(root, "licenses", "bundled-node-notice-overrides.json");
    writeJson(overrides, {
      schema_version: 1,
      overrides: [
        {
          name: "beta",
          version: "3.0.0",
          instance: "node_modules/beta",
          notice_file: "licenses/overrides/beta-3.0.0.txt",
        },
      ],
    });

    const accepted = runGenerator(root, "--write", "--overrides", overrides);
    assert.equal(accepted.status, 0, `${accepted.stdout}\n${accepted.stderr}`);
    const manifest = JSON.parse(
      readFileSync(path.join(root, "licenses", "bundled-node-dependencies.json"), "utf8"),
    );
    assert.deepEqual(manifest.packages[0].notices, [
      {
        source: "licenses/overrides/beta-3.0.0.txt",
        sha256: manifest.packages[0].notices[0].sha256,
        override: true,
      },
    ]);
    assert.match(
      readFileSync(path.join(root, "licenses", "BUNDLED-NODE-NOTICES.txt"), "utf8"),
      /explicit beta notice/u,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("stale overrides and override paths outside the project fail closed", () => {
  const root = createRoot();
  try {
    writePackage(root, "node_modules/gamma", {
      name: "gamma",
      version: "4.0.0",
      license: "MIT",
      licenseFile: "LICENSE",
      licenseText: "upstream gamma notice\n",
    });
    writeLockfile(root, {
      "node_modules/gamma": {
        version: "4.0.0",
        resolved: "https://registry.npmjs.org/gamma/-/gamma-4.0.0.tgz",
        integrity: "sha512-fixture-gamma",
        license: "MIT",
      },
    });
    writeJson(path.join(root, "build", "meta.json"), {
      outputs: {
        "build/app/server.mjs": {
          inputs: { "node_modules/gamma/index.js": { bytesInOutput: 4 } },
        },
      },
    });
    const overrideText = path.join(root, "licenses", "overrides", "gamma-4.0.0.txt");
    mkdirSync(path.dirname(overrideText), { recursive: true });
    writeFileSync(overrideText, "stale gamma override\n", "utf8");
    const overrides = path.join(root, "licenses", "bundled-node-notice-overrides.json");
    writeJson(overrides, {
      schema_version: 1,
      overrides: [
        {
          name: "gamma",
          version: "4.0.0",
          instance: "node_modules/gamma",
          notice_file: "licenses/overrides/gamma-4.0.0.txt",
        },
      ],
    });

    const stale = runGenerator(root, "--write", "--overrides", overrides);
    assert.notEqual(stale.status, 0);
    assert.match(stale.stderr, /Unused notice override for gamma@4\.0\.0/u);

    writeJson(overrides, {
      schema_version: 1,
      overrides: [
        {
          name: "gamma",
          version: "4.0.0",
          instance: "node_modules/gamma",
          notice_file: "../outside-project.txt",
        },
      ],
    });
    const escaped = runGenerator(root, "--write", "--overrides", overrides);
    assert.notEqual(escaped.status, 0);
    assert.match(escaped.stderr, /must stay within the project root/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a bundled package missing its exact package-lock instance is rejected", () => {
  const root = createRoot();
  try {
    writePackage(root, "node_modules/delta", {
      name: "delta",
      version: "1.0.0",
      license: "MIT",
      licenseFile: "LICENSE",
      licenseText: "delta notice\n",
    });
    writeLockfile(root, {});
    writeJson(path.join(root, "build", "meta.json"), {
      outputs: {
        "build/app/server.mjs": {
          inputs: { "node_modules/delta/index.js": { bytesInOutput: 6 } },
        },
      },
    });

    const result = runGenerator(root, "--write");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /delta.*no exact package-lock\.json packages entry/iu);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("project-owned contributors are bound to the exact root lock identity", () => {
  const root = createRoot();
  try {
    writeJson(path.join(root, "package-lock.json"), {
      name: "notice-fixture",
      version: "2.0.0",
      lockfileVersion: 3,
      requires: true,
      packages: {
        "": {
          name: "notice-fixture",
          version: "2.0.0",
        },
      },
    });
    writeJson(path.join(root, "build", "meta.json"), {
      outputs: {
        "build/app/server.mjs": {
          inputs: { "src/entry.js": { bytesInOutput: 12 } },
        },
      },
    });

    const result = runGenerator(root, "--write");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /version mismatch for <root>/iu);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("package-lock name and version must match the installed contributor", () => {
  const root = createRoot();
  try {
    writePackage(root, "node_modules/epsilon", {
      name: "epsilon",
      version: "1.0.0",
      license: "MIT",
      licenseFile: "LICENSE",
      licenseText: "epsilon notice\n",
    });
    writeJson(path.join(root, "build", "meta.json"), {
      outputs: {
        "build/app/server.mjs": {
          inputs: { "node_modules/epsilon/index.js": { bytesInOutput: 8 } },
        },
      },
    });

    writeLockfile(root, {
      "node_modules/epsilon": {
        name: "not-epsilon",
        version: "1.0.0",
        resolved: "https://registry.npmjs.org/epsilon/-/epsilon-1.0.0.tgz",
        integrity: "sha512-fixture-epsilon",
      },
    });
    const wrongName = runGenerator(root, "--write");
    assert.notEqual(wrongName.status, 0);
    assert.match(wrongName.stderr, /name mismatch for node_modules\/epsilon/iu);

    writeLockfile(root, {
      "node_modules/epsilon": {
        version: "2.0.0",
        resolved: "https://registry.npmjs.org/epsilon/-/epsilon-2.0.0.tgz",
        integrity: "sha512-fixture-epsilon-wrong-version",
      },
    });
    const wrongVersion = runGenerator(root, "--write");
    assert.notEqual(wrongVersion.status, 0);
    assert.match(wrongVersion.stderr, /version mismatch for node_modules\/epsilon/iu);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a nested contributor cannot bind to a same-name lock entry at another instance", () => {
  const root = createRoot();
  try {
    writePackage(root, "node_modules/host/node_modules/zeta", {
      name: "zeta",
      version: "2.0.0",
      license: "MIT",
      licenseFile: "LICENSE",
      licenseText: "nested zeta notice\n",
    });
    writeLockfile(root, {
      "node_modules/host": {
        version: "1.0.0",
        resolved: "https://registry.npmjs.org/host/-/host-1.0.0.tgz",
        integrity: "sha512-fixture-host",
        dependencies: { zeta: "2.0.0" },
      },
      "node_modules/zeta": {
        version: "2.0.0",
        resolved: "https://registry.npmjs.org/zeta/-/zeta-2.0.0.tgz",
        integrity: "sha512-fixture-zeta-top-level",
        license: "MIT",
      },
    });
    writeJson(path.join(root, "build", "meta.json"), {
      outputs: {
        "build/app/server.mjs": {
          inputs: { "node_modules/host/node_modules/zeta/index.js": { bytesInOutput: 9 } },
        },
      },
    });

    const result = runGenerator(root, "--write");
    assert.notEqual(result.status, 0);
    assert.match(
      result.stderr,
      /node_modules\/host\/node_modules\/zeta.*no exact package-lock\.json packages entry/iu,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("case-colliding package-lock instances are rejected as ambiguous", () => {
  const root = createRoot();
  try {
    writePackage(root, "node_modules/theta", {
      name: "theta",
      version: "1.0.0",
      license: "MIT",
      licenseFile: "LICENSE",
      licenseText: "theta notice\n",
    });
    writeLockfile(root, {
      "node_modules/theta": {
        version: "1.0.0",
        resolved: "https://registry.npmjs.org/theta/-/theta-1.0.0.tgz",
        integrity: "sha512-fixture-theta-lower",
      },
      "node_modules/THETA": {
        name: "theta",
        version: "1.0.0",
        resolved: "https://registry.npmjs.org/theta/-/theta-1.0.0.tgz",
        integrity: "sha512-fixture-theta-upper",
      },
    });
    writeJson(path.join(root, "build", "meta.json"), {
      outputs: {
        "build/app/server.mjs": {
          inputs: { "node_modules/theta/index.js": { bytesInOutput: 5 } },
        },
      },
    });

    const result = runGenerator(root, "--write");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /ambiguous package instances/iu);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("checked-in notices match the clean-checkout candidate bundle metafile", () => {
  const result = spawnSync(
    process.execPath,
    [
      generator,
      "--check",
      "--project-root", projectRoot,
      "--metafile", path.join(projectRoot, "build", "candidate-v12", "esbuild-meta.json"),
      "--metafile-label", "build/esbuild-meta.json",
      "--output-dir", path.join(projectRoot, "licenses"),
    ],
    { cwd: projectRoot, encoding: "utf8", windowsHide: true, timeout: 300_000 },
  );
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /Verified notices for 24 bundled package instances\./u);
});
