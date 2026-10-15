# Portable Read-Only MQL5 CHM MCP v1.3.16

## Value Proposition

Give Codex and Claude Code fast, exact, offline access to the user's local MQL5 documentation and its technically useful diagrams, screenshots, charts, and object icons. Preserve text-search behavior while adding explicit source/index revisions, stable citations, bounded image discovery, exact original-image retrieval, and a safe reviewed path for adopting newer official CHMs.

Target user: a Windows Codex user developing and reviewing MQL5 code.

Core actions:

1. Search all three CHM corpora with source-aware and MQL5-aware ranking.
2. Read a bounded topic or focused passage with pagination, related-topic metadata, and bounded technical-image references.
3. Retrieve exactly one catalogued technical image by stable opaque asset ID.
4. Inspect the active corpus/index revision, asset-catalog status, and last manual update check.
5. Stage, review, activate, or roll back immutable documentation indexes outside the MCP runtime.

## Why an LLM Tool

Codex contributes intent recognition, API-name recognition, source selection, interpretation of retrieved diagrams, and application of local documentation to MQL5 engineering work. Bounded local retrieval avoids loading whole CHMs or noisy web pages. Images remain opt-in binary results and never change FTS ranking. When a question explicitly requires current information, the MCP recommends a domain-restricted official web query without performing network access itself.

## User Experience and Flows

There is no custom UI. All inputs and outputs are conversational or PowerShell maintenance commands.

Search documentation:

1. Codex submits an API name or documentation question.
2. The server ranks exact matches first, merges original and expanded full-text candidates by weighted reciprocal rank, and then adds bounded typo-tolerant matches.
3. Codex selects a stable topic or section ID and cites the exact returned title, stable topic ID, and the shared corpus or index revision.
4. When local evidence is absent, fuzzy-only, known stale, or explicitly required to be current, the result recommends an official-domain web check.

Read documentation:

1. Codex submits a stable topic ID returned by search.
2. The server returns a bounded topic or focused section plus a compact citation.
3. The result includes up to the requested number of related topics, prioritizing explicit See also links, then inline links, then same-title cross-source topics.
4. Codex follows the opaque continuation cursor only when more text from the same selection is needed.
5. By default the result also includes up to five deduplicated technical-image references. An independent opaque image cursor exposes further references without repeating the documentation passage.

Read an image:

1. Codex selects a stable asset ID returned by a topic read.
2. The server resolves only the catalog row, revalidates the opaque stored file, and returns exactly one original PNG or JPEG image content block.
3. Metadata contains no path and no duplicate base64. Unknown, decorative, unsupported, oversized, or guessed IDs disclose no bytes.

Inspect status:

1. Codex calls the status tool with no arguments.
2. The server returns the active corpus/index revision, per-source metadata, topic/link/asset counts, image-support availability, and the last validated manual update-check result when present.

Update documentation:

1. The user runs the update checker, which downloads only the three allowlisted official CHMs into temporary storage and compares hashes.
2. The user may stage either different CHMs or a same-corpus index-contract/policy upgrade; extraction, indexing, asset cataloguing, diffing, and all validation complete without changing the active pointer.
3. The user reviews the report and explicitly activates a specific 64-character index revision hash.
4. Codex is fully restarted to use the new index. Rollback atomically selects the prior verified revision; schema-2 rollback retains text tools and reports image support unavailable.

## Product Context

- Workspace root: `C:\Users\Shari\Desktop\MQL5 EAS\MQL5 CODEX`
- Development project root: the root of the `MQL5-CHM-MCP` repository, containing `package.json`, `src/`, and `scripts/`. Resolve commands relative to that checkout wherever it is stored.
- Windows version-resource queries use extended drive/UNC paths for Node and both 7-Zip binaries while retaining canonical recorded paths. Exact binary and license identities remain pinned. Metadata unavailability and native execution/CHM-codec failure are diagnosed separately from file damage: intact binaries are not downloaded or replaced, and pending recovery evidence is retained. Native 7-Zip path limits still apply; retry from a shorter package path and supported working directory.
- Initial trusted sources: `mql5.chm`, `mql5book.chm`, `neuronetworksbook.chm`
- Initial corpus: 4,134 + 581 + 112 = 4,827 HTML topics
- Initial searchable sections: 16,261
- Initial resolved topic links: 20,769
- Initial raster corpus: 798 files (797 PNG and one GIF), 11,652,126 bytes
- Initial in-topic image occurrences: 828
- Initial public technical set: 787 PNG assets and 811 occurrences
- Hosts: Codex and Claude Code on Windows x64
- Transport: local stdio
- Authentication: none
- Runtime: bundled Node.js exactly 24.17.0
- MCP SDK: pinned production v1 (`@modelcontextprotocol/sdk@1.29.0`)
- Search store: SQLite FTS5 opened read-only, with extensions disabled and defensive mode enabled
- Portability: the release ZIP contains only the active schema-3 revision, runtime, scripts, checksums, and licenses; it is published with a timestamp-free ZIP manifest sidecar

## Public MCP Interfaces

The initialize result carries concise server `instructions` (at most 1,500 characters, essentials within the first 512) that Codex and Claude Code show to the model: the status, lookup and read workflow; that an exact match only identifies a candidate until a returned passage supports the claim; text-only read flags and cursor continuation; reuse of a verified passage while the index revision is unchanged; citation fields; and the `require_current` freshness check. They name only registered tools and real input parameters (tested), and stay consistent with the companion skill.

All tools use `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`, and `openWorldHint: false`.
All bounded inputs are validated strictly. Out-of-range values are rejected and never silently clamped.

### `mql5_chm_search`

Inputs:

- `query`: required string, 1-200 characters
- `source`: optional `all`, `mql5`, `mql5book`, or `neuronetworksbook`; default `all`
- `limit`: optional integer 1-8; default 3
- `expand`: optional boolean; default `true`
- `require_current`: optional boolean; default `false`

Results:

- Stable topic/section IDs, source, title, breadcrumb, conservative signature, source revision, match kind, bounded matched terms, structured citation, and excerpt limited to 500 characters
- `match_kind` is one of `exact`, `fts`, `expanded`, or `fuzzy`
- `online_check` contains a recommendation boolean, a bounded reason enum, and a safe `site:mql5.com` query when recommended
- Full documentation text is never duplicated in structured output

Ranking precedence:

1. Exact normalized title or alias, with `mql5` API-reference priority.
2. A deterministic reciprocal-rank merge of original-query FTS5 candidates at weight `1.0` and MQL5 expansion candidates at the lower weight `0.35`; original-query candidates win ties.
3. Bounded trigram similarity over titles and aliases.

Exact API-like identifiers are never expanded in a way that displaces their exact match.
The typo fallback scores a bounded candidate set that covers every selected source before applying global similarity and source-priority ranking; the default `all` filter must not discard book or NeuroBook titles before scoring.

Performance without ranking changes (v1.3.14): exact title/alias lookups probe the `topics(source, normalized_title)` and `aliases(normalized_alias)` indexes and fetch candidates by primary key instead of scanning every topic of the source; the typo fallback builds its normalized title/alias trigram keys once per verified service; prepared statements are reused per SQL shape; and expansion terms are not generated once exact matches fill the requested limit. Results are identical to v1.3.13: the release compared complete `search` and `mql5_chm_lookup_identifiers` output for every stored title and alias across sources, limits, expansion settings and typo queries.
Returned signatures are conservative: a declaration is emitted only when its callable identifier matches the normalized topic title or the first trusted in-help H1. The H1 accommodates stale or shortened HTML titles. Lexical declaration guards exclude unrelated example code and declarations for other callable identifiers.

### `mql5_chm_lookup_identifiers`

Read-only identifier batch lookup, additive in 1.3.0. Input is a closed object with required `identifiers` (array of 1 to 16 ASCII identifiers or exact topic titles of at most 128 characters matching `^[A-Za-z_][A-Za-z0-9_]*(?: [A-Za-z0-9_]+)*$`; titles were added in 1.3.16. Names are matched literally: FTS terms are quoted, and a name is `exact` only when a topic title or alias equals the whole normalized name, with no identifier tokens extracted from it — for space-free identifiers this is the same result as before), optional `source` (the existing four-source filter, default `mql5`), `limit` (integer 1 to 3 per name, default 1), and `require_current` (boolean, default false). The complete input is validated before any query; no values are clamped. Names are returned in input order, including duplicates.

The service applies the existing single search with expansion disabled to each name. Output commits `source`, `limit`, `count` (input names), `result_count` (total candidates, at most 48), `corpus_revision`, `index_sha256`, and `lookups`. Each lookup contains `identifier`, `match_status` (`exact` if any candidate has exact search rank, otherwise `non_exact` for nonempty candidates or `none`), `count`, `online_check`, and up to three existing search results with full independent citations. Search status is not passage-level identifier proof. No passage, snippet or binary bytes are included in structured output. Native text supplies concise statuses and citations. Query failures fail the request without claiming partial success. The verified read-only index and all other tool interfaces remain unchanged.

### `mql5_chm_read`

Inputs:

- `topic_id`: required stable ID returned by search
- `section_id`: optional stable section ID
- `focus`: optional string, 1-200 characters
- `cursor`: optional opaque continuation cursor
- `max_chars`: optional integer 500-8,000; default 4,000
- `include_related`: optional boolean; default `true`
- `related_limit`: optional integer 0-5; default 3
- `include_images`: optional boolean; default `true`
- `image_limit`: optional integer 1-8; default 5
- `image_cursor`: optional opaque cursor bound to active index, topic, and selected section

Results:

- Source metadata, source/index revision, offsets, bounded passage, compact citation footer, structured citation, related-topic metadata, `next_cursor`, bounded `images`, `image_count`, and `next_image_cursor`
- `focus_match` is `exact`, `approximate`, or `none` for an initial focused read and `null` for unfocused reads and continuation pages. An exact match must occur in the returned bounded passage; a phrase extending beyond that passage is approximate. Token boundaries are checked against the original documentation, so truncating an identifier suffix cannot turn a partial match into an exact match. Complete identifier/phrase matches take priority over partial matches. Approximate and unmatched focus results include an explicit text notice; an unmatched focus without an explicit section falls back to the topic rather than an arbitrary section. Callers must verify the complete identifier in the actual returned passage before asserting support.
- Related topics contain metadata only and never duplicate their body text
- Image references contain only asset ID, contextual caption, detected MIME, dimensions, byte count, section ID, occurrence count, and topic citation; they never contain binary or base64
- Topic-wide reads cover the topic. Section/focus reads cover the selected section. Returned asset IDs are deduplicated while occurrence counts are retained and ordering is deterministic by section, rendered-text offset, and occurrence ordinal.
- Supplying `image_cursor` returns the next metadata page with a concise continuation message instead of repeating the documentation passage

Text continuation cursors use the authenticated payload `{v:2,i,t,s,o}` and domain `mql5-chm-read-cursor-v2\0`; image continuation cursors use payload `{v:1,i,t,s,o}` and the independent domain `mql5-chm-image-cursor-v1\0`. Both tags are truncated HMAC-SHA-256 values authenticated by one process-ephemeral 256-bit key. The index field `i` must equal the active index SHA-256 before the topic, section, or UTF-16 offset is accepted. Legacy text-cursor v1, prior-process, stale-revision, tampered, wrong-topic, and wrong-section cursors fail closed. The cursor semantics add no named MCP argument or response fields. All tool input objects are closed schemas, so unknown arguments fail validation.

### `mql5_chm_read_image`

Input:

- `asset_id`: required stable ID matching `^(mql5|mql5book|neuronetworksbook):asset:[0-9a-f]{24}$`

No path, URL, MIME override, batch, resize, output-file, variant, cursor, or arbitrary-file input is accepted.

Success result:

- `content` contains exactly one MCP image content block with the original base64 bytes and detected `image/png` or `image/jpeg` MIME
- `structuredContent` contains metadata only: asset ID, source, canonical caption, MIME, bytes, dimensions, SHA-256, association count, deterministic primary topic citation, source revision, corpus revision, and index revision
- Internal CHM paths, storage keys, local paths, and duplicate base64 are never returned

Errors are text-only. `ASSET_CATALOG_UNAVAILABLE` means the active rollback revision is schema 2. `ASSET_NOT_AVAILABLE` intentionally conflates unknown, excluded, unsupported, oversized, and guessed IDs. `ASSET_INTEGRITY_FAILED` means the prepared catalog file failed per-call validation.

### `mql5_chm_status`

Inputs: none.

Results:

- Active index revision and corpus revision; `index_sha256` remains a compatibility alias for the active index revision
- Index build/retrieval timestamps and topic/section totals
- Per-source filename, SHA-256, bytes, HTTP Last-Modified/ETag when observed, retrieval timestamp, topic count, and section count
- Asset-support availability; cataloged, exposed, excluded, occurrence, exposed-occurrence, and byte totals; per-source asset counts
- Last update-check timestamp, status, and candidate revision when a valid bounded local status report exists

The update-check report is advisory and mutable. A missing, stale, inaccessible, or malformed report is exposed as unavailable and never prevents access to the verified documentation index.

HTTP timestamps are labeled as HTTP metadata or retrieval time, never as a CHM build date.

## Index and Revision Model

- Server/package version: 1.3.16. Manifest and SQLite schema version: 3. Pointer schema: 2.
- `corpus_sha256` is the SHA-256 of the UTF-8 concatenation `source_id + NUL + lowercase_chm_sha256 + NUL` for `mql5`, `mql5book`, then `neuronetworksbook`. It intentionally depends only on the downloaded source set so the checker can name a candidate before extraction.
- `index_revision` is the lowercase SHA-256 of the completed schema-3 SQLite database. The database contains the complete asset catalog and asset-tree digest, so this identity binds text and image metadata without creating a self-hash cycle.
- SQLite identity-bearing data excludes build/retrieval times, ETags, and HTTP Last-Modified. Those values remain in the manifest. Identical inputs, index contract, and image policy must produce byte-identical databases and index revisions.
- SQLite metadata includes `index_contract`, the image-policy digest, asset-catalog digest, asset-tree digest, and exact counts. `index_contract` changes whenever extraction or indexing semantics change without a SQL-schema change. v1.3.16 emits `mql5-chm-index-v3-assets-v4`, introduced in v1.3.3 for DOM-ordered image associations and offset-aware trailing-whitespace trimming. The transitional runtime accepts rollback contracts `mql5-chm-index-v3-assets-v1` and `mql5-chm-index-v3-assets-v2`, and `mql5-chm-index-v3-assets-v3` as well as the current contract, while new candidate activation requires the current contract.
- Image occurrences use the latest preceding retained heading in source DOM order; occurrences before the first retained heading or in heading-free topics use the first section. An image may legitimately share the following heading's text offset while belonging to the preceding section. Trailing-whitespace removal updates recorded heading and image positions before final normalization, without inserting markers or changing rendered text.
- Each immutable revision lives under `revisions/<index_revision>/` and contains its three CHMs, database, manifest, corpus lock, stage report when staged, and the exact `assets/` tree.
- `data/active.json` is the only activation pointer. Schema 2 retains `active_revision`, `previous_revision`, and `activated_at`; revision fields identify indexes and are replaced atomically.
- Stage reports, transition journals, and update-status files distinguish index revisions from corpus revisions. `Update-Documentation.ps1 -Apply -Revision` accepts the staged index revision.
- Runtime accepts pointer schemas 1 and 2 and manifest/database schemas 2 and 3 for rollback compatibility. It confines all resolved paths under the project root and verifies pointer, manifest, CHMs, database, schema, FTS, counts, and schema-3 asset closure before serving tools.
- Stable topic IDs continue to derive only from source plus normalized internal CHM path, and section IDs derive from the topic ID plus a three-digit ordinal from 0 through 999. Startup recomputes these identities and rejects mismatches. Existing valid IDs remain unchanged after migration.
- Section boundaries are captured from the actual heading nodes during the deterministic HTML-to-text render pass. A matching word in prose, a signature, or an earlier code example cannot become a section start. Topic text, content hashes, section ordering, stable section IDs, and section totals remain unchanged except that section text ranges use the corrected rendered heading offsets.
- Text lengths, section offsets, image offsets, and pagination cursors use JavaScript UTF-16 code units because the runtime slices JavaScript strings. SQLite constraints and integrity checks must not reinterpret those values as Unicode code-point counts; JavaScript validates stored lengths directly, including supplementary-plane characters.
- Image-policy identity hashes UTF-8 policy text after canonicalizing CRLF or lone CR to LF, so Git checkout line-ending conversion cannot masquerade as a policy change. When corpus, schema, current index contract, and this image-policy SHA-256 are unchanged, a real rebuild must reproduce the active database hash. Equality means already current; drift is rejected before any journal, revision, checksum, stage report, update status, or active pointer mutation. Asset-reduction acknowledgement cannot bypass this deterministic-identity gate.
- Topic links are extracted only from anchors inside `div#help`. Eligible internal links are normalized relative to the source topic, fragments are retained, traversal is rejected, and assets/scripts/external schemes are ignored.
- Per-topic content hashes support changed-topic reports without affecting stable IDs.

### Retry-safe schema-2 migration

1. Validate the existing schema-2 active and previous revisions without modifying them.
2. Copy each legacy corpus-keyed revision through a temporary sibling into `revisions/<legacy database SHA-256>`. Existing equivalent destinations are accepted only after full validation; conflicts fail closed.
3. Atomically translate the pointer to schema 2 while preserving its active/previous selections and activation time.
4. Build schema 3 from the selected active CHMs, install it under its index revision, and run the full acceptance suite.
5. Activate schema 3 through the transition journal and retain the copied schema-2 index as `previous_revision`.
6. Retry after interruption is idempotent and cannot toggle revisions. Legacy originals remain untouched. Schema-2 rollback keeps search/read/status available and makes image reads return `ASSET_CATALOG_UNAVAILABLE`.
7. Portable packages contain only the active schema-3 revision and set `previous_revision` to `null`.

## Asset Catalog and Image Policy

Schema 3 adds:

- `assets`: stable asset ID, source, normalized internal path, full path digest, opaque storage key, detected MIME, SHA-256, byte count, width, height, pixel count, exposure classification/reason, caption components, and canonical caption.
- `topic_assets`: topic ID, occurrence ordinal, asset ID, section ID, rendered-text offset, normalized alt/nearby/contextual caption, and caption source. `(topic_id, occurrence_ordinal)` preserves repeated occurrences.

Identity and storage rules:

- `asset_id = <source>:asset:<first 24 hex of SHA-256(lowercase normalized CHM path)>`.
- Truncated-ID or case-folded normalized-path collisions fail indexing; IDs are never silently disambiguated.
- Indexing checks each raster file's size before reading it and rejects files above the policy `max_bytes`; retained catalog bytes are capped at 256 MiB in total. These maintenance-time memory bounds never change a valid index.
- Original bytes are copied exactly to `assets/<source>/<full-path-digest>.bin`. Runtime resolves only database-provided opaque storage keys and never converts a CHM path into a filesystem path.
- All 798 raster files are catalogued and externally preserved, including non-exposed artwork. Extracted HTML, CSS, JavaScript, XML, fonts, and other source artifacts are not shipped.
- The deterministic HTML-to-text pass records image offsets without inserting markers. Existing topic text and content hashes remain unchanged.
- v1.3.5 validation leaves the v4 extraction contract and existing genuine index identity unchanged. Prior schema-3 build descriptors and restored prior sets may use supported contracts v1–v4; new and recovered candidate sets require v4. Database and manifest contracts must agree, and complete recovery sets are semantically checked before any canonical rename or deletion.
- v1.3.6 shares raw-byte identifier checks between indexing and runtime validation: PNG chunk names contain four original ASCII letters, with the reserved third-byte rule retained, and GIF signatures match exactly `GIF87a` or `GIF89a`. The standalone release-identity checker requires serialized object roots in package.json and package-lock.json before pipeline enumeration; legitimate arrays inside objects remain valid. These checks preserve public interfaces, image policy and existing genuine corpus/index identities.
- Indexed PNG validation reverses all five filter types for each non-interlaced or Adam7 pass and checks actual 1/2/4/8-bit pixel indices against the palette. Row-padding bits are ignored, previous rows reset at each pass, and working row buffers remain bounded.
- The shared transparency validator follows [PNG tRNS rules](https://www.w3.org/TR/png-3/#11tRNS): grayscale requires two bytes, truecolor requires six, and indexed alpha tables may be shorter than the palette but never longer. Color types 4/6 forbid tRNS. Duplicates, transparency after image data, and transparency before a present palette are rejected. Sample high bits are not an additional rejection rule.

A version-controlled image policy exposes only validated, local technical images inside `div#help`. It retains meaningful small MQL5 icons and excludes navigation chrome, branding, `#footer-links` artwork, presentation-only elements, and explicit denylist entries. A new in-help image that cannot be classified deterministically blocks staging.

The initial denylist contains six Previous/Next buttons, `mql5/copyright.gif`, and `code_base_icon.png` plus `metaeditor_icon.png` in each book. The required baseline is 798 raster assets (797 PNG and one GIF), 11,652,126 original bytes, 828 in-topic occurrences, 787 exposed PNG assets, 811 exposed occurrences, 11 excluded files, and zero missing, unsafe, unsupported in-help, oversized, or unclassified references.

Public delivery permits static PNG and JPEG only. SVG, HTML, data URLs, external resources, BMP, ICO, GIF, WebP, APNG, extension/signature mismatches, and unsupported formats are rejected. PNG checks cover framing, CRCs, critical-chunk structure, bounded decompression, scanline filters, indexed pixels, and the transparency rules below. They do not validate the semantics of every ancillary chunk or guarantee rendering by every decoder. JPEG checks retain their existing structural and decoding limits. Hard limits are 2 MiB raw bytes, 4,096 pixels per dimension, and 4,194,304 decoded pixels. A non-decorative in-help reference that fails these checks blocks activation.

One source anomaly is explicitly policy-pinned rather than weakening generic PNG validation: `neuronetworksbook/opencl_test.png`, SHA-256 `04d0d664766a185021ab8aa26eb657fa58860a1113f5d4cb844ee674e5fee8f0`, is 23,807 bytes and contains a strictly valid static PNG prefix ending at byte 10,372 followed by official trailing data. Indexing and runtime may preserve and return its full original bytes only when source, normalized path, full hash, byte count, and prefix length all match the version-controlled exception; the prefix must independently pass complete CRC/chunk/IEND/dimension validation. Every other PNG with trailing bytes, and any near-match to this exception, fails closed.

Caption precedence is `<figcaption>`, meaningful `title`, meaningful `alt`, nearest same-block or immediately adjacent explanatory text, then normalized filename. Components remain separate, controls/whitespace are normalized, each is capped at 500 characters, and a reused asset receives one deterministic canonical caption. Captions, filenames, nearby text, and OCR are excluded from FTS5. OCR is deferred from v1.2.

## Search Expansion and Citations

- A version-controlled JSON synonym map handles bounded domain phrases such as trade opening, position tickets, indicator buffers, hedging account mode, and activation functions.
- Corpus aliases and resolved related-topic titles may contribute additional bounded terms, but no LLM or network is used at runtime.
- Exact title and alias matches precede the merged FTS results. Original-query FTS matches receive reciprocal-rank weight 1.0 and expansion matches receive weight 0.35; original matches win equal-score ties. A highly ranked expansion can precede a lower-ranked original FTS match. Expansion terms and matched terms are deduplicated and bounded.
- Structured citations contain source filename, topic title, breadcrumb, topic/section ID, source revision, corpus revision, and index revision.
- Model-facing search/read guidance tells Codex to cite the exact returned topic title or selected section heading, the stable topic ID and relevant section ID, and one shared corpus or index revision per answer when multiple findings use that revision. It does not require revision metadata to be repeated in every paragraph.
- Human-readable read content ends with one concise source footer; search entries contain one concise source line each. A search entry prints its signature once: when the whitespace-flattened signature appears verbatim in the snippet, that copy is omitted from the human-readable text. Structured output is unchanged.
- PNG chunk CRCs use Node's native CRC-32/IEEE (`zlib.crc32`) at indexing and runtime; results are identical to the previous JavaScript implementation.

## Online Check Policy

- Runtime contains no HTTP or general web-search capability.
- `online_check.recommended` is true when `require_current` is true, no local result exists, the best result is fuzzy-only, or a valid local update-check report says a newer revision is available.
- The recommended query is restricted to `site:mql5.com/en/docs`, `site:mql5.com/en/book`, or `site:mql5.com/en/neurobook` based on the source filter.
- Codex decides whether to use its existing web capability. No companion online MCP is installed.

## Maintenance and Safety Boundaries

- `Check-DocumentationUpdates.ps1` may use network and temporary storage but never changes the active revision.
- The weekly GitHub documentation-freshness workflow performs a separate read-only comparison of all three fixed official CHM downloads against the tracked `corpus.lock.json` hashes. It writes only the workflow summary and exit status, deletes temporary downloads, and never stages, applies, commits, or publishes documentation.
- Corpus-lock consumers check original source identifiers, filenames, and hashes before scalar conversion. The tracked freshness checker requires its schema `1.0` string and source array before downloading. Revision validation checks the source array and whole-number topic counts without rounding fractional values; valid current and prior revision contracts and optional null total counts retain their existing policy. Malformed metadata is rejected while its evidence remains unchanged; these checks supplement the existing CHM and index hashes.
- Official download hosts are restricted to HTTPS `www.mql5.com`; redirects to other hosts are rejected, downloads are size-bounded, and one cancellation deadline covers redirects, streaming, and incremental SHA-256 computation.
- `Update-Documentation.ps1 -Stage` creates and validates an inactive index revision and a deterministic change report. Same-corpus reindexing is allowed when schema, index contract, or image policy changes; corpus equality alone is not an early-exit condition.
- Before extraction, the bundled CHM-capable 7-Zip derives an inventory of every index input: `.htm`, `.html`, `.hhc`, `.hhk`, and the extensions declared by the image policy. Unsafe, rooted, traversing, duplicate, case-colliding, invalid, or size-invalid paths fail closed. `hh.exe` runs in an isolated candidate directory and must produce every expected path at its exact size with two matching sorted path/size/SHA-256 closure digests. The stable closure is copied into a separate snapshot and only that snapshot may be published, so late compiler writes cannot reach the indexed tree. Timeout or incomplete output uses a separate synchronous 7-Zip directory subject to the same double-closure and snapshot validation; a failed fallback exposes no partial destination.
- `Update-Documentation.ps1 -Apply -Revision <sha256>` accepts only a fully staged and validated index revision, atomically changes `data/active.json`, and records the former active index for rollback. Every activation acceptance boundary, including inactive-candidate packaging, uses the same verifier. Any reduction in catalogued assets, exposed assets, total occurrences, or exposed occurrences requires a reviewed report and the explicit `-AcceptAssetReduction` acknowledgement.
- `Rollback-Documentation.ps1` atomically reactivates the recorded previous verified revision.
- Manifest and active-pointer readers validate serialized object roots and scalar JSON types before PowerShell enumeration or casts. Numeric values must be safe whole numbers; strings, arrays, and Booleans cannot stand in for counts or revisions. Source inventories, nullable HTTP headers, and optional legacy corpus aliases follow the runtime contract. Valid schema-2 and schema-3 manifests remain supported.
- Confinement checks preserve the separators of allowed filesystem roots, including drive and UNC share roots, so returned paths remain absolute when reused by filesystem APIs. Root-target refusal remains the default, and ordinary directory canonicalization is unchanged.
- Check, stage, apply, rollback, rebuild, install, and portable snapshot operations coordinate through one physical-path-derived machine-global `Global\...` mutex. Portable-package output publication additionally uses a separate machine-global mutex derived from the physical release-output root, which serializes different source clones targeting the same root. The Windows abandoned-owner result permits recovery, but inability to open either global object has no session-local fallback and fails before mutation. Physical aliases resolve to the same mutex, and the compatibility marker `maintenance/.update.lock` remains an unchanged zero-byte file. Apply and rollback additionally use a strict, atomically written `maintenance/revision-transition.json` journal so interruption after the pointer switch is retry-safe and cannot reverse the intended transition. Rebuild and documentation staging use a strict `maintenance/revision-stage.json` journal that binds the validated candidate tree, fixed stage report, active validation base, operation, and prior report state before the inactive revision is published. Any pending stage install is repaired or rejected before rollback may change that active base. Recovery accepts only the exact journal-bound tree and old-to-new report transition, reruns deterministic identity and semantic verification before report acknowledgement or mutation, reconciles managed checksums idempotently, and clears the journal only after checksum validation succeeds. Extraction/index scratch work is confined to the Windows temporary directory outside the checksummed package. Atomic JSON, stage-report, and checksum producers write and flush under exact `.writing` names before renaming to prepared temporary names; an exact lone writing artifact is provably prepublication and may be reclaimed under the lock, while prepared/backed-up/ambiguous states remain validation-bound and fail closed.
- The direct indexer lock is strict JSON containing schema version, PID, hostname, owner token, and UTC start time. Only a proven-dead same-host owner may be reclaimed. Live, inaccessible, malformed, foreign-host, or otherwise ambiguous locks fail closed. Legacy `{pid,started_at}` recovery requires explicit operator same-host attestation (`--reclaim-dead-legacy-lock`), a reparse-free output on an OS-verified Windows fixed or RAM-backed local volume, a definitely dead PID, and no ambiguous swap or transaction debris; mapped, UNC, and device paths are rejected. Before replacing the database, manifest, or assets, `.index-build-transaction.json` durably binds complete old and candidate hashes, sizes, revisions, asset-tree identities, and token-derived temporary/backup names. Recovery completes a fully valid candidate, restores a fully valid prior set when the candidate is incomplete, clears only journal-bound partial files from a first build, or preserves everything and stops when neither set validates. Backups and the journal are removed only after the complete canonical set validates; CHMs, corpus inputs, and unrelated output content are never removed.
- Reparse-point rejection covers the target and every existing lexical ancestor to the filesystem root. Lock identity is derived only after this validation so aliases cannot bypass the single-writer boundary.
- A tree containing `checksums.sha256` is authoritatively portable even if development-marker files are added. Install, rebuild, update, and packaging paths validate exact package checksum closure before executing bundled Node, 7-Zip, application bundles, or other native/package code; mixed or tampered trees fail before native execution.
- Recovery revalidates both revisions. Apply recovery also reruns the stage-report base, topic-loss, database integrity, FTS, representative-topic, and exact-ranking acceptance checks before completing the recorded transition.
- Restaging an already installed candidate always refreshes its stage report against the current active base. The staging journal records the exact prior report hash, so recovery may replace only that proven report; managed checksums are refreshed only after all unrelated checksummed files verify unchanged.
- Stage reports include base/candidate corpus and index revisions plus added, removed, changed, exposed, excluded, unsupported, oversized, unresolved, and unclassified asset counts. New official documentation may reduce total assets only after explicit report review; missing or unsafe non-decorative in-topic references always block activation.
- Activation is refused if any source loses topics under the current policy, required representative topics disappear, extraction is incomplete, internal integrity/FTS checks fail, exact ranking regresses, asset/catalog closure fails, or package hashes mismatch.
- At startup the schema-3 runtime verifies pointer, manifest, database, CHMs, SQLite integrity/FTS, all catalog rows, every asset file, exact asset-directory closure, byte totals, hashes, MIME, dimensions, pixel limits, and absence of reparse points.
- The stdio transport connects before that verification so `initialize` and `tools/list` (static schemas and instructions, no documentation data) are answered within about 150 ms; clients such as Codex that snapshot tools when a turn starts would otherwise miss a server that answers after its ~2.5 s verification. Every tool call awaits the single verification result and nothing is served unless it succeeds. A failed verification writes the same `[mql5-chm] CODE: message` diagnostic, closes the connection, and exits with code 1; waiting calls receive no data. The "verified read-only stdio server ready." line is still written only after verification succeeds.
- On every image call it resolves only a prepared catalog row, opens the opaque storage key read-only, enforces the byte cap before reading, and revalidates bytes, SHA-256, MIME, dimensions, and static-image policy before disclosure.
- Runtime may use read-only filesystem primitives but exposes no network, process-spawning, extraction, temporary-file, arbitrary-file, write, delete, reindex, SQLite-extension, MetaTrader, MetaEditor, or trading capability.
- Stdout is reserved for MCP JSON-RPC; diagnostics use stderr.

## Build, Release, and Packaging

- The PowerShell 7 release identity checker requires the entire serialized version string to satisfy SemVer. Matching package and lockfile versions do not permit trailing whitespace or line breaks; branch and tag validation apply the same version rule.

- Update this specification first, add failing schema/migration/asset/MCP/security tests, and build candidate server/indexer bundles outside working `app/` before replacing generated artifacts.
- The v1.2 runtime is transitional: install it before schema-3 activation so a failed migration still serves legacy text documentation.
- Build schema 3 in temporary directories, validate it, install it immutably under its database hash, and change the pointer only through the journaled transition.
- Generated production bundles in `app/` are replaced only after candidate tests pass.
- `scripts/build.mjs` accepts only production `app/` or generated descendants of `build/` as bundle destinations, writes metadata only beneath `build/`, rejects protected/overlapping paths and reparse-point ancestors, and builds into a private sibling candidate. It publishes the complete validated bundle pair with rollback; compilation or metadata failure preserves the previous working pair.
- Index output must be a fresh, empty, tool-owned candidate directory disjoint from source/extracted/project-protected/immutable revision paths. The indexer never replaces an unrelated `assets/` tree or writes in place to an active revision.
- A complete development tree must rebuild successfully. A transferred portable tree may reuse prebuilt bundles only when development inputs are absent and its existing package checksums verify before bundled Node or 7-Zip is executed; partial or checksum-less portable trees fail closed.
- Before Codex registration lookup or mutation, installation launches the bundled `app/server.mjs` with the exact bundled Node executable and a 30-second overall deadline, without a working-directory or `MQL5_CHM_MCP_ROOT` override. It completes `initialize`, `notifications/initialized`, `tools/list`, and a `tools/call` to `mql5_chm_status`; requires the package server version, exact five-tool set, and exact read-only annotations; and binds active, index, corpus, and schema status to the already validated package. Any startup, protocol, tool, annotation, status, timeout, or termination failure leaves registration unchanged. Codex registration lookup then parses structural JSON and selects exactly one `mql5-chm` entry. All package-managed lookup/add/remove sequences serialize through one fixed machine-global registration mutex. Ownership means the absolute stdio command and sole argument target this package's Node and server paths; equivalence additionally requires no environment or tool-filter overrides. The working directory may be absent/null or be a fully qualified path selecting the package root; root-relative and drive-relative paths are rejected. An allowlist must be absent/null; even an empty allowlist is restrictive. An empty/null denylist is allowed. Install is idempotent only for an equivalent enabled entry and preserves/rejects disabled, modified, differently owned, malformed, or duplicate entries. Post-add validation requires equivalence and enabled state. Failure removes only an entry still observed as owned by the just-added paths and confirms the post-state; ambiguous observed replacements are preserved and combined rollback errors are reported. Uninstall is a no-op when absent and removes only a path-owned registration, even if package files are damaged or optional settings changed; differently owned or malformed entries are preserved and rejected, and successful removal is confirmed. The package-global mutex provides this guarantee among cooperating package scripts. The current Codex CLI removes by name and exposes no ownership compare-and-swap token, so preservation cannot be atomic against an unrelated external writer that replaces the entry inside Codex's name-only remove command window; operators must stop other Codex configuration writers for install/uninstall.
- `Install-Claude.ps1` applies the same package, checksum, journal, pinned-Node and bundled stdio smoke gates under the maintenance lock, then registers the package with Claude Code at user scope (`claude mcp add --scope user mql5-chm -- <node> <server>`) while still holding that lock, serialized by the fixed machine-global mutex `Global\Mql5ChmMcp-ClaudeRegistration-v1`. The Claude CLI is located on PATH or in the native installer's `%USERPROFILE%\.local\bin` and must pass a bounded `--version` probe. Registration state is read from `.claude.json` (inside `CLAUDE_CONFIG_DIR` when set, otherwise in the user's home) with a case-sensitive JSON reader under both PowerShell hosts, because Claude Code may hold project keys that differ only by case. Ownership and equivalence use the Codex rules (stdio, absolute package Node command, sole package server argument, no environment overrides). Install is idempotent for an equivalent entry, refuses conflicting entries, rolls back only an entry still owned by the just-added paths, and warns about per-project local-scope entries that override the user scope. `Uninstall-Claude.ps1` removes only a path-owned user-scope entry and confirms absence. Neither script changes the Codex registration.
- Node is pinned exactly to 24.17.0 in code and package metadata. Development bootstrap streams only from HTTPS `nodejs.org`, with no redirects, a 300-second deadline, and a 64 MiB cap. It verifies the official archive hash, extracted executable hash/version/x64 architecture, and license. Durable copies use token-bound `.writing` names, cross to `.prepared` only after exact validation, and are transactionally published with `node.exe` last as completion marker; any failure preserves the prior canonical pair. Portable repack is offline and never downloads or repairs runtime files.
- Bundled 7-Zip is pinned to the official Windows x64 26.02 executable/DLL/license set and checked against version-controlled artifact, executable, DLL, architecture, version, CHM-capability, and license provenance. A damaged development set is repaired only from that validated official MSI through a 300-second bounded administrative extraction, using the same writing/prepared transactional boundary; installed-program and opportunistic fallback copies are forbidden. Bundled dependency notices are deterministically generated and checked from the lockfile plus every esbuild contributor with nonzero `bytesInOutput`; nested duplicate versions and complete license text are retained, and missing or drifted coverage blocks packaging.
- Portable packaging copies the active revision recursively, includes only that schema-3 index, the image/query policy configuration, the complete maintenance scripts, the provenance-bound 7-Zip pair, and required licenses/notices. It checksums every externalized asset exactly once. Local inactive/previous revisions remain available for rollback but are excluded from the ZIP. `-CandidateRevision` packages a validated inactive schema-3 revision without changing production only after the staged report names the exact current active base and fresh database inspection reproduces its topic, source, ranking, and asset-change semantics. A reported asset reduction additionally requires `-AcceptAssetReduction`; `-OutputDirectory` selects a reviewed output root. Final packaging preserves the real active pointer's activation timestamp; an inactive candidate uses its immutable manifest `indexed_at` value instead of packaging time.
- Release checksum validation requires exact immutable-tree closure and an exact package ownership marker. Mutable advisory status and the transient maintenance journals are excluded from both checksums and a newly built ZIP; every immutable package artifact and the active pointer are checksummed, and successful publication leaves no build/runtime/release transaction journal. Checksum records are sorted by normalized package path using ordinal comparison. Installation and repackaging refuse pending journals, missing, extra, tampered, or reparse-point artifacts before native execution. Before any stage reset or ZIP publication, physical-directory identity plus nearest-existing-ancestor checks reject existing or future stage/ZIP equality and ancestor overlaps hidden by DOS, volume-GUID, SUBST, or 8.3 aliases. Staging cannot overlap the project or copied/immutable sources and cannot silently replace an unowned directory. Revision candidates are first copied into a validated temporary sibling beneath `revisions/`, then atomically renamed on that volume; interruption cannot leave a partial immutable destination that poisons retries.
- The release ZIP and timestamp-free `<ReleaseName>.zip.manifest.json` are byte-reproducible and published as one journaled transaction. The pinned 7-Zip executable consumes an explicit case-insensitive ordinal file list with fixed compression settings, threading disabled, timestamps omitted, file attributes normalized, and no directory entries; this deterministic compression subprocess has a bounded 900-second deadline. ZIP validation enforces exact entry order, fixed DOS epoch metadata, archive attributes, stage hashes, and exact closure. Active-pointer and sidecar JSON use canonical compact UTF-8/LF serialization. Compression and sidecar serialization first use token-bound `.writing` names; only fully flushed, stage-matching, checksum-closed bytes become prepared candidates. Sidecars and prepared file-set journals require serialized JSON object roots under both PowerShell hosts; arrays, scalars and null are rejected before canonical mutations. File-set journal headers and item descriptors also validate their original scalar types before pipeline enumeration or casts; singleton arrays cannot replace operation, role, transaction identity, filename, hash, Boolean, or byte-count fields. Exact integer representation checks remain in force. The strict sidecar is `{schema_version,file,bytes,sha256}`, with schema 1, the ZIP basename, exact integer byte count, and lowercase 64-hex digest. A legacy ZIP without a sidecar may be upgraded; an unexplained malformed or mismatched existing pair is refused. Publication succeeds only after the persisted pair is independently revalidated, and interrupted publication either completes the valid candidate or restores the complete prior pair.
- Keep the existing release ZIP and active pointer unchanged until candidate bundles, reproducible schema-3 indexes, migration/recovery tests, MCP tests, security tests, and a temporary portable package all pass.
- After candidate success, install the transitional app, atomically activate schema 3, fully restart Codex, and perform a real search -> topic image reference -> image-read rendering flow. If Codex does not visibly render the image, roll back and do not replace the release ZIP.
- Rebuild the final ZIP only after activation and all acceptance checks pass, then persist and independently revalidate its sidecar byte size and SHA-256.
- Moving computers remains: unzip, run installer, restart Codex.
- Pull requests run the fast Windows suite with Node.js 24.17.0 and syntax validation under PowerShell 7 and Windows PowerShell 5.1. Release-tag validation copies only `data` and `revisions` from a sidecar-verified prior corpus fixture, creates fresh maintenance state, binds all subprocess tests to setup-node 24.17.0, runs fast, maintenance, packaging, corpus, and bundled-MCP suites under both PowerShell hosts as applicable, then builds the package twice and requires identical SHA-256 values. Fixture runtime and maintenance files are never restored. A manual dispatch may set `corpus_fixture_release` to a reviewed release or draft containing a current fixture when the latest prior release is stale; strict sidecar validation plus exact current-source and current-image-policy binding remain mandatory.

## Acceptance Criteria

- Initial source hashes and exact topic counts remain 4,134, 581, and 112; total 4,827.
- Exact section and resolved-link totals remain 16,261 and 20,769.
- Existing stable topic IDs for representative APIs remain identical.
- Every existing topic content hash remains identical after the schema-3 rebuild.
- Exact searches for `OnTick`, `PositionSelectByTicket`, `OrderSend`, and `CopyBuffer` rank the MQL5 reference first.
- Domain expansions improve natural-language queries without regressing exact-name rankings.
- Default-all fuzzy searches recover representative typos from every corpus, including `ChatID` -> `ChartID`, `1.5.2 Droout` -> `1.5.2 Dropout`, and `1.8 Data inut` -> `1.8 Data input`.
- `CompareEqual` returns only its matching declaration; overview/class topics such as `CArrayObj` and `Resources` do not expose unrelated example fragments as signatures. Existing representative API signatures remain valid.
- Two builds from identical inputs produce byte-identical databases and the same index revision.
- Asset totals exactly match the initial contract: 798 catalogued, 787 exposed, 11 excluded, 11,652,126 bytes, 828 occurrences, and 811 exposed occurrences.
- At least one reused asset has one catalog row and multiple topic/occurrence rows. Caption precedence, normalization, 500-character limits, section association, rendered offsets, and deterministic ordering pass tests.
- All 44 images associated with `enum_object.htm` are discoverable through image-reference pagination without duplicates or repeated passage text.
- Search/batch/read/status/image schemas, annotations, citations, related topics, online recommendations, limits, validation failures, focus, and pagination pass automated MCP tests. The installer handshake lists exactly five read-only tools and binds status revisions before registration.
- Text cursor tests cover current, stale-revision, tampered, wrong-topic, wrong-section, supplementary-plane Unicode offsets, and rejected legacy text-cursor v1 tokens. The cursor work adds no named public fields; all five tool inputs are closed schemas and reject unknown arguments.
- A decoded successful image block is exactly equal to the indexed SHA-256, byte count, MIME, and dimensions. Search remains text-only; topic reads contain no binary/base64; structured image metadata contains neither base64 nor paths.
- Link normalization, fragment handling, deduplication, unresolved-link reporting, and traversal rejection pass unit/integration tests.
- Real and synthetic heading-boundary tests prove headings are anchored to rendered DOM positions even when identical text appears earlier in prose or code. Astral Unicode text builds, validates, reads, focuses, and paginates using the documented UTF-16 offset contract.
- Traversal variants, queries/fragments, double encoding, UNC/drive paths, schemes/data URLs, controls, case/truncated-ID collisions, PNG/JPEG validation, malformed/truncated files, APNG, extension mismatch, zero/oversized dimensions, pixel limits, missing/altered/extra assets, and reparse points fail closed.
- Decorative, unsupported, and guessed asset IDs never disclose bytes. Per-call tampering returns `ASSET_INTEGRITY_FAILED`.
- Update checking, complete CHM input inventories, delayed HHC/HHK/image extraction, same-size rewrites, snapshot races, isolated fallback, unsafe paths, same-corpus staging, stage-report refresh, refusal gates, pointer-schema migration, atomic activation, interrupted migration/apply/rollback recovery, interrupted inactive-revision publication/report/checksum recovery, cross-volume candidate installation, idempotent retry, conflict refusal, package-layout trust, pre-native checksum enforcement, ancestor-junction rejection, failed bundle publication, and legacy mutable-checksum migration pass isolated fixtures without touching production until the release gate.
- Machine-global mutex tests cover contention, forced-holder termination, abandoned recovery, physical-path aliases, and unchanged zero-byte marker bytes. Direct-indexer tests cover stale/live/inaccessible/malformed/foreign/legacy locks and every database/manifest/assets publication cut point, including complete-candidate commit, complete-prior restoration, partial first-build cleanup, ambiguity preservation, and idempotent retry.
- A real same-input rebuild proves that equality is a no-op and that any rejected drift leaves all protected revision, checksum, report, status, and release hashes unchanged.
- Fake-Codex tests cover install/uninstall success, absence, partial creation, rollback, malformed/duplicate JSON, disabled or modified entries, repointing, package-managed serialization, and observable post-command replacement without reading or changing the real Codex registration. They do not claim an unavailable compare-and-swap guarantee against an uncooperating external writer inside Codex's name-only remove operation.
- Runtime and packaging tests cover truncated Node repair, timeout, size overflow, bad archive/executable/license hashes, wrong version/architecture, publication rollback, exact engine consistency, partial Node/7-Zip/ZIP/sidecar writing recovery, offline prepared-evidence preservation, 7-Zip provenance/version/architecture/CHM-capability failures, deterministic notice drift, a canonical ZIP golden hash, equivalent-tree timestamp/order independence, and every ZIP/sidecar interruption recovery path.
- Rollback from schema 3 to schema 2 preserves all three text tools, reports asset support unavailable, and reapplication succeeds.
- SQLite integrity/FTS checks pass, and CHM/database/manifest/active-pointer/complete-asset-tree hashes remain unchanged across read-only calls; batch compatibility separately verifies the complete corpus inventory, requested source/limit, lookup/result counts, match statuses, batch revisions, and each result's topic/section/revision citations for mixed and maximum-size requests.
- Runtime-source security tests prove there are no network, process-spawning, write, extraction, temporary-file, or SQLite-extension capabilities.
- Every PowerShell source file parses under both PowerShell 7 and Windows PowerShell 5.1; Node syntax checks and the complete automated suite pass against the final build-script-generated `app/` bundles with candidate/production parity.
- A candidate portable ZIP and its sidecar work from a path containing spaces without system Node, source tree, or `node_modules`; exact internal checksum closure, independent ZIP/sidecar hashes, offline nested repackaging, bundled five-tool calls, large/small/reused/decorative/44-image cases, and immutable-tree closure pass.
- A fully restarted Codex visibly renders a retrieved image rather than displaying or dropping raw base64 before the active pointer and release ZIP are considered final.

## Explicit Exclusions

- No UI, authentication, public marketplace package, companion online MCP, scheduled background updater, automatic activation, image server, trading tool, or live/demo account requirement. The weekly source-hash monitor is read-only notification automation, not an updater.
- No OCR in v1.2. A later reviewed release may use maintenance-time-only offline OCR with engine/version/language/confidence provenance, bounded storage, and no FTS participation unless separately authorized.
- No runtime image conversion, resize, transcoding, variants, or native image-processing runtime.
- No scraping of forums, Market, CodeBase, articles, or third-party websites.
- No changes to existing MetaTrader or MetaEditor MCP registrations.
- No public redistribution workflow for the CHM files.
