import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

import {
  INDEX_CONTRACT,
  SCHEMA_VERSION,
  SOURCE_DEFINITIONS,
  buildIndex,
  computeCorpusRevision,
  createSchema,
  decodeHtml,
  makeTopicId,
  parseHtmlTopic,
  resolveInternalLink,
} from "../src/indexer.mjs";

async function createDefaultCliCorpus(root) {
  const sourceRoot = path.join(root, "sources");
  const extractedRoot = path.join(root, "build", "extracted");
  await mkdir(sourceRoot, { recursive: true });
  await mkdir(path.join(root, "config"), { recursive: true });
  await writeFile(
    path.join(root, "config", "mql5-image-policy.json"),
    await readFile(new URL("../config/mql5-image-policy.json", import.meta.url)),
  );

  const sources = [];
  for (const definition of SOURCE_DEFINITIONS) {
    const chmBytes = Buffer.from(`default-cli-${definition.source}`, "utf8");
    await writeFile(path.join(sourceRoot, definition.filename), chmBytes);
    const extractedDirectory = path.join(extractedRoot, definition.extractedDirectory);
    await mkdir(extractedDirectory, { recursive: true });
    await writeFile(
      path.join(extractedDirectory, "topic.htm"),
      `<div id="help"><h1>${definition.source}</h1><p>Default CLI fixture.</p></div>`,
      "utf8",
    );
    sources.push({
      id: definition.source,
      filename: definition.filename,
      sha256: createHash("sha256").update(chmBytes).digest("hex"),
      bytes: chmBytes.length,
      expected_topics: 1,
    });
  }
  await writeFile(path.join(root, "corpus.lock.json"), JSON.stringify({
    schema_version: 1,
    expected_total_topics: sources.length,
    sources,
  }));
}

function getWindowsShortPath(candidate) {
  const systemRoot = process.env.SystemRoot;
  if (process.platform !== "win32" || !systemRoot || !path.win32.isAbsolute(systemRoot)) return "";
  const command = path.win32.join(
    systemRoot,
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  );
  const script = [
    "$ErrorActionPreference='Stop'",
    "$signature='[DllImport(\"kernel32.dll\", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint GetShortPathName(string longPath, System.Text.StringBuilder shortPath, uint bufferLength);'",
    "Add-Type -MemberDefinition $signature -Name NativePath -Namespace Mql5ChmTest",
    "$buffer=New-Object System.Text.StringBuilder 32768",
    "$length=[Mql5ChmTest.NativePath]::GetShortPathName($env:MQL5_CHM_TEST_PATH,$buffer,[uint32]$buffer.Capacity)",
    "if($length -eq 0 -or $length -ge $buffer.Capacity){exit 4}",
    "[Console]::Out.Write($buffer.ToString())",
  ].join(";");
  const result = spawnSync(
    command,
    [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-EncodedCommand",
      Buffer.from(script, "utf16le").toString("base64"),
    ],
    {
      encoding: "utf8",
      env: { ...process.env, MQL5_CHM_TEST_PATH: candidate },
      timeout: 10_000,
      windowsHide: true,
    },
  );
  return result.status === 0 && !result.error ? result.stdout.trim() : "";
}

function hasUnpairedSurrogate(value) {
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (index + 1 >= value.length) return true;
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return true;
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return true;
    }
  }
  return false;
}

test("direct indexer defaults keep sources and output in separate directories", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-default-cli-"));
  try {
    await createDefaultCliCorpus(root);
    const result = await buildIndex(root);
    assert.equal(path.dirname(result.databasePath), path.join(root, "build", "index-candidate"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("direct indexer rejects a future output reached through a DOS path alias before creating it", async (context) => {
  if (process.platform !== "win32") {
    context.skip("DOS 8.3 aliases are a Windows filesystem boundary.");
    return;
  }

  const root = await mkdtemp(path.join(tmpdir(), "mql5-index-physical-alias-"));
  try {
    await createDefaultCliCorpus(root);
    const sourceDirectory = path.join(root, "source directory with a deliberately long name");
    await rename(path.join(root, "sources"), sourceDirectory);
    const shortSource = getWindowsShortPath(sourceDirectory);
    const shortLeaf = path.win32.basename(shortSource);
    if (!shortSource || shortLeaf.toLowerCase() === path.basename(sourceDirectory).toLowerCase()) {
      context.skip("The test volume does not expose a DOS 8.3 alias for the fixture.");
      return;
    }

    const aliasedSource = path.join(root, shortLeaf);
    assert.equal(
      await readFile(path.join(aliasedSource, SOURCE_DEFINITIONS[0].filename), "utf8"),
      await readFile(path.join(sourceDirectory, SOURCE_DEFINITIONS[0].filename), "utf8"),
    );
    const futureOutput = path.join(aliasedSource, "future-index-output");
    await assert.rejects(
      buildIndex(root, { sourceDirectory, outputDirectory: futureOutput }),
      /output directory.*overlap.*source directory/i,
    );
    await assert.rejects(stat(futureOutput), (error) => error?.code === "ENOENT");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("schema v3 keeps deterministic source identity and adds the image catalog", () => {
  const database = new DatabaseSync(":memory:");
  try {
    createSchema(database);
    assert.equal(Number(database.prepare("PRAGMA user_version").get().user_version), 3);

    const sourceColumns = new Set(database.prepare("PRAGMA table_info(sources)").all().map((row) => row.name));
    for (const column of [
      "chm_bytes",
      "topic_count",
      "section_count",
    ]) assert.ok(sourceColumns.has(column), `missing sources.${column}`);
    for (const column of ["http_last_modified", "http_etag", "retrieved_at"]) {
      assert.ok(!sourceColumns.has(column), `dynamic sources.${column} leaked into index identity`);
    }

    const topicColumns = new Set(database.prepare("PRAGMA table_info(topics)").all().map((row) => row.name));
    assert.ok(topicColumns.has("content_sha256"));

    const linkColumns = new Set(database.prepare("PRAGMA table_info(topic_links)").all().map((row) => row.name));
    for (const column of [
      "source_topic_id",
      "target_topic_id",
      "target_internal_path",
      "target_fragment",
      "label",
      "relationship",
      "resolution_status",
    ]) assert.ok(linkColumns.has(column), `missing topic_links.${column}`);

    const assetColumns = new Set(database.prepare("PRAGMA table_info(assets)").all().map((row) => row.name));
    for (const column of [
      "asset_id", "source", "internal_path", "path_sha256", "storage_key", "mime_type",
      "sha256", "byte_count", "width", "height", "pixel_count", "exposure",
      "exposure_reason", "canonical_caption",
    ]) assert.ok(assetColumns.has(column), `missing assets.${column}`);

    const occurrenceColumns = new Set(
      database.prepare("PRAGMA table_info(topic_assets)").all().map((row) => row.name),
    );
    for (const column of [
      "topic_id", "occurrence_ordinal", "asset_id", "section_id", "text_offset",
      "figcaption_text", "title_text", "alt_text", "nearby_text", "contextual_caption", "caption_source",
    ]) assert.ok(occurrenceColumns.has(column), `missing topic_assets.${column}`);
  } finally {
    database.close();
  }
  assert.equal(SCHEMA_VERSION, 3);
  assert.equal(INDEX_CONTRACT, "mql5-chm-index-v3-assets-v4");
});

test("topic schema stores JavaScript UTF-16 content lengths for supplementary Unicode", () => {
  const database = new DatabaseSync(":memory:");
  try {
    createSchema(database);
    database.prepare(`
      INSERT INTO sources(source, chm_filename, chm_sha256, chm_bytes, topic_count, section_count)
      VALUES('mql5', 'mql5.chm', ?, 1, 1, 1)
    `).run("a".repeat(64));
    const content = "A\ud83d\ude00B";
    database.prepare(`
      INSERT INTO topics(
        topic_id, source, internal_path, title, normalized_title, breadcrumb,
        signature, content_sha256, content, content_length
      ) VALUES(?, 'mql5', 'astral.htm', 'Astral', 'astral', 'Astral', '', ?, ?, ?)
    `).run(
      makeTopicId("mql5", "astral.htm"),
      createHash("sha256").update(content, "utf8").digest("hex"),
      content,
      content.length,
    );
    const row = database.prepare(`
      SELECT content, content_length AS contentLength, length(content) AS sqliteLength FROM topics
    `).get();
    assert.equal(row.contentLength, 4);
    assert.equal(row.content.length, 4);
    assert.equal(row.sqliteLength, 3);
  } finally {
    database.close();
  }
});

test("initial source-only corpus revision uses real NUL-delimited canonical bytes", () => {
  assert.equal(
    computeCorpusRevision(SOURCE_DEFINITIONS),
    "8d058569d975ec5b5ec419770d952757acd0ea51ad8b63fe78eb49fb00751adc",
  );
  assert.throws(
    () => computeCorpusRevision(SOURCE_DEFINITIONS.slice(0, 2)),
    /exactly these sources|Missing or invalid SHA-256/,
  );
});

test("representative v1 topic IDs remain stable in schema v3", () => {
  assert.equal(makeTopicId("mql5", "ontick.htm"), "mql5:88cfa0c6607b1dc2827dc4ff");
  assert.equal(makeTopicId("mql5", "positionselectbyticket.htm"), "mql5:317220fffc831a69d7f0cfe5");
  assert.equal(makeTopicId("mql5", "ordersend.htm"), "mql5:97448830fb7a699ce8db9b3c");
  assert.equal(makeTopicId("mql5", "copybuffer.htm"), "mql5:a781b9698a284ee42633665f");
});

test("internal link resolution accepts confined HTML targets and rejects unsafe or external targets", () => {
  assert.deepEqual(resolveInternalLink("reference/trading/order.htm", "../types.htm#enum%5Fvalue"), {
    targetInternalPath: "reference/types.htm",
    targetFragment: "enum_value",
  });
  assert.deepEqual(resolveInternalLink("reference/trading/order.htm", "#return"), {
    targetInternalPath: "reference/trading/order.htm",
    targetFragment: "return",
  });
  assert.equal(resolveInternalLink("reference/order.htm", "../../escape.htm"), null);
  assert.equal(resolveInternalLink("reference/order.htm", "https://www.mql5.com/en/docs"), null);
  assert.equal(resolveInternalLink("reference/order.htm", "javascript:alert(1)"), null);
  assert.equal(resolveInternalLink("reference/order.htm", "%68%74%74%70%73%3A%2F%2Fevil.test/x.htm"), null);
  assert.equal(resolveInternalLink("reference/order.htm", "image.png"), null);
  assert.equal(resolveInternalLink("reference/order.htm", "%2e%2e/%2e%2e/escape.htm"), null);
});

test("bounded link metadata and signatures never split a Unicode surrogate pair", () => {
  const longFragment = `${"a".repeat(299)}😀tail`;
  const resolved = resolveInternalLink("reference/order.htm", `#${longFragment}`);
  assert.ok(resolved);
  assert.ok(resolved.targetFragment.length <= 300);
  assert.equal(hasUnpairedSurrogate(resolved.targetFragment), false);

  const longLabel = `${"a".repeat(299)}😀tail`;
  const linkedTopic = parseHtmlTopic(
    `<div id="help"><h1>Demo</h1><p><a href="other.htm">${longLabel}</a></p></div>`,
    { source: "mql5", internalPath: "demo.htm" },
  );
  assert.ok(linkedTopic.links[0].label.length <= 300);
  assert.equal(hasUnpairedSurrogate(linkedTopic.links[0].label), false);

  const declaration = `void Demo(${"a".repeat(786)}😀tail)`;
  const signatureTopic = parseHtmlTopic(
    `<div id="help"><h1>Demo</h1><p class="p_CodeExample">${declaration}</p></div>`,
    { source: "mql5", internalPath: "demo.htm" },
  );
  assert.ok(signatureTopic.signature.length <= 800);
  assert.equal(hasUnpairedSurrogate(signatureTopic.signature), false);
});

test("topic parsing extracts only safe help anchors, deduplicates them, and upgrades See also relationships", () => {
  const topic = parseHtmlTopic(
    `<!doctype html><html><head><title>Order Helper</title></head><body>
      <a href="outside.htm">Navigation</a>
      <div id="help"><h1>Order Helper</h1>
        <p>Uses <a href="../types.htm#request">request type</a>.</p>
        <p><a href="image.png">diagram</a> <a href="https://example.com">external</a></p>
        <p class="p_BoldTitles">See also</p>
        <p class="p_SeeAlso"><a href="../types.htm#request">Request Types</a>
          <a href="other.html">Other API</a></p>
      </div></body></html>`,
    { source: "mql5", internalPath: "reference/trading/order.htm" },
  );

  assert.equal(topic.contentSha256, createHash("sha256").update(topic.content, "utf8").digest("hex"));
  assert.deepEqual(topic.links, [
    {
      targetInternalPath: "reference/types.htm",
      targetFragment: "request",
      label: "Request Types",
      relationship: "see-also",
      ordinal: 0,
    },
    {
      targetInternalPath: "reference/trading/other.html",
      targetFragment: "",
      label: "Other API",
      relationship: "see-also",
      ordinal: 1,
    },
  ]);
});

test("section offsets come from the rendered heading nodes, not earlier matching text", () => {
  const topic = parseHtmlTopic(
    `<div id="help"><h1>Demo</h1><p>Parameters appear here.</p>
      <pre>DemoParameters()</pre><h2>Parameters</h2><p>Actual section.</p></div>`,
    { source: "mql5", internalPath: "demo.htm" },
  );

  assert.equal(topic.sections.length, 2);
  const actualHeadingOffset = topic.content.lastIndexOf("Parameters");
  assert.ok(actualHeadingOffset > topic.content.indexOf("Parameters"));
  assert.equal(topic.sections[1].heading, "Parameters");
  assert.equal(topic.sections[1].startOffset, actualHeadingOffset);
  assert.equal(topic.sections[1].content, "Parameters\nActual section.");
  assert.match(topic.sections[0].content, /Parameters appear here\./);
  assert.match(topic.sections[0].content, /DemoParameters\(\)/);

  const multilineHeading = parseHtmlTopic(
    `<div id="help"><h1>Demo</h1><p class="p_H4">bool Demo(<br>int value)</p><p>Body.</p></div>`,
    { source: "mql5", internalPath: "multiline-heading.htm" },
  );
  assert.equal(multilineHeading.sections.length, 1);
});

test("signature extraction returns only the declaration whose callable matches the topic title", async () => {
  const loadTopic = async (name) => parseHtmlTopic(
    decodeHtml(await readFile(new URL(`../build/extracted/mql5/${name}.htm`, import.meta.url))),
    { source: "mql5", internalPath: `${name}.htm` },
  );

  const compareEqual = await loadTopic("compareequal");
  assert.match(compareEqual.signature, /\bCompareEqual\s*\(/u);
  assert.doesNotMatch(compareEqual.signature, /\bvector::Compare\s*\(/u);
  assert.equal((await loadTopic("carrayobj")).signature, "");
  assert.equal((await loadTopic("resources")).signature, "");
  for (const [name, callable] of [
    ["ontick", "OnTick"],
    ["ordersend", "OrderSend"],
    ["copybuffer", "CopyBuffer"],
  ]) {
    assert.match((await loadTopic(name)).signature, new RegExp(`\\b${callable}\\s*\\(`, "u"));
  }
});

test("signature extraction preserves matching const methods and templated dotted titles", () => {
  const balance = parseHtmlTopic(
    `<html><head><title>Balance</title></head><body><div id="help">
      <h1>Balance</h1><p class="p_CodeExample">double  Balance() const</p>
    </div></body></html>`,
    { source: "mql5", internalPath: "balance.htm" },
  );
  assert.equal(balance.signature, "double  Balance() const");

  const create = parseHtmlTopic(
    `<html><head><title>matrix&lt;T&gt;.Create</title></head><body><div id="help">
      <h1>matrix&lt;T&gt;.Create</h1><p class="p_CodeExample">bool matrix&lt;T&gt;::Create(int size) const</p>
    </div></body></html>`,
    { source: "mql5", internalPath: "matrix-create.htm" },
  );
  assert.equal(create.signature, "bool matrix<T>::Create(int size) const");

  const python = parseHtmlTopic(
    `<html><head><title>account_info</title></head><body><div id="help">
      <h1>account_info</h1><p class="p_CodeExample">account_info()</p>
    </div></body></html>`,
    { source: "mql5", internalPath: "account-info-python.htm" },
  );
  assert.equal(python.signature, "account_info()");

  const pythonWithTerminator = parseHtmlTopic(
    `<html><head><title>order_send</title></head><body><div id="help">
      <h1>order_send</h1><p class="p_CodeExample">order_send(<br> request<br> );</p>
    </div></body></html>`,
    { source: "mql5", internalPath: "order-send-python.htm" },
  );
  assert.match(pythonWithTerminator.signature, /^order_send\([\s\S]*\);$/u);
});

test("signature extraction trusts the help H1 when the HTML title is stale or shortened", async () => {
  const cases = [
    ["caccountinfointeger", "InfoInteger"],
    ["cdealinfotimemsc", "TimeMsc"],
    ["ceditoncreate", "OnCreate"],
    ["cpositioninfotimeupdate", "TimeUpdate"],
    ["chistoryorderinfotimedonemsc", "TimeDoneMsc"],
    ["chighbufferrefreshcurrent", "RefreshCurrent"],
    ["ctreeclear", "Clear"],
    ["cchartautoscroll", "AutoScroll"],
    ["terminalinfointeger", "TerminalInfoInteger"],
  ];
  for (const [name, callable] of cases) {
    const topic = parseHtmlTopic(
      decodeHtml(await readFile(new URL(`../build/extracted/mql5/${name}.htm`, import.meta.url))),
      { source: "mql5", internalPath: `${name}.htm` },
    );
    assert.match(topic.signature, new RegExp(`\\b${callable}\\s*\\(`, "u"), name);
  }
});

test("explicit function spans corroborate help identity but never replace it with an arbitrary callable", () => {
  const declaration = parseHtmlTopic(
    `<html><head><title>Create</title></head><body><div id="help"><h1>OnCreate</h1>
      <p class="p_CodeExample">virtual bool <span class="f_Functions">OnCreate</span>()</p>
    </div></body></html>`,
    { source: "mql5", internalPath: "stale-create.htm" },
  );
  assert.equal(declaration.signature, "virtual bool OnCreate()");

  const exampleCall = parseHtmlTopic(
    `<html><head><title>Trading overview</title></head><body><div id="help"><h1>Trading overview</h1>
      <p class="p_CodeExample"><span class="f_Functions">OrderSend</span>(request,result);</p>
    </div></body></html>`,
    { source: "mql5", internalPath: "trading-overview.htm" },
  );
  assert.equal(exampleCall.signature, "");

  const copiedWrongDeclaration = parseHtmlTopic(
    `<html><head><title>OnSetColorBorder</title></head><body><div id="help"><h1>OnSetColorBorder</h1>
      <p class="p_CodeExample">virtual bool <span class="f_Functions">OnSetColorBackground</span>()</p>
    </div></body></html>`,
    { source: "mql5", internalPath: "wrong-copied-declaration.htm" },
  );
  assert.equal(copiedWrongDeclaration.signature, "");
});

test("query expansion configuration is versioned and bounded", async () => {
  const configuration = JSON.parse(
    await readFile(new URL("../config/mql5-query-expansions.json", import.meta.url), "utf8"),
  );
  assert.equal(configuration.schema_version, 1);
  assert.ok(configuration.expansions.length >= 5 && configuration.expansions.length <= 64);
  for (const expansion of configuration.expansions) {
    assert.ok(expansion.phrases.length >= 1 && expansion.phrases.length <= 8);
    assert.ok(expansion.terms.length >= 1 && expansion.terms.length <= 12);
    for (const value of [...expansion.phrases, ...expansion.terms]) {
      assert.ok(typeof value === "string" && value.length >= 1 && value.length <= 80);
    }
  }
});
