import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, rename, rm, stat, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

import { createSchema, makeTopicId } from "../src/indexer.mjs";
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

async function buildFixture({
  schemaVersion = 3,
  indexContract = "mql5-chm-index-v3-assets-v1",
  invalidIdentity = null,
  invalidIntegrity = null,
} = {}) {
  const root = path.join(tmpdir(), `mql5-chm-v12-runtime-${process.pid}-${Date.now()}`);
  const candidate = path.join(root, "candidate");
  await mkdir(schemaVersion === 3 ? path.join(candidate, "assets", "mql5") : candidate, { recursive: true });
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
  if (schemaVersion === 2) {
    database.exec(`
      PRAGMA foreign_keys = OFF;
      DROP TABLE sources;
      CREATE TABLE sources (
        source TEXT PRIMARY KEY,
        chm_filename TEXT NOT NULL,
        chm_sha256 TEXT NOT NULL CHECK(length(chm_sha256) = 64),
        chm_bytes INTEGER NOT NULL CHECK(chm_bytes > 0),
        http_last_modified TEXT,
        http_etag TEXT,
        retrieved_at TEXT NOT NULL,
        topic_count INTEGER NOT NULL CHECK(topic_count >= 0),
        section_count INTEGER NOT NULL CHECK(section_count >= 0)
      ) STRICT;
      PRAGMA foreign_keys = ON;
    `);
  }

  const insertSource = database.prepare(
    schemaVersion === 3
      ? "INSERT INTO sources(source,chm_filename,chm_sha256,chm_bytes,topic_count,section_count) VALUES(?,?,?,?,?,?)"
      : "INSERT INTO sources(source,chm_filename,chm_sha256,chm_bytes,http_last_modified,http_etag,retrieved_at,topic_count,section_count) VALUES(?,?,?,?,?,?,?,?,?)",
  );
  const insertTopic = database.prepare(
    "INSERT INTO topics(topic_id,source,internal_path,title,normalized_title,breadcrumb,signature,content_sha256,content,content_length) VALUES(?,?,?,?,?,?,?,?,?,?)",
  );
  const insertSection = database.prepare(
    "INSERT INTO sections(section_id,topic_id,ordinal,heading,start_offset,end_offset,content) VALUES(?,?,?,?,?,?,?)",
  );
  const insertAlias = database.prepare(
    "INSERT INTO aliases(alias,normalized_alias,topic_id,source_kind) VALUES(?,?,?,?)",
  );
  const insertFts = database.prepare(
    "INSERT INTO search_fts(topic_id,section_id,source,title,aliases,heading,breadcrumb,body) VALUES(?,?,?,?,?,?,?,?)",
  );
  const topicIds = [];
  const firstTopicBySource = new Map();
  let secondMql5TopicId = null;
  database.exec("BEGIN IMMEDIATE");
  try {
    if (invalidIdentity === "topic-noncanonical" || invalidIntegrity === "topic-extension") {
      database.exec("PRAGMA defer_foreign_keys = ON");
    }
    for (const source of Object.keys(SOURCE_COUNTS)) {
      if (schemaVersion === 3) {
        insertSource.run(source, sources[source].filename, sources[source].sha256, sources[source].bytes, SOURCE_COUNTS[source], SOURCE_COUNTS[source]);
      } else {
        insertSource.run(
          source,
          sources[source].filename,
          sources[source].sha256,
          sources[source].bytes,
          null,
          null,
          NOW,
          SOURCE_COUNTS[source],
          SOURCE_COUNTS[source],
        );
      }
      for (let index = 0; index < SOURCE_COUNTS[source]; index += 1) {
        const internalPath = `topic-${index}.htm`;
        const topicId = makeTopicId(source, internalPath);
        const title = index === 0 ? `${source} image fixture` : `${source} topic ${index}`;
        const content = `${title}\nVerified documentation text.`;
        const sectionId = `${topicId}:s000`;
        const aliasDefinitions = source === "mql5" && index === 0
          ? [
            { alias: title, normalized: title.toLowerCase(), sourceKind: "html-title" },
            { alias: "\u{10000}", normalized: "\u{10000}", sourceKind: "html-keyword" },
          ]
          : [{ alias: title, normalized: title.toLowerCase(), sourceKind: "html-title" }];
        insertTopic.run(topicId, source, internalPath, title, title.toLowerCase(), title, "", sha256(content), content, content.length);
        for (const alias of aliasDefinitions) {
          insertAlias.run(alias.alias, alias.normalized, topicId, alias.sourceKind);
        }
        insertSection.run(sectionId, topicId, 0, title, 0, content.length, content);
        insertFts.run(
          topicId,
          sectionId,
          source,
          title,
          aliasDefinitions.map((alias) => alias.alias).join(" | "),
          title,
          title,
          content,
        );
        if (index === 0) firstTopicBySource.set(source, topicId);
        if (source === "mql5" && index === 0) topicIds.push(topicId, sectionId);
        if (source === "mql5" && index === 1) secondMql5TopicId = topicId;
      }
    }

    const assetDefinitions = (schemaVersion === 3 ? [
      { internalPath: "images/diagram-a.png", bytes: PNG, mime: "image/png", exposure: "exposed", reason: "technical-in-help", caption: "Technical diagram A" },
      { internalPath: "images/icon-b.png", bytes: PNG, mime: "image/png", exposure: "exposed", reason: "technical-in-help", caption: "Technical icon B" },
      { internalPath: "copyright.gif", bytes: GIF, mime: "image/gif", exposure: "excluded", reason: "decorative-denylist", caption: "Copyright" },
    ] : []).map((asset) => {
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
    if (schemaVersion === 3) {
      insertOccurrence.run(topicIds[0], 0, assetDefinitions[0].assetId, topicIds[1], 0, "", "", "Diagram A", "Nearby A", "Diagram A", "alt");
      insertOccurrence.run(topicIds[0], 1, assetDefinitions[0].assetId, topicIds[1], 3, "", "", "Diagram A repeated", "Nearby A", "Diagram A repeated", "alt");
      insertOccurrence.run(topicIds[0], 2, assetDefinitions[1].assetId, topicIds[1], 6, "", "Technical icon", "Icon B", "Nearby B", "Technical icon", "title");
      insertOccurrence.run(topicIds[0], 3, assetDefinitions[2].assetId, topicIds[1], 9, "", "", "Copyright", "", "Copyright", "alt");
    }

    const hasLinkFixture = typeof invalidIntegrity === "string" && invalidIntegrity.startsWith("link-");
    if (hasLinkFixture) {
      database.prepare(
        "INSERT INTO topic_links(source_topic_id,ordinal,target_topic_id,target_internal_path,target_fragment,label,relationship,resolution_status) VALUES(?,?,?,?,?,?,?,?)",
      ).run(topicIds[0], 0, secondMql5TopicId, "topic-1.htm", "", "Related topic", "inline", "resolved");
    }

    if (invalidIdentity === "topic-path") {
      database.prepare("UPDATE topics SET internal_path='tampered.htm' WHERE topic_id=?").run(topicIds[0]);
    } else if (invalidIdentity === "topic-noncanonical") {
      const noncanonicalPath = "/topic-0.htm";
      const noncanonicalTopicId = `mql5:${sha256(noncanonicalPath.toLowerCase()).slice(0, 24)}`;
      const noncanonicalSectionId = `${noncanonicalTopicId}:s000`;
      database.prepare("UPDATE topic_assets SET topic_id=?, section_id=? WHERE topic_id=?").run(
        noncanonicalTopicId,
        noncanonicalSectionId,
        topicIds[0],
      );
      database.prepare("UPDATE aliases SET topic_id=? WHERE topic_id=?").run(noncanonicalTopicId, topicIds[0]);
      database.prepare("UPDATE sections SET topic_id=?, section_id=? WHERE topic_id=?").run(
        noncanonicalTopicId,
        noncanonicalSectionId,
        topicIds[0],
      );
      database.prepare("UPDATE search_fts SET topic_id=?, section_id=? WHERE topic_id=?").run(
        noncanonicalTopicId,
        noncanonicalSectionId,
        topicIds[0],
      );
      database.prepare("UPDATE topics SET topic_id=?, internal_path=? WHERE topic_id=?").run(
        noncanonicalTopicId,
        noncanonicalPath,
        topicIds[0],
      );
      topicIds[0] = noncanonicalTopicId;
      topicIds[1] = noncanonicalSectionId;
    } else if (invalidIdentity === "section-ordinal") {
      database.prepare("UPDATE sections SET ordinal=1000 WHERE section_id=?").run(topicIds[1]);
    }

    if (invalidIntegrity === "topic-extension") {
      const textPath = "topic-0.txt";
      const textTopicId = `mql5:${sha256(textPath.toLowerCase()).slice(0, 24)}`;
      const textSectionId = `${textTopicId}:s000`;
      database.prepare("UPDATE topic_assets SET topic_id=?, section_id=? WHERE topic_id=?").run(
        textTopicId,
        textSectionId,
        topicIds[0],
      );
      database.prepare("UPDATE aliases SET topic_id=? WHERE topic_id=?").run(textTopicId, topicIds[0]);
      database.prepare("UPDATE sections SET topic_id=?, section_id=? WHERE topic_id=?").run(
        textTopicId,
        textSectionId,
        topicIds[0],
      );
      database.prepare("UPDATE search_fts SET topic_id=?, section_id=? WHERE topic_id=?").run(
        textTopicId,
        textSectionId,
        topicIds[0],
      );
      database.prepare("UPDATE topics SET topic_id=?, internal_path=? WHERE topic_id=?").run(
        textTopicId,
        textPath,
        topicIds[0],
      );
      topicIds[0] = textTopicId;
      topicIds[1] = textSectionId;
    } else if (invalidIntegrity === "topic-content-hash") {
      database.prepare("UPDATE topics SET content_sha256=? WHERE topic_id=?").run("0".repeat(64), topicIds[0]);
    } else if (invalidIntegrity === "missing-section") {
      database.prepare(
        "DELETE FROM sections WHERE section_id=(SELECT s.section_id FROM sections s WHERE s.topic_id<>? LIMIT 1)",
      ).run(topicIds[0]);
    } else if (invalidIntegrity === "orphan-fts") {
      const orphanTopicId = `mql5:${"a".repeat(24)}`;
      database.prepare(
        "UPDATE search_fts SET topic_id=?, section_id=? WHERE rowid=(SELECT rowid FROM search_fts LIMIT 1)",
      ).run(orphanTopicId, `${orphanTopicId}:s000`);
    } else if (invalidIntegrity === "section-content") {
      database.prepare("UPDATE sections SET content='tampered' WHERE section_id=?").run(topicIds[1]);
    } else if (invalidIntegrity === "fts-body") {
      database.prepare("UPDATE search_fts SET body='tampered' WHERE section_id=?").run(topicIds[1]);
    } else if (invalidIntegrity === "alias-normalization") {
      database.prepare(
        "UPDATE aliases SET normalized_alias='tampered', source_kind='unknown' WHERE topic_id=? AND source_kind='html-title'",
      ).run(
        topicIds[0],
      );
    } else if (invalidIntegrity === "occurrence-outside-section") {
      const topic = database.prepare(
        "SELECT title, breadcrumb, content, content_length FROM topics WHERE topic_id=?",
      ).get(topicIds[0]);
      const splitOffset = 3;
      const firstContent = topic.content.slice(0, splitOffset).trimEnd();
      const secondContent = topic.content.slice(splitOffset).trimEnd();
      const secondSectionId = `${topicIds[0]}:s001`;
      database.prepare("UPDATE sections SET end_offset=?, content=? WHERE section_id=?").run(
        splitOffset,
        firstContent,
        topicIds[1],
      );
      database.prepare("UPDATE search_fts SET body=? WHERE section_id=?").run(firstContent, topicIds[1]);
      insertSection.run(
        secondSectionId,
        topicIds[0],
        1,
        topic.title,
        splitOffset,
        topic.content_length,
        secondContent,
      );
      insertFts.run(
        topicIds[0],
        secondSectionId,
        "mql5",
        topic.title,
        `${topic.title} | \u{10000}`,
        topic.title,
        topic.breadcrumb,
        secondContent,
      );
      database.prepare(
        "UPDATE topic_assets SET section_id=? WHERE topic_id=? AND occurrence_ordinal IN (1,3)",
      ).run(secondSectionId, topicIds[0]);
      database.prepare("UPDATE sources SET section_count=section_count+1 WHERE source='mql5'").run();
      sources.mql5.section_count += 1;
    } else if (invalidIntegrity === "asset-source") {
      const bookTopicId = firstTopicBySource.get("mql5book");
      database.prepare(
        "UPDATE topic_assets SET topic_id=?, section_id=?, text_offset=0 WHERE topic_id=? AND occurrence_ordinal=0",
      ).run(bookTopicId, `${bookTopicId}:s000`, topicIds[0]);
    } else if (invalidIntegrity === "fts-options") {
      const rows = database.prepare(
        "SELECT topic_id,section_id,source,title,aliases,heading,breadcrumb,body FROM search_fts",
      ).all();
      database.exec(`
        DROP TABLE search_fts;
        CREATE VIRTUAL TABLE search_fts USING fts5(
          topic_id UNINDEXED,
          section_id UNINDEXED,
          source UNINDEXED,
          title,
          aliases,
          heading,
          breadcrumb,
          body,
          tokenize = 'porter',
          prefix = '2 3 4'
        );
      `);
      const insertWrongFts = database.prepare(
        "INSERT INTO search_fts(topic_id,section_id,source,title,aliases,heading,breadcrumb,body) VALUES(?,?,?,?,?,?,?,?)",
      );
      for (const row of rows) {
        insertWrongFts.run(
          row.topic_id,
          row.section_id,
          row.source,
          row.title,
          row.aliases,
          row.heading,
          row.breadcrumb,
          row.body,
        );
      }
    } else if (invalidIntegrity === "link-path") {
      database.prepare("UPDATE topic_links SET target_internal_path='topic-2.htm'").run();
    } else if (invalidIntegrity === "link-source") {
      database.prepare("UPDATE topic_links SET target_topic_id=?").run(firstTopicBySource.get("mql5book"));
    } else if (invalidIntegrity === "link-resolution-count") {
      database.prepare(
        "UPDATE topic_links SET target_topic_id=NULL, resolution_status='unresolved'",
      ).run();
    }

    const declaredLinkCount = hasLinkFixture ? 1 : 0;
    const declaredResolvedLinkCount = hasLinkFixture ? 1 : 0;
    const declaredSectionCount = Object.values(sources).reduce(
      (total, source) => total + source.section_count,
      0,
    );
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
    const metadata = schemaVersion === 3
      ? {
        schema_version: "3",
        index_contract: indexContract,
        corpus_sha256: corpus,
        image_policy_sha256: policyHash,
        asset_catalog_sha256: catalogHash,
        asset_tree_sha256: treeHash,
        total_topic_count: "4827",
        total_section_count: String(declaredSectionCount),
        topic_link_count: String(declaredLinkCount),
        resolved_topic_link_count: String(declaredResolvedLinkCount),
        unresolved_topic_link_count: "0",
        asset_count: "3",
        exposed_asset_count: "2",
        excluded_asset_count: "1",
        topic_asset_count: "4",
        exposed_topic_asset_count: "3",
        asset_total_bytes: String(totalAssetBytes),
      }
      : {
        schema_version: "2",
        build_timestamp: NOW,
        indexed_at: NOW,
        corpus_sha256: corpus,
        total_topic_count: "4827",
        total_section_count: String(declaredSectionCount),
        topic_link_count: String(declaredLinkCount),
        resolved_topic_link_count: String(declaredResolvedLinkCount),
        unresolved_topic_link_count: "0",
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
      schema_version: schemaVersion,
      corpus_sha256: corpus,
      corpus_revision: corpus,
      database: { filename: "mql5-docs.sqlite", sha256: databaseHash, bytes: databaseBytes },
      sources,
      total_topic_count: 4_827,
      total_section_count: declaredSectionCount,
      topic_link_count: declaredLinkCount,
      resolved_topic_link_count: declaredResolvedLinkCount,
      unresolved_topic_link_count: 0,
      indexed_at: NOW,
      build_timestamp: NOW,
    };
    if (schemaVersion === 3) {
      manifest.index_contract = indexContract;
      manifest.index_revision = databaseHash;
      manifest.assets = {
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
      };
    }
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

test("schema-2 rollback fixture passes the semantic startup verifier", async () => {
  const fixture = await buildFixture({ schemaVersion: 2 });
  let service;
  try {
    service = await createSearchService({ root: fixture.root });
    const status = service.status();
    assert.equal(status.schema_version, 2);
    assert.equal(status.active_revision, fixture.databaseHash);
    assert.equal(status.asset_support_available, false);
    assert.equal(status.assets.available, false);
    const result = service.search({ query: "mql5 image fixture", source: "mql5", limit: 1 });
    assert.equal(result.results[0].topic_id, fixture.topicId);
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

test("schema-3 startup rejects topic and section identities outside the public ID contract", async () => {
  for (const invalidIdentity of ["topic-path", "topic-noncanonical", "section-ordinal"]) {
    const fixture = await buildFixture({ invalidIdentity });
    try {
      await assert.rejects(
        async () => {
          const opened = await createSearchService({ root: fixture.root });
          opened.close();
        },
        (error) => error?.code === "INVALID_INDEX",
        invalidIdentity,
      );
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("schema-3 startup rejects semantic database integrity drift", async () => {
  const invalidCases = [
    "topic-extension",
    "topic-content-hash",
    "missing-section",
    "orphan-fts",
    "section-content",
    "fts-body",
    "alias-normalization",
    "occurrence-outside-section",
    "asset-source",
    "fts-options",
    "link-path",
    "link-source",
    "link-resolution-count",
  ];
  for (const invalidIntegrity of invalidCases) {
    const fixture = await buildFixture({ invalidIntegrity });
    try {
      await assert.rejects(
        async () => {
          const opened = await createSearchService({ root: fixture.root });
          opened.close();
        },
        (error) => error?.code === "INVALID_INDEX",
        invalidIntegrity,
      );
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});
