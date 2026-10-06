import assert from "node:assert/strict";
import { lstat, mkdir, readFile, rename, rm, stat, symlink, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { createSearchService, encodeImageCursor } from "../src/search-service.mjs";

import { buildFixture, sha256, PNG } from "./helpers/runtime-fixture.mjs";

for (const version of [1, 2, 3, 4]) {
  test(`schema-3 runtime opens image contract v${version} for current use or rollback`, async () => {
    const fixture = await buildFixture({ indexContract: `mql5-chm-index-v3-assets-v${version}` });
    let service;
    try {
      service = await createSearchService({ root: fixture.root });
      assert.equal(service.status().index_revision, fixture.databaseHash);
      assert.equal(service.readImage({ asset_id: fixture.assets[0].assetId }).metadata.sha256, sha256(PNG));
    } finally {
      service?.close();
      await rm(fixture.root, { recursive: true, force: true });
    }
  });
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

test("schema-2 and schema-3 startup reject the wrong SQLite application ID", async () => {
  for (const schemaVersion of [2, 3]) {
    const fixture = await buildFixture({ schemaVersion, databaseApplicationId: 0 });
    let opened;
    try {
      await assert.rejects(
        async () => {
          opened = await createSearchService({ root: fixture.root });
          return opened;
        },
        (error) => error?.code === "INVALID_INDEX" && /application ID/i.test(error.message),
      );
    } finally {
      opened?.close();
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("schema-2 and schema-3 startup reject SQLite user_version drift", async () => {
  for (const schemaVersion of [2, 3]) {
    const fixture = await buildFixture({
      schemaVersion,
      databaseUserVersion: schemaVersion === 2 ? 3 : 2,
    });
    let opened;
    try {
      await assert.rejects(
        async () => {
          opened = await createSearchService({ root: fixture.root });
          return opened;
        },
        (error) => error?.code === "INVALID_INDEX" && /schema version/i.test(error.message),
      );
    } finally {
      opened?.close();
      await rm(fixture.root, { recursive: true, force: true });
    }
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
