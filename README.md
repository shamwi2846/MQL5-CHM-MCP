# MQL5 CHM MCP 1.2.1

A portable, local MCP server for the official English MQL5 reference, AlgoBook, and Neural Networks book. The active corpus contains 4,827 indexed topics, 16,261 sections, and a secure catalog of the original technical diagrams, screenshots, charts, and MQL5 object icons. Runtime access is offline, stdio-only, and strictly read-only; no MetaTrader account, HTTP port, trading access, or authentication is required.

The server exposes four closed-world tools:

- `mql5_chm_search` searches exact API names first, then deterministically merges full-text matches with lower-weight MQL5-aware expansions before bounded typo recovery.
- `mql5_chm_read` reads a bounded topic passage with citations, related-topic links, and bounded image references. It never returns binary image data.
- `mql5_chm_read_image` returns exactly one catalogued original technical image by stable asset ID.
- `mql5_chm_status` reports active corpus/index revisions, source metadata, text and asset counts, and the last valid update-check result.

Normal searches remain text-only. Captions and filenames do not enter FTS5, and images are returned only after an explicit image-tool call.

## Install in Codex

Run from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Codex.ps1
```

Fully close and reopen Codex after installation, activation, or rollback.

## Check, stage, and activate official updates

Update checking is manual. It downloads only the three fixed HTTPS CHM URLs on `www.mql5.com` into temporary storage, enforces redirect and size limits, compares hashes, and never activates anything:

```powershell
.\Check-DocumentationUpdates.ps1
```

Stage a different official corpus or a same-corpus index-contract upgrade. This downloads when required, independently counts each CHM's HTML directory entries before extraction, extracts exactly that count, indexes text and safe assets, verifies SQLite/asset integrity, rejects unsafe in-topic references or topic loss, checks representative API ranking, writes a change report, and leaves the index inactive:

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

Apply and rollback use a strict recovery journal under the same maintenance lock. If either command is interrupted, rerun the corresponding command; it completes the recorded direction without toggling back. Check, stage, rebuild, package, and install refuse to cross an incomplete transition.

Source metadata records hashes, byte sizes, retrieval/acceptance time, and available HTTP `ETag`/`Last-Modified` values. These timestamps are never presented as a CHM publication or build version.

## Rebuild and transfer

`Rebuild-Index.ps1` rebuilds from the active revision's CHMs and can migrate the legacy corpus-keyed schema-2 layout additively. Existing legacy revisions are copied, never modified or removed. Use the staged update workflow, not manual CHM replacement, for later documentation changes.

```powershell
.\Rebuild-Index.ps1
.\Package-Portable.ps1
```

To review a validated inactive schema-3 revision without touching the production ZIP, build a candidate package explicitly:

```powershell
.\Package-Portable.ps1 -CandidateRevision <64-character-index-revision>
```

Candidate packages default to `build\portable-candidate-release`. `-OutputDirectory <directory>` selects a different output root, and `-ReleaseName <safe-name>` selects the stage/ZIP name. Output staging is rejected if it equals, contains, or overlaps the project, an immutable revision, application/scripts/config/runtime/tools sources, or a reparse point. An existing stage is replaced only when it contains the package ownership marker written by this packager. The final ZIP is validated in a temporary sibling and atomically published, preserving an existing known-good ZIP if compression fails.

Copy or unzip the complete portable package on another Windows x64 computer and run `Install-Codex.ps1`. The bundled Node.js runtime means no system Node installation is needed.

`Package-Portable.ps1` rebuilds bundles in a complete development checkout. In a transferred portable copy it instead verifies `checksums.sha256` before executing bundled Node or 7-Zip and before reusing the prebuilt bundles, so repackaging does not require source files, npm packages, or system Node. A tree containing `checksums.sha256` is always treated as portable even if extra development-looking files were added. Install, rebuild, update, and repackaging therefore reject missing, extra, or tampered package files before bundled code or native tools execute. A portable repack defaults to a sibling `<package-folder>-repack-output` directory outside the verified source; a custom `-OutputDirectory` must also be non-overlapping.

The portable package includes `config\mql5-image-policy.json` and `config\mql5-query-expansions.json`, so a transferred copy can perform a verified offline same-corpus rebuild without a source tree or `node_modules`. Extraction/index scratch directories live under the Windows temporary directory and are not part of the checksummed package; interrupted atomic-write debris is reconciled under the maintenance lock before retry.

## Uninstall from Codex

```powershell
.\Uninstall-Codex.ps1
```

Uninstalling removes only the `mql5-chm` Codex registration. Documentation, revisions, and update history remain on disk. MetaTrader and MetaEditor MCP registrations are never changed.

## Security boundary

- Runtime opens only the active verified revision and never writes to it.
- Tool inputs cannot select paths, execute SQL, spawn processes, write files, or access the network.
- Asset IDs resolve only prepared catalog rows and opaque digest-based storage keys. Startup validates exact asset-tree closure, hashes, MIME, dimensions, byte/pixel limits, and reparse-point absence; every image call revalidates the requested bytes.
- Only validated static PNG/JPEG technical assets can be returned. Decorative, unsupported, unknown, guessed, missing, or oversized IDs disclose no bytes.
- Update downloads are restricted to HTTPS with final host exactly `www.mql5.com`.
- Candidate revisions remain inactive until validation passes and `-Apply` is run explicitly.
- Online freshness guidance is returned to Codex as metadata; the MCP runtime itself stays offline.
- The advisory `maintenance\update-status.json` and the strictly validated recovery journals `maintenance\revision-transition.json` and `maintenance\revision-stage.json` are intentionally mutable and not checksummed. Every immutable package file and asset plus `data\active.json` is covered by exact checksum closure; pending journals block unrelated installation or maintenance until their bound operation is safely completed.

OCR, image conversion, resize/transcoding, extracted HTML, and native image-processing runtimes are not included.

See `SPEC.md` for the complete public contract.
