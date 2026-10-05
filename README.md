# MQL5 CHM MCP 1.3.2

This checkout prepares **v1.3.2**, applying extended-path Windows metadata queries consistently to Node and both 7-Zip binaries, distinguishing native execution limitations from file damage, and correcting the repository-root description. It preserves the pinned binaries, existing runtime repairs, and documentation corpus. The previously published Windows package is available from the [v1.3.0 release](https://github.com/shamwi2846/MQL5-CHM-MCP/releases/tag/v1.3.0). Release tags must match the package, lockfile, server, documentation and download user agents. Publish only the portable ZIP and checksum sidecar retained by the successful release-validation run for that exact commit; that run requires MCP/skill compatibility, the full Windows suite and two identical package builds. The companion skill now has [versioned packages and verified update/rollback](https://github.com/shamwi2846/MQL5-Coding-Skill/blob/main/skills/mql5-coding/references/releases.md).

A portable, local MCP server for the official English MQL5 reference, AlgoBook, and Neural Networks book. The active corpus contains 4,827 indexed topics, 16,261 sections, and a secure catalog of the original technical diagrams, screenshots, charts, and MQL5 object icons. Runtime access is offline, stdio-only, and strictly read-only; no MetaTrader account, HTTP port, trading access, or authentication is required.

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

Batch names must be ASCII identifiers, 1 to 128 characters, matching `[A-Za-z_][A-Za-z0-9_]*`; expressions, qualified names, whitespace and paths are rejected before any search runs. `exact`, `non_exact` and `none` describe the search outcome for that name. A prefix, FTS result or typo candidate remains non-exact. Read the selected topic/section and verify the complete identifier before making an API claim. Batch output contains bounded metadata; it does not return passages or image bytes. A request error fails the entire batch instead of returning a successful partial result. Existing single-search behavior is unchanged, and older clients can continue using it.

Example tool arguments: `{"identifiers":["OnTick","CopyBuffer","SYMBOL_VOLUME_STEP"],"source":"mql5","limit":1}`. From a development checkout with locked dependencies installed, measure the shipped tool against sequential and parallel single calls on a verified corpus using `npm run benchmark:identifiers -- --package-root <absolute-package-root> --server-path <absolute-server.mjs> --report <new-report.json>`. The benchmark validates every warm and measured response before accepting a sample, preserves result metadata/citations, and reports request counts, local median latency and serialized response bytes for 1, 4, 8 and 16 names. `--samples` accepts 3–21 samples per mode (default 9); for an even count, the median averages the two middle values. Tool errors, changed source/index identity, inconsistent counts or match statuses, and changed result metadata fail the command without publishing a passed report. Timing is descriptive; batch searches remain synchronous and do not guarantee a latency improvement.

For a focused read, `focus_match` reports `exact`, `approximate`, or `none`; it is `null` for unfocused reads and continuation pages. An exact match must occur in the returned bounded passage; a phrase extending beyond that passage is reported as approximate. Token boundaries are checked against the original documentation, so truncating an identifier suffix cannot turn a partial match into an exact match. Complete identifiers and phrases take priority over partial matches, so `OBJPROP_FONT` is preferred over the prefix in `OBJPROP_FONTSIZE`. Approximate and absent matches include a text notice. An absent focus without an explicit section returns a bounded topic passage rather than an arbitrary section. Verify the complete requested identifier in the returned passage before using it as documentation support.

When documentation supports a final answer, use the structured citation metadata: name the exact returned topic `title`, or the exact read `section_heading` when present; include the stable `citation.topic_id` and relevant `citation.section_id`; and state `citation.corpus_revision` or `citation.index_revision` once per answer when multiple findings share that revision. The structured citation also retains the source filename. Revision metadata does not need to be repeated in every paragraph.

## Install in Codex

Run from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Codex.ps1
```

Fully close and reopen Codex after installation, activation, or rollback.

Before changing Codex registration, the installer launches the bundled server with the bundled Node runtime and a 30-second deadline. It verifies `initialize`, the initialized notification, the exact five read-only tools returned by `tools/list`, and `mql5_chm_status` against the package revisions already validated by the installer. A startup, protocol, tool, annotation, or revision failure leaves Codex registration unchanged.

Installation and uninstallation serialize package-managed registration changes through one machine-global registration mutex. Installation is idempotent only when the existing `mql5-chm` registration is enabled, path-owned by this package, and has no environment or tool-filter overrides. The working directory may be absent/null or be a fully qualified path selecting the package root; root-relative and drive-relative paths are rejected. An allowlist must be absent/null; even an empty allowlist is restrictive. An empty/null denylist is allowed. Disabled, modified, differently owned, malformed, or duplicate entries are preserved and rejected. If registration fails, rollback removes only an entry still observed as owned by the exact Node/server paths just added, then confirms the post-state. This prevents races between cooperating package scripts. Codex currently exposes removal by name rather than by an ownership compare-and-swap token, so an unrelated external config writer must not replace `mql5-chm` during the small `codex mcp remove` command window; the package cannot atomically preserve a replacement it was never able to observe.

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

```powershell
.\Rebuild-Index.ps1
.\Package-Portable.ps1
```

To review a validated inactive schema-3 revision without touching the production ZIP, build a candidate package explicitly:

```powershell
.\Package-Portable.ps1 -CandidateRevision <64-character-index-revision>
```

Candidate packaging revalidates the staged report against the current active base and freshly inspects both databases. A report that reduces cataloged or exposed image coverage or image occurrences is rejected unless the reviewed package command also includes `-AcceptAssetReduction`.

Candidate packages default to `build\portable-candidate-release`. `-OutputDirectory <directory>` selects a different output root, and `-ReleaseName <safe-name>` selects the stage/ZIP name. Output staging is rejected if it equals, contains, or overlaps the project, an immutable revision, application/scripts/config/runtime/tools sources, or a reparse point. An existing stage is replaced only when it contains the package ownership marker written by this packager. The pinned 7-Zip runtime archives a case-insensitive ordinally sorted file list with fixed ZIP timestamps, attributes, compression settings, and no directory entries; this deterministic single-threaded compression step has a bounded 900-second deadline. Generated active-pointer and sidecar JSON use canonical UTF-8/LF bytes, checksum lines are ordered by package path, and mutable update status is omitted. Identical package inputs therefore produce an identical ZIP SHA-256. ZIP and sidecar bytes are durably completed and validated under token-bound `.writing` names before they become prepared candidates. The final ZIP and timestamp-free `<ReleaseName>.zip.manifest.json` sidecar are then validated and published as one journaled transaction. The sidecar contains exactly `schema_version`, `file`, `bytes`, and lowercase `sha256`. A legacy ZIP without a sidecar may be upgraded; an unexplained malformed or mismatched existing pair is refused.

Copy or unzip the complete portable package on another Windows x64 computer and run `Install-Codex.ps1`. The bundled runtime is exactly Node.js `24.17.0`, so no system Node installation is needed.

Windows version metadata for Node and both 7-Zip binaries is queried through normalized extended drive or UNC paths, including inputs already carrying an extended prefix. Stored paths and exact version, hash, size, architecture, license, and native capability checks are preserved. A long path can still prevent native 7-Zip DLL/CHM-codec loading or process startup. When pinned binaries are intact but metadata or native execution is unavailable, the command stops with a diagnostic and a bounded probe excerpt, retaining pending recovery evidence without a repair download or binary replacement. Retry from a shorter package path and a supported working directory; no temporary runtime fallback is provided. Missing or damaged files retain the existing development repair workflow.

`Package-Portable.ps1` rebuilds bundles in a complete development checkout. In a transferred portable copy it instead verifies `checksums.sha256` before executing bundled Node or 7-Zip and before reusing the prebuilt bundles, so repackaging does not require source files, npm packages, or system Node. A tree containing `checksums.sha256` is always treated as portable even if extra development-looking files were added. Install, rebuild, update, and repackaging therefore reject missing, extra, or tampered package files before bundled code or native tools execute. A portable repack defaults to a sibling `<package-folder>-repack-output` directory outside the verified source; a custom `-OutputDirectory` must also be non-overlapping.

In a development checkout, missing or damaged runtime files are repaired only from the official HTTPS `nodejs.org` archive through a 300-second, 64 MiB bounded stream. Archive, executable, exact version, x64 architecture, and license hashes are verified; each copied payload crosses from `.writing` to `.prepared` only after its exact descriptor validates, the prior runtime pair is preserved on failure, and validated files are transactionally published with `node.exe` last. Portable repacking is offline and never downloads or repairs its runtime. Bundled 7-Zip is the pinned official Windows x64 `26.02` executable/DLL/license set, validated against checked-in provenance including CHM capability and repaired only from the official MSI through a 300-second bounded administrative extraction in a development checkout; installed-program fallbacks are not used. Packaging also checks deterministic complete dependency notices against the lockfile and the nonzero esbuild bundle contributors.

The portable package includes `config\mql5-image-policy.json` and `config\mql5-query-expansions.json`, so a transferred copy can perform a verified offline same-corpus rebuild without a source tree or `node_modules`. Extraction/index scratch directories live under the Windows temporary directory and are not part of the checksummed package. Interrupted `.writing` payloads are known to precede publication and are reclaimed only in their exact token-bound context; prepared candidates, backups, journals, and canonical files remain subject to strict validation and fail-closed ambiguity handling under the maintenance lock.

## Validation and CI

In a complete development checkout, `npm test` runs the fast build, notice, syntax, MCP contract, and unit suite used on pull requests. `npm run test:maintenance` runs the maintenance fixtures. `npm run test:release` runs the fast suite, full maintenance and packaging fixtures under PowerShell 7 and Windows PowerShell 5.1, corpus-backed MCP tests, and the bundled-server test. Transferred portable packages intentionally omit the development tests, source tree, lockfile, and npm dependency tree, so these npm validation commands are not available there. Release-tag validation restores only `data` and `revisions` from a checksum-sidecar-verified prior corpus fixture, creates fresh maintenance state, binds subprocess tests to setup-node `24.17.0`, and builds the portable ZIP twice to prove equal SHA-256 values. It never restores executable runtime or mutable maintenance files from the fixture. For the first release after an official CHM, index-contract, or image-policy update, manually dispatch the release workflow with `corpus_fixture_release` set to a reviewed release or draft containing the current portable corpus fixture; the same strict sidecar, current-source, and current-policy checks still apply.

## Uninstall from Codex

```powershell
.\Uninstall-Codex.ps1
```

Uninstalling is a no-op when `mql5-chm` is absent. It removes only a registration path-owned by this package, even when optional settings changed or package runtime files are damaged; malformed or differently owned entries are preserved and rejected. Documentation, revisions, and update history remain on disk. MetaTrader and MetaEditor MCP registrations are never changed.

## Security boundary

- Runtime opens only the active verified revision and never writes to it.
- Tool inputs cannot select paths, execute SQL, spawn processes, write files, or access the network.
- Asset IDs resolve only prepared catalog rows and opaque digest-based storage keys. Startup validates exact asset-tree closure, hashes, MIME, dimensions, byte/pixel limits, and reparse-point absence; every image call revalidates the requested bytes.
- Only validated static PNG/JPEG technical assets can be returned. Decorative, unsupported, unknown, guessed, missing, or oversized IDs disclose no bytes.
- Update downloads are restricted to HTTPS with final host exactly `www.mql5.com`.
- Candidate revisions remain inactive until validation passes and `-Apply` is run explicitly.
- Allowed filesystem roots remain absolute through confinement checks. Selecting `X:\` does not become the drive-relative `X:`; using the confinement root itself as a mutation target still requires an explicit allow-root mode.
- Maintenance requires object-root manifests and active pointers with runtime-compatible JSON types. Numeric strings, wrapped arrays, Boolean counts, and unexpected documentation sources are rejected before activation; supported schema-2 rollback metadata remains valid.
- Online freshness guidance is returned to Codex as metadata; the MCP runtime itself stays offline.
- The advisory `maintenance\update-status.json` and the strictly validated recovery journals `maintenance\revision-transition.json` and `maintenance\revision-stage.json` are intentionally mutable and not checksummed or included in a new release ZIP. Every immutable package file and asset plus `data\active.json` is covered by exact checksum closure; pending journals block unrelated installation or maintenance until their bound operation is safely completed.

OCR, image conversion, resize/transcoding, extracted HTML, and native image-processing runtimes are not included.

See `SPEC.md` for the complete public contract.

## Skill compatibility

For installation troubleshooting, the coding skill supplies one read-only `Test-Mql5Environment.ps1` command. It checks Codex registration, the installed package's listed checksums and pinned Node version, actual MCP stdio startup, source differences, skill contents, MetaEditor paths, and Python availability. It never starts MetaEditor or MT5. See the skill's [environment health command](https://github.com/shamwi2846/MQL5-Coding-Skill/blob/main/skills/mql5-coding/references/environment-health.md) for invocation and limits. Both repositories exercise it against a real MCP bundle on Windows under PowerShell 7 and Windows PowerShell 5.1 in their compatibility job.

Both repositories verify the actual MCP server against the [MQL5 coding skill](https://github.com/shamwi2846/MQL5-Coding-Skill)'s packaged consumer contract on trusted pushes and pull requests. MCP release validation also requires this check. Each successful run retains both repository revisions and artifact hashes. See [the compatibility guide](https://github.com/shamwi2846/MQL5-CHM-MCP/blob/main/docs/skill-compatibility.md) for the checks, private-repository CI credentials, and local or installed-pair commands.

For identifier batches, the compatibility check verifies requested source and limit, lookup and result counts, match statuses, and corpus/index revisions for both mixed names and the maximum-size request. Each result's citation must match its topic, section, and verified revisions. Structurally valid replies with inconsistent commitments fail the check.
