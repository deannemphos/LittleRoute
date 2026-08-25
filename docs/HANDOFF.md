# LittleRoute Remediation — Handoff

Continuation of `docs/REMEDIATION.md`. That file holds the full 32-task plan and
the per-task specs. This file records what is done, what is left, and the rules
the effort has been run under.

## State

- Branch: `contexts`, at `94e54e6`. Working tree clean. **Nothing has been pushed.**
- 28 of 32 tasks merged. No unmerged `lr/*` branches.
- Test suite: ~100 tests across `ContextDetectionTests.swift` and
  `PlaybackTests.swift`.
- SwiftData schema is at **V4**; `LittleRouteApp.makeModelContainer` builds
  `Schema(versionedSchema: SongSchemaV4.self)`. V1–V3 are frozen with nested
  `Song` classes; V4 points at the live one.

**Nothing in this branch has ever been compiled.** The dev machine is Windows —
no Xcode, no iOS SDK. Every task was implemented and reviewed by inspection
only. Expect compile errors; the user has said they will fix them later.

## Remaining tasks

### LR-16 — Use the model's identity, not the filename
**Next up.** Schema V5.

`songName` is used as identity throughout (`id: \.songName` in list views,
`firstIndex(where:)` in `play(song:)`). It is user-derived and not unique.

- Add `@Attribute(.unique)` to `songName`; switch view identity to
  `persistentModelID`.
- Needs a **`willMigrate`** that deduplicates before the constraint applies —
  not `didMigrate`. Applying a unique constraint to a column already holding
  duplicates fails the migration. `existingSongsByName` in
  `AudioPlayerManager` documents that duplicates are currently possible.
- Freeze V4 first, same checklist.

### LR-19 — Migrate the observable objects to `@Observable`
**Must run alone.** Touches every source file.

`AudioPlayerManager`, `LocationHandler` and `ContextDetector` are Combine
`ObservableObject`s. `ContentView` observes the audio manager, so the 0.5s
`currentTime` tick rebuilds the whole body twice a second.

- Convert all three to `@Observable`; views move to `@State`/`let`.
- `LittleRouteApp` currently injects via `.environmentObject`; there is a
  `@TODO` there noting this collapses to `.environment` once the classes are
  `@Observable`. `ContentView` holds them as `@EnvironmentObject`.
- `ContextDetector` holds `poiProvider` as `weak var (any POIProviding)?`.
- Done when a progress tick no longer invalidates `MapView`.

### LR-25 — Turn on targeted strict concurrency
**Depends on LR-19.**

- Set `SWIFT_STRICT_CONCURRENCY = targeted` in `project.pbxproj` (both app-target
  configurations), add `@MainActor` where the compiler asks.
- `AudioPlayerManager` currently uses ~8 `DispatchQueue.main.async` hops that
  capture non-Sendable `self` in `@Sendable` closures; each will warn under
  `targeted`. LR-07 chose hops over `@MainActor` because all six unsafe entry
  points cross an ObjC runtime boundary (`@objc` `AVAudioPlayerDelegate`,
  `#selector` notification dispatch, `MPRemoteCommand` blocks) where actor
  isolation is not enforced. If converting to `@MainActor`, those three entry
  points need `nonisolated` **and must keep their hops**.
- `static let shared` isolation interacts with `ContentView`/`LibraryView`,
  which read it from nonisolated stored-property initialisers.
- pbxproj edits: match tabs exactly, add minimum lines, never reformat.

### LR-26 — Replace `print` with structured logging
**Run last.** Touches every file in `Data Handling/`, so it conflicts with
everything.

- Adopt `Logger(subsystem:category:)` per subsystem.
- Add an `OSSignposter` interval around each POI search so battery cost is
  profilable.
- Done when no `print` remains in `Data Handling/`.

## Sequencing

All four are serial. There is no remaining parallelism.

```
LR-16  →  LR-19  →  LR-25  →  LR-26
```

## Operating rules

These are what the effort has run on. They exist for reasons that cost work to
learn.

1. **Agents cannot build.** Every brief must say so explicitly and forbid
   claiming verification. Define done as "diff is complete, minimal, reviewable,
   and I have stated what I could not check."
2. **Commit early.** Six agents were killed mid-task by session limits. Those
   that had committed kept their work; those that hadn't were salvaged by hand
   from their worktree or lost. Tell every agent to commit as soon as it has
   something coherent and refine on the same branch.
3. **One agent per file.** Assign lanes by file, not by task. Name the files
   other agents own and instruct them to stop and report rather than edit across
   a boundary. Merge conflicts cannot be caught by a build here.
4. **The specs in `REMEDIATION.md` are stale.** Line numbers are wrong
   everywhere. File lists have proved incomplete repeatedly. Tell each agent to
   grep and verify its own file list, and that finding a missed site is the list
   being wrong, not scope creep.
5. **Tell each agent what landed underneath it.** Most tasks now depend on
   changes made after their spec was written. A "what changed underneath you"
   section prevents rebuilding work that already exists.
6. **Verify branches independently.** Check base commit, diff scope, and the
   specific claim each agent is least sure about, rather than trusting reports.
7. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
   Deployment target iOS 18.1. `PBXFileSystemSynchronizedRootGroup` means new
   `.swift` files need no `project.pbxproj` edit; build settings still do.
8. `*.md` is gitignored — docs need `git add -f`.

## Available but unused

`.github/workflows/ios.yml` runs `xcodebuild build-for-testing` and
`test-without-building` on `macos-latest`. It triggers on push to `main` and on
pull requests targeting `main`. It has never run on this branch. A draft PR from
`contexts` to `main` would compile and test all 28 merged tasks. The user has
declined to push so far; the option remains.

## Known-unverified, highest risk first

1. **V4 is shape-identical to V3** — LR-15 changed string *contents*, not
   columns. If SwiftData identifies a store by shape-derived hash, a V3 store is
   taken for V4 and the V3→V4 stage never runs, leaving `locations` holding
   display strings that no longer match anything. Detect it by the absence of
   `context key migration: rewrote tags on N of M songs` in the console on first
   launch against a pre-LR-15 store. Nothing is destroyed if it happens and the
   rewrite is idempotent, so the fix is to force a shape difference in V4 and
   run again. LR-15 chose this over `@Attribute(originalName:)` deliberately:
   the alternative's failure mode silently destroys the array.
2. Four `@Model` classes named `Song` coexist (`SongSchemaV1/V2/V3.Song`, plus
   the top-level one). LR-16 adds a fifth. Whether SwiftData tolerates this is
   unconfirmed.
3. LR-17's V2→V3 stage is `.custom` and assumes SwiftData still performs the
   inferred column addition, with `didMigrate` only filling it. If wrong, the
   `isImported` column is never added.
4. `ContentView.body` was split into eleven computed properties to stay within
   the type checker's budget. Untested.
5. `MKMapItem.identifier` / `.rawValue` accessor spelling (LR-22).
6. `withAnimation(nil)` cancelling a `repeatForever` animation (LR-18).
