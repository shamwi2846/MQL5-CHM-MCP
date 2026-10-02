import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { buildFixture } from "./helpers/runtime-fixture.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const packageVersion = JSON.parse(await readFile(path.join(repository, "package.json"), "utf8")).version;
const peerSkill = process.env.MQL5_HEALTH_SKILL_ROOT;
const skillVersion = peerSkill ? JSON.parse(await readFile(path.join(peerSkill, "version.json"), "utf8")).version : null;
const python = process.env.MQL5_HEALTH_PYTHON;
const hash = bytes => createHash("sha256").update(bytes).digest("hex");

async function inventory(root, prefix = "") {
  const entries = {};
  for (const file of await readdir(root, { withFileTypes: true })) {
    const relative = `${prefix}${file.name}`;
    assert.ok(!file.isSymbolicLink(), "Test fixture must not contain links");
    if (file.isDirectory()) Object.assign(entries, await inventory(path.join(root, file.name), `${relative}/`));
    else entries[relative] = hash(await readFile(path.join(root, file.name)));
  }
  return Object.fromEntries(Object.entries(entries).sort(([a], [b]) => a.localeCompare(b)));
}

const fakeSource = `
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
using System.Reflection;
[assembly: AssemblyFileVersion("5.0.0.6230")]
[assembly: AssemblyDescription("MetaEditor 5")]
[assembly: AssemblyTitle("MetaEditor 5")]
public class FakeCodex {
  public static int Main(string[] args) {
    string state = Environment.GetEnvironmentVariable("MQL5_HEALTH_FAKE_STATE");
    if (args.Length == 1 && args[0] == "--version") { Console.WriteLine("codex-cli 0.159.0"); return 0; }
    if (args.Length == 4 && args[0] == "mcp" && args[1] == "get" && args[2] == "mql5-chm" && args[3] == "--json") {
      // Verify the selected directory, allowing Windows short/long path aliases.
      string home = Environment.GetEnvironmentVariable("CODEX_HOME");
      if (home == null || File.ReadAllText(Path.Combine(home, "health-home-marker.txt")) != File.ReadAllText(Path.Combine(state, "home.txt"))) return 9;
      string mode = File.ReadAllText(Path.Combine(state, "mode.txt"));
      if (mode == "timeout") { File.WriteAllText(Path.Combine(state, "pid.txt"), Process.GetCurrentProcess().Id.ToString()); Thread.Sleep(30000); }
      if (mode == "malformed") { Console.WriteLine("SENSITIVE_TEST_VALUE invalid-json"); return 0; }
      if (mode == "unavailable") { Console.Error.WriteLine("SENSITIVE_TEST_VALUE failed-query"); return 1; }
      Console.WriteLine(File.ReadAllText(Path.Combine(state, "registration.json"))); return 0;
    }
    File.WriteAllText(Path.Combine(state, "editor-executed.txt"), "unexpected"); return 7;
  }
}
`;

for (const shell of ["pwsh.exe", "powershell.exe"]) {
  test(`environment health with a real MCP bundle under ${shell}`, { skip: process.platform !== "win32", timeout: 300_000 }, async t => {
    assert.ok(peerSkill && path.isAbsolute(peerSkill), "Set MQL5_HEALTH_SKILL_ROOT to the actual counterpart skill directory");
    assert.ok(python && path.isAbsolute(python), "Set MQL5_HEALTH_PYTHON to a Python executable with PyYAML");
    const fixture = await buildFixture();
    const temporary = await mkdtemp(path.join(tmpdir(), "mql5-health tests "));
    t.after(async () => { await rm(temporary, { recursive: true, force: true }); await rm(fixture.root, { recursive: true, force: true }); });
    const skill = path.join(temporary, "installed skill");
    const sourceSkill = path.join(temporary, "source skill");
    const sourceMcp = path.join(temporary, "source mcp");
    const state = path.join(temporary, "probe state");
    const codexHome = path.join(temporary, "codex home");
    await cp(peerSkill, skill, { recursive: true });
    await cp(peerSkill, sourceSkill, { recursive: true });
    for (const directory of [sourceMcp, state, codexHome, path.join(fixture.root, "runtime"), path.join(fixture.root, "app"), path.join(fixture.root, "scripts")]) await mkdir(directory, { recursive: true });
    await cp(process.execPath, path.join(fixture.root, "runtime/node.exe"));
    await cp(path.join(repository, "build/candidate-v12/app/server.mjs"), path.join(fixture.root, "app/server.mjs"));
    await cp(path.join(repository, "scripts/Smoke-Test-McpServer.mjs"), path.join(fixture.root, "scripts/Smoke-Test-McpServer.mjs"));
    await cp(path.join(repository, "package.json"), path.join(fixture.root, "package.json"));
    await writeFile(path.join(fixture.root, "README.md"), "health fixture\n");
    const packageFiles = await inventory(fixture.root);
    const checksumText = Object.entries(packageFiles).map(([name, sha]) => `${sha} *${name}\n`).join("");
    await writeFile(path.join(fixture.root, "checksums.sha256"), checksumText);
    for (const name of ["package.json", "README.md"]) await cp(path.join(fixture.root, name), path.join(sourceMcp, name));
    const homeMarker = hash(Buffer.from(codexHome));
    await writeFile(path.join(state, "home.txt"), homeMarker);
    await writeFile(path.join(codexHome, "health-home-marker.txt"), homeMarker);
    await writeFile(path.join(state, "mode.txt"), "valid");
    const cs = path.join(temporary, "FakeCodex.cs");
    const codex = path.join(temporary, "codex.exe");
    const editor = path.join(temporary, "metaeditor64.exe");
    await writeFile(cs, fakeSource);
    const csc = path.join(process.env.WINDIR, "Microsoft.NET/Framework64/v4.0.30319/csc.exe");
    execFileSync(csc, ["/nologo", `/out:${codex}`, cs], { windowsHide: true, timeout: 30_000 });
    await cp(codex, editor);
    const mt4 = path.join(temporary, "MT4");
    await mkdir(mt4);
    await cp(codex, path.join(mt4, "metaeditor64.exe"));
    const mt4Source = path.join(temporary, "FakeMt4.cs");
    await writeFile(mt4Source, fakeSource.replace('AssemblyFileVersion("5.0.0.6230")', 'AssemblyFileVersion("4.0.0.2418")'));
    execFileSync(csc, ["/nologo", `/out:${path.join(mt4, "terminal.exe")}`, mt4Source], { windowsHide: true, timeout: 30_000 });
    const health = path.join(peerSkill, "scripts/Test-Mql5Environment.ps1");
    const registration = { name: "mql5-chm", enabled: true, enabled_tools: null, disabled_tools: null, transport: { type: "stdio", command: path.join(fixture.root, "runtime/node.exe"), args: [path.join(fixture.root, "app/server.mjs")], cwd: fixture.root, env: null, env_vars: [] } };
    const saveRegistration = async value => writeFile(path.join(state, "registration.json"), JSON.stringify(value));
    await saveRegistration(registration);
    function run(extra = [], expected = 0) {
      const started = Date.now();
      const parameters = new Map([["-WorkspaceRoot", temporary], ["-CodexHome", codexHome], ["-CodexPath", codex], ["-McpPackageRoot", fixture.root],
        ["-SkillRoot", skill], ["-SkillSourceRoot", sourceSkill], ["-McpSourceRoot", sourceMcp], ["-MetaEditorPath", editor], ["-PythonPath", python], ["-TimeoutSeconds", "5"]]);
      const switches = ["-Json"];
      for (let index = 0; index < extra.length; index += 1) {
        if (["-RequireCompiler", "-RequirePython"].includes(extra[index])) switches.push(extra[index]);
        else { parameters.set(extra[index], extra[index + 1]); index += 1; }
      }
      const result = spawnSync(shell, ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", health, ...[...parameters].flat(), ...switches],
      { cwd: repository, encoding: "utf8", windowsHide: true, timeout: 35_000, env: { ...process.env, MQL5_HEALTH_FAKE_STATE: state, MQL5_CHM_MCP_ROOT: path.join(temporary, "unused ambient override") } });
      assert.ifError(result.error);
      assert.equal(result.status, expected, result.stdout + result.stderr);
      assert.ok(!`${result.stdout}${result.stderr}`.includes("SENSITIVE_TEST_VALUE"), "Probe/config secrets escaped the report");
      assert.equal(result.stderr, "", "JSON mode leaked diagnostics on stderr");
      const report = JSON.parse(result.stdout.replace(/^\uFEFF/u, ""));
      assert.equal(report.exit_code, expected);
      assert.equal(report.schema_version, 1);
      return { report, elapsed: Date.now() - started };
    }
    const codes = report => report.issues.map(issue => issue.code);
    const originalPackage = await inventory(fixture.root);
    const originalSkill = await inventory(skill);

    await t.test("healthy package, registration, source, editor metadata and Python", () => {
      const { report } = run(["-RequireCompiler", "-RequirePython"]);
      assert.equal(report.status, "passed");
      assert.equal(report.codex.version, "0.159.0");
      assert.equal(report.codex.native_chat_availability, "not_checked");
      assert.equal(report.mcp.stdio_available, true);
      assert.equal(report.mcp.integrity, "passed");
      assert.equal(report.mcp.package_version, packageVersion);
      assert.equal(report.mcp.node_version, "v24.17.0");
      assert.equal(report.mcp.index_revision, fixture.databaseHash);
      assert.equal(report.mcp.checked_files, Object.keys(packageFiles).length);
      assert.equal(report.mcp.source_comparison.status, "same");
      assert.equal(report.skill.source_comparison.status, "same");
      assert.equal(report.skill.file_count, 21);
      assert.equal(report.skill.declared_version, skillVersion);
      assert.match(report.skill.fingerprint_sha256, /^[0-9a-f]{64}$/u);
      assert.equal(report.skill.fingerprint_sha256, hash(Buffer.from(Object.keys(originalSkill).sort().map(name => `${name}\0${originalSkill[name]}`).join("\n"))), "Inventory fingerprints must agree across PowerShell versions");
      assert.equal(report.metaeditor.candidates[0].build, 6230);
      assert.equal(report.python.available, true);
      assert.equal(report.python.pyyaml_available, true);
    });
    await t.test("missing optional tools warn or fail when required", () => {
      const missing = path.join(temporary, "missing.exe");
      const { report } = run(["-MetaEditorPath", missing, "-PythonPath", missing]);
      assert.equal(report.status, "warning");
      assert.deepEqual(codes(report).sort(), ["metaeditor_missing", "python_unavailable"]);
      assert.equal(run(["-MetaEditorPath", missing, "-PythonPath", missing, "-RequireCompiler", "-RequirePython"], 1).report.status, "failed");
    });
    await t.test("MT4-associated editor is excluded despite editor version 5", () => {
      const { report } = run(["-MetaEditorPath", path.join(mt4, "metaeditor64.exe"), "-RequireCompiler"], 1);
      assert.equal(report.metaeditor.available, false);
      assert.ok(codes(report).includes("metaeditor_missing"));
    });
    for (const [name, change, code] of [
      ["disabled registration", { enabled: false }, "mcp_disabled"],
      ["disabled required tool", { disabled_tools: ["mql5_chm_read"] }, "mcp_tool_disabled"],
      ["empty enabled-tools list", { enabled_tools: [] }, "mcp_tool_disabled"],
      ["partial enabled-tools list", { enabled_tools: ["mql5_chm_status"] }, "mcp_tool_disabled"],
      ["wrong working directory", { transport: { ...registration.transport, cwd: temporary } }, "mcp_registration_mismatch"],
      ["ambient root override", { transport: { ...registration.transport, env_vars: ["MQL5_CHM_MCP_ROOT"] } }, "mcp_ambient_root"],
    ]) {
      await t.test(name, async () => {
        await saveRegistration({ ...registration, ...change });
        try { const { report } = run([], 1); assert.ok(codes(report).includes(code)); assert.equal(report.mcp.stdio_available, true); }
        finally { await saveRegistration(registration); }
      });
    }
    await t.test("custom environment values stay private and startup remains unverified", async () => {
      await saveRegistration({ ...registration, transport: { ...registration.transport, env: { PRIVATE_TOKEN: "SENSITIVE_TEST_VALUE" } } });
      try { assert.ok(codes(run().report).includes("mcp_custom_environment")); }
      finally { await saveRegistration(registration); }
    });
    await t.test("skill differences list changed, missing and extra files", async () => {
      const changed = path.join(sourceSkill, "SKILL.md");
      const previous = await readFile(changed);
      await writeFile(changed, Buffer.concat([previous, Buffer.from("\nsource change\n")]));
      await writeFile(path.join(sourceSkill, "source-only.txt"), "source");
      await writeFile(path.join(skill, "installed-only.txt"), "installed");
      try {
        const { report } = run();
        assert.ok(codes(report).includes("skill_source_differs"));
        assert.deepEqual(report.skill.source_comparison.differences.map(item => item.state).sort(), ["changed", "installed_only", "missing_installed"]);
      } finally { await writeFile(changed, previous); await rm(path.join(sourceSkill, "source-only.txt")); await rm(path.join(skill, "installed-only.txt")); }
    });
    await t.test("common distributable differences are warnings", async () => {
      await writeFile(path.join(sourceMcp, "README.md"), "changed source");
      try { const { report } = run(); assert.ok(codes(report).includes("mcp_source_differs")); assert.equal(report.mcp.source_comparison.differences[0].relative_path, "README.md"); }
      finally { await cp(path.join(fixture.root, "README.md"), path.join(sourceMcp, "README.md")); }
    });
    await t.test("unavailable optional sources do not prevent real stdio checks", () => {
      const { report } = run(["-SkillSourceRoot", path.join(temporary, "missing skill source"), "-McpSourceRoot", path.join(temporary, "missing mcp source")]);
      assert.deepEqual(codes(report).sort(), ["mcp_source_unavailable", "skill_source_unavailable"]);
      assert.equal(report.mcp.stdio_available, true);
    });
    await t.test("tampered bundle fails before Node execution", async () => {
      const file = path.join(fixture.root, "app/server.mjs"); const bytes = await readFile(file);
      await writeFile(file, "throw new Error('SENSITIVE_TEST_VALUE');");
      try { const { report } = run([], 1); assert.equal(report.mcp.integrity, "failed"); assert.equal(report.mcp.node_version, null); assert.ok(codes(report).includes("mcp_integrity_failed")); }
      finally { await writeFile(file, bytes); }
    });
    await t.test("missing checksum coverage for probe fails before execution", async () => {
      await writeFile(path.join(fixture.root, "checksums.sha256"), checksumText.split("\n").filter(line => !line.endsWith("*scripts/Smoke-Test-McpServer.mjs")).join("\n"));
      try { assert.ok(codes(run([], 1).report).includes("mcp_integrity_failed")); }
      finally { await writeFile(path.join(fixture.root, "checksums.sha256"), checksumText); }
    });
    for (const [name, update, code] of [
      ["pinned Node version mismatch", packageJson => ({ ...packageJson, engines: { node: "0.0.0" } }), "mcp_node_version_failed"],
      ["server version mismatch", packageJson => ({ ...packageJson, version: "0.0.0" }), "mcp_stdio_failed"],
    ]) {
      await t.test(name, async () => {
        const file = path.join(fixture.root, "package.json"); const bytes = await readFile(file);
        const changed = Buffer.from(JSON.stringify(update(JSON.parse(bytes))));
        await writeFile(file, changed);
        await writeFile(path.join(fixture.root, "checksums.sha256"), checksumText.replace(`${packageFiles["package.json"]} *package.json`, `${hash(changed)} *package.json`));
        try { const { report } = run([], 1); assert.equal(report.mcp.integrity, "passed"); assert.equal(report.mcp.stdio_available, false); assert.ok(codes(report).includes(code)); }
        finally { await writeFile(file, bytes); await writeFile(path.join(fixture.root, "checksums.sha256"), checksumText); }
      });
    }
    await t.test("missing essential skill helper is an installation fault", async () => {
      const file = path.join(skill, "scripts/Compile-Mql5.ps1"); const bytes = await readFile(file); await rm(file);
      try { assert.ok(codes(run([], 1).report).includes("skill_unreadable")); }
      finally { await writeFile(file, bytes); }
    });
    for (const mode of ["malformed", "unavailable", "timeout"]) {
      await t.test(`Codex ${mode} is diagnosed without leaking subprocess output`, async () => {
        await writeFile(path.join(state, "mode.txt"), mode);
        try {
          const { report, elapsed } = run([], 1);
          assert.ok(codes(report).includes("codex_registration_unavailable"));
          assert.equal(report.mcp.stdio_available, true);
          if (mode === "timeout") {
            assert.ok(elapsed < 20_000, `Probe deadline was not bounded: ${elapsed}ms`);
            const pid = (await readFile(path.join(state, "pid.txt"), "utf8")).trim();
            assert.ok(!execFileSync("tasklist.exe", ["/FI", `PID eq ${pid}`, "/FO", "CSV", "/NH"], { encoding: "utf8", windowsHide: true }).includes(`"${pid}"`), "Timed-out Codex probe is still running");
          }
        } finally { await writeFile(path.join(state, "mode.txt"), "valid"); }
      });
    }
    await t.test("report creation is exclusive and preserves an existing report", async () => {
      const file = path.join(temporary, "health.json");
      const first = run(["-ReportPath", file]).report;
      const bytes = await readFile(file);
      assert.deepEqual(JSON.parse(bytes), first);
      assert.ok(codes(run(["-ReportPath", file], 2).report).includes("report_write_failed"));
      assert.deepEqual(await readFile(file), bytes);
    });
    await t.test("no MetaEditor execution or changes to installed inputs", async () => {
      await assert.rejects(readFile(path.join(state, "editor-executed.txt")), { code: "ENOENT" });
      assert.deepEqual(await inventory(fixture.root), originalPackage);
      assert.deepEqual(await inventory(skill), originalSkill);
    });
  });
}
