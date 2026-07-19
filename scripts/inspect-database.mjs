import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';

const databasePath = process.argv[2];
if (!databasePath || process.argv.length !== 3) {
  throw new Error('Usage: node inspect-database.mjs <database-path>');
}

const db = new DatabaseSync(databasePath, { readOnly: true, allowExtension: false });
try {
  db.enableLoadExtension(false);
  db.enableDefensive(true);

  const scalar = (sql) => Number(db.prepare(sql).get().value);
  const integrity = db.prepare('PRAGMA integrity_check').all().map((row) => Object.values(row)[0]);
  const required = ['OnTick', 'PositionSelectByTicket', 'OrderSend', 'CopyBuffer'];
  const ranking = {};
  for (const query of required) {
    const row = db.prepare(`
      SELECT title, source
      FROM topics
      WHERE normalized_title = ?
      ORDER BY CASE source WHEN 'mql5' THEN 0 WHEN 'mql5book' THEN 1 ELSE 2 END, topic_id
      LIMIT 1
    `).get(query.toLowerCase());
    ranking[query] = row ?? null;
  }

  const topics = Object.fromEntries(
    db.prepare('SELECT topic_id, content_sha256 FROM topics ORDER BY topic_id')
      .all()
      .map((row) => [row.topic_id, row.content_sha256]),
  );
  const hasAssets = Number(db.prepare(`
    SELECT count(*) AS value
    FROM sqlite_master
    WHERE type = 'table' AND name IN ('assets', 'topic_assets')
  `).get().value) === 2;
  const metadata = Object.fromEntries(
    db.prepare('SELECT key, value FROM metadata').all().map((row) => [row.key, row.value]),
  );

  let assetCount = 0;
  let topicAssetCount = 0;
  let invalidAssetCount = 0;
  let invalidTopicAssetCount = 0;
  let assets = {};
  let assetSummary = {
    cataloged_count: 0,
    exposed_count: 0,
    excluded_count: 0,
    occurrence_count: 0,
    exposed_occurrence_count: 0,
    total_bytes: 0,
  };
  if (hasAssets) {
    assetCount = scalar('SELECT count(*) AS value FROM assets');
    topicAssetCount = scalar('SELECT count(*) AS value FROM topic_assets');
    invalidAssetCount = scalar(`
      SELECT count(*) AS value
      FROM assets
      WHERE length(asset_id) < 1
         OR length(path_sha256) != 64
         OR length(sha256) != 64
         OR byte_count <= 0
         OR width <= 0
         OR height <= 0
         OR pixel_count != width * height
         OR exposure NOT IN ('exposed', 'excluded')
    `);
    invalidTopicAssetCount = scalar(`
      SELECT count(*) AS value
      FROM topic_assets AS ta
      LEFT JOIN topics AS t ON t.topic_id = ta.topic_id
      LEFT JOIN assets AS a ON a.asset_id = ta.asset_id
      LEFT JOIN sections AS s ON s.section_id = ta.section_id
      WHERE t.topic_id IS NULL
         OR a.asset_id IS NULL
         OR (ta.section_id IS NOT NULL AND (s.section_id IS NULL OR s.topic_id != ta.topic_id))
    `);
    const occurrenceDigests = new Map();
    for (const row of db.prepare(`
      SELECT asset_id, topic_id, occurrence_ordinal, section_id, text_offset,
             figcaption_text, title_text, alt_text, nearby_text, contextual_caption, caption_source
      FROM topic_assets
      ORDER BY asset_id, topic_id, occurrence_ordinal
    `).all()) {
      let state = occurrenceDigests.get(row.asset_id);
      if (!state) {
        state = { hash: createHash('sha256'), count: 0 };
        occurrenceDigests.set(row.asset_id, state);
      }
      for (const value of [row.topic_id, row.occurrence_ordinal, row.section_id, row.text_offset, row.figcaption_text, row.title_text, row.alt_text, row.nearby_text, row.contextual_caption, row.caption_source]) {
        state.hash.update(`${value ?? ''}\0`, 'utf8');
      }
      state.count += 1;
    }
    assets = Object.fromEntries(db.prepare(`
      SELECT asset_id, sha256, byte_count, width, height, mime_type, exposure, exposure_reason, canonical_caption
      FROM assets
      ORDER BY asset_id
    `).all().map((row) => {
      const state = occurrenceDigests.get(row.asset_id);
      return [row.asset_id, {
        sha256: row.sha256,
        byte_count: Number(row.byte_count),
        width: Number(row.width),
        height: Number(row.height),
        mime_type: row.mime_type,
        exposure: row.exposure,
        exposure_reason: row.exposure_reason,
        canonical_caption: row.canonical_caption,
        occurrence_count: state?.count ?? 0,
        occurrence_sha256: state?.hash.digest('hex') ?? createHash('sha256').digest('hex'),
      }];
    }));
    assetSummary = {
      cataloged_count: assetCount,
      exposed_count: scalar("SELECT count(*) AS value FROM assets WHERE exposure='exposed'"),
      excluded_count: scalar("SELECT count(*) AS value FROM assets WHERE exposure='excluded'"),
      occurrence_count: topicAssetCount,
      exposed_occurrence_count: scalar("SELECT count(*) AS value FROM topic_assets AS ta JOIN assets AS a ON a.asset_id=ta.asset_id WHERE a.exposure='exposed'"),
      total_bytes: scalar('SELECT COALESCE(sum(byte_count),0) AS value FROM assets'),
    };
  }

  const result = {
    integrity,
    topic_count: scalar('SELECT count(*) AS value FROM topics'),
    section_count: scalar('SELECT count(*) AS value FROM sections'),
    fts_count: scalar('SELECT count(*) AS value FROM search_fts'),
    ranking,
    topics,
    metadata,
    has_assets: hasAssets,
    asset_count: assetCount,
    topic_asset_count: topicAssetCount,
    invalid_asset_count: invalidAssetCount,
    invalid_topic_asset_count: invalidTopicAssetCount,
    assets,
    asset_summary: assetSummary,
  };
  process.stdout.write(JSON.stringify(result));
} finally {
  db.close();
}
