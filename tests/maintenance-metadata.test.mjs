import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { createSearchService, verifyPackage } from "../src/search-service.mjs";
import { buildFixture } from "./helpers/runtime-fixture.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const checker = `
param([string]$Common,[string]$Root,[string]$Revision,[string]$Cases)
. $Common
$manifestPath=Join-Path $Root ('revisions/'+$Revision+'/manifest.json')
$pointerPath=Join-Path $Root 'data/active.json'
$manifest=[IO.File]::ReadAllText($manifestPath)
$pointer=[IO.File]::ReadAllText($pointerPath)
$results=@()
try {
    foreach($case in (Get-Content -LiteralPath $Cases -Raw -Encoding UTF8 | ConvertFrom-Json).cases) {
        [IO.File]::WriteAllText($manifestPath,$manifest)
        [IO.File]::WriteAllText($pointerPath,$pointer)
        $destination=if($case.kind -ceq 'manifest'){$manifestPath}else{$pointerPath}
        [IO.File]::WriteAllText($destination,$case.json)
        $accepted=$false;$message=$null
        try {
            if($case.kind -ceq 'manifest'){Assert-Revision -ProjectRoot $Root -Revision $Revision -IdentityMode Index | Out-Null}
            else{Get-ActiveRevisionPointer -ProjectRoot $Root | Out-Null}
            $accepted=$true
        } catch {$message=$_.Exception.Message}
        $results += [pscustomobject]@{name=$case.name;kind=$case.kind;accepted=$accepted;message=$message}
    }
} finally {
    [IO.File]::WriteAllText($manifestPath,$manifest)
    [IO.File]::WriteAllText($pointerPath,$pointer)
}
ConvertTo-Json -InputObject $results -Depth 4 -Compress
`;

for (const shell of ["pwsh.exe", "powershell.exe"]) {
  for (const schemaVersion of [2, 3]) {
    test(`maintenance and runtime metadata agree for schema ${schemaVersion} under ${shell}`, { skip: process.platform !== "win32", timeout: 60_000 }, async t => {
      const fixture = await buildFixture({ schemaVersion });
      t.after(() => rm(fixture.root, { recursive: true, force: true }));
      const revision = path.join(fixture.root, "revisions", fixture.databaseHash);
      const manifestPath = path.join(revision, "manifest.json");
      const pointerPath = path.join(fixture.root, "data/active.json");
      const original = await readFile(manifestPath, "utf8");
      const originalPointer = await readFile(pointerPath, "utf8");
      const manifest = JSON.parse(original);
      const pointer = JSON.parse(originalPointer);
      await writeFile(path.join(revision, "corpus.lock.json"), JSON.stringify({ schema_version: "1.1", sources: Object.entries(manifest.sources).map(([id, value]) => ({ id, ...value, expected_topics: value.topic_count })), expected_total_topics: manifest.total_topic_count }));
      const service = await createSearchService({ root: fixture.root });
      service.close(); // The unmodified fixture must also pass full runtime index validation.
      const cases = [];
      function add(kind, name, change, valid = false) {
        const value = structuredClone(kind === "manifest" ? manifest : pointer);
        cases.push({ kind, name, json: JSON.stringify(change(value)), valid });
      }
      add("manifest", "valid", value => value, true);
      cases.push({ kind: "manifest", name: "whole JSON number with decimal notation", json: original.replace(`"schema_version": ${schemaVersion}`, `"schema_version": ${schemaVersion}.0`), valid: true });
      add("manifest", "extra nonsemantic top-level metadata", value => ({ ...value, fixture_note: "supported" }), true);
      if (schemaVersion === 2) add("manifest", "optional null legacy corpus alias", value => ({ ...value, corpus_revision: null }), true);
      add("manifest", "root singleton array", value => [value]);
      add("manifest", "string schema", value => ({ ...value, schema_version: String(schemaVersion) }));
      add("manifest", "array schema", value => ({ ...value, schema_version: [schemaVersion] }));
      add("manifest", "fractional schema", value => ({ ...value, schema_version: schemaVersion + 0.1 }));
      add("manifest", "wrapped database", value => ({ ...value, database: [value.database] }));
      add("manifest", "string database bytes", value => (value.database.bytes = String(value.database.bytes), value));
      add("manifest", "wrapped source", value => (value.sources.mql5 = [value.sources.mql5], value));
      add("manifest", "string source count", value => (value.sources.mql5.topic_count = String(value.sources.mql5.topic_count), value));
      add("manifest", "array source hash", value => (value.sources.mql5.sha256 = [value.sources.mql5.sha256], value));
      add("manifest", "boolean HTTP header", value => (value.sources.mql5.http_etag = true, value));
      add("manifest", "empty array HTTP header", value => (value.sources.mql5.http_etag = [], value));
      add("manifest", "HTTP header control character", value => (value.sources.mql5.http_etag = "etag\n", value));
      add("manifest", "conflicting corpus alias", value => ({ ...value, corpus_revision: "0".repeat(64) }));
      add("manifest", "boolean zero link count", value => (value.topic_link_count = false, value));
      add("manifest", "extra source", value => (value.sources.extra = value.sources.mql5, value));
      add("manifest", "unsafe integer", value => (value.total_topic_count = 9007199254740992, value));
      if (schemaVersion === 3) {
        add("manifest", "wrapped assets", value => (value.assets = [value.assets], value));
        add("manifest", "string asset count", value => (value.assets.cataloged_count = String(value.assets.cataloged_count), value));
        add("manifest", "boolean zero source asset count", value => (value.assets.by_source.mql5book.cataloged_count = false, value));
        add("manifest", "extra asset source", value => (value.assets.by_source.extra = value.assets.by_source.mql5book, value));
      }
      add("pointer", "valid", value => value, true);
      add("pointer", "root singleton array", value => [value]);
      add("pointer", "string schema", value => ({ ...value, schema_version: "2" }));
      add("pointer", "array schema", value => ({ ...value, schema_version: [2] }));
      add("pointer", "array active revision", value => ({ ...value, active_revision: [value.active_revision] }));
      add("pointer", "empty previous revision array", value => ({ ...value, previous_revision: [] }));
      const casePath = path.join(fixture.root, "metadata-cases.json");
      const script = path.join(fixture.root, "check-metadata.ps1");
      await writeFile(casePath, JSON.stringify({ cases }));
      await writeFile(script, checker);
      const result = spawnSync(shell, ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-Common", path.join(repository, "scripts/Common.ps1"), "-Root", fixture.root, "-Revision", fixture.databaseHash, "-Cases", casePath], { encoding: "utf8", windowsHide: true, timeout: 45_000 });
      assert.ifError(result.error);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.equal(result.stderr, "");
      const maintenance = JSON.parse(result.stdout.replace(/^\uFEFF/u, ""));
      assert.equal(maintenance.length, cases.length);
      try {
        for (const [index, item] of cases.entries()) {
          await writeFile(manifestPath, original);
          await writeFile(pointerPath, originalPointer);
          await writeFile(item.kind === "manifest" ? manifestPath : pointerPath, item.json);
          if (item.valid) await verifyPackage({ root: fixture.root });
          else await assert.rejects(verifyPackage({ root: fixture.root }), { code: item.kind === "manifest" ? "INVALID_MANIFEST" : "INVALID_ACTIVE_POINTER" });
          assert.equal(maintenance[index].accepted, item.valid, `${item.kind}: ${item.name}: ${maintenance[index].message}`);
        }
      } finally {
        await writeFile(manifestPath, original);
        await writeFile(pointerPath, originalPointer);
      }
      assert.equal(await readFile(manifestPath, "utf8"), original);
      assert.equal(await readFile(pointerPath, "utf8"), originalPointer);
    });
  }
}
