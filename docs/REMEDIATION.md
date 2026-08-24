# LittleRoute Remediation Plan

Thirty-one independently shippable tasks from the architecture and performance
review of the `contexts` branch. Each is scoped to a single small PR and states
its own acceptance criteria.

Web version (same content, filterable):
https://claude.ai/code/artifact/fa64fa63-bbfa-4c83-9160-8adf2423a0f8

---

## Read this before starting any task

**You almost certainly cannot build this project.** It is an iOS app — SwiftUI,
MapKit, AVFoundation, SwiftData, WeatherKit — and the primary development
machine is Windows. There is no Xcode, no simulator, no `xcodebuild`. The Swift
toolchain for Windows ships none of those frameworks, so it cannot even
typecheck these files.

Therefore:

- **Do not claim you verified a build, ran tests, or confirmed behaviour.** Say
  plainly what you changed and what you could not check.
- Keep diffs minimal and reviewable. A human reviews these on a Mac, in a batch.
- If you are unsure something compiles — an API you half-remember, an
  availability annotation, an actor-isolation rule — say so in the PR body
  rather than guessing silently.
- If a task's "Done when" requires a build or a device, treat it as the
  reviewer's checklist, not yours.

**The file lists below are indicative, not exhaustive.**

They were compiled by reading the codebase, not by exhaustively grepping it, and
at least one has already proved incomplete: LR-01's list omitted
`ContextRingView.swift`, which declared the very type that task renames. The
agent found it by grepping rather than trusting the list.

So: **treat each task's file list as a starting point and verify it yourself.**
Grep for the symbol, type, or API you are changing across the whole repo before
you decide the task is done. If you find a site the list missed, handle it and
say so in your report — that is the list being wrong, not you exceeding scope.

The same caveat applies to the lane table below: lanes were drawn from those
same file lists, so lane boundaries may leak. If your task turns out to touch a
file another lane owns, stop and flag it rather than editing across the boundary.

**Conventions**

- Branch from the current integration branch (`contexts` unless told otherwise).
- One task per branch, one branch per PR. Do not bundle tasks.
- Match the surrounding code's style: comment density, naming, and idiom in this
  repo are distinctive — read the neighbours before writing.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not
  XCTest. Match that.
- Deployment target is **iOS 18.1**. Everything through iOS 18 is available:
  `@Observable`, `CLMonitor`, `CLLocationUpdate.liveUpdates()`, SwiftData
  `#Index` / `#Unique`.

---

## Sequencing

```
LR-01 alone  ->  merge  ->  6 lanes in parallel  ->  merge  ->  LR-19 alone
   ->  merge  ->  lanes resume (LR-21, 24, 28, 29)  ->  LR-25, 26, 31
```

Two tasks must run solo because they cross every file: **LR-01** (renames a type
across nine files) and **LR-19** (rewrites observation in every view). Anything
in flight during either will conflict badly.

### Lanes

Parallelism is limited by file contention, not by the dependency graph. Assign
one agent per lane; it produces that lane's PRs in sequence.

| Lane | Owns | Tasks |
|---|---|---|
| Playback | `AudioPlayerManager.swift` | LR-04, 05, 06, 07, 09, 23, 29 |
| Location | `LocationHandler.swift` | LR-11, 20, 24 |
| Detection | `ContextDetector.swift`, `ContextClassifier.swift` | LR-03, 12, 13, 21, 22, 28 |
| Model | `Song.swift`, schema, `Item.swift` | LR-14, 15, 16, 17 |
| App shell | `LittleRouteApp.swift`, `ContentView.swift` | LR-02, 08, 10 |
| Views | `SpinningAlbumView`, `CurvedText`, themes | LR-18, 30 |

Solo / cross-cutting: LR-01, LR-19, LR-25, LR-26, LR-27, LR-31.

### Critical path

The app's premise — music that changes as you move — does not currently work
with the phone in a pocket. Location stops at background, and the detection
timer stops with it.

`LR-01 -> LR-02 -> LR-03 -> LR-11 -> LR-12`

---

## Phase 0 — Foundation

Wide, mechanical changes that later PRs would otherwise collide with. Merge
these before opening anything else.

### LR-01 — Move the context enum out of AudioPlayerManager
**Blocker · M · depends: nothing (goes first)**

Extract the nested `AudioPlayerManager.Context` enum into a top-level
`MusicContext` in its own file. Right now four unrelated types — the classifier,
the detector, the map, the library — depend on the audio player just to express
a *location* concept. Move the `tintColor` extension and the `icon(for:)` switch
alongside it. Delete the unused `Context` struct in `Context.swift`: it is dead
code, and its `priority` field duplicates `ContextClassifier.Profile.specificity`.

- Files: new `Data Handling/MusicContext.swift` · `AudioPlayerManager.swift:239`
  · `Context.swift` · `ContextClassifier.swift` · `ContextDetector.swift` ·
  `MapView.swift:92` · `LibraryView.swift` · `ContentView.swift` ·
  `ContextRingView.swift:13` · `ContextDetectionTests.swift`
- Done when: `AudioPlayerManager` declares no nested type, two types named
  Context no longer coexist, and the existing tests pass with only the rename
  applied.

**Status: done** — branch `lr/01-music-context`, commit `fc564dc`, awaiting
review and a Mac build. `ContextRingView.swift` was missing from the original
file list and was found by grep; the entry above is corrected.

### LR-02 — Own the location objects at app scope
**Blocker · S · depends: nothing (sequence with LR-01)**

`ContentView.init()` constructs `LocationHandler` and `ContextDetector`, then
holds them as `@ObservedObject` — which does not own its object. A struct
re-init spawns a second `CLLocationManager`, discards accumulated debt, dwell
and buffer state, and leaks the poll timer. Create both in `LittleRouteApp`,
hold with `@State`, inject via `.environment`.

- Files: `LittleRouteApp.swift` · `ContentView.swift:20-27`
- Done when: `ContentView` has no custom `init`, and detector state survives a
  forced view re-render.

### LR-03 — Make ContextDetector testable in isolation
**High · S · depends: LR-01**

Introduce `protocol POIProviding` exposing `currentLocation` and
`getPointsOfInterest`, conform `LocationHandler`, and have the detector hold the
protocol instead of the concrete class. Also drop the live-network default
`weatherProvider: WeatherProviding? = WeatherKitProvider()` — a default argument
should not open a network connection.

- Files: new `POIProviding.swift` · `LocationHandler.swift` ·
  `ContextDetector.swift:68-87`
- Done when: a test drives the full detector state machine with a stub provider,
  no `CLLocationManager` and no network.

---

## Phase 1 — Correctness

Bugs a user would hit in the first session. Mostly independent — good candidates
to run in parallel across lanes.

### LR-04 — Stop reloadQueue from killing playback
**Blocker · S · depends: nothing**

`reloadQueue` unconditionally sets `currentIndex = 0` and calls `loadAudio`,
replacing `audioPlayer` and deallocating the one that was playing. Its callers
include `LibraryView.toggleTag` and `ContentView.onChange(of: songs)` — so
toggling a single context chip stops the music. If `currentSong` is still
present in the rebuilt queue, keep its index and leave the player untouched.

- Files: `AudioPlayerManager.swift:425-448`
- Done when: toggling a context chip mid-song does not interrupt playback, and
  the queue still reflects the new tags.

### LR-05 — Handle audio interruptions and route changes
**Blocker · M · depends: nothing**

Nothing observes `AVAudioSession.interruptionNotification` or
`routeChangeNotification`. A phone call stops playback permanently; unplugging
headphones stops the audio while `isPaused` still reports playing, so the UI
lies. Observe both — resume on `.ended` with `.shouldResume`, pause and publish
accurate state on `.oldDeviceUnavailable`. Table stakes for a music app.

Fold in: lock-screen elapsed time is only pushed on transport events, so the
Control Center scrubber drifts during playback.

- Files: `AudioPlayerManager.swift`
- Done when: an interrupting call resumes afterward, and unplugging headphones
  pauses with the UI in sync.

### LR-06 — Activate the audio session lazily
**Medium · S · depends: LR-05 (same file, land after)**

`configureAudioSession()` calls `setActive(true)` from the singleton's `init`,
so the app seizes the audio session the moment it launches and can cut off
another app's music before the user has pressed play. Set the category at init;
activate on first playback and deactivate with `.notifyOthersOnDeactivation`
when stopped.

- Files: `AudioPlayerManager.swift:39-46`
- Done when: launching LittleRoute while another app plays audio does not
  interrupt it.

### LR-07 — Make playback callbacks main-thread safe
**High · S · depends: nothing**

`audioPlayerDidFinishPlaying` and the five `MPRemoteCommandCenter` handlers are
not guaranteed to arrive on the main thread, yet each calls `skip()` or
`musicPlayPause()`, which mutate published state. Hop to the main actor at every
entry point.

- Files: `AudioPlayerManager.swift:52-73`, `:370-375`
- Done when: no published mutation is reachable off-main from a delegate or
  remote-command callback.

### LR-08 — Replace the onContextChange closure with declarative state
**High · S · depends: LR-02**

The `onContextChange` callback captures `songs` and has to be manually
reassigned in `onChange` to avoid going stale — a bug waiting to recur every
time someone adds a code path. `confirmedContext` is already published: delete
the callback and react with `.onChange(of: contextDetector.confirmedContext)`,
reading `songs` fresh at that moment.

- Files: `ContentView.swift:238`, `:247` · `ContextDetector.swift:60`
- Done when: no closure reassignment remains, and a context switch after an
  import uses the newly imported songs.

### LR-09 — Keep a stable order so unshuffle doesn't restart the song
**Medium · S · depends: LR-04 (same function area)**

`toggleShuffle` un-shuffles by passing the already-filtered `songQueue` back
through `reloadQueue`, which re-filters it, resets `currentIndex` to zero and
reloads audio — so turning shuffle off restarts playback from the top of the
queue. Keep an unshuffled `orderedQueue` alongside and restore from it.

- Files: `AudioPlayerManager.swift:339-347`
- Done when: toggling shuffle off preserves both the playing song and its
  playback position.

### LR-10 — Don't crash on a bad model store
**Medium · S · depends: nothing**

`fatalError` on `ModelContainer` creation turns a corrupt store or a failed
migration into an unrecoverable launch crash — the user's only fix is deleting
the app. Fall back to an in-memory container and surface a non-fatal error state.

- Files: `LittleRouteApp.swift:13-25`
- Done when: a deliberately corrupted store launches the app in a degraded but
  usable state.

---

## Phase 2 — Background location

This is what makes the app do the thing it says on the tin. LR-11 and LR-12 must
ship together — the plist change alone does not restart a suspended timer.

### LR-11 — Request and declare background location
**Blocker · S · depends: nothing (pair with LR-12)**

The app declares only `NSLocationWhenInUseUsageDescription` and only the `audio`
background mode, and calls `requestWhenInUseAuthorization()`. Location therefore
stops the moment the app backgrounds while audio keeps playing, so context
detection only works with the screen on. Add
`NSLocationAlwaysAndWhenInUseUsageDescription`, add `location` to
`UIBackgroundModes`, set `allowsBackgroundLocationUpdates = true`, and escalate
to always-authorization after when-in-use is granted.

- Files: `Info.plist:21-26` · new `LittleRoute.entitlements` ·
  `project.pbxproj` · `LocationHandler.swift:40-42`
- Done when: locking the phone and walking a few blocks still delivers location
  updates.

### LR-12 — Retire the poll timer for OS-driven detection
**Blocker · L · depends: LR-03, LR-11 — split if it grows**

Detection runs off `Timer.scheduledTimer`, which does not fire while the app is
suspended — so even after LR-11 the state machine stalls in the background. The
deployment target is 18.1, so `CLLocationUpdate.liveUpdates()` and `CLMonitor`
are both available; `CLMonitor`'s circular conditions model "dwell inside a
zone" directly and let the OS wake the app rather than burning a timer. Drive
detection from location delivery instead of wall-clock.

- Files: `ContextDetector.swift:94-105`, `:140-185` · `LocationHandler.swift`
- Done when: a context change is detected and applied with the app backgrounded,
  and no `Timer` remains in `ContextDetector`.

### LR-13 — Persist detector state across launches
**Medium · S · depends: LR-12**

Debt, dwell and buffer live only in memory, so a relaunch — or a background
jetsam, which is likely once the app runs with location in the background —
resets them and hands the user an abrupt context reshuffle. Persist with
timestamps and rehydrate on start, decaying debt by elapsed wall-clock time.

- Files: `ContextDetector.swift:44-57`
- Done when: force-quitting and relaunching preserves the confirmed context and
  the debt balances.

---

## Phase 3 — Data layer

Pre-1.0 is the only moment these are free. LR-14 unblocks the other three and
must land first.

### LR-14 — Add a versioned schema and migration plan
**High · M · depends: nothing (before any other model change)**

There is no `VersionedSchema` and no `SchemaMigrationPlan`, and `Item.self` — an
unused Xcode template model — is still in the container schema. Three planned
changes (a unique constraint on `songName`, stable context keys, an `isImported`
flag) are breaking without a migration path. Establish V1 matching what ships
today, wrap the container in a plan, and drop `Item` as the first migration step.

- Files: `LittleRouteApp.swift:13-25` · `Song.swift` · `Item.swift` · new
  `SongSchema.swift`
- Done when: an existing store opens after the `Item` removal with no data loss,
  and adding a property is a one-line schema bump.

### LR-15 — Decouple stored context tags from display names
**High · M · depends: LR-01, LR-14**

`Song.locations` stores the enum's display raw values — `"Gyms"`,
`"Restaurants"` — so renaming a case for UI reasons silently orphans every
user's tags, and nothing checks at compile time that a stored string is a real
context. Store a stable key and derive the display string separately; migrate
existing rows.

- Files: `MusicContext.swift` · `Song.swift:20` · `LibraryView.swift:35-39` ·
  `AudioPlayerManager.swift:430`
- Done when: changing a context's display name leaves every existing tag intact.

### LR-16 — Use the model's identity, not the filename
**Medium · S · depends: LR-14**

`songName` serves as identity everywhere — `id: \.songName` in two list views,
`firstIndex(where:)` in `play(song:)`. It is user-derived and not guaranteed
unique, and `songExists` is a race-prone stand-in for a real constraint. Add
`@Attribute(.unique)` and switch view identity to `persistentModelID`.

- Files: `Song.swift` · `AudioPlayerManager.swift:304` ·
  `QueueDrawerView.swift:94` · `LibraryView.swift:63`
- Done when: importing the same file twice cannot create two records, and views
  identify songs by model ID.

### LR-17 — Track imported songs on the model
**High · S · depends: LR-14**

`LibraryView.importedSongs` runs a synchronous `FileManager.fileExists` per song
on every body evaluation — main-thread disk I/O inside a view body, re-run every
time the `List` re-evaluates. Add an `isImported` flag set at import time and
filter on that.

- Files: `Song.swift` · `LibraryView.swift:26-33` ·
  `AudioPlayerManager.swift:153-210`
- Done when: no `FileManager` call remains inside any view body.

---

## Phase 4 — Performance

The render loop costs more than the classification algorithm does. LR-18 is the
best return per line changed; LR-19 is the systemic fix and should land once
Phase 1 is merged.

### LR-18 — Spin the album art on the GPU
**High · S · depends: nothing**

Rotation is driven by a 30 Hz `Timer.publish` mutating `@State` — thirty full
SwiftUI invalidations a second, forever, of a stack containing an angular
gradient, two strokes and a shadow. Replace it with a single `.rotationEffect`
under `.linear(duration:).repeatForever(autoreverses: false)`, driven by
`isPaused`.

- Files: `SpinningAlbumView.swift:24`, `:73-76`
- Done when: no timer remains in the view, and an Instruments trace shows no
  per-frame CPU work while the disc spins.

### LR-19 — Migrate the observable objects to @Observable
**High · L · depends: LR-02, LR-08 — land after Phase 1 merges**

`ContentView` holds the audio manager as `@ObservedObject`, so the half-second
`currentTime` tick rebuilds the entire body — the map, the disc, both
`CurvedText` arcs (one `Text` view per character, each with a shadow) and the
queue drawer, twice a second. `@Observable` is free on iOS 18.1 and makes
SwiftUI track which properties a body actually reads, so a progress tick stops
redrawing the map. This is the systemic fix behind most of the render cost.

- Files: `AudioPlayerManager.swift` · `LocationHandler.swift` ·
  `ContextDetector.swift` · all views
- Done when: all three classes use `@Observable`, views use `@State`/`let`, and
  a progress tick no longer invalidates `MapView`.

### LR-20 — Remove unused published state and the reverse geocode
**High · S · depends: nothing**

`currentLocationName`, `lastKnownLocation`, `nearbyPlaces` and `locationError`
are written but read by no view. `nearbyPlaces` is republished on every POI
poll, invalidating `ContentView` — which observes the handler for
`authorizationStatus` — for nothing. `currentLocationName` exists only to hold
the result of a `CLGeocoder` reverse-geocode run on every accepted location
update, allocating a fresh geocoder each time; Apple rate-limits that to roughly
one request per minute. Delete all four and the geocode call.

- Files: `LocationHandler.swift:14-17`, `:91`, `:165-170`
- Done when: the handler publishes only `authorizationStatus` and
  `currentLocation`, and no geocoding happens in normal operation.

### LR-21 — Gate POI search on displacement and fix the radius
**High · M · depends: LR-12**

Two problems in one path. `MKLocalSearch` runs every ten seconds; it is
server-backed and throttled, and because locations are only accepted every 60s
or 400m, most of those calls re-query an identical region for an identical
answer — gate on displacement or a cache TTL instead. Separately, `searchRadius`
already doubles the max effective radius to 1200m, then `getPointsOfInterest`
doubles it again into a 2400m span. `MKLocalSearch` caps its result set, so an
oversized region returns an arbitrary sample of a huge area — an accuracy bug as
much as a cost one. Target ~600m to match the profile radii.

- Files: `ContextDetector.swift:70`, `:140-185` · `LocationHandler.swift:66-71`
  · `ContextClassifier.swift:90`
- Done when: a stationary user triggers no repeat searches, and a walk logs
  searches proportional to distance covered rather than to time.

### LR-22 — Stabilize zone identity so the map can diff
**Medium · S · depends: LR-01**

`zoneID` embeds latitude, longitude and name, so IDs churn on every poll and
`MapView`'s `ForEach` tears down and rebuilds every circle and annotation
instead of diffing them. Derive the ID from a stable identifier for the place.

- Files: `ContextClassifier.swift:215-218` · `MapView.swift:43`
- Done when: repeated polls at the same location produce identical zone IDs.

### LR-23 — Fix the N+1 fetches on import
**Medium · S · depends: nothing**

`loadSongsFromBundle` runs one `FetchDescriptor` per mp3 file, and `importSongs`
calls `songExists` twice per file. Fetch existing `songName`s once into a `Set`
and check membership.

- Files: `AudioPlayerManager.swift:112`, `:164`, `:176`, `:212-215`
- Done when: importing N songs performs a constant number of fetches rather than N.

### LR-24 — Tune CoreLocation for battery
**Medium · S · depends: LR-12**

`kCLLocationAccuracyBest` is the most expensive GPS mode, and the handler then
discards most of what it receives in a hand-rolled 60s/400m throttle. Push the
filtering into `distanceFilter` on the manager so the OS never wakes the
process, and drop to `kCLLocationAccuracyNearestTenMeters` — the smallest POI
radius in the profile table is 70m, so ten-metre precision is ample.

- Files: `LocationHandler.swift:22-33`, `:147-171`
- Done when: the manual throttle is gone and Energy Log shows a measurable drop
  in location cost on a walk.

---

## Phase 5 — Hardening & polish

Everything that makes it shippable rather than working. LR-30 is a store-review
risk, not a nice-to-have.

### LR-25 — Turn on targeted strict concurrency
**High · M · depends: LR-07, LR-19**

The project builds in Swift 5 mode with no `SWIFT_STRICT_CONCURRENCY` setting,
and concrete races already exist: `WeatherKitProvider.fetchInFlight` is written
from a `@MainActor Task` and read from arbitrary callers, and
`ContextDetector.poll` reads `locationHandler.currentLocation` off-main. Set
`SWIFT_STRICT_CONCURRENCY = targeted` and add `@MainActor` where the compiler
asks. Far cheaper now than as a Swift 6 migration later.

- Files: `project.pbxproj` · `AudioPlayerManager.swift` · `LocationHandler.swift`
  · `ContextDetector.swift:141` · `WeatherProvider.swift:42-49`
- Done when: the target builds clean at `targeted`, with a follow-up issue filed
  for `complete`.

### LR-26 — Replace print with structured logging
**Medium · S · depends: nothing**

Roughly twenty `print` calls carry all diagnostics, and errors never reach the
user — `locationError` is published but never displayed, and POI search failures
are swallowed silently. Adopt `Logger(subsystem:category:)` per subsystem, and
add an `OSSignposter` interval around each POI poll so battery cost becomes
profilable in Instruments.

- Files: all of `Data Handling/` · `ContextDetector.swift:180-183`
- Done when: no `print` remains in `Data Handling/`, and POI polls appear as
  signpost intervals in Instruments.

### LR-27 — Add the WeatherKit entitlement, or shelve the feature
**High · S · depends: LR-11 (creates the entitlements file)**

There is no entitlements file and no `CODE_SIGN_ENTITLEMENTS` build setting, so
`WeatherKitProvider` throws on every call, prints, and returns nil — `.rainy`
and `.snowy` can never fire on device. The graceful degradation is good design,
but it means the feature silently does nothing rather than failing loudly.
Either enable the capability on the developer account, or gate the provider
behind a flag so its absence is explicit.

- Files: `LittleRoute.entitlements` · `project.pbxproj` ·
  `WeatherProvider.swift:57-61`
- Done when: a device build either returns real conditions or logs one explicit
  "weather disabled" line at startup.

### LR-28 — Make weather a score modifier, not a hard override
**Medium · M · depends: LR-27**

`contextOverride` returns `.rainy` for any rain, trumping everything including
speed and nearby POIs — walk into a gym in the rain and you get rain music.
Weather reads more like a second axis than a winner-take-all: apply it as a
multiplier, or only when the top POI score falls below a threshold.

- Files: `ContextClassifier.swift:43-55`, `:137-204` · `ContextDetectionTests.swift`
- Done when: an indoor context with a strong POI score survives rain, while open
  ground in rain still selects `.rainy`.

### LR-29 — Build a real crossfade
**Low · L · depends: LR-04, LR-06**

There is only ever one `audioPlayer`, so `switchContext` fades out, waits 1.5s
on `asyncAfter`, then stops and constructs a new player — that is a gap, not a
crossfade. The pending closure is also not cancellable, so two rapid context
changes queue conflicting work. Use two players (or `AVAudioEngine` with two
`AVAudioPlayerNode`s) and a cancellable `Task`.

- Files: `AudioPlayerManager.swift:395-422`
- Done when: outgoing and incoming tracks overlap audibly, and a second context
  change during a fade cancels the first cleanly.

### LR-30 — Accessibility and Dynamic Type pass
**High · M · depends: nothing**

Every font is a fixed `.system(size:)`, so Dynamic Type does nothing at all.
`CurvedText` builds one `Text` per character, so VoiceOver reads song titles
letter by letter — it needs `.accessibilityElement(children: .ignore)` and a
real label. The hardcoded 320pt disc plus an 18pt text radius overflows an
iPhone SE's 320pt-wide screen; size relative to the container instead.

- Files: `CurvedText.swift:27-36` · `ContentView.swift:39-40` · all views
- Done when: the app is usable at the largest accessibility text size, VoiceOver
  announces the title as one phrase, and nothing clips on an SE.

### LR-31 — Test the queue and playback logic
**Medium · M · depends: LR-04, LR-09**

`ContextClassifier` has real coverage because it is a pure static struct — the
queue and playback logic, which is what users actually notice, has none, and
`LittleRouteTests.swift` is still the empty template stub. Cover: `reloadQueue`
preserving the current song, shuffle/unshuffle round-tripping, skip and previous
wrapping at queue boundaries, and the empty-queue guards.

- Files: new `LittleRouteTests/PlaybackTests.swift` · `LittleRouteTests.swift`
- Done when: the four behaviours above have tests and the template stub is
  deleted.

---

## Noted, not scheduled

Too small to justify their own PRs. Fold each into whichever task next touches
that file.

- `addSong(title:artist:modelContext:)` inserts a record with the literal
  filename `"filename"` and location `"location"`. It is unreachable from the
  UI — delete it rather than fixing it.
- `ContentView` and `LibraryView` each carry their own `.fileImporter` with
  identical configuration. Worth collapsing into one modifier.
- `Song.deinit` is an empty body with a comment. Remove it.
- `MKPointOfInterestCategory.allCases` lists `.stadium`, `.tennis` and `.park`
  twice, and its own comment calls it inefficient. It is only reachable from the
  unused no-filter branch of `getPointsOfInterest` — likely dead once LR-21
  lands.
