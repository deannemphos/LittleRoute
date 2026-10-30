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


## Current Features
- [x] Music playback
- [x] Live map
- [x] User uploaded music 

## Planned for 1.0 release
- [ ] Custom locations
- [x] Song playback varying by location
- [ ] Playlists

## Planned for future release
- [ ] Streaming service integration
- [ ] Custom geotags
- [ ] Custom themes
- [ ] Crossfade and song blending (rudimentary implementation rn)


## Development Resources
### Location
- https://stackoverflow.com/questions/75704998/looking-up-nearest-point-of-interest-using-mapkit
- https://developer.apple.com/documentation/mapkit/interacting-with-nearby-points-of-interest  
  - https://developer.apple.com/documentation/mapkit/mkaddressfilter/options
    - Filter by locality, zip code, neighborhood, etc
  - https://developer.apple.com/documentation/mapkit/mklocalsearch 
