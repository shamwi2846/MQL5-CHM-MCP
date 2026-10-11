import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { performance } from "node:perf_hooks";
import { median } from "./IdentifierBenchmarkStatistics.mjs";

const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const normalized = text => String(text).replace(/\s+/gu, " ").trim();
const sha = /^[0-9a-f]{64}$/u;
const record = value => value !== null && typeof value === "object" && !Array.isArray(value);
const expectedCitationMatches = (value, expected, manifest, sectionId = expected.section_id) => {
  const source = manifest.sources[expected.source];
  return record(value) && value.source_file === source.filename && value.title === expected.title &&
    value.topic_id === expected.topic_id && value.section_id === sectionId && value.source_revision === expected.source_revision &&
    value.corpus_revision === manifest.corpus_revision && value.index_revision === manifest.index_revision;
};
export function validateQualityCases(value) {
  assert.ok(value && !Array.isArray(value) && value.schema_version === 1, "Unsupported quality case manifest");
  assert.ok(sha.test(value.corpus_revision) && sha.test(value.index_revision), "Missing frozen documentation identities");
  assert.ok(Array.isArray(value.cases) && value.cases.length === 32, "Quality manifest requires 32 cases");
  assert.deepEqual(Object.fromEntries(["exact", "concept", "typo", "absent", "focused"].map(k => [k, value.cases.filter(c => c.category === k).length])), { exact: 8, concept: 12, typo: 4, absent: 4, focused: 4 });
  const ids = new Set();
  for (const c of value.cases) {
    assert.ok(typeof c.id === "string" && c.id && !ids.has(c.id), "Duplicate or invalid case identity"); ids.add(c.id);
    assert.ok(c.arguments && c.expected && ["search", "read"].includes(c.operation), "Invalid quality case");
    assert.equal(c.operation, c.category === "focused" ? "read" : "search", "Category/operation mismatch");
    if (c.category === "absent") assert.equal(c.expected.forbid_exact, true);
    else {
      const e = c.expected;
      assert.ok(value.sources?.[e.source]?.filename && value.sources[e.source].sha256 === e.source_revision && sha.test(e.html_sha256), "Missing independent source commitments");
      assert.equal(e.topic_id, `${e.source}:${hash(Buffer.from(e.path.toLowerCase(), "utf8")).slice(0, 24)}`, "Expected path/ID mismatch");
      assert.ok(typeof e.title === "string" && e.title);
      if (c.operation === "search") assert.ok(Number.isInteger(e.max_rank) && e.max_rank >= 1 && e.max_rank <= 8);
      else assert.ok(typeof e.passage === "string" && e.passage && typeof e.section_id === "string" && e.section_id.startsWith(e.topic_id + ":s"));
    }
  }
  return value;
}
export function gradeQualityResponse(c, result, manifest) {
  const issues = [], content = result?.structuredContent;
  if (result?.isError || !record(content)) return { issues: ["Tool response is unavailable or failed"], rank: null };
  if (content.corpus_revision !== manifest.corpus_revision || content.index_sha256 !== manifest.index_revision) issues.push("Documentation identity mismatch");
  const citation = (entry, expected = null) => {
    if (!record(entry) || !["topic_id", "title", "source", "source_revision"].every(key => typeof entry[key] === "string")) { issues.push("Invalid citation entry"); return; }
    const p = entry.citation;
    if (!record(p) || p.topic_id !== entry.topic_id || p.corpus_revision !== manifest.corpus_revision || p.index_revision !== manifest.index_revision || p.title !== entry.title || p.section_id !== entry.section_id) { issues.push("Citation identity mismatch"); return; }
    const source = manifest.sources[entry.source];
    if (!source || p.source_file !== source.filename || p.source_revision !== source.sha256 || entry.source_revision !== source.sha256) issues.push("Citation source commitment mismatch");
    if (expected && (entry.title !== expected.title || entry.source !== expected.source || entry.topic_id !== expected.topic_id)) issues.push("Relevant result does not match original documentation");
  };
  let rank = null;
  if (c.operation === "search") {
    if (!Array.isArray(content.results) || content.count !== content.results.length || content.query !== c.arguments.query || content.source !== c.arguments.source || content.results.length > c.arguments.limit) return { issues: [...issues, "Invalid search response"], rank };
    for (const entry of content.results) citation(entry);
    if (c.expected.forbid_exact) {
      if (content.results.some(r => record(r) && r.match_kind === "exact")) issues.push("Misleading exact match for nonexistent identifier");
      if (!content.results.length && content.online_check?.recommended !== true) issues.push("Missing unavailable-documentation guidance");
    } else {
      const i = content.results.findIndex(r => record(r) && r.topic_id === c.expected.topic_id);
      rank = i < 0 ? null : i + 1;
      if (rank === null || rank > c.expected.max_rank) issues.push("Relevant result missing or below the required rank");
      else { citation(content.results[i], c.expected); if (c.expected.exact_required && content.results[i].match_kind !== "exact") issues.push("Identifier was not classified as exact"); }
    }
  } else {
    citation(content, c.expected);
    if (content.topic_id !== c.expected.topic_id || content.section_id !== c.expected.section_id || content.section_heading !== c.expected.section_heading || content.focus_match !== c.expected.focus_match) issues.push("Focused section mismatch");
    const blocks = Array.isArray(result.content) ? result.content : [];
    if (!Array.isArray(result.content) || blocks.some(block => !record(block) || typeof block.type !== "string" || (block.type === "text" && typeof block.text !== "string"))) issues.push("Invalid text content blocks");
    const text = normalized(blocks.filter(block => record(block) && block.type === "text" && typeof block.text === "string").map(block => block.text).join("\n"));
    if (!text.includes(normalized(c.expected.passage))) issues.push("Independently verified passage missing");
    if (!text.includes(c.expected.topic_id) || !text.includes(c.expected.section_id) || !text.includes(c.expected.source_revision.slice(0, 12))) issues.push("Text citation missing or incorrect");
    const images = Array.isArray(content.images) ? content.images : [];
    const imageLimit = c.arguments.image_limit ?? 5;
    if (!Array.isArray(content.images) || !Number.isInteger(content.image_count) || content.image_count < images.length || images.length > imageLimit || images.some(image => !record(image))) issues.push("Invalid image references");
    if (c.arguments.include_images === false && (images.length || content.image_count !== 0 || content.next_image_cursor !== null)) issues.push("Image evidence returned when disabled");
    if (c.expected.image) {
      const image = images.find(image => record(image) && image.asset_id === c.expected.image.asset_id);
      if (!image || image.bytes !== c.expected.image.bytes || image.section_id !== c.expected.image.section_id || !expectedCitationMatches(image.citation, c.expected, manifest, c.expected.image.section_id)) issues.push("Image/section commitment mismatch");
    }
  }
  return { issues, rank };
}
export async function measureQuality(client, manifest, samples = 9) {
  validateQualityCases(manifest);
  assert.equal(samples, 9, "Quality measurements use nine warm samples");
  const cases = [];
  const safeCall = async parameters => {
    try { return await client.callTool(parameters); }
    catch (error) { return { isError: true, content: [], protocol_error: String(error?.message ?? error).slice(0, 2048) }; }
  };
  for (const c of manifest.cases) {
    const tool = c.operation === "search" ? "mql5_chm_search" : "mql5_chm_read";
    const call = () => safeCall({ name: tool, arguments: c.arguments });
    const warm = await call(), initial = gradeQualityResponse(c, warm, manifest), issues = [...initial.issues];
    const timings = [], bytes = [], commitments = [];
    for (let i = 0; i < samples; i++) {
      const start = performance.now(), result = await call(); timings.push(performance.now() - start);
      const serialized = JSON.stringify(result); bytes.push(Buffer.byteLength(serialized)); commitments.push(hash(serialized));
      issues.push(...gradeQualityResponse(c, result, manifest).issues.map(issue => `Sample ${i + 1}: ${issue}`));
    }
    if (c.expected.image) {
      const image = await safeCall({ name: "mql5_chm_read_image", arguments: { asset_id: c.expected.image.asset_id } });
      const blocks = Array.isArray(image?.content) ? image.content : [];
      const block = blocks.find(block => record(block) && block.type === "image" && typeof block.data === "string"), expected = c.expected.image;
      const metadata = image?.structuredContent;
      // The frozen ControlsButton case has one independently verified association;
      // shared assets do not universally use the requesting topic as their primary citation.
      if (!record(image) || image.isError || !Array.isArray(image.content) || blocks.some(block => !record(block)) || !block || hash(Buffer.from(block.data, "base64")) !== expected.sha256 ||
          !record(metadata) || metadata.asset_id !== expected.asset_id || metadata.bytes !== expected.bytes || metadata.sha256 !== expected.sha256 ||
          metadata.source !== c.expected.source || metadata.source_revision !== c.expected.source_revision || metadata.corpus_revision !== manifest.corpus_revision || metadata.index_revision !== manifest.index_revision ||
          !expectedCitationMatches(metadata.primary_topic_citation, c.expected, manifest, expected.section_id)) issues.push("Original image bytes or citation changed");
      const following = await safeCall({ name: "mql5_chm_read", arguments: { topic_id: c.expected.topic_id, section_id: expected.absent_section, max_chars: 500 } });
      const followingContent = following?.structuredContent, followingImages = followingContent?.images;
      if (!record(following) || following.isError || !record(followingContent) || !Array.isArray(followingImages) || followingImages.some(image => !record(image) || typeof image.asset_id !== "string")) issues.push("Invalid following-section response");
      else {
        if (followingContent.topic_id !== c.expected.topic_id || followingContent.section_id !== expected.absent_section || followingContent.source !== c.expected.source || followingContent.source_revision !== c.expected.source_revision ||
            followingContent.corpus_revision !== manifest.corpus_revision || followingContent.index_sha256 !== manifest.index_revision || !expectedCitationMatches(followingContent.citation, c.expected, manifest, expected.absent_section)) issues.push("Following-section identity mismatch");
        if (!Number.isInteger(followingContent.image_count) || followingContent.image_count !== followingImages.length || followingContent.next_image_cursor !== null) issues.push("Following-section image evidence is incomplete");
        if (followingImages.some(image => image.asset_id === expected.asset_id)) issues.push("Image incorrectly associated with following section");
      }
    }
    cases.push({ id: c.id, category: c.category, status: issues.length ? "failed" : "passed", issues: [...new Set(issues)], relevant_result_rank: initial.rank, warm_samples_ms: timings, median_ms: median(timings), response_bytes: bytes, response_sha256: commitments, initial_response: warm });
  }
  return { schema_version: 1, operation: "documentation_quality", status: cases.every(c => c.status === "passed") ? "passed" : "failed", corpus_revision: manifest.corpus_revision, index_revision: manifest.index_revision, samples_per_case: samples, cases, timing_scope: "Warm local stdio measurements, descriptive only; no latency acceptance threshold." };
}
