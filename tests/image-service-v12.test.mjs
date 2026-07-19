import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, rename, rm, stat, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

import { createSchema } from "../src/indexer.mjs";
import { createSearchService, encodeImageCursor, makeRuntimeAssetId } from "../src/search-service.mjs";

const SOURCE_COUNTS = { mql5: 4_134, mql5book: 581, neuronetworksbook: 112 };
const SOURCE_FILES = { mql5: "mql5.chm", mql5book: "mql5book.chm", neuronetworksbook: "neuronetworksbook.chm" };
const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);
const GIF = Buffer.from("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==", "base64");
const NOW = "2026-07-18T12:00:00.000Z";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function corpusRevision(sources) {
  const hash = createHash("sha256");
  for (const source of Object.keys(SOURCE_COUNTS)) hash.update(`${source}\0${sources[source].sha256}\0`, "utf8");
  return hash.digest("hex");
}

async function buildFixture({ indexContract = "mql5-chm-index-v3-assets-v1" } = {}) {
  const root = path.join(tmpdir(), `mql5-chm-v12-runtime-${process.pid}-${Date.now()}`);
  const candidate = path.join(root, "candidate");
  await mkdir(path.join(candidate, "assets", "mql5"), { recursive: true });
  const sources = {};
  for (const [source, filename] of Object.entries(SOURCE_FILES)) {
    const bytes = Buffer.from(`fixture-${source}`, "utf8");
    await writeFile(path.join(candidate, filename), bytes);
    sources[source] = {
      filename,
      sha256: sha256(bytes),
      bytes: bytes.length,
      http_last_modified: null,
      http_etag: null,
      retrieved_at: NOW,
      topic_count: SOURCE_COUNTS[source],
      section_count: SOURCE_COUNTS[source],
    };
  }
  const corpus = corpusRevision(sources);
  const policyHash = "d".repeat(64);
  const databasePath = path.join(candidate, "mql5-docs.sqlite");
  const database = new DatabaseSync(databasePath);
  createSchema(database);

  const insertSource = database.prepare(
    "INSERT INTO sources(source,chm_filename,chm_sha256,chm_bytes,topic_count,section_count) VALUES(?,?,?,?,?,?)",
  );
  const insertTopic = database.prepare(
    "INSERT INTO topics(topic_id,source,internal_path,title,normalized_title,breadcrumb,signature,content_sha256,content,content_length) VALUES(?,?,?,?,?,?,?,?,?,?)",
  );
  const insertSection = database.prepare(
    "INSERT INTO sections(section_id,topic_id,ordinal,heading,start_offset,end_offset,content) VALUES(?,?,?,?,?,?,?)",
  );
  const insertFts = database.prepare(
    "INSERT INTO search_fts(topic_id,section_id,source,title,aliases,heading,breadcrumb,body) VALUES(?,?,?,?,?,?,?,?)",
  );
  const topicIds = [];
  database.exec("BEGIN IMMEDIATE");
  try {
    for (const source of Object.keys(SOURCE_COUNTS)) {
      insertSource.run(source, sources[source].filename, sources[source].sha256, sources[source].bytes, SOURCE_COUNTS[source], SOURCE_COUNTS[source]);
      for (let index = 0; index < SOURCE_COUNTS[source]; index += 1) {
        const topicId = `${source}:${index.toString(16).padStart(24, "0")}`;
        const title = index === 0 ? `${source} image fixture` : `${source} topic ${index}`;
        const content = `${title}\nVerified documentation text.`;
        const sectionId = `${topicId}:s000`;
        insertTopic.run(topicId, source, `topic-${index}.htm`, title, title.toLowerCase(), title, "", sha256(content), content, content.length);
        insertSection.run(sectionId, topicId, 0, title, 0, content.length, content);
        insertFts.run(topicId, sectionId, source, title, "", title, title, content);
        if (source === "mql5" && index === 0) topicIds.push(topicId, sectionId);
      }
    }

    const assetDefinitions = [
      { internalPath: "images/diagram-a.png", bytes: PNG, mime: "image/png", exposure: "exposed", reason: "technical-in-help", caption: "Technical diagram A" },
      { internalPath: "images/icon-b.png", bytes: PNG, mime: "image/png", exposure: "exposed", reason: "technical-in-help", caption: "Technical icon B" },
      { internalPath: "copyright.gif", bytes: GIF, mime: "image/gif", exposure: "excluded", reason: "decorative-denylist", caption: "Copyright" },
    ].map((asset) => {
      const pathDigest = sha256(asset.internalPath.toLowerCase());
      return {
        ...asset,
        assetId: makeRuntimeAssetId("mql5", asset.internalPath),
        pathDigest,
        storageKey: `assets/mql5/${pathDigest}.bin`,
        byteHash: sha256(asset.bytes),
      };
    });
    const insertAsset = database.prepare(
      "INSERT INTO assets(asset_id,source,internal_path,path_sha256,storage_key,mime_type,sha256,byte_count,width,height,pixel_count,exposure,exposure_reason,canonical_caption) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    );
    for (const asset of assetDefinitions) {
      insertAsset.run(asset.assetId, "mql5", asset.internalPath, asset.pathDigest, asset.storageKey, asset.mime, asset.byteHash, asset.bytes.length, 1, 1, 1, asset.exposure, asset.reason, asset.caption);
      await writeFile(path.join(candidate, ...asset.storageKey.split("/")), asset.bytes);
    }
    const insertOccurrence = database.prepare(
      "INSERT INTO topic_assets(topic_id,occurrence_ordinal,asset_id,section_id,text_offset,figcaption_text,title_text,alt_text,nearby_text,contextual_caption,caption_source) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
    );
    insertOccurrence.run(topicIds[0], 0, assetDefinitions[0].assetId, topicIds[1], 0, "", "", "Diagram A", "Nearby A", "Diagram A", "alt");
    insertOccurrence.run(topicIds[0], 1, assetDefinitions[0].assetId, topicIds[1], 3, "", "", "Diagram A repeated", "Nearby A", "Diagram A repeated", "alt");
    insertOccurrence.run(topicIds[0], 2, assetDefinitions[1].assetId, topicIds[1], 6, "", "Technical icon", "Icon B", "Nearby B", "Technical icon", "title");
    insertOccurrence.run(topicIds[0], 3, assetDefinitions[2].assetId, topicIds[1], 9, "", "", "Copyright", "", "Copyright", "alt");

    const catalogRows = assetDefinitions
      .map((asset) => [
        asset.assetId, "mql5", asset.internalPath, asset.pathDigest, asset.storageKey, asset.mime, asset.byteHash,
        asset.bytes.length, 1, 1, 1, asset.exposure, asset.reason, asset.caption,
      ])
      .sort((left, right) => left[0].localeCompare(right[0]));
    const catalogHash = sha256(JSON.stringify(catalogRows));
    const treeHashState = createHash("sha256");
    for (const asset of [...assetDefinitions].sort((left, right) => left.storageKey.localeCompare(right.storageKey))) {
      treeHashState.update(`${asset.storageKey}\0${asset.byteHash}\0${asset.bytes.length}\0`, "utf8");
    }
    const treeHash = treeHashState.digest("hex");
    const totalAssetBytes = assetDefinitions.reduce((sum, asset) => sum + asset.bytes.length, 0);
    const metadata = {
      schema_version: "3",
      index_contract: indexContract,
      corpus_sha256: corpus,
      image_policy_sha256: policyHash,
      asset_catalog_sha256: catalogHash,
      asset_tree_sha256: treeHash,
      total_topic_count: "4827",
      total_section_count: "4827",
      topic_link_count: "0",
      resolved_topic_link_count: "0",
      unresolved_topic_link_count: "0",
      asset_count: "3",
      exposed_asset_count: "2",
      excluded_asset_count: "1",
      topic_asset_count: "4",
      exposed_topic_asset_count: "3",
      asset_total_bytes: String(totalAssetBytes),
    };
    const insertMetadata = database.prepare("INSERT INTO metadata(key,value) VALUES(?,?)");
    for (const [key, value] of Object.entries(metadata)) insertMetadata.run(key, value);
    database.exec("COMMIT");
    database.close();

    const databaseBytes = (await stat(databasePath)).size;
    const databaseHash = sha256(await readFile(databasePath));
    const revisionRoot = path.join(root, "revisions", databaseHash);
    await mkdir(path.dirname(revisionRoot), { recursive: true });
    await rename(candidate, revisionRoot);
    const emptyAssetSummary = { cataloged_count: 0, exposed_count: 0, excluded_count: 0, occurrence_count: 0, exposed_occurrence_count: 0, total_bytes: 0 };
    const totalAssetBytesValue = assetDefinitions.reduce((sum, asset) => sum + asset.bytes.length, 0);
    const manifest = {
      schema_version: 3,
      index_contract: indexContract,
      index_revision: databaseHash,
      corpus_sha256: corpus,
      corpus_revision: corpus,
      database: { filename: "mql5-docs.sqlite", sha256: databaseHash, bytes: databaseBytes },
      sources,
      total_topic_count: 4_827,
      total_section_count: 4_827,
      topic_link_count: 0,
      resolved_topic_link_count: 0,
      unresolved_topic_link_count: 0,
      assets: {
        directory: "assets",
        cataloged_count: 3,
        exposed_count: 2,
        excluded_count: 1,
        occurrence_count: 4,
        exposed_occurrence_count: 3,
        total_bytes: totalAssetBytesValue,
        catalog_sha256: catalogHash,
        tree_sha256: treeHash,
        policy_sha256: policyHash,
        by_source: {
          mql5: { cataloged_count: 3, exposed_count: 2, excluded_count: 1, occurrence_count: 4, exposed_occurrence_count: 3, total_bytes: totalAssetBytesValue },
          mql5book: emptyAssetSummary,
          neuronetworksbook: emptyAssetSummary,
        },
      },
      indexed_at: NOW,
      build_timestamp: NOW,
    };
    await writeFile(path.join(revisionRoot, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    await mkdir(path.join(root, "data"), { recursive: true });
    await writeFile(path.join(root, "data", "active.json"), `${JSON.stringify({ schema_version: 2, active_revision: databaseHash, previous_revision: null, activated_at: NOW }, null, 2)}\n`, "utf8");
    return { root, topicId: topicIds[0], sectionId: topicIds[1], assets: assetDefinitions, databaseHash };
  } catch (error) {
    try { database.exec("ROLLBACK"); } catch { /* already closed or rolled back */ }
    try { database.close(); } catch { /* already closed */ }
    await rm(root, { recursive: true, force: true });
    throw error;
  }
}

test("schema-3 service validates assets and serves bounded metadata then one verified image", async () => {
  const fixture = await buildFixture();
  let service;
  try {
    service = await createSearchService({ root: fixture.root });
    const status = service.status();
    assert.equal(status.schema_version, 3);
    assert.equal(status.active_revision, fixture.databaseHash);
    assert.equal(status.index_revision, fixture.databaseHash);
    assert.equal(status.asset_support_available, true);
    assert.deepEqual(
      [status.assets.cataloged, status.assets.exposed, status.assets.excluded, status.assets.occurrences, status.assets.exposed_occurrences],
      [3, 2, 1, 4, 3],
    );

    const first = service.read({ topic_id: fixture.topicId, image_limit: 1, max_chars: 500 });
    assert.equal(first.images.length, 1);
    assert.equal(first.images[0].asset_id, fixture.assets[0].assetId);
    assert.equal(first.images[0].occurrence_count, 2);
    assert.equal(first.image_count, 2);
    assert.ok(first.next_image_cursor);
    assert.equal(first.text.includes("Verified documentation text"), true);

    const continued = service.read({ topic_id: fixture.topicId, image_cursor: first.next_image_cursor, image_limit: 1 });
    assert.equal(continued.image_continuation, true);
    assert.equal(continued.text, "");
    assert.equal(continued.images[0].asset_id, fixture.assets[1].assetId);
    assert.equal(continued.next_image_cursor, null);
    assert.throws(
      () => service.read({ topic_id: fixture.topicId, section_id: `${fixture.topicId}:s001`, image_cursor: first.next_image_cursor }),
      (error) => error?.code === "INVALID_IMAGE_CURSOR",
    );
    assert.throws(
      () => service.read({
        topic_id: fixture.topicId,
        image_cursor: encodeImageCursor({ indexRevision: "e".repeat(64), topicId: fixture.topicId, sectionId: null, offset: 1 }),
      }),
      (error) => error?.code === "INVALID_IMAGE_CURSOR",
    );

    const image = service.readImage({ asset_id: fixture.assets[0].assetId });
    assert.equal(image.metadata.sha256, sha256(PNG));
    assert.deepEqual(Buffer.from(image.data, "base64"), PNG);
    assert.equal(image.metadata.association_count, 2);
    assert.equal(Object.hasOwn(image.metadata, "storage_key"), false);
    assert.throws(
      () => service.readImage({ asset_id: fixture.assets[2].assetId }),
      (error) => error?.code === "ASSET_NOT_AVAILABLE",
    );
    assert.throws(
      () => service.readImage({ asset_id: `mql5:asset:${"f".repeat(24)}` }),
      (error) => error?.code === "ASSET_NOT_AVAILABLE",
    );
    assert.throws(
      () => service.readImage({ asset_id: fixture.assets[0].assetId, path: "secret" }),
      (error) => error?.code === "INVALID_ARGUMENT",
    );

    const assetPath = path.join(fixture.root, "revisions", fixture.databaseHash, ...fixture.assets[0].storageKey.split("/"));
    await writeFile(assetPath, Buffer.alloc(PNG.length, 0));
    assert.throws(
      () => service.readImage({ asset_id: fixture.assets[0].assetId }),
      (error) => error?.code === "ASSET_INTEGRITY_FAILED",
    );
  } finally {
    service?.close();
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("schema-3 startup rejects files outside exact asset-tree closure", async () => {
  const fixture = await buildFixture();
  try {
    await writeFile(
      path.join(fixture.root, "revisions", fixture.databaseHash, "assets", "mql5", "untracked.bin"),
      Buffer.from("untracked"),
    );
    await assert.rejects(
      () => createSearchService({ root: fixture.root }),
      (error) => error?.code === "INVALID_INDEX",
    );
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("schema-3 startup rejects a junction replacing the immutable asset directory", async (context) => {
  if (process.platform !== "win32") {
    context.skip("Windows junction regression test");
    return;
  }

  const fixture = await buildFixture();
  const revisionRoot = path.join(fixture.root, "revisions", fixture.databaseHash);
  const assetDirectory = path.join(revisionRoot, "assets");
  const junctionTarget = path.join(fixture.root, "junction-target-assets");
  let junctionCreated = false;
  try {
    await rename(assetDirectory, junctionTarget);
    try {
      await symlink(junctionTarget, assetDirectory, "junction");
      junctionCreated = true;
    } catch (error) {
      if (["EPERM", "EACCES", "ENOTSUP", "ENOSYS", "EINVAL"].includes(error?.code)) {
        context.skip(`Windows junction creation is unavailable: ${error.code}`);
        return;
      }
      throw error;
    }

    assert.equal((await lstat(assetDirectory)).isSymbolicLink(), true, "fixture did not create a junction");
    await assert.rejects(
      () => createSearchService({ root: fixture.root }),
      (error) => error?.code === "INVALID_PACKAGE_FILE" && /asset|directory/i.test(error.message),
    );
  } finally {
    if (junctionCreated) await unlink(assetDirectory).catch(() => {});
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("schema-3 startup rejects an unknown self-consistent index contract", async () => {
  const fixture = await buildFixture({ indexContract: "mql5-chm-index-v3-assets-v999" });
  try {
    await assert.rejects(
      () => createSearchService({ root: fixture.root }),
      (error) => error?.code === "INVALID_MANIFEST" && /contract/i.test(error.message),
    );
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});
