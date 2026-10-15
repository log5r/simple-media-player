# iPhone Duo Layout and Verification

**English** | [日本語](iphone-duo.ja.md)

Build with the iOS SDK in Xcode 27.1 or later. iOS 27.1 reserved-region and ArrangementView APIs are isolated to iOS and guarded for availability; iOS 27.0 falls back to ordinary layouts. Native macOS controls and deck dimensions are preserved.

## Choosing the Layout

The app uses the scene's horizontal size class, rather than device names, `UIDevice` idiom, or physical pixels. Compact scenes use the iPhone tabs and deck; regular scenes use the expanded library layout. Only an unspecified size class falls back to the current View's width, with a 600pt boundary.

An expanded Duo also reports a display division through `reservedRegions(kind: .division, options: [.includeInactive])`. The app checks this capability at the root and passes it through `usesDividedDisplay`, so the Duo layout remains available in Open posture while its hinge region is inactive. Landscape uses NavigationSplitView and the bottom panel; portrait uses the player described below. iPad keeps the expanded library layout, and macOS keeps its native controls and deck dimensions.

The expanded iOS sidebar is 180–240pt, ideally 200pt. The list-and-details region shows a 240pt details panel when it has at least 620pt of width and 300pt of height. In smaller regions or at accessibility text sizes, the Details button opens a sheet. EQ also opens a sheet when the list region is less than 430pt tall. These are content constraints, not Duo screen resolutions.

## Playback and Partial Folding

In Duo landscape, the LED region occupies the right half of the playback panel and compact controls occupy the left half. Volume uses a 44pt-tall horizontal row, extending the bar across the remaining width beside Mute/Unmute and Output Device. Playback, volume, and adjustment buttons retain touch targets of at least 44pt; smaller regions change rows and can scroll the controls. Expanded Mute/Unmute and Output Device (AirPlay) controls use the same rectangular background, border, and shadow as the playback buttons.

In Duo portrait, the upper half of the player is divided into two full-width rows: LED above, meters and lamps below. The lower half contains seeking, playback, volume, adjustment, and navigation controls. Library opens the library in the same view; Close returns to the player. In partially folded portrait, the library appears below the active horizontal division as a sheet with rounded top corners, leaving the LED and meters on the upper half visible. When the keyboard or another inset leaves less than 280pt below the division, the library fills the view as before. Both placements use the same view, so search and browsing state are preserved. In the same posture, the player's Settings, Equalizer, and Details sheets open at the `.medium` height and expand to `.large` when pulled up. This arrangement applies in Open and Book postures. The expanded Duo layout takes precedence over stored Classic and left-side LED preferences; iPad and macOS continue to use those preferences. Because the portrait LED does not touch a window corner, the Adaptive LED Corners setting uses the same small fixed radius on all four LED corners in both Open and Book postures; Rounded is unchanged.

In portrait, the player splits at the center of its current view in both Open and Book postures, without adding a gap for the fold division. Its seek bar can also span the division. Components still avoid active occlusions such as the camera in local coordinates. The landscape player and standard library containers continue to adapt to the fold.

Opening Now Playing while Closed and then unfolding adapts the deck's Display page to the same portrait or landscape design. Its full-screen presenter, page selection, and editing sheets keep their existing ownership. Ordinary compact scenes retain the vertical scrolling deck. The ArrangementView used by the other deck layout sits inside NavigationStack and outside each pane's ScrollView. View toggles, settings, and filters prefer the standard vertical toolbar placement on iOS 27.1.

Full-screen video in partially folded portrait fits within the area above the active horizontal display division, including its margins. Unfolding or rotating to landscape restores the full display area. The same AVPlayer stays attached during these layout changes; playback, pause, and close keep their existing behavior. Open Duo, ordinary iPhone, iPad, and macOS retain centered full-screen video.

## Toolbars and Keyboard Commands

On the Closed outer screen, iOS 27.1 places navigation bars and the tab bar vertically along the trailing edge. Toolbar items stay standard `ToolbarItem`s so they can lay out vertically. They are not combined in an `HStack`, and buttons have no fixed frames or icon-only label styles. Secondary commands of the library root, track lists, and the deck use `ToolbarOverflowMenu`, so the system overflow button is the only ellipsis. Filters, Add Tracks, Done, Close, and Edit Lyrics have `visibilityPriority(.high)` and stay outside the overflow when space runs out; other items keep the default order. Done is text-only and may remain horizontal. Sheets whose only toolbar item is Close (Settings, Playback Adjustments, and Equalizer) keep a horizontal bar with `toolbarVerticalBehavior(.disabled)` on iOS 27.1, so a single button does not occupy a column of the narrow screen.

Keyboard playback commands depend on the providers in the focused scene, not on the device idiom. Compact and expanded layouts provide `AppMenuActions`. When the iOS player scene has no layout-specific provider, as in the Duo portrait player, Space and Command-Left/Right Arrow control the player directly. On macOS these commands stay disabled without a provider.

## State and Ownership

LibraryBrowsingState lives above the layout branch. It shares category, group and playlist routes, search, filters, sorting, selection, bulk editing, and scroll anchors, including when switching between the portrait player and library. iOS settings, information and lyrics editors, bulk editing, artwork previews, and export naming also have stable presenters. Deck pages and sheets, and full-screen video, are owned by their stable parent views.

LibraryListUpdates is attached once to the parent above the portrait/landscape branches. With an updater on each branch, the outgoing branch's `onDisappear` can cancel the shared projection after the incoming branch has updated it, clearing its inputs and visible items. The common parent keeps the updater alive during rotation.

Layout changes neither recreate PlayerViewModel nor stop or reload playback. Seeking records the item ID and playback generation at gesture start. Stop, switching, reloading the same item, engine reset, and failure invalidate an earlier completion. Pause, resume, and layout changes preserve the generation.

SharedExportSession owns files prepared for sharing. Destroying the activity controller does not delete them. Completion, cancellation, or releasing the session does. If the system ends the presentation, choosing Export again shares the retained output. Presentation IDs reject completion callbacks from an obsolete controller.

## Verification

Set `DEVELOPER_DIR` per command without changing the global Xcode selection.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.0-Release.Candidate.app/Contents/Developer \
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -derivedDataPath .build/DuoDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

- Unit suites: LibraryLayoutPolicyTests, DuoPortraitPlayerLayoutTests, LibraryBrowsingStateTests, AdaptiveBottomPanelTests, PlayerPlaybackGenerationTests, SharedExportSessionTests, and iOS IPhoneShareSheetTests. They verify boundary sizes, the portrait visual rows, reserved regions, deletion, playback reloads, and activity-controller recreation.
- Run each DuoPlayerDesignUITests case after selecting its actual posture and orientation in Device Hub. `testLandscapeLEDConsumesRightHalf` requires Open landscape; `testPortraitVisualsStayAboveControlsAndLibraryReturns` accepts Open or Book portrait. They check the LED and control allocation, 44pt targets, and playback while opening and closing Library and Settings. Panel allocation comes from GeometryReader diagnostics. The portrait check maps root dimensions and safe areas into screen coordinates and verifies that the visual and control regions meet at the center even in Book posture. Cases skip mismatched orientations or coordinate bounds and active occlusions. `testPartiallyFoldedPortraitDoesNotReserveACenterGap` requires partially folded portrait and checks the center allocation and seek-bar reachability. `testPartiallyFoldedPortraitLibraryAndSettingsStayBelowTheFold` also requires partially folded portrait. It checks that the library spans from the bottom of the division to the bottom of the view with the LED above it, and that the Settings sheet's Close button sits below the division. They never set `XCUIDevice.orientation`, because a synthetic orientation notification can leave the Duo's actual display unchanged. Launching with Classic and left-side LED preferences verifies that the expanded Duo design takes precedence.
- Run `DuoPlayerDesignUITests/testLibrarySurvivesRealRotationFromPortrait` from Open or Book portrait with `TEST_RUNNER_DUO_INTERACTIVE_ORIENTATION_TESTS=1` in the xcodebuild environment. Follow the `DuoOrientationStep` logs and rotate the actual display in Device Hub from portrait to landscape and back. The case checks that the library shows the fixture track in landscape and after reopening Library in portrait, while playback keeps the same item, queue, and generation. It skips unless interactive rotation is enabled.
- Select Open in Device Hub and run DuoLayoutUITests and DuoBrowsingUITests for rotation, playback, settings, groups, playlists, and lyrics/export-name drafts. Xcode 27.1 Beta may report an XCTest orientation change without rotating the actual display. In that case, set `TEST_RUNNER_DUO_INTERACTIVE_ORIENTATION_TESTS=1` and rotate in Device Hub when `DuoOrientationStep` appears in the log. The tests wait for the actual scene dimensions to change; the orientation notification alone does not pass the check.
- Run DuoFoldTransitionUITests with `TEST_RUNNER_DUO_INTERACTIVE_POSE_TESTS=1` in the xcodebuild environment. Follow `DuoPostureStep` logs to select Closed → Book → Open in Device Hub. XCTest exposes no public fold-posture operation, so this test needs an operator.
- The DEBUG `--ui-testing-duo-layout` diagnostics record View dimensions, size classes, safe areas, reserved regions, and playback state. Each panel's `<regionID>Metrics` returns its assigned region's global `x/y/width/height`. Accessibility group bounds can include child content outside that allocation, so they are not used to measure panel allocation. `--ui-testing-compact-layout` is a forced layout for existing iPhone suites; it does not verify real Duo folding.
- If the UI runner cannot deliver input, launch the DEBUG app with `--ui-testing-phone-layout --ui-testing-duo-layout --ui-testing-duo-autoplay-probe --ui-testing-audible-layout --ui-testing-duo-long-playback`. It plays the first fixture track once and prints `DuoPlaybackMetrics` to stdout every second. Change the actual posture in Device Hub and check item, queue, generation, advancing time, and both RMS values. This verifies playback across real folds separately from starting playback or editing through the UI.
- Build macOS, iPad, and an iPhone running iOS 27.0, then run the relevant operation tests. Run `scripts/lint.sh` and `git diff --check`.

Results, measured geometry, and unverified conditions are recorded in the [GitHub Wiki implementation record](https://github.com/log5r/simple-media-player/wiki/iPhone-Duo-Implementation-Plan).

FullScreenVideoLayoutTests verifies the upper video area, division margins and local coordinates, unfolding, landscape, and non-splitting regions. Run DuoFullScreenVideoUITests in partially folded portrait to check the video frame against the actual division and test pause/resume, double-tap to close, and the Close button with a generated video. The case skips if the posture or screen coordinates do not match. Manually unfold and rotate during full-screen playback to check the transition. With `--ui-testing-duo-layout`, `fullScreenVideoMetrics` reports the assigned video frame for comparison with the active division.

## Apple References

The implementation follows [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Prepare your app for iPhone Duo](https://developer.apple.com/iphone-duo/prepare/), [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), and the Tech Talks [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/), [Adapt tab bars and toolbars](https://developer.apple.com/videos/play/tech-talks/111462/), [Adapt custom layouts](https://developer.apple.com/videos/play/tech-talks/111463/), and [Displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/). App Store screenshot requirements are recorded in the [TestFlight distribution preparation](https://github.com/log5r/simple-media-player/wiki/TestFlight-Distribution-Preparation) page of the Wiki.
