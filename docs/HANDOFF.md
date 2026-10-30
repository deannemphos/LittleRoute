# LittleRoute Remediation — Handoff

Continuation of `docs/REMEDIATION.md`. That file holds the full 32-task plan and
the per-task specs. This file records what is done and what is left.

## State

- Branch: `contexts`, at `fef3adb`. Working tree clean. **Nothing has been pushed.**
- **32 of 32 tasks merged.** The remediation plan is complete.
- Test suite: ~100 tests across `ContextDetectionTests.swift` and
  `PlaybackTests.swift`.
- SwiftData schema is at **V5**; `LittleRouteApp.makeModelContainer` builds
  `Schema(versionedSchema: SongSchemaV5.self)`. V1–V4 are frozen with nested
  `Song` classes; V5 points at the live one.
- `SWIFT_STRICT_CONCURRENCY = targeted` on both app-target configurations.
- Diagnostics go through `Logger`/`OSSignposter` (`Data Handling/Logging.swift`),
  not `print`.

**Nothing in this branch has ever been compiled.** The dev machine is Windows —
no Xcode, no iOS SDK. Every task was implemented and reviewed by inspection
only. Expect compile errors.

## The four tasks that closed the plan

- **LR-16** — `@Attribute(.unique)` on `Song.songName`, `SongSchemaV5`, and a
  `willMigrate` dedup stage (the file's only `willMigrate`: a unique constraint
  cannot be applied to a column already holding duplicates). Views identify
  songs by `persistentModelID`. Queue matching in `AudioPlayerManager` stays on
  `songName` deliberately — see the note at `play(song:)`.
- **LR-19** — all three service classes on `@Observable`, views on `@State`/`let`
  and `@Environment(Type.self)`. `MapView` now depends on `zones` alone, so the
  0.5s progress tick no longer invalidates it.
- **LR-25** — the setting turned on and one real race closed
  (`WeatherKitProvider`'s guards now run on the same actor as its writes). **No
  isolation annotations were added**; see the worklist below for why.
- **LR-26** — 48 `print` calls converted across six files, six logger categories,
  and `OSSignposter` intervals around POI searches.

## Compile worklist

This is what to expect on the first Mac build, worst first.

### Likely to be errors

1. **`AudioPlayerManager.shared` under strict concurrency.** LR-25 declined to
   mark the class `@MainActor` because the resolution depends on something
   unknowable here: SwiftUI declares `View` as `@MainActor @preconcurrency` on
   iOS 17+, so `ContentView`/`LibraryView` may already infer isolation and the
   problem may not exist — or it may want `@MainActor` spelled out on both
   structs, or `nonisolated(unsafe) static let shared`. Three plausible answers.
   If it fires, the one-word fix is `nonisolated(unsafe)`.
2. **`OSSignposter` API spelling** (`beginInterval(_:id:)` →
   `OSSignpostIntervalState`, `endInterval(_:_:)`, `makeSignpostID()`,
   `emitEvent(_:)`). Unverified against the SDK.
3. **`Logger` privacy interpolation** — written as `\(value, privacy: .public)`,
   not the older `%{public}` C spelling. Unverified.
4. **`PersistentIdentifier` / `persistentModelID` spelling** in `LibraryView` and
   `QueueDrawerView` (LR-16).
5. **Five `@Model` classes named `Song` coexisting** (V1–V4 nested + live).
   Whether SwiftData tolerates this is unconfirmed; four already coexisted.

### Expected warnings, deliberately left standing

Each is documented in-file at the site.

6. `AudioPlayerManager` — eight `DispatchQueue.main.async` sites capturing
   non-`Sendable` `self` in a `@Sendable` closure, plus the
   `Timer.scheduledTimer` block in `startPlaybackTimer`.
7. `ContextDetector` — two equivalent captures, in `evaluate()` and
   `refreshNow()`.
8. `WeatherProvider` — the `Task { @MainActor in }` capture (same class of
   diagnostic; predates LR-25, which widened what the closure covers).
9. `LocationHandler.getPointsOfInterest` — `completion` captured inside
   `MKLocalSearch.start`'s handler. Depends on whether
   `MKLocalSearch.CompletionHandler` is `@Sendable` in the iOS 18 SDK.
10. `SpinningAlbumView.loadArtwork` — `await MainActor.run { … }` captures a
    non-`Sendable` struct. Resolves together with item 1.
11. `OSSignpostIntervalState` captured in escaping non-`@Sendable` closures
    (LR-26) may add one more.

**Do not chase `complete`-mode diagnostics.** `targeted` will not emit them, and
the `MigrationStage` statics in `SongSchema.swift` would light up for nothing.

### Smaller unknowns

- Whether numeric interpolations default to public in `OSLogMessage`. If they
  don't, ~6 debug/info lines lose their counts; the two protected migration
  lines are explicit and safe either way.
- `String(describing: error)` was used because `OSLogMessage` is believed to have
  no overload for a bare `Error` existential. If it does, this is verbose but not
  wrong.
- Whether `import os` is sufficient in all six files.

## Verify at runtime, not just at compile

1. **The V4→V5 dedup actually runs.** Console, subsystem `nemphos.LittleRoute`,
   category `migration`: `songName dedup: collapsed N duplicate row(s) across M
   name(s)`. It fires even at zero, so silence means the stage did not run.
   **Note it is no longer a `print`** — it will not appear in Xcode's console the
   way it used to. Filter on the subsystem.
2. **V4 is shape-identical to V3** (the long-standing LR-15 risk). Detect by the
   absence of `context key migration: rewrote tags on N of M songs` on first
   launch against a pre-LR-15 store. Nothing is destroyed if it happens and the
   rewrite is idempotent; the fix is to force a shape difference and re-run. V5
   adds a real shape change, which *should* make the V4→V5 transition detectable
   — reasoning, not observation.
3. **`willMigrate` semantics** — that its context speaks the *source* schema's
   models, that `delete` + `save()` inside it is legal, and that the deletions
   are visible to the constraint application that follows. The whole stage rests
   on this.
4. `@Attribute(.unique)` upsert-on-collision behaviour (asserted from docs, not
   observed). Both insert paths check the name first, so nothing depends on it.
5. A progress tick should no longer redraw `MapView` — the LR-19 done-criterion,
   checkable with Self._printChanges() or an Instruments SwiftUI trace.
6. `MKMapItem.identifier` / `.rawValue` accessor spelling (LR-22).
7. `withAnimation(nil)` cancelling a `repeatForever` animation (LR-18).
8. `ContentView.body` was split into eleven computed properties to stay within
   the type checker's budget. Untested.

## Known follow-ups

- Four `print` calls remain outside `Data Handling/`, deliberately:
  `LittleRouteApp.swift:135` (container fallback), `ContentView.swift:149` and
  `LibraryView.swift:131` (import failures) — all natural fits for
  `Log.library` — and `ErrorView.swift:99`, preview scaffolding that should
  probably just be deleted.
- `LocationHandler.didFailWithError` logs at `.error` including
  `kCLErrorLocationUnknown`, which is spammy. TODO left in place to split that
  code down to `.debug`.
- `AudioPlayerManager.addSong` hardcodes `songName: "filename"`, which now
  collides on the unique key. Dead code; flagged in a comment.
- LR-25's follow-up: `SWIFT_STRICT_CONCURRENCY = complete`, once `targeted` is
  clean.
- The test target does **not** have strict concurrency on. Turning it on would
  double every diagnostic above while the app target is still dirty.

## Operating rules

These are what the effort ran on. They exist for reasons that cost work to
learn.

1. **Agents cannot build.** Every brief must say so explicitly and forbid
   claiming verification. Define done as "diff is complete, minimal, reviewable,
   and I have stated what I could not check." Where a task's own done-criterion
   requires a compiler — LR-25's did — restate it as something reachable rather
   than letting the agent quietly claim it.
2. **Commit early.** Eight agents were killed mid-task by session limits across
   the effort. Those that had committed kept their work. LR-19 was killed twice:
   the first attempt had committed nothing and lost everything, the second had
   committed after each file and lost nothing — it died during final
   verification with all nine commits already on the branch. Tell every agent to
   branch and make an empty commit *before reading any file*, then commit per
   file.
3. **One agent per file.** Assign lanes by file, not by task. Merge conflicts
   cannot be caught by a build here.
4. **The specs in `REMEDIATION.md` are stale.** Line numbers are wrong
   everywhere. Tell each agent to grep and verify its own file list, and that
   finding a missed site is the list being wrong, not scope creep. This kept
   paying: LR-16 found that freezing V4 broke `rewriteLocationsAsContextKeys`
   the same way LR-15's freeze of V3 had broken `backfillIsImported`.
5. **Tell each agent what landed underneath it.** Most late tasks depended on
   changes made after their spec was written. LR-25's spec named a race in
   `ContextDetector.poll` that LR-12 had already made structurally impossible.
6. **Verify branches independently.** Check base commit, diff scope, and the
   specific claim each agent is least sure about. LR-25 reported "comments only"
   for three files; that was checkable and true. Its worklist was missing one
   diagnostic, which review caught (`2c4b64a`).
7. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
   Deployment target iOS 18.1. `PBXFileSystemSynchronizedRootGroup` means new
   `.swift` files need no `project.pbxproj` edit; build settings still do.
8. `*.md` is gitignored — docs need `git add -f`.

## Available but unused

`.github/workflows/ios.yml` runs `xcodebuild build-for-testing` and
`test-without-building` on `macos-latest`. It triggers on push to `main` and on
pull requests targeting `main`. It has never run on this branch. A draft PR from
`contexts` to `main` would compile and test all 32 merged tasks — which is now
the single highest-value action available, since the whole plan is implemented
and none of it has been through a compiler. The user has declined to push so
far; the option remains.
