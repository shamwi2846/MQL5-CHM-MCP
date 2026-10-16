# MQL5 CHM MCP 1.3.17

A portable, local MCP server for the official English MQL5 reference, AlgoBook, and Neural Networks book. The active corpus contains 4,827 indexed topics, 16,261 sections, and a secure catalog of the original technical diagrams, screenshots, charts, and MQL5 object icons. Runtime access is offline, stdio-only, and strictly read-only; no MetaTrader account, HTTP port, trading access, or authentication is required.

**v1.3.17** changes no server behaviour: the Claude Code installer stops with a clear error when neither `CLAUDE_CONFIG_DIR` nor `USERPROFILE` is set, and the batch-name rules here and in the specification describe exact topic titles. Since v1.3.16, batch lookups take exact topic titles (such as `Order Properties`) beside identifiers. Earlier changes are listed under [Release history](#release-history).

The server exposes five closed-world tools:

- `mql5_chm_search` searches exact API names first, then deterministically merges full-text matches with lower-weight MQL5-aware expansions before bounded typo recovery.
- `mql5_chm_lookup_identifiers` looks up 1 to 16 API or constant names in one request. Order and duplicates are preserved; each name has its own match status, candidates, advisory check and citations. Default source is `mql5`, expansion is disabled, and `limit` is 1 to 3 per name (default 1; at most 48 candidates total).
- `mql5_chm_read` reads a bounded topic passage with citations, related-topic links, and bounded image references. It never returns binary image data.
- `mql5_chm_read_image` returns exactly one catalogued original technical image by stable asset ID.
- `mql5_chm_status` reports active corpus/index revisions, source metadata, text and asset counts, and the last valid update-check result.

Normal searches remain text-only. Captions and filenames do not enter FTS5, and images are returned only after an explicit image-tool call.

Text and image continuation cursors are opaque, revision-bound HMAC tokens authenticated with a process-ephemeral key. A cursor is accepted only by the running server process and for the active index, topic, and selected section that issued it; legacy text-cursor v1, prior-process, stale-revision, tampered, wrong-topic, and wrong-section cursors are rejected. The cursor changes add no named MCP argument or response fields. Tool input objects are closed schemas: unknown arguments are rejected instead of silently ignored.

## Bounded calls and stable citations

`mql5_chm_search.limit` must be an integer from 1 through 8. `mql5_chm_read.max_chars` must be an integer from 500 through 8,000 and must not exceed 8,000. Out-of-range values are rejected and are never silently clamped.

Batch names must be ASCII identifiers or exact topic titles, each 1 to 128 characters matching `^[A-Za-z_][A-Za-z0-9_]*(?: [A-Za-z0-9_]+)*$` (words of letters, digits and underscores separated by single spaces); expressions, qualified names, other whitespace and paths are rejected before any search runs. Names are matched literally, and a name is `exact` only when a topic title or alias equals the whole name. `exact`, `non_exact` and `none` describe the search outcome for that name. A prefix, FTS result or typo candidate remains non-exact. Read the selected topic/section and verify the complete identifier before making an API claim. Batch output contains bounded metadata; it does not return passages or image bytes. A request error fails the entire batch instead of returning a successful partial result. Existing single-search behavior is unchanged, and older clients can continue using it.

Example tool arguments: `{"identifiers":["OnTick","CopyBuffer","SYMBOL_VOLUME_STEP"],"source":"mql5","limit":1}`. From a development checkout with locked dependencies installed, measure the shipped tool against sequential and parallel single calls on a verified corpus using `npm run benchmark:identifiers -- --package-root <absolute-package-root> --server-path <absolute-server.mjs> --report <new-report.json>`. The benchmark validates every warm and measured response before accepting a sample, preserves result metadata/citations, and reports request counts, local median latency and serialized response bytes for 1, 4, 8 and 16 names. `--samples` accepts 3–21 samples per mode (default 9); for an even count, the median averages the two middle values. Tool errors, changed source/index identity, inconsistent counts or match statuses, and changed result metadata fail the command without publishing a passed report. Timing is descriptive; batch searches remain synchronous and do not guarantee a latency improvement.

For a focused read, `focus_match` reports `exact`, `approximate`, or `none`; it is `null` for unfocused reads and continuation pages. An exact match must occur in the returned bounded passage; a phrase extending beyond that passage is reported as approximate. Token boundaries are checked against the original documentation, so truncating an identifier suffix cannot turn a partial match into an exact match. Complete identifiers and phrases take priority over partial matches, so `OBJPROP_FONT` is preferred over the prefix in `OBJPROP_FONTSIZE`. Approximate and absent matches include a text notice. An absent focus without an explicit section returns a bounded topic passage rather than an arbitrary section. Verify the complete requested identifier in the returned passage before using it as documentation support.

When documentation supports a final answer, use the structured citation metadata: name the exact returned topic `title`, or the exact read `section_heading` when present; include the stable `citation.topic_id` and relevant `citation.section_id`; and state `citation.corpus_revision` or `citation.index_revision` once per answer when multiple findings share that revision. The structured citation also retains the source filename. Revision metadata does not need to be repeated in every paragraph.

## Install in Codex

Maintenance and installation scripts support Windows PowerShell 5.1 and PowerShell 7.5 or later. PowerShell 7.0–7.4 convert ISO timestamps in JSON to dates, which the strict revision readers reject; use `powershell.exe` (5.1) there.

Run from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Codex.ps1
```

Fully close and reopen every client that uses this package (Codex, Claude Code) after installation, activation, or rollback.

On connection the server sends short usage instructions that both clients show to the model: the status, lookup and read workflow, the rule that an exact match is only a candidate until a returned passage supports the claim, text-only read flags, reuse of a verified passage, citation fields, and the freshness check.

Before changing Codex registration, the installer launches the bundled server with the bundled Node runtime and a 30-second deadline. It verifies `initialize`, the initialized notification, the exact five read-only tools returned by `tools/list`, and `mql5_chm_status` against the package revisions already validated by the installer. A startup, protocol, tool, annotation, or revision failure leaves Codex registration unchanged.

Installation and uninstallation serialize package-managed registration changes through one machine-global registration mutex. Installation is idempotent only when the existing `mql5-chm` registration is enabled, path-owned by this package, and has no environment or tool-filter overrides. The working directory may be absent/null or be a fully qualified path selecting the package root; root-relative and drive-relative paths are rejected. An allowlist must be absent/null; even an empty allowlist is restrictive. An empty/null denylist is allowed. Disabled, modified, differently owned, malformed, or duplicate entries are preserved and rejected. If registration fails, rollback removes only an entry still observed as owned by the exact Node/server paths just added, then confirms the post-state. This prevents races between cooperating package scripts. Codex currently exposes removal by name rather than by an ownership compare-and-swap token, so an unrelated external config writer must not replace `mql5-chm` during the small `codex mcp remove` command window; the package cannot atomically preserve a replacement it was never able to observe.

## Install in Claude Code

Run from PowerShell in the extracted package:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Claude.ps1
```

The Claude Code installer applies the same checksum, pinned-Node and bundled stdio smoke checks as the Codex installer, under the same maintenance lock, and then runs `claude mcp add --scope user mql5-chm -- <package node.exe> <package server.mjs>`. The `claude` CLI must be on PATH or in `%USERPROFILE%\.local\bin`. Installation is idempotent for an equivalent entry; a conflicting user-scope `mql5-chm` entry is preserved and rejected, and a failed registration is rolled back only while it still points at this package. The installer warns about projects whose own local-scope `mql5-chm` entry overrides the user scope. `Uninstall-Claude.ps1` removes only a user-scope entry owned by this package. The Codex and Claude Code registrations are independent; install either or both. Restart Claude Code afterwards; its tools appear as `mcp__mql5-chm__<tool>`.

Clients may ask before each tool call. All five tools are read-only, but that annotation does not grant permission by itself. In Claude Code you can optionally allow them with the permission rule `mcp__mql5-chm` (see the [Claude Code permissions guide](https://code.claude.com/docs/en/permissions)); in Codex use its MCP server approval settings (see the [Codex MCP guide](https://developers.openai.com/codex/mcp)). The installers never change permission settings.

## Check, stage, and activate official updates

Update checking is manual. It downloads only the three fixed HTTPS CHM URLs on `www.mql5.com` into temporary storage, enforces redirect and size limits, compares hashes, and never activates anything:

```powershell
.\Check-DocumentationUpdates.ps1
```

The `Documentation freshness` GitHub Actions workflow also performs a weekly read-only comparison of all three official CHMs against `corpus.lock.json`. Downloads remain in temporary storage and are deleted after comparison. A changed hash or unavailable check fails the workflow for notification; it never stages, applies, commits, or publishes an update.

Stage a different official corpus or a same-corpus index-contract upgrade. Before extraction, the archive inventory covers every `.htm`, `.html`, `.hhc`, `.hhk`, and image-policy input and rejects unsafe, rooted, traversing, duplicate, case-colliding, or invalid paths. `hh.exe` and the synchronous 7-Zip fallback run in separate isolated directories; every expected file must have the exact size, and two sorted path/size/SHA-256 closure digests must match before an immutable snapshot is published. The command then indexes text and safe assets, verifies SQLite/asset integrity, rejects unsafe in-topic references or topic loss, checks representative API ranking, writes a change report, and leaves the index inactive:

```powershell
.\Update-Documentation.ps1 -Stage
```

The stage command prints the validated index revision hash. Activate that exact revision explicitly:

```powershell
.\Update-Documentation.ps1 -Apply -Revision <64-character-revision>
```

If the verified stage report shows any reduction in catalogued assets, exposed assets, total occurrences, or exposed occurrences, activation stops. Review that report first; only then may you acknowledge the reviewed reduction explicitly:

```powershell
.\Update-Documentation.ps1 -Apply -Revision <64-character-revision> -AcceptAssetReduction
```

Return to the previous verified revision:

```powershell
.\Rollback-Documentation.ps1
```

`data\active.json` is the small atomic active-index pointer. Verified artifacts live under `revisions\<index_revision>\`. Corpus identity remains the hash of the three CHMs, while index identity is the hash of the completed database. Previous installed revisions remain local for rollback; a portable ZIP contains only the active schema-3 index.

Apply and rollback use a strict recovery journal under the same maintenance lock. If either command is interrupted, rerun the corresponding command; it completes the recorded direction without toggling back. Apply and interrupted-stage semantic acceptance rerun the same deterministic-identity gate before report acknowledgement or mutation, so an older staged same-input drift candidate cannot bypass the current staging checks. Check, stage, rebuild, package, and install refuse to cross an incomplete transition.

All maintenance writers coordinate through one physical-path-derived machine-global `Global\...` mutex. Portable-package publication additionally uses a separate machine-global mutex derived from the physical release-output root, so different source clones targeting that root cannot race. A terminated holder is recovered through the Windows abandoned-mutex contract; inability to open either global object fails before mutation, and path aliases cannot create another writer. The compatibility marker `maintenance\.update.lock` remains zero bytes and is never used as the ownership record.

The direct Node indexer also uses a strict hostname- and owner-token-bound lock. A legacy `{pid,started_at}` lock fails closed by default; an operator who has independently confirmed that its owner was on this machine may use `--reclaim-dead-legacy-lock`. That recovery additionally requires a reparse-free output path on a Windows fixed or RAM-backed local volume, a definitely dead PID, and no ambiguous transaction debris; mapped, UNC, device, live, inaccessible, or uncertain owners are retained.

Source metadata records hashes, byte sizes, retrieval/acceptance time, and available HTTP `ETag`/`Last-Modified` values. These timestamps are never presented as a CHM publication or build version.

## Rebuild and transfer

`Rebuild-Index.ps1` rebuilds from the active revision's CHMs and can migrate the legacy corpus-keyed schema-2 layout additively. Existing legacy revisions are copied, never modified or removed. Use the staged update workflow, not manual CHM replacement, for later documentation changes.

For the same corpus with current schemas, the current index contract, and the same image-policy SHA-256 (canonicalized across Git LF/CRLF checkout conversion), a rebuild must be byte-deterministic. An equal index hash reports “already current”; a different hash is rejected before any journal, revision, checksum, report, or status mutation. Asset-reduction acknowledgement cannot bypass this gate.

Release CI verifies restored fixture integrity, pinned CHM identities, and image-policy identity before rebuilding an older supported index contract with the current indexer. It then stages and activates the verified candidate and enforces the current-contract gate before the full release suite and reproducible package checks.

```powershell
.\Rebuild-Index.ps1
.\Package-Portable.ps1
```

To review a validated inactive schema-3 revision without touching the production ZIP, build a candidate package explicitly:

```powershell
.\Package-Portable.ps1 -CandidateRevision <64-character-index-revision>
```

Candidate packaging revalidates the staged report against the current active base and freshly inspects both databases. A report that reduces cataloged or exposed image coverage or image occurrences is rejected unless the reviewed package command also includes `-AcceptAssetReduction`.

Candidate packages default to `build\portable-candidate-release`. `-OutputDirectory <directory>` selects a different output root, and `-ReleaseName <safe-name>` selects the stage/ZIP name. Output staging is rejected if it equals, contains, or overlaps the project, an immutable revision, application/scripts/config/runtime/tools sources, or a reparse point. An existing stage is replaced only when it contains the package ownership marker written by this packager. The pinned 7-Zip runtime archives a case-insensitive ordinally sorted file list with fixed ZIP timestamps, attributes, compression settings, and no directory entries; this deterministic single-threaded compression step has a bounded 900-second deadline. Generated active-pointer and sidecar JSON use canonical UTF-8/LF bytes, checksum lines are ordered by package path, and mutable update status is omitted. Identical package inputs therefore produce an identical ZIP SHA-256. ZIP and sidecar bytes are durably completed and validated under token-bound `.writing` names before they become prepared candidates. The final ZIP and timestamp-free `<ReleaseName>.zip.manifest.json` sidecar are then validated and published as one journaled transaction. The sidecar contains exactly `schema_version`, `file`, `bytes`, and lowercase `sha256`. Sidecars and prepared transaction journals require a serialized JSON object root; array, scalar and null roots are rejected under both supported PowerShell versions before publication or recovery changes files. A legacy ZIP without a sidecar may be upgraded; an unexplained malformed or mismatched existing pair is refused.

Copy or unzip the complete portable package on another Windows x64 computer and run `Install-Codex.ps1`, `Install-Claude.ps1`, or both. The bundled runtime is exactly Node.js `24.17.0`, so no system Node installation is needed.

Windows version metadata for Node and both 7-Zip binaries is queried through normalized extended drive or UNC paths, including inputs already carrying an extended prefix. Stored paths and exact version, hash, size, architecture, license, and native capability checks are preserved. A long path can still prevent native 7-Zip DLL/CHM-codec loading or process startup. When pinned binaries are intact but metadata or native execution is unavailable, the command stops with a diagnostic and a bounded probe excerpt, retaining pending recovery evidence without a repair download or binary replacement. Retry from a shorter package path and a supported working directory; no temporary runtime fallback is provided. Missing or damaged files retain the existing development repair workflow.

`Package-Portable.ps1` rebuilds bundles in a complete development checkout. In a transferred portable copy it instead verifies `checksums.sha256` before executing bundled Node or 7-Zip and before reusing the prebuilt bundles, so repackaging does not require source files, npm packages, or system Node. A tree containing `checksums.sha256` is always treated as portable even if extra development-looking files were added. Install, rebuild, update, and repackaging therefore reject missing, extra, or tampered package files before bundled code or native tools execute. A portable repack defaults to a sibling `<package-folder>-repack-output` directory outside the verified source; a custom `-OutputDirectory` must also be non-overlapping.

In a development checkout, missing or damaged runtime files are repaired only from the official HTTPS `nodejs.org` archive through a 300-second, 64 MiB bounded stream. Archive, executable, exact version, x64 architecture, and license hashes are verified; each copied payload crosses from `.writing` to `.prepared` only after its exact descriptor validates, the prior runtime pair is preserved on failure, and validated files are transactionally published with `node.exe` last. Portable repacking is offline and never downloads or repairs its runtime. Bundled 7-Zip is the pinned official Windows x64 `26.02` executable/DLL/license set, validated against checked-in provenance including CHM capability and repaired only from the official MSI through a 300-second bounded administrative extraction in a development checkout; installed-program fallbacks are not used. Packaging also checks deterministic complete dependency notices against the lockfile and the nonzero esbuild bundle contributors.

The portable package includes `config\mql5-image-policy.json` and `config\mql5-query-expansions.json`, so a transferred copy can perform a verified offline same-corpus rebuild without a source tree or `node_modules`. Extraction/index scratch directories live under the Windows temporary directory and are not part of the checksummed package. Interrupted `.writing` payloads are known to precede publication and are reclaimed only in their exact token-bound context; prepared candidates, backups, journals, and canonical files remain subject to strict validation and fail-closed ambiguity handling under the maintenance lock.

## Validation and CI

In a complete development checkout, `npm test` runs the fast build, notice, syntax, MCP contract, and unit suite used on pull requests. `npm run test:maintenance` runs the maintenance fixtures. `npm run test:release` runs the fast suite, full maintenance and packaging fixtures under PowerShell 7 and Windows PowerShell 5.1, corpus-backed MCP tests, and the bundled-server test. Transferred portable packages intentionally omit the development tests, source tree, lockfile, and npm dependency tree, so these npm validation commands are not available there. Release-tag validation restores only `data` and `revisions` from a checksum-sidecar-verified prior corpus fixture, creates fresh maintenance state, binds subprocess tests to setup-node `24.17.0`, and builds the portable ZIP twice to prove equal SHA-256 values. It never restores executable runtime or mutable maintenance files from the fixture. For the first release after an official CHM, index-contract, or image-policy update, manually dispatch the release workflow with `corpus_fixture_release` set to a reviewed release or draft containing the current portable corpus fixture; the same strict sidecar, current-source, and current-policy checks still apply.

Development validation includes [deterministic generated malformed-input checks](tests/GENERATED-INPUTS.md). Portable runtime packages exclude those generators. Compatibility CI checks both counterpart `main` (or explicit `peer_ref`) and the approved skill version and commit recorded in `.github/approved-peer.json`; both checks gate packaging.

`npm run test:search-parity` compares complete search, batch-lookup, read and image output of the working tree with a pinned baseline release (v1.3.13 by default, `--baseline <commit>` to change it) on the checkout's corpus fixture; it extracts the baseline's `src` and `config` with `git archive` into the ignored `build` folder, needs the full git history, and fails on any difference. Run it after any search or verification change meant to keep results identical.

## Uninstall from Codex or Claude Code

```powershell
.\Uninstall-Codex.ps1
.\Uninstall-Claude.ps1
```

Each script affects only its own client. Uninstalling is a no-op when `mql5-chm` is absent. It removes only a registration path-owned by this package, even when optional settings changed or package runtime files are damaged; malformed or differently owned entries are preserved and rejected. Documentation, revisions, and update history remain on disk. MetaTrader and MetaEditor MCP registrations are never changed.

## Security boundary

- Runtime opens only the active verified revision and never writes to it.
- Tool inputs cannot select paths, execute SQL, spawn processes, write files, or access the network.
- Asset IDs resolve only prepared catalog rows and opaque digest-based storage keys. Startup validates exact asset-tree closure, hashes, MIME, dimensions, byte/pixel limits, and reparse-point absence; every image call revalidates the requested bytes.
- Only validated static PNG/JPEG technical assets can be returned. Decorative, unsupported, unknown, guessed, missing, or oversized IDs disclose no bytes.
- Update downloads are restricted to HTTPS with final host exactly `www.mql5.com`.
- Candidate revisions remain inactive until validation passes and `-Apply` is run explicitly.
- Allowed filesystem roots remain absolute through confinement checks. Selecting `X:\` does not become the drive-relative `X:`; using the confinement root itself as a mutation target still requires an explicit allow-root mode.
- Maintenance requires object-root manifests and active pointers with runtime-compatible JSON types. Numeric strings, wrapped arrays, Boolean counts, and unexpected documentation sources are rejected before activation; supported schema-2 rollback metadata remains valid.
- Online freshness guidance is returned to the client (Codex or Claude Code) as metadata; the MCP runtime itself stays offline.
- The advisory `maintenance\update-status.json` and the strictly validated recovery journals `maintenance\revision-transition.json` and `maintenance\revision-stage.json` are intentionally mutable and not checksummed or included in a new release ZIP. Every immutable package file and asset plus `data\active.json` is covered by exact checksum closure; pending journals block unrelated installation or maintenance until their bound operation is safely completed.

OCR, image conversion, resize/transcoding, extracted HTML, and native image-processing runtimes are not included.

See `SPEC.md` for the complete public contract.

## Skill compatibility

For installation troubleshooting, the coding skill supplies one read-only `Test-Mql5Environment.ps1` command. With `-ClientHost Codex` or `-ClientHost Claude` it checks that client's registration, the installed package's listed checksums and pinned Node version, actual MCP stdio startup, source differences, skill contents, MetaEditor paths, and Python availability. It never starts MetaEditor or MT5. See the skill's [environment health command](https://github.com/shamwi2846/MQL5-Coding-Skill/blob/main/skills/mql5-coding/references/environment-health.md) for invocation and limits. Both repositories exercise it against a real MCP bundle on Windows under PowerShell 7 and Windows PowerShell 5.1 in their compatibility job.

Both repositories verify the actual MCP server against the [MQL5 coding skill](https://github.com/shamwi2846/MQL5-Coding-Skill)'s packaged consumer contract on trusted pushes and pull requests. MCP release validation also requires this check. Each successful run retains both repository revisions and artifact hashes. See [the compatibility guide](https://github.com/shamwi2846/MQL5-CHM-MCP/blob/main/docs/skill-compatibility.md) for the checks, private-repository CI credentials, and local or installed-pair commands.

For identifier batches, the compatibility check verifies requested source and limit, lookup and result counts, match statuses, and corpus/index revisions for both mixed names and the maximum-size request. Each result's citation must match its topic, section, and verified revisions. Structurally valid replies with inconsistent commitments fail the check.

The development identifier benchmark accepts `--quality-cases <absolute-json>` together with `--quality-output <new-absolute-json>`. Use `tests/fixtures/documentation-quality.json` for the frozen 32-case suite. Existing invocations retain their identifier-only behavior. Quality results record relevant-result rank, independently selected passages, citations, original image commitments, response bytes, and nine warm timing samples. Timing is descriptive; correctness is required. Golden expectations originate from original CHM HTML and are not generated from server answers. Full results, including failed cases, remain in the separate quality artifact. Development benchmarks are excluded from portable runtime packages.

## Release history

v1.3.17 applies a CodeRabbit review of the 1.3.10–1.3.16 changes and changes no search, read or image output. `Install-Claude.ps1` and `Uninstall-Claude.ps1` now fail with an explicit error when neither `CLAUDE_CONFIG_DIR` nor `USERPROFILE` is set, instead of resolving `.claude.json` against the current directory. The README batch-name rule and the specification now state the 128-character limit and grammar for both identifiers and exact topic titles, and the parity command documents its `tar` requirement. The health tests check that a Claude Code server turned off with `/mcp disable` is reported as disabled (skill 1.2.10 and later).

v1.3.16 follows a review of real usage (62 EA-project sessions, about 3,100 tool calls, where every tool error was an input-validation error): `mql5_chm_lookup_identifiers` accepts exact topic titles of letters, digits and underscores separated by single spaces, matched literally and reported `exact` only when a title or alias equals the whole name; the read tool and connection instructions say there is no offset or limit (continue with `next_cursor`) and to prefer `section_id` or `focus` over a large `max_chars`. Complete search, batch, read and image output for previously accepted inputs is identical to v1.3.13 in the full parity check, which now also covers typo and missing names in batches.

v1.3.15 changes no server behaviour: the README now opens with the product description and keeps release notes here, and the tracked `scripts/Compare-SearchOutput.mjs` (`npm run test:search-parity`) compares complete search, batch-lookup, read and image output with the pinned v1.3.13 baseline. `npm run test:corpus` now runs the whole corpus-backed service test file, so the locale-independent tie-breaker test is part of the release gate, and the cross-repo health test checks the skill's probe-failure categories.

v1.3.14 makes lookups much faster with identical results: exact identifier lookups use the title and alias indexes instead of scanning every topic (about 0.5 ms instead of 8 ms per name, so a 16-name batch takes a few milliseconds), the typo fallback reuses precomputed trigram keys (about 6 ms instead of 74 ms), prepared statements are reused, expansion work is skipped once exact matches fill the limit, and startup verification is about 0.5 s shorter with every check kept. Complete search and batch-lookup output was compared with v1.3.13 across every stored title and alias. The connection instructions also ask agents to reuse a verified passage instead of reading it again. v1.3.13 fixes Codex missing the tools on a session's first turn: the server now connects before its ~2.5 s startup verification, so it answers `initialize` and `tools/list` in about 150 ms, while every tool call still waits for verification and nothing is served unless it succeeds. v1.3.12: the server sends short usage instructions on connection, which Codex and Claude Code both show to the model, so agents get the status/lookup/read workflow and evidence rule even without the companion skill; maintenance messages and documentation address both clients; and the cross-repo health test covers Claude Code registration scopes. v1.3.11: official-site search suggestions keep every quoted clause complete within 500 characters; duplicate names in a batch lookup are searched once; cursor errors explain how to recover and the read tool documents cursor scope and text-only flags; rollback can recover a pending legacy transition in a development tree; rebuild staging inspects the base index once instead of three times; Codex registration rolls back after a CLI exception like Claude Code does; Claude configuration is parsed once per lookup; and legacy revision copies refuse a junction in the destination path. v1.3.10 started about 20% faster by computing PNG chunk CRCs with Node's native `zlib.crc32` (identical results) and prints each search result's signature once instead of repeating it inside the snippet text. v1.3.9 added Claude Code installation and removal scripts (`Install-Claude.ps1`, `Uninstall-Claude.ps1`) beside the Codex scripts, and bounding indexer memory by checking each raster file's size before reading it and capping retained catalog bytes. The production tools, image policy, index contract and documentation identities remain unchanged. v1.3.8 added an optional development-only documentation-quality benchmark with 32 source-reviewed cases. It includes the committed runtime and maintenance audit fixes and retains the deterministic malformed-input tests and approved-commit compatibility from v1.3.7. The production tools and documentation identities remain unchanged. It retains v1.3.6 fixes validating PNG chunk names and GIF headers against their original bytes, and requiring object roots in the standalone release-identity checker before PowerShell can unwrap arrays. It preserves the shared PNG transparency checks and maintenance JSON-root validation from v1.3.5, the indexed-pixel and prior-contract recovery fixes from v1.3.4, and the DOM-ordered image associations and whitespace-position repairs from v1.3.3. Rendered topic text, section definitions, topic/section/asset IDs, original image bytes, and the existing CHMs, corpus revision and genuine index revision remain unchanged. The index uses contract `mql5-chm-index-v3-assets-v4`; contracts v1 through v3 remain readable for rollback. The previously published Windows package is available from the [v1.3.0 release](https://github.com/shamwi2846/MQL5-CHM-MCP/releases/tag/v1.3.0). Release tags must match the package, lockfile, server, documentation and download user agents. Publish only the portable ZIP and checksum sidecar retained by the successful release-validation run for that exact commit; that run requires MCP/skill compatibility, the full Windows suite and two identical package builds. The companion skill now has [versioned packages and verified update/rollback](https://github.com/shamwi2846/MQL5-Coding-Skill/blob/main/skills/mql5-coding/references/releases.md).

Version 1.3.6 requires PNG chunk names to contain four original ASCII-letter bytes before decoding and matches GIF87a/GIF89a headers byte-for-byte. The standalone PowerShell 7 release checker now rejects non-object roots in both package files while preserving nested arrays and existing version/tag checks. Public tools, image policy, dependencies, schemas and extraction contract remain unchanged; valid genuine corpus assets retain their identities and original bytes.

Version 1.3.5 adds shared checks for PNG transparency chunk types, lengths, palette bounds, ordering, and duplicates. It preserves valid shorter indexed alpha tables and existing image limits. Validation covers the structures described in [the specification](SPEC.md); it does not establish complete ancillary-chunk conformance or universal decoder support. All object-only PowerShell readers now reject array, scalar, and null roots before deserialization can unwrap them, including staging and transition journals, reports, orphaned sidecars, provenance, corpus locks, update status, and repair manifests. Invalid recovery evidence is retained.

Version 1.3.4 validates indexed PNG pixels after reversing filters 0–4 for every non-interlaced or Adam7 pass, including 1-, 2-, 4- and 8-bit samples; unused row-padding bits are ignored. Validation preserves the existing image limits and original bytes, including the exact policy-pinned official PNG exception. Direct schema-3 rebuilds accept owned prior contracts v1–v4, and recovery can restore those prior contracts; every new or recovered candidate still requires v4 and database/manifest contract agreement. This validation-only release preserves existing genuine corpus and index identities.
