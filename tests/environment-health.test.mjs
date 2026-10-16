import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
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
// Capability gates use the counterpart's declared version, so a newer peer can
// never silently skip a check (source-text detection could).
const peerAtLeast = minimum => {
  const have = String(skillVersion).split(".").map(Number), need = minimum.split(".").map(Number);
  assert.ok(have.length === 3 && have.every(Number.isSafeInteger), `invalid counterpart skill version ${skillVersion}`);
  for (let i = 0; i < 3; i++) if (have[i] !== need[i]) return have[i] > need[i];
  return true;
};
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
  [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
  struct StartupInfo {
    public uint Size; public string Reserved, Desktop, Title;
    public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
    public ushort ShowWindow, ReservedSize; public IntPtr ReservedData, Input, Output, Error;
  }
  [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
  struct ProcessInfo { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
  [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
  static extern bool CreateProcess(string application, System.Text.StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo information);
  [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CloseHandle(IntPtr handle);
  public static int Main(string[] args) {
    string state = Environment.GetEnvironmentVariable("MQL5_HEALTH_FAKE_STATE");
    if (args.Length == 1 && args[0] == "--probe-child") { Thread.Sleep(30000); return 0; }
    if (args.Length == 1 && args[0] == "--version") { Console.WriteLine("codex-cli 0.159.0"); return 0; }
    if (args.Length == 4 && args[0] == "mcp" && args[1] == "get" && args[2] == "mql5-chm" && args[3] == "--json") {
      // Verify the selected directory, allowing Windows short/long path aliases.
      string home = Environment.GetEnvironmentVariable("CODEX_HOME");
      if (home == null || File.ReadAllText(Path.Combine(home, "health-home-marker.txt")) != File.ReadAllText(Path.Combine(state, "home.txt"))) return 9;
      string mode = File.ReadAllText(Path.Combine(state, "mode.txt"));
      if (mode == "timeout") { File.WriteAllText(Path.Combine(state, "pid.txt"), Process.GetCurrentProcess().Id.ToString()); Thread.Sleep(30000); }
      if (mode == "oversized-stderr" || mode == "oversized-stdout") {
        File.WriteAllText(Path.Combine(state, "pid.txt"), Process.GetCurrentProcess().Id.ToString());
        if (mode == "oversized-stderr") Console.Error.Write("SENSITIVE_TEST_VALUE" + new string('X', 2 * 1024 * 1024));
        else Console.Write(new string('X', 2 * 1024 * 1024));
      }
      if (mode == "early-exit-child" || mode == "early-exit-detached-child") {
        bool detached = mode == "early-exit-detached-child";
        string application = Process.GetCurrentProcess().MainModule.FileName;
        uint childId;
        if (detached) {
          // Disable all handle inheritance. Framework Process.Start can retain
          // unrelated pipe handles even when its standard streams are redirected.
          StartupInfo startup = new StartupInfo(); startup.Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(StartupInfo));
          ProcessInfo child;
          if (!CreateProcess(application, new System.Text.StringBuilder("\\\"" + application + "\\\" --probe-child"), IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, null, ref startup, out child)) return 8;
          childId = child.ProcessId; CloseHandle(child.Thread); CloseHandle(child.Process);
        } else {
          using (Process child = Process.Start(new ProcessStartInfo { FileName = application, Arguments = "--probe-child", UseShellExecute = false, CreateNoWindow = true })) childId = (uint)child.Id;
        }
        File.WriteAllText(Path.Combine(state, "child-pid.txt"), childId.ToString());
      }
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
    const invalidEditors = [];
    for (const [name, editorMajor, terminalMajors] of [
      ["non-MT5 editor beside an MT5 terminal", 4, [5]],
      ["non-MT5 standalone editor with an MT5 label", 4, []],
      ["mixed MT4 and MT5 terminal directory", 5, [5, 4]],
    ]) {
      const directory = path.join(temporary, name);
      await mkdir(directory);
      const selected = path.join(directory, "metaeditor64.exe");
      await cp(editorMajor === 5 ? codex : path.join(mt4, "terminal.exe"), selected);
      for (const [index, major] of terminalMajors.entries()) {
        await cp(major === 5 ? codex : path.join(mt4, "terminal.exe"), path.join(directory, ["terminal64.exe", "terminal.exe"][index]));
      }
      invalidEditors.push([name, selected]);
    }
    const health = path.join(peerSkill, "scripts/Test-Mql5Environment.ps1");
    const registration = { name: "mql5-chm", enabled: true, enabled_tools: null, disabled_tools: null, transport: { type: "stdio", command: path.join(fixture.root, "runtime/node.exe"), args: [path.join(fixture.root, "app/server.mjs")], cwd: fixture.root, env: null, env_vars: [] } };
    const saveRegistration = async value => writeFile(path.join(state, "registration.json"), JSON.stringify(value));
    await saveRegistration(registration);
    function run(extra = [], expected = 0, workingDirectory = repository) {
      const started = Date.now();
      const parameters = new Map([["-WorkspaceRoot", temporary], ["-CodexHome", codexHome], ["-CodexPath", codex], ["-McpPackageRoot", fixture.root],
        ["-SkillRoot", skill], ["-SkillSourceRoot", sourceSkill], ["-McpSourceRoot", sourceMcp], ["-MetaEditorPath", editor], ["-PythonPath", python], ["-TimeoutSeconds", "5"]]);
      const switches = ["-Json"];
      for (let index = 0; index < extra.length; index += 1) {
        if (["-RequireCompiler", "-RequirePython"].includes(extra[index])) switches.push(extra[index]);
        else { parameters.set(extra[index], extra[index + 1]); index += 1; }
      }
      const result = spawnSync(shell, ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", health, ...[...parameters].flat(), ...switches],
      { cwd: workingDirectory, encoding: "utf8", windowsHide: true, timeout: 35_000, env: { ...process.env, MQL5_HEALTH_FAKE_STATE: state, MQL5_CHM_MCP_ROOT: path.join(temporary, "unused ambient override") } });
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
      assert.equal(report.skill.file_count, Object.keys(originalSkill).length);
      assert.equal(report.skill.declared_version, skillVersion);
      assert.match(report.skill.fingerprint_sha256, /^[0-9a-f]{64}$/u);
      assert.equal(report.skill.fingerprint_sha256, hash(Buffer.from(Object.keys(originalSkill).sort().map(name => `${name}\0${originalSkill[name]}`).join("\n"))), "Inventory fingerprints must agree across PowerShell versions");
      assert.equal(report.metaeditor.candidates[0].build, 6230);
      assert.equal(report.python.available, true);
      assert.equal(report.python.pyyaml_available, true);
    });
    // The approved-peer CI leg pins an older skill whose health command has no
    // Claude Code mode; exercise these cases only against a supporting peer.
    const peerSupportsClaude = peerAtLeast("1.2.3");
    await t.test("Claude Code registration: user scope, overriding local scope, and absence", { skip: peerSupportsClaude ? false : "peer skill predates Claude Code health checks" }, async () => {
      const claudeHome = path.join(temporary, "claude home");
      await mkdir(claudeHome, { recursive: true });
      const workspaceKey = temporary.replaceAll("\\", "/");
      const entry = command => ({ type: "stdio", command, args: [path.join(fixture.root, "app/server.mjs")], env: {} });
      const owned = entry(path.join(fixture.root, "runtime/node.exe"));
      // Case-distinct project keys are legal in Claude Code's configuration.
      const writeConfig = (user, local, disabled) => writeFile(path.join(claudeHome, ".claude.json"), JSON.stringify({
        projects: { [workspaceKey]: { mcpServers: local ? { "mql5-chm": local } : {}, ...(disabled === undefined ? {} : { disabledMcpServers: disabled }) }, [workspaceKey.toUpperCase() + "-other"]: { disabledMcpServers: ["mql5-chm"] }, [workspaceKey.toLowerCase() + "-other"]: {} },
        mcpServers: user ? { "mql5-chm": user } : {},
      }));
      const claude = ["-ClientHost", "Claude", "-ClaudeConfigDirectory", claudeHome, "-ClaudePath", path.join(temporary, "missing-claude.exe")];
      await writeConfig(owned, null);
      let { report } = run(claude);
      assert.equal(report.client_host, "Claude");
      assert.equal(report.claude.registration_state, "enabled");
      assert.equal(report.claude.registration_scope, "user");
      assert.equal(report.mcp.stdio_available, true);
      assert.deepEqual(report.issues.filter(issue => issue.severity === "error"), []);
      assert.ok(codes(report).includes("claude_cli_missing"));
      if (peerAtLeast("1.2.10")) {
        // `/mcp disable` lists the exact name in this workspace's project entry;
        // other projects, other names and non-array values leave it enabled.
        await writeConfig(owned, null, ["other", "mql5-chm"]);
        ({ report } = run(claude, 1));
        assert.equal(report.claude.registration_state, "disabled");
        assert.ok(codes(report).includes("mcp_disabled"));
        for (const disabled of [["MQL5-CHM"], "mql5-chm", []]) {
          await writeConfig(owned, null, disabled);
          ({ report } = run(claude));
          assert.equal(report.claude.registration_state, "enabled", JSON.stringify(disabled));
        }
      }
      await writeConfig(owned, entry(path.join(temporary, "other package/runtime/node.exe")));
      ({ report } = run(claude, 1));
      assert.equal(report.claude.registration_scope, "local");
      assert.deepEqual(report.claude.shadowed_scopes, ["user"]);
      assert.ok(codes(report).includes("mcp_registration_mismatch"));
      await writeConfig(null, null);
      ({ report } = run(claude, 1));
      assert.equal(report.claude.registration_state, "absent");
      assert.ok(codes(report).includes("claude_registration_missing"));
    });
    await t.test("matching inventories accept an additional skill resource without a fixed file count", async () => {
      const relative = "assets/health-inventory-fixture.txt";
      const bytes = Buffer.from("Additional supported asset used only by this fixture.\n");
      try {
        for (const root of [skill, sourceSkill]) await writeFile(path.join(root, relative), bytes);
        const expanded = await inventory(skill);
        const { report } = run();
        assert.equal(report.status, "passed");
        assert.equal(report.skill.file_count, Object.keys(expanded).length);
        assert.equal(report.skill.source_comparison.status, "same");
        assert.equal(report.skill.fingerprint_sha256, hash(Buffer.from(Object.keys(expanded).sort().map(name => `${name}\0${expanded[name]}`).join("\n"))));
      } finally {
        for (const root of [skill, sourceSkill]) await rm(path.join(root, relative), { force: true });
      }
    });
    async function withDriveRoot(directory, action) {
      const letter = ["Z", "Y", "X", "W", "V", "U", "T", "S", "R"].find(value => !existsSync(`${value}:\\`));
      assert.ok(letter, "A free drive letter is needed for the disposable root-path fixture");
      const drive = `${letter}:`, root = `${drive}\\`;
      const subst = path.join(process.env.WINDIR, "System32/subst.exe");
      execFileSync(subst, [drive, directory], { windowsHide: true, timeout: 10_000 });
      try { return await action(root); }
      finally { execFileSync(subst, [drive, "/D"], { windowsHide: true, timeout: 10_000 }); }
    }
    await t.test("installed skill at a drive root keeps the complete inventory from a nested working folder", async () => {
      await withDriveRoot(skill, root => {
        const { report } = run(["-SkillRoot", root], 0, path.join(root, "scripts"));
        assert.equal(report.status, "passed");
        assert.equal(report.skill.root, root);
        assert.equal(report.skill.file_count, Object.keys(originalSkill).length);
        assert.equal(report.skill.source_comparison.status, "same");
        assert.equal(report.skill.fingerprint_sha256, hash(Buffer.from(Object.keys(originalSkill).sort().map(name => `${name}\0${originalSkill[name]}`).join("\n"))));
      });
    });
    await t.test("skill source at a drive root compares every relative path from a nested working folder", async () => {
      await withDriveRoot(sourceSkill, root => {
        const { report } = run(["-SkillSourceRoot", root], 0, path.join(root, "scripts"));
        assert.equal(report.status, "passed");
        assert.equal(report.skill.source_comparison.source_root, root);
        assert.equal(report.skill.source_comparison.status, "same");
      });
    });
    await t.test("MCP source comparison preserves an absolute drive root", async () => {
      await withDriveRoot(sourceMcp, root => {
        const { report } = run(["-McpSourceRoot", root]);
        assert.equal(report.status, "passed");
        assert.equal(report.mcp.source_comparison.source_root, root);
        assert.equal(report.mcp.source_comparison.status, "same");
      });
    });
    await t.test("MCP package at a drive root completes real stdio from a nested working folder", async () => {
      await withDriveRoot(fixture.root, async root => {
        await saveRegistration({ ...registration, transport: { ...registration.transport, command: path.join(root, "runtime/node.exe"), args: [path.join(root, "app/server.mjs")], cwd: root } });
        try {
          const { report } = run(["-McpPackageRoot", root], 0, path.join(root, "scripts"));
          assert.equal(report.status, "passed");
          assert.equal(report.mcp.package_root, root);
          assert.equal(report.mcp.integrity, "passed");
          assert.equal(report.mcp.checked_files, Object.keys(packageFiles).length);
          assert.equal(report.mcp.stdio_available, true);
        } finally { await saveRegistration(registration); }
      });
    });
    for (const cwd of [null, undefined]) {
      await t.test(`inherited working directory (${cwd === null ? "null" : "absent"}) agrees with installer registration`, async () => {
        const changed = { ...registration, transport: { ...registration.transport } };
        if (cwd === null) changed.transport.cwd = null;
        else delete changed.transport.cwd;
        await saveRegistration(changed);
        try { assert.equal(run().report.status, "passed"); }
        finally { await saveRegistration(registration); }
      });
    }
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
    for (const [name, selected] of invalidEditors) {
      await t.test(name, () => {
        const { report } = run(["-MetaEditorPath", selected, "-RequireCompiler"], 1);
        assert.equal(report.metaeditor.available, false);
        assert.ok(codes(report).includes("metaeditor_missing"));
      });
    }
    for (const [name, change, code] of [
      ["disabled registration", { enabled: false }, "mcp_disabled"],
      ["disabled required tool", { disabled_tools: ["mql5_chm_read"] }, "mcp_tool_disabled"],
      ["empty enabled-tools list", { enabled_tools: [] }, "mcp_tool_disabled"],
      ["partial enabled-tools list", { enabled_tools: ["mql5_chm_status"] }, "mcp_tool_disabled"],
      ["wrong working directory", { transport: { ...registration.transport, cwd: temporary } }, "mcp_registration_mismatch"],
      ["root-relative working directory", { transport: { ...registration.transport, cwd: fixture.root.slice(2) } }, "mcp_registration_mismatch"],
      ["ambient root override", { transport: { ...registration.transport, env_vars: ["MQL5_CHM_MCP_ROOT"] } }, "mcp_ambient_root"],
    ]) {
      await t.test(name, async () => {
        await saveRegistration({ ...registration, ...change });
        try { const { report } = run([], 1); assert.ok(codes(report).includes(code)); assert.equal(report.mcp.stdio_available, true); }
        finally { await saveRegistration(registration); }
      });
    }
    for (const [name, change] of [
      ["missing enabled state", { enabled: undefined }],
      ["string enabled state", { enabled: "true" }],
      ["scalar server arguments", { transport: { ...registration.transport, args: registration.transport.args[0] } }],
      ["scalar tool denylist", { disabled_tools: "unused_tool" }],
    ]) {
      await t.test(`malformed registration: ${name}`, async () => {
        await saveRegistration({ ...registration, ...change });
        try { const { report } = run([], 1); assert.ok(codes(report).includes("codex_registration_unavailable")); assert.equal(report.codex.registration_state, "unavailable"); }
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
    // Peers older than skill 1.2.8 report no probe-failure category.
    const peerReportsProbeFailure = peerAtLeast("1.2.8");
    for (const [name, update, code, phase, reason] of [
      ["pinned Node version mismatch", packageJson => ({ ...packageJson, engines: { node: "0.0.0" } }), "mcp_node_version_failed", "node_version", "unexpected_result"],
      ["server version mismatch", packageJson => ({ ...packageJson, version: "0.0.0" }), "mcp_stdio_failed", "stdio", "nonzero_exit"],
    ]) {
      await t.test(name, async () => {
        const file = path.join(fixture.root, "package.json"); const bytes = await readFile(file);
        const changed = Buffer.from(JSON.stringify(update(JSON.parse(bytes))));
        await writeFile(file, changed);
        await writeFile(path.join(fixture.root, "checksums.sha256"), checksumText.replace(`${packageFiles["package.json"]} *package.json`, `${hash(changed)} *package.json`));
        try {
          const { report } = run([], 1);
          assert.equal(report.mcp.integrity, "passed"); assert.equal(report.mcp.stdio_available, false); assert.ok(codes(report).includes(code));
          if (peerReportsProbeFailure) {
            assert.equal(report.mcp.probe_failure.phase, phase);
            assert.equal(report.mcp.probe_failure.reason, reason);
            assert.equal(reason === "nonzero_exit" ? report.mcp.probe_failure.exit_code !== 0 : report.mcp.probe_failure.exit_code === 0, true);
            const issue = report.issues.find(entry => entry.code === code);
            assert.match(issue.message, reason === "nonzero_exit" ? /exited with a failure code/u : /unexpected version or result/u);
          }
        }
        finally { await writeFile(file, bytes); await writeFile(path.join(fixture.root, "checksums.sha256"), checksumText); }
      });
    }
    await t.test("missing essential skill helper is an installation fault", async () => {
      const file = path.join(skill, "scripts/Compile-Mql5.ps1"); const bytes = await readFile(file); await rm(file);
      try { assert.ok(codes(run([], 1).report).includes("skill_unreadable")); }
      finally { await writeFile(file, bytes); }
    });
    for (const [name, identity] of [
      ["array root", [{ schema_version: 1, version: skillVersion }]],
      ["array version", { schema_version: 1, version: [skillVersion] }],
      ["array schema", { schema_version: [1], version: skillVersion }],
      ["boolean schema", { schema_version: true, version: skillVersion }],
      ["string schema", { schema_version: "1", version: skillVersion }],
      ["unknown field", { schema_version: 1, version: skillVersion, extra: true }],
    ]) {
      await t.test(`invalid skill version: ${name}`, async () => {
        const file = path.join(skill, "version.json");
        const bytes = await readFile(file);
        const invalid = Buffer.from(JSON.stringify(identity));
        await writeFile(file, invalid);
        try {
          const { report } = run([], 1);
          assert.ok(codes(report).includes("skill_unreadable"));
          assert.equal(report.skill.installed, false);
          assert.equal(report.skill.declared_version, null);
          assert.equal(report.mcp.stdio_available, true);
          assert.deepEqual(await readFile(file), invalid, "Health inspection modified invalid version evidence");
        } finally { await writeFile(file, bytes); }
      });
    }
    for (const mode of ["malformed", "unavailable", "timeout", "early-exit-child", "early-exit-detached-child", "oversized-stderr", "oversized-stdout"]) {
      await t.test(`Codex ${mode} is diagnosed without leaking subprocess output`, async () => {
        await writeFile(path.join(state, "mode.txt"), mode);
        try {
          const detached = mode === "early-exit-detached-child";
          const { report, elapsed } = run([], detached ? 0 : 1);
          if (detached) assert.equal(report.status, "passed");
          else assert.ok(codes(report).includes("codex_registration_unavailable"));
          // Name the probe-failure category if the direct MCP probe ever fails here.
          assert.equal(report.mcp.stdio_available, true, JSON.stringify({ probe_failure: report.mcp.probe_failure ?? null, issues: report.issues.map((issue) => issue.code) }));
          if (mode === "timeout") {
            assert.ok(elapsed < 20_000, `Probe deadline was not bounded: ${elapsed}ms`);
            const pid = (await readFile(path.join(state, "pid.txt"), "utf8")).trim();
            assert.ok(!execFileSync("tasklist.exe", ["/FI", `PID eq ${pid}`, "/FO", "CSV", "/NH"], { encoding: "utf8", windowsHide: true }).includes(`"${pid}"`), "Timed-out Codex probe is still running");
          }
          if (mode.startsWith("early-exit-")) {
            assert.ok(elapsed < 20_000, `Orphan cleanup was not bounded: ${elapsed}ms`);
            const pid = (await readFile(path.join(state, "child-pid.txt"), "utf8")).trim();
            assert.ok(!execFileSync("tasklist.exe", ["/FI", `PID eq ${pid}`, "/FO", "CSV", "/NH"], { encoding: "utf8", windowsHide: true }).includes(`"${pid}"`), "A child survived after its probe parent exited");
          }
          if (mode.startsWith("oversized-")) {
            assert.ok(elapsed < 20_000, `Oversized output cleanup was not bounded: ${elapsed}ms`);
            const pid = (await readFile(path.join(state, "pid.txt"), "utf8")).trim();
            assert.ok(!execFileSync("tasklist.exe", ["/FI", `PID eq ${pid}`, "/FO", "CSV", "/NH"], { encoding: "utf8", windowsHide: true }).includes(`"${pid}"`), "An oversized-output probe survived cleanup");
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
