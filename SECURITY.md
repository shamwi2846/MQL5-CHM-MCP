# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for a security problem. Include the affected version, the steps to reproduce and the impact you observed.

## Supported versions

Only the latest release on `main` receives fixes. Releases are immutable: a published release and its assets are never edited, so a correction always ships as a new version and tag.

## Scope

The server is a read-only documentation lookup over a local index. In scope are the MCP server and its input validation, the index and package integrity checks, and the install, update and uninstall scripts, which change only the `mql5-chm` registration in Codex or Claude Code. The server never trades, places orders or handles account credentials.

## Automated checks

- **Secret scanning with push protection** blocks pushes that contain known credential formats and scans the full history.
- **Dependabot** raises alerts and security-update pull requests for npm, and weekly pull requests that move the pinned GitHub Actions commits.
- **Dependency review** fails a pull request that adds a dependency with a known high or critical vulnerability.
- **CodeQL** scans JavaScript and the workflows; **zizmor** audits the workflows; **PSScriptAnalyzer** checks the PowerShell scripts with a curated security and correctness rule set. Findings appear under **Security > Code scanning**.
- Every workflow pins its actions to full commit SHAs, checks out code without persisted credentials and runs with a read-only token unless a job needs more.

## Pins maintained by hand

Dependabot does not update these; review them at least monthly and after any advisory that affects them:

- npm version updates. A dependency bump must rerun `npm run build:candidate` and `npm run notices:check`, and the regenerated `licenses/BUNDLED-NODE-NOTICES.txt` must be reviewed before merging.
- The `@hono/node-server` override in `package.json`, a patched version pinned for security. Raise it only to a release that keeps the MCP SDK's HTTP adapter API, as `tests/ci-contract.test.mjs` checks.
- The bundled Node.js runtime (`$script:PinnedNodeVersion` in `scripts/Common.ps1`) and the 7-Zip runtime (`$script:PinnedSevenZipVersion`), which are verified by hash when a package is built.
- The scanner versions: zizmor (`version:` in `.github/workflows/static-analysis.yml`) and PSScriptAnalyzer (`$AnalyzerVersion` in `.github/scripts/Invoke-PSScriptAnalyzerSarif.ps1`). Dependabot moves the actions that run them, not these versions.
