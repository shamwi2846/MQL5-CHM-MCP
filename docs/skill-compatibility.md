# MCP and coding skill compatibility

The skill owns `skills/mql5-coding/references/mcp-contract.json`; the MCP owns `scripts/Test-SkillCompatibility.mjs`. A contract change and its corresponding implementation must pass together. The runner reads the actual skill files, validates its YAML dependency using PyYAML, and starts the real bundled MCP over stdio. It checks advertised schemas and actual responses, including citation/revision correlation, complete identifier tokens, bounded reads and opaque cursors, native image hashes, invalid requests, and unchanged corpus artifacts. Regression tests deliberately remove required tools/fields, tighten input ranges, change types, and introduce misleading prefix matches to ensure the checker detects them.

The default indexed synthetic corpus is generated locally and deleted after the run. It contains no authoritative MQL5 documentation. A pass establishes these interface behaviors for the recorded repository pair; it does not prove all MQL5 API facts, compile an EA, start MT5, or evaluate a trading strategy. The existing corpus, compiler, and tester suites retain their separate roles.

## Local repository pair

From the MCP checkout, with the skill checkout alongside it and Node.js 24.17.0 installed:

```powershell
npm ci
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
npm run build:candidate
if ($LASTEXITCODE -ne 0) { throw 'MCP build failed.' }
$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE '.codex'
} else { $env:CODEX_HOME }
$pythonPath = Join-Path $codexHome 'tools\mql5-python\.venv\Scripts\python.exe'
$skillRoot = (Resolve-Path -LiteralPath '..\MQL5-Coding-Skill\skills\mql5-coding').Path
$reportPath = Join-Path $PWD ('compatibility-' + [guid]::NewGuid().ToString('N') + '.json')
node scripts/Test-SkillCompatibility.mjs --skill-root $skillRoot --python $pythonPath --report $reportPath
if ($LASTEXITCODE -ne 0) { throw 'MCP and skill compatibility failed.' }
```

An absolute Python executable path with PyYAML is required; another isolated environment may be supplied. The shared `.cmd` launcher is not an executable accepted by Node's direct process API. Reports use exclusive creation and never replace earlier evidence. Temporary reports in the checkout should be kept outside commits.

## Installed pair

Use the same runner from a dependency-installed MCP checkout, with explicit paths to the installed skill, package root, and bundle. For example, after assigning `$pythonPath` and `$codexHome` as above:

```powershell
$installedSkill = Join-Path $codexHome 'skills\mql5-coding'
$packageRoot = '<absolute-installed-MCP-package-root>'
$serverPath = Join-Path $packageRoot 'app\server.mjs'
$reportPath = Join-Path $PWD ('installed-compatibility-' + [guid]::NewGuid().ToString('N') + '.json')
node scripts/Test-SkillCompatibility.mjs --skill-root $installedSkill --python $pythonPath --package-root $packageRoot --server-path $serverPath --report $reportPath
if ($LASTEXITCODE -ne 0) { throw 'Installed MCP and skill compatibility failed.' }
```

This mode checks the current indexed corpus and never starts MetaEditor or MT5. It reads `OnTester` and a topic with an image; those identifiers are test probes, not permanently cached topic IDs. Installed consumer files and the bundle are hashed; an installed skill without Git metadata has a null checkout commit. The MCP checkout commit identifies the test runner's source. The report's server path/hash identifies the tested bundle.

## Private repository CI

The pair job also runs the skill's environment-health command against an actual MCP bundle and indexed synthetic corpus under PowerShell 7 and Windows PowerShell 5.1. Native synthetic Codex and editor executables provide controlled registration/error metadata; the editor is never executed. Cases cover source differences, disabled/tool-filtered registration, version/checksum failures, missing optional dependencies, redaction, timeouts, and exclusive report creation. Installed inputs must remain unchanged. For local regression testing from this MCP checkout after building the candidate bundle:

```powershell
$env:MQL5_HEALTH_SKILL_ROOT = $skillRoot
$env:MQL5_HEALTH_PYTHON = $pythonPath
npm run test:environment-health
if ($LASTEXITCODE -ne 0) { throw 'Environment health regression tests failed.' }
```

The skill has the [installed health command and options](https://github.com/shamwi2846/MQL5-Coding-Skill/blob/main/skills/mql5-coding/references/environment-health.md). The health regression suite is a separate Windows pair-job gate; it is not part of the MCP's standalone fast test count.

The counterpart skill also ships [reusable project profiles](https://github.com/shamwi2846/MQL5-Coding-Skill/blob/main/skills/mql5-coding/references/project-profiles.md). The current health gate expects its seventeen-file package, including the profile validator, creation/invocation commands, and reference. Profile regression tests run in the skill's Windows CI under both shells. These additions require no change to the production MCP runtime or documentation interface.

Each repository's `.github/workflows/skill-compatibility.yml` checks out its event revision and the counterpart's `main`; a manual run can select another `peer_ref`. Both exact resolved commits are recorded in the artifact. Node and Python versions, dependency lockfiles, and action commits are pinned. MCP release packaging has `needs: compatibility`; skill tag pushes run the pair check as well.

Each repository needs an Actions secret named `MQL5_PEER_READ_KEY`: a unique read-only SSH deploy key registered on the counterpart repository. Create separate keys for each direction. Never store private keys in source control, use write access, or copy an account's broad token into CI. Checkouts set `persist-credentials: false`. Fork pull requests skip the secret-bearing job; trusted runs fail when the credential is missing. Rotate a target deploy key and its corresponding consumer secret together.

The JSON artifact records the MCP and skill commits, server version/hash, consumer file hashes, corpus revision, and passed scenarios. It is proof for that recorded pair rather than a guarantee about later counterpart changes. Re-run after either repository changes; the two CI jobs cover changes from either direction.
