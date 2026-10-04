import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { median } from "../scripts/IdentifierBenchmarkStatistics.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverPath = path.join(repository, "tests/helpers/benchmark-server.mjs");
for (const [label, samples, expected] of [
  ["one sample", [7], 7],
  ["odd count", [10, 2, 4], 4],
  ["even count", [10, 2, 8, 4], 6],
  ["fractional samples", [0.5, 1.25], 0.875],
  ["repeated zero samples", [0, 0, 0, 0], 0],
]) {
  test(`identifier benchmark median: ${label}`, () => {
    const original = [...samples];
    assert.equal(median(samples), expected);
    assert.deepEqual(samples, original, "Statistics must preserve the original measurements");
  });
}
test("identifier benchmark refuses a median without samples", () => {
  assert.throws(() => median([]), RangeError);
});
const faultCases = ["status-error", ...["sequential", "parallel", "batch"].flatMap(mode => [`${mode}-error`, `${mode}-metadata`, `${mode}-revision`, `${mode}-count`]), "batch-match-status"];
for (const [fault, samples] of [["none", 3], ["none", 4], ...faultCases.map(fault => [fault, 3])]) {
  test(`identifier benchmark validates ${fault} with ${samples} samples`, { timeout: 20_000 }, async t => {
    const fixture = await mkdtemp(path.join(tmpdir(), "mql5-identifier-benchmark-"));
    t.after(async () => {
      assert.ok(path.resolve(fixture).startsWith(path.resolve(tmpdir()) + path.sep));
      await rm(fixture, { recursive: true, force: true });
    });
    await mkdir(path.join(fixture, "data"));
    const pointer = path.join(fixture, "data/active.json");
    const report = path.join(fixture, "measurement.json");
    await writeFile(pointer, "{}\n");
    await writeFile(path.join(fixture, "fault.txt"), fault);
    const originalServer = await readFile(serverPath), originalPointer = await readFile(pointer);
    const result = spawnSync(process.execPath, [path.join(repository, "scripts/Measure-IdentifierBatch.mjs"), "--package-root", fixture, "--server-path", serverPath, "--samples", String(samples), "--report", report], { encoding: "utf8", windowsHide: true, timeout: 15_000 });
    assert.equal(result.error, undefined);
    if (fault === "none") {
      assert.equal(result.status, 0, result.stderr);
      const record = JSON.parse(result.stdout);
      assert.equal(record.status, "passed");
      assert.equal(record.samples_per_mode, samples);
      assert.deepEqual(record.measurements.map(row => row.identifiers), [1, 4, 8, 16]);
      assert.ok(record.measurements.every(row => row.result_metadata_equal));
      assert.deepEqual(JSON.parse(await readFile(report, "utf8")), record);
    } else {
      assert.notEqual(result.status, 0, "A failed measurement was reported as passed");
      assert.match(result.stderr, /Identifier benchmark failed/);
      assert.doesNotMatch(result.stdout, /"status": "passed"/);
      await assert.rejects(access(report), { code: "ENOENT" });
    }
    assert.deepEqual(await readFile(serverPath), originalServer);
    assert.deepEqual(await readFile(pointer), originalPointer);
  });
}
