# DevSweep

[![CI](https://github.com/Lukitaduarte/DevSweep/actions/workflows/ci.yml/badge.svg)](https://github.com/Lukitaduarte/DevSweep/actions/workflows/ci.yml)
[![CodeQL](https://github.com/Lukitaduarte/DevSweep/actions/workflows/codeql.yml/badge.svg)](https://github.com/Lukitaduarte/DevSweep/actions/workflows/codeql.yml)
[![codecov](https://codecov.io/gh/Lukitaduarte/DevSweep/graph/badge.svg)](https://codecov.io/gh/Lukitaduarte/DevSweep)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Lukitaduarte/DevSweep/badge)](https://scorecard.dev/viewer/?uri=github.com/Lukitaduarte/DevSweep)
[![CodeRabbit Reviews](https://img.shields.io/coderabbit/prs/github/Lukitaduarte/DevSweep?labelColor=171717&color=FF570A&label=CodeRabbit%20reviews)](https://coderabbit.ai)
[![Latest release](https://img.shields.io/github/v/release/Lukitaduarte/DevSweep)](https://github.com/Lukitaduarte/DevSweep/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](#install)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14624/badge)](https://www.bestpractices.dev/projects/14624)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A macOS menu bar app for developers that tells you **what** to clean and **when**, then cleans it in one click: dev processes stuck in limbo, and the caches, builds and simulator data that Flutter, iOS, Android, Node/Next.js and Go leave behind.

Available in English, Português (Brasil) and Español.

<p align="center">
  <img src="docs/images/suggestions.png" width="24%" alt="Suggestions tab">
  <img src="docs/images/processes.png" width="24%" alt="Processes tab">
  <img src="docs/images/storage.png" width="24%" alt="Storage tab">
  <img src="docs/images/settings.png" width="24%" alt="Settings">
</p>

## What it does

- **Processes.** It finds dev tools left running after whatever started them has closed: orphaned language servers, Dart tooling daemons, hung Crashlytics `upload-symbols`, `go run` binaries, idle Gradle daemons, helpers of apps that already quit. Processes still in use by your editor are listed but never suggested.
- **Storage.** It measures DerivedData, Xcode indexes, Gradle caches of old versions, pub/npm/Go caches, FVM versions no project uses, `node_modules` and builds of projects you haven't touched in weeks, old `.ipa`/`.apk` files, and more.
- **Proactive.** It checks processes every 2 minutes and disk every few hours, and sends a notification with a **Clean now** button when something crosses your thresholds, memory gets tight or the disk runs low.
- **Safe by default.** Every item is labeled *Safe*, *Re-downloads* or *Deletes data*. Items that delete data are never cleaned in bulk and ask for confirmation.
- **Keeps itself up to date.** When a new version is out, you get an update card with a link to the changelog and a one-click install.

## General workspace

Open **General workspace** from the menu bar to use the larger window. The existing developer scans and recommendations remain available in the menu.

| Area | Available behavior |
|---|---|
| Logs | Discover logs older than 30 days in user Logs, application Logs and sandbox containers, without requiring an app-specific rule. |
| Caches | Find recognizable cache directories and `CACHEDIR.TAG` folders. Unknown owners without a valid cache tag remain analysis-only; identified owners must be closed before removal. |
| Old temporary files | Review regular `.tmp`/`.temp` files owned by the current user and modified over 7 days ago in the private user temporary directory. Open files are protected; selected files go to Trash. |
| Review Trash | Read-only inventory of the account Trash, with Finder access and JSON export. Restore/manage items in Finder; this view does not empty Trash or permanently delete files. |
| External metadata | On an explicitly selected writable local external volume/folder, review validated `.DS_Store` files and `.TemporaryItems` contents older than 7 days and owned by this user. AppleDouble files are excluded and preserved. Volume Trash, backups and indexing folders are excluded. |
| Projects | Discover 34 artifact folder names across confirmed workspaces using project markers. Git-tracked content, nested repositories and open artifacts are protected. These are manual candidates, not a claim that every artifact is unused. |
| Storage explorer | Browse folders/local external volumes or recursively find large files. Filter by allocated size, modification age and extension; sort by size, date or name; reveal in Finder and review selected items. |
| Installers | Find macOS/mobile installer files and ZIPs with installer entries, inspecting a bounded central directory without extraction. |
| Applications | Inventory third-party app bundles and review exact-identifier caches, logs, saved state, preferences and application data before removal. Personal data requires individual selection; containers stay read-only. Apple apps remain analysis-only. |
| Maintenance | Inspect launch agents, preference-file validity, Spotlight, login items and filesystem integrity. DNS resolver cache and QuickLook cache refresh are separate confirmed actions. |
| Monitoring | Refresh CPU per core, memory, swap, load, uptime, local volume capacity, network rates per interface, processes, thermal pressure and battery charge when available. |

The explorer's **Find large files** mode starts at 100 MB in the interface and searches the selected folder and subfolders. Change the minimum to any size, 100 MB, 1 GB or 5 GB; filter by modification age and comma-separated extensions. The search skips app bundles, Git internals, links, other mounts and online-only cloud files. It is bounded to 100,000 entries, 32 levels and 30 seconds; reaching a limit produces a partial result and disables removal until a narrower search completes. The selected volume's free/total capacity is shown separately from result sizes. JSON exports respect search/filters/selection and include the root, mode, filter settings, volume capacity and independent discovery/measurement completeness.

Cached results are checked against root and authorized-file identities off the main actor before reuse. Measurement updates are published in batches; missing or incomplete sizes have an explicit finished state instead of a perpetual spinner. Removed/replaced authorized files or roots invalidate the cache. Newly created files can still require **Refresh** within the 60-second cache lifetime.

Searches support cancellation, bounded traversal and explicit partial results. Measurements that time out or fail are not reported as zero or eligible for removal. Results and monitoring snapshots can be exported as JSON. Folder scans do not follow symlinks or cross mounts and skip online-only cloud files.

Temporary discovery is limited to 6 levels and the external metadata search to 12 levels; each uses a 50,000-entry/15-second budget. Reaching a limit or encountering access failures produces partial results and disables removal. External discovery requires a connected writable mount from the local volume inventory. Temporary cleanup does not target the shared `/tmp` tree, Downloads or arbitrary `.tmp` files elsewhere. AppleDouble may contain resource forks and is preserved. Moving a file to Trash on the same volume does not immediately increase that volume's free space.

In **Applications → Review related files**, association uses the exact `CFBundleIdentifier`, not fuzzy app/folder names. The review covers `Library/Caches/<id>`, `Logs/<id>`, `Saved Application State/<id>.savedState`, `Preferences/<id>.plist`, `Application Support/<id>` and read-only `Containers/<id>`. No items are selected automatically. **Select all** excludes preferences, application data and containers; preferences/application data require individual selection and the final data-loss confirmation. Selected application data can contain valuable files or credentials. Keychains, cloud folders and Group Containers are not searched.

Related data stays protected when the bounded inventory finds another installation with the same identifier or cannot establish a sole owner. The inventory covers standard application locations and the selected app's parent folder, not every possible copy on every disk. Before each related removal, the owning app's Info.plist identity/version and the installation inventory are checked again; the app must be closed and its related targets must not be open. The app bundle is processed after related targets, preserving this ownership evidence during the operation. This is a sequential operation rather than an atomic uninstall; cancellation or failures can leave some selected items in place and are reported through the shared cleanup status/history. App bundle identity is also checked when removing it; another copy protects shared data without preventing removal of the selected bundle. JSON exports include association category, identifier and evidence, without reading preference or support-data contents. Applications already removed and artifacts with unrelated folder names require a later residue-discovery feature.

General removal always requires selection, review and confirmation, uses Trash and shares cleanup progress and history. Scanned files, parents and roots are revalidated by identity before removal; modified regular files are preserved. Protected home roots, shell configuration and credential paths cannot be removed from this window. These observations do not lock the filesystem against concurrent changes. Allocated sizes are estimates and can count shared APFS blocks more than once.

This is the general foundation, not complete Mole parity: GPU/SMART, disk transfer rates, fan/temperature sensors, battery health/cycles, orphan-service removal, firmware, backup cleanup and privileged or automatic repairs are not implemented. No maintenance task requests administrator privileges or repairs preferences automatically.

## Install

```bash
npx @lukitaduarte/devsweep                                          # one command, no Homebrew
```

or with Homebrew:

```bash
brew trust --tap https://github.com/Lukitaduarte/DevSweep
brew tap lukitaduarte/devsweep https://github.com/Lukitaduarte/DevSweep
brew install --cask devsweep
```

Homebrew 7 refuses to load casks from a tap you haven't trusted, which is why the first command exists — it's Homebrew asking you to confirm you meant to install software from outside its official taps, and it's a good habit to read what a tap contains before trusting it. Here that's a [single file](Casks/devsweep.rb). The trust command names the URL rather than `lukitaduarte/devsweep`, because a tap whose repository isn't named `homebrew-something` is matched by URL only.

Both paths download the release from GitHub, check it against the published SHA-256 and put **DevSweep.app** in `/Applications`.

Prefer to do it by hand? Download `DevSweep-x.y.z.zip` from the [latest release](https://github.com/Lukitaduarte/DevSweep/releases/latest), unzip it and move the app to `/Applications`.

### The first launch

DevSweep is **not notarized by Apple**, because notarizing requires a paid Apple Developer account. macOS therefore blocks the first launch of anything it downloaded and quarantined, with *"Apple could not verify DevSweep.app is free of malware"*.

- **Homebrew** quarantines what it installs, so you will see it. Allow it once in **System Settings → Privacy & Security → Open Anyway**, or install with `brew install --cask --no-quarantine devsweep` if you'd rather opt out of the check knowingly.
- **A manual download** behaves the same way: allow it once in System Settings.
- **`npx @lukitaduarte/devsweep`** doesn't quarantine, so the app opens directly.

Updates install normally afterwards either way. If you want to know what you're allowing before you allow it, the [verification commands](#verifying-a-download) prove the download came from this repository's release workflow — which is a stronger guarantee than notarization gives you, since it ties the file to a public build log.

### Verifying a download

Every release asset is signed with [Sigstore](https://sigstore.dev) by the release workflow, carries SLSA build provenance and ships with an SBOM. The quickest check needs only the GitHub CLI:

```bash
gh attestation verify DevSweep-x.y.z.zip --repo Lukitaduarte/DevSweep
```

Or, with [cosign](https://docs.sigstore.dev/cosign/), against the signature bundle published next to the file:

```bash
cosign verify-blob DevSweep-x.y.z.zip \
  --bundle DevSweep-x.y.z.zip.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/Lukitaduarte/DevSweep/\.github/workflows/release\.yml@refs/(heads/main|tags/v.+)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The identity covers both refs the workflow runs from: `refs/heads/main` for a normal release and `refs/tags/vX.Y.Z` when the assets of a tag are rebuilt. Either check proves the file came out of this repository's release workflow, not from someone re-uploading a zip.

### Build from source

Requires macOS 14+ and Xcode 16+ (or a Swift 6 toolchain).

```bash
git clone https://github.com/Lukitaduarte/DevSweep.git
cd DevSweep
make install     # builds, copies to /Applications and launches
```

Builds from source don't update themselves (they aren't signed with the release key). **Settings → Updates** links to the releases page instead.

To see what DevSweep would suggest on your Mac without changing anything:

```bash
DEVSWEEP_LIVE=1 swift test --filter LiveReportTests
```

## Updates

DevSweep checks this repository's releases once a day using [Sparkle](https://sparkle-project.org). Every update is signed with an EdDSA key and verified before it's installed. In **Settings → Updates** you can check now, turn on automatic installs, or open the releases and changelog.

## Your project folders

The first time you open DevSweep it asks where your projects live, and **recommends nothing until
you confirm the list**. That list is not cosmetic: "this Flutter SDK is unused" and "this project
has been idle for weeks" are both derived from it. A folder missing from the list makes a project
you work in every day look abandoned — and its pinned SDK look disposable.

### What it proposes, and where that comes from

Two sources, both only proposals you can edit before confirming:

1. **Folders your editors have open.** VS Code and its forks (Code, Insiders, Cursor, Antigravity
   IDE, Windsurf, VSCodium) record opened folders in `User/globalStorage/storage.json`, and
   JetBrains IDEs (IntelliJ, Android Studio, GoLand, PyCharm…) in `options/recentProjects.xml`.
   DevSweep reads those lists and proposes the **parent folder** of each project, so wherever you
   actually work gets found even if its name is unusual.
2. **Conventional folder names**, when they exist in your home folder:

   | Source | Folders |
   |---|---|
   | Common by convention | `~/Project` `~/Projects` `~/Developer` `~/dev` `~/code` `~/workspace` `~/src` `~/work` `~/git` `~/repos` `~/Sites` |
   | JetBrains IDEs | `~/StudioProjects` `~/AndroidStudioProjects` `~/IdeaProjects` `~/PycharmProjects` `~/WebstormProjects` `~/GolandProjects` `~/PhpstormProjects` `~/RubymineProjects` `~/CLionProjects` `~/RiderProjects` `~/DataGripProjects` |
   | Other tools | `~/eclipse-workspace` `~/NetBeansProjects` `~/Documents/GitHub` (GitHub Desktop) `~/Unity` |

Parent folders are enough — DevSweep looks a few levels inside each one. Your home folder itself is
never proposed, and the list is capped at 8 entries. Change it any time in **Settings → Projects**.

### What it reads, and what it doesn't

Inside those folders DevSweep reads only what it needs to tell projects apart: marker files
(`pubspec.yaml`, `package.json`, `go.mod`, …), the FVM pin, and modification dates. **It never reads
your source code.** The editor lists above are read once, locally, to propose the folders; nothing
about them leaves your machine.

## Reviewing a cleanup

In **Storage**, click the list button beside a category to review its paths, grouped by project.
Select individual artifacts, inspect them in Finder, and clean only the selected items. Categories
that use a tool's cleanup command remain a single action: selecting paths cannot constrain what
that command removes. Items labeled *Deletes data* still require a second confirmation.

Project artifacts with Git-tracked files or open handles detected for the current user are
preserved. A process whose working directory is the project root also protects the project.
These checks run again before cleanup; an inconclusive activity probe preserves the artifact.
They are conservative checks, not a filesystem lock against concurrent changes.

Measurements distinguish complete, partial (`+`), and unavailable results. Incomplete sizes are
excluded from automatic recommendations. Cleanup progress shows the current path; **Cancel next
items** lets the current operation finish and leaves the remaining items untouched. The result
stays visible, and **Cleanup history** opens recent attempts, errors, and session summaries from
the local cleanup log. Reported reclaimed bytes are estimates, not a guarantee of immediate free
space on APFS or after moving files to Trash.

## Mac cleanup

The **Mac** group in Storage includes disk caches for standard Chrome, Chromium, Edge and Brave
profiles; Firefox HTTP caches (`cache2` in standard local profiles); Slack and Discord web/rendering
caches; Slack, Discord and Zoom `.log` files older than 30 days; and user crash reports older than
30 days. These categories are manual: they do not join automatic recommendations. Browser cookies,
passwords, bookmarks and history, application sessions, local storage, Discord modules, Zoom
recordings and chat files are outside their path rules. Custom browser profile locations are not
scanned. Discord test-channel data and nested Zoom logs are outside this increment's scope.

Close the owning application before cleaning its cache. Review checks bundle identifiers (including
helpers and renamed app bundles) and open files; execution checks again. An uncertain check keeps
the item. Old logs and crash reports require individual confirmation and move to Trash because
historical diagnostics cannot be regenerated. A file that becomes recent after scanning is kept.

Cache layout references: [Chromium user/cache directories](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md)
and [Electron session storage](https://www.electronjs.org/docs/latest/api/app/). The rules select only
named cache subdirectories; they never sweep an entire application profile or system log tree.
Additional references: [Firefox profile directories](https://firefox-source-docs.mozilla.org/toolkit/profile/index.html),
[Firefox HTTP cache](https://firefox-source-docs.mozilla.org/networking/cache2/doc.html),
[Discord cache troubleshooting](https://support.discord.com/hc/en-us/articles/31623498041623-Discord-Troubleshooting-Guide),
[Discord debug logs](https://support.discord.com/hc/en-us/articles/1500006052822-How-to-Report-a-Bug)
and [Zoom client logs](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060047).

## Delivery checklist

“Tested” below means fixture-based automated verification. App validation means an interactive
check of that feature in the packaged app; a successful build alone does not count.

| Feature | Implemented | Tested | Validated in app |
|---|---|---|---|
| External project cleanup | Yes | Yes | Confirmed by user |
| Project/path review, progress and history | Yes | Yes | Pending |
| Chrome disk cache | Yes | Yes | Pending |
| Chromium disk cache | Yes | Yes | Pending |
| Edge disk cache | Yes | Yes | Pending |
| Brave disk cache | Yes | Yes | Pending |
| Slack web/rendering caches | Yes | Yes | Pending |
| Slack logs older than 30 days | Yes | Yes | Pending |
| User crash reports older than 30 days | Yes | Yes | Pending |
| Firefox HTTP cache | Yes | Yes | Pending |
| Discord web/rendering caches | Yes | Yes | Pending |
| Discord logs older than 30 days | Yes | Yes | Pending |
| Zoom logs older than 30 days | Yes | Yes | Pending |
| More app caches, cloud/Office, virtualization and orphan cleanup | Planned | Pending | Pending |
| Additional development stacks and artifact types | Planned | Pending | Pending |
| Disk explorer and large-file review | Planned | Pending | Pending |
| macOS installer discovery | Planned | Pending | Pending |
| Assisted application uninstall | Planned | Pending | Pending |
| Explicit macOS maintenance actions | Planned | Pending | Pending |
| Expanded monitoring and diagnostics | Planned | Pending | Pending |

## Customizing

Stack knowledge lives in YAML files under [`stacks/`](stacks), one per stack. You can add your own without rebuilding:

```bash
mkdir -p ~/.config/devsweep/stacks
cp docs/stack-template.yaml ~/.config/devsweep/stacks/my-stack.yaml
```

Then click **Settings → Stacks → Reload**. Entries with the same `id` as a bundled one replace it, and `disabled: true` turns one off.

## Trust and security

DevSweep deletes files and stops processes, so it's built to be easy to audit:

- **Open and small.** What gets detected and cleaned is plain YAML in [`stacks/`](stacks). Nothing is hidden in code.
- **Guard rails in code.**
  - It only deletes inside your home folder and refuses well-known roots (`~/Documents`, `~/Library/Caches`, …).
  - It never touches shell configuration (`~/.zshrc`, `~/.oh-my-zsh`, `~/.gitconfig`, …), whatever a stack file asks for.
  - It recommends nothing until you confirm [your project folders](#your-project-folders), so no cleanup is based on a guess about your layout.
  - It only stops processes owned by your user, and first checks that the PID still runs the same command.
  - It never runs as root.
- **No telemetry.** The only network access is the daily update check against GitHub releases.
- **A record of every cleanup.** What ran, what it deleted and any errors go to `~/Library/Application Support/DevSweep/cleanup.log`, so you can always find out what touched a file.
- **Checked on every change:**
  - [CodeQL](https://github.com/Lukitaduarte/DevSweep/security/code-scanning) static analysis;
  - [TruffleHog](https://github.com/trufflesecurity/trufflehog) secret scanning;
  - the [OpenSSF Scorecard](https://scorecard.dev/viewer/?uri=github.com/Lukitaduarte/DevSweep);
  - Dependabot updates;
  - AI code review by [CodeRabbit](https://coderabbit.ai);
  - tests that validate every rule and fail if personal data lands in the repository.
- **Signed updates** via Sparkle.

Found a problem? See [SECURITY.md](SECURITY.md).

## Contributing

New stacks, better rules and translations are very welcome, and most need no Swift. See [CONTRIBUTING.md](CONTRIBUTING.md). If you use [Claude Code](https://claude.com/claude-code), [`CLAUDE.md`](CLAUDE.md) and the skills in [`.claude/skills`](.claude/skills) walk it through adding stacks, translations, investigating detections and preparing screenshots.

## Maintaining

Cutting a release is merging the pull request release-please keeps open; everything else is automated. [`docs/MAINTAINING.md`](docs/MAINTAINING.md) covers the one-time setup — signing key, repository settings, Codecov, CodeRabbit, the Homebrew tap and npm — and [`.claude/skills/release/SKILL.md`](.claude/skills/release/SKILL.md) covers the release flow itself and what to do when part of it fails.

## Project layout

```
stacks/        what to detect and clean, per stack (YAML)
locales/       UI translations (YAML)
docs/          stack template, README images
Sources/DevSweep/
  App/           entry point, state, scheduling, updater
  Advisor/       what to suggest, notifications
  Core/          shell, formatting, localization, preferences
  Definitions/   YAML schema, loader, validation, path resolution
  Processes/     ps/lsof parsing, limbo detection, stopping processes
  Storage/       project scanning, providers, sizing, safe deletion
  UI/            menu bar popover
Tests/           unit tests plus validation of stacks, locales and privacy
scripts/         app bundle, release packaging, signing keys, screenshot redaction
```

## License

[MIT](LICENSE)
