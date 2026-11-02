# LittleRoute
A geolocation context-based music app written in Swift for iOS

## Building and testing

The Xcode project is the canonical app build and requires macOS, Xcode, and an
iOS 18.1-or-newer SDK/simulator. Windows Swift cannot build the Apple frameworks
used by this app. `Package.swift` is an auxiliary xtool manifest, not an
equivalent app packaging or testing path.

Create the gitignored `LittleRoute/Music` directory before building a clean
checkout, then select an installed iPhone simulator in the **LittleRoute** scheme.
For command-line testing, use its explicit UDID rather than a device name with
an implicit latest runtime:

```sh
mkdir -p LittleRoute/Music
xcrun simctl list devices available
xcodebuild test -project LittleRoute.xcodeproj -scheme LittleRoute \
  -destination 'platform=iOS Simulator,id=<installed-simulator-UDID>' \
  CODE_SIGNING_ALLOWED=NO
```

The iOS Build and Test workflow selects an available iPhone by UDID and uploads
its test result bundle. Device checks are still required for background
location/audio, permissions, interruptions, and energy use. If the persistent
library cannot be opened, the app leaves it intact and disables import/editing
instead of accepting changes into a temporary store.


## Listening zones

The map uses interlocking, weighted context polygons instead of overlapping POI
circles. A broad park or beach can outweigh a smaller nearby venue; it is not a
nearest-place Voronoi map. Rendering and geographic lookup share the same bounded
10 m sampled score mesh, including holes and disconnected regions. These are
approximate listening areas inferred from MapKit POIs, not property boundaries.
MapKit may omit places. Ground outside the loaded core is unknown, not a confirmed
Traveling zone.

**Stable mode is the default.** Crossing an outline does not immediately change
music. Automatic changes require:

- Fresh, ordered fixes with horizontal accuracy at most 50 m.
- A position more than `max(25 m, reported accuracy)` inside the candidate.
- At least 30 seconds and three consistent fixes, with no evidence gap over 15 seconds.
- At least 90 seconds since the last confirmed music-context change.

Refresh Zones updates nearby data without bypassing these rules. Switch Now is
separate and requires a fresh, reliable candidate. Opt-in Variety allows
time-based rotation but retains confirmation. Weather and high-speed travel can
affect the music without moving geographic polygons; the status distinguishes
the geographic area, music context, and modifier reason.

The disc includes an Expand Map action, a full-screen map with boundary legend,
place details and a textual nearby-place list. Queue access and manual playback
remain available when location is denied. Background adaptation requests its
permission upgrade separately. Low-quality or unavailable evidence keeps the
last confirmed music rather than guessing a new context.

## Playback and library

Context queues contain exact tagged matches. When there are none, songs tagged
All are used with a visible fallback explanation; All is not a universal tag.
A current eligible song keeps its player and playhead. Transport, seek, library
edits and newer context changes cancel obsolete fade work. Transitions use
cancellable fade-out/fade-in, not simultaneous two-player blending.

MP3 imports have progress and per-batch results, serialized updates, staged file
replacement and save-failure compensation. Library deletion requires confirmation.
Search and title/artist sorting do not filter the playback library. Tags without
an automatic detector remain stored and are labeled accordingly.

Artwork requests are track-bound and downsampled off the main actor. Progress
updates live in a separate seek-control view. Decorative motion stops when hidden,
backgrounded or Reduce Motion is enabled; disc/ring motion also stops when paused.
The player preserves its disc aesthetic with wrapping track text at accessibility
sizes and explicit map/queue controls.

## Validation and release limitations

The test targets cover weighted geometry, stable evidence, request cancellation,
queue/fade races using generated valid audio, import/delete recovery, on-disk
migration and view-independent playback coordination. Debug UI fixtures use
synthetic places without live location/weather requests. CI captures the expanded
map in its test result bundle.

Geometry and transition helpers can also compile without Apple frameworks; that
does not validate the iOS app. Simulator builds/tests do not establish device
frame rate, memory, energy, locked-device adaptation, audio interruptions or
permission behavior. Qualify those on a physical iPhone before release. Weather
requires correctly configured WeatherKit entitlements and connectivity; failure
does not prove a provisioning fault.

Custom Home/Work zones, general playlists, streaming and dual-player crossfade
remain deferred.


## Development Resources
### Location
- https://stackoverflow.com/questions/75704998/looking-up-nearest-point-of-interest-using-mapkit
- https://developer.apple.com/documentation/mapkit/interacting-with-nearby-points-of-interest  
  - https://developer.apple.com/documentation/mapkit/mkaddressfilter/options
    - Filter by locality, zip code, neighborhood, etc
  - https://developer.apple.com/documentation/mapkit/mklocalsearch 
