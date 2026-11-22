# LittleRoute — Working Notes

Current behaviour, build and test instructions live in the README. This file
keeps what the README doesn't: how work gets done here, and what is still open.

## Working from Windows

- The app cannot build on the Windows dev machine: no Xcode, no iOS SDK. The
  only real compile and test is the macOS GitHub Actions run, which starts on
  any push (`ios.yml` tests, `ipa.yml` builds the unsigned sideload IPA).
- Foundation-only files (`ContextZoneGeometry`, `ContextTransitionState`,
  `Spectrum`, `CustomPlace`) and their `LittleRouteTests/*Checks.swift` can be
  compiled locally with Swift for Windows.
- Never claim a change was built, tested or verified unless CI or a device
  actually did it. Say what could not be checked.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
  Deployment target is iOS 18.1.
- `PBXFileSystemSynchronizedRootGroup` means new `.swift` files need no
  `project.pbxproj` edit; build settings still do.
- `*.md` is gitignored, so new docs need `git add -f`.
- Diagnostics go through `Logger`/`OSSignposter` (`Data Handling/Logging.swift`),
  subsystem `nemphos.LittleRoute`, not `print`.

## Working with agents

- Have each agent branch and commit early and per file; agents killed by
  session limits keep only what they committed.
- Split parallel work by file, not by task. Merge conflicts can't be caught by
  a build here.
- Tell each agent what has already landed underneath it, and verify every
  branch independently: base commit, diff scope, and the claim it is least sure
  of.

## Measured so far

Optimized Swift 6.3.3 on the Windows host measured a 61.27 ms p95 geometry
build for 100 POIs over a 1.2 km square at 10 m sampling (30 builds after one
warmup). The 2 m reference fixtures cover 860,000 points with no ownership
differences outside the 20 m ambiguity band. These are not iPhone performance
claims.

## Still open

- Physical-iPhone qualification: background adaptation, interruptions, routes,
  equalizer, visualizer, accessibility, frame rate, memory and energy.
- Two `print` calls remain: the store fallback in `LittleRouteApp.swift` (a
  natural fit for `Log.library`) and preview scaffolding in `ErrorView.swift`.
- `AudioPlayerManager.addSong` is unreachable dead code that writes a literal
  `"filename"` song name; delete it.
- `ContentView` and `LibraryView` each carry an identical `.fileImporter`.
- `Song.deinit` is empty; remove it.
- `SWIFT_STRICT_CONCURRENCY` is `targeted` on the app target. Move to
  `complete` once `targeted` is clean; the test target has none set.
