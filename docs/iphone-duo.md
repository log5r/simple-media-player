# iPhone Duo Layout and Verification

**English** | [日本語](iphone-duo.ja.md)

Build with the iOS SDK in Xcode 27.1 or later. iOS 27.1 reserved-region and ArrangementView APIs are isolated to iOS and guarded for availability; iOS 27.0 falls back to ordinary layouts. Native macOS controls and deck dimensions are preserved.

## Choosing the Layout

The app uses the scene's horizontal size class, rather than device names, `UIDevice` idiom, or physical pixels. Compact scenes use the iPhone tabs and deck; regular scenes use NavigationSplitView and the bottom panel. Only an unspecified size class falls back to the current View's width, with a 600pt boundary.

The expanded iOS sidebar is 180–240pt, ideally 200pt. The list-and-details region shows a 240pt details panel when it has at least 620pt of width and 300pt of height. In smaller regions or at accessibility text sizes, the Details button opens a sheet. EQ also opens a sheet when the list region is less than 430pt tall. These are content constraints, not Duo screen resolutions.

## Playback and Partial Folding

Expanded iOS playback, volume, and adjustment controls have touch targets of at least 44pt. LED and control widths follow their content requirements. Narrow regions change rows and can scroll the controls. On iOS 27.1, each component avoids active division and occlusion regions, including their margins, in local coordinates.

The deck's Display page places ArrangementView inside NavigationStack and outside each pane's ScrollView, separating LED/video from controls. It avoids controls across an active hinge and retains the existing vertical scrolling layout for ordinary compact scenes. Hinge angles do not determine the layout. View toggles, settings, and filters prefer the standard vertical toolbar placement on iOS 27.1.

## State and Ownership

LibraryBrowsingState lives above the layout branch. It shares category, group and playlist routes, search, filters, sorting, selection, bulk editing, and scroll anchors. iOS settings, information and lyrics editors, bulk editing, artwork previews, and export naming also have stable presenters. Deck pages and sheets, and full-screen video, are owned by their stable parent views.

Layout changes neither recreate PlayerViewModel nor stop or reload playback. Seeking records the item ID and playback generation at gesture start. Stop, switching, reloading the same item, engine reset, and failure invalidate an earlier completion. Pause, resume, and layout changes preserve the generation.

SharedExportSession owns files prepared for sharing. Destroying the activity controller does not delete them. Completion, cancellation, or releasing the session does. If the system ends the presentation, choosing Export again shares the retained output. Presentation IDs reject completion callbacks from an obsolete controller.

## Verification

Set `DEVELOPER_DIR` per command without changing the global Xcode selection.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer \
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -derivedDataPath .build/DuoDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

- Unit suites: LibraryLayoutPolicyTests, LibraryBrowsingStateTests, AdaptiveBottomPanelTests, PlayerPlaybackGenerationTests, SharedExportSessionTests, and iOS IPhoneShareSheetTests. They verify boundary sizes, reserved regions, deletion, playback reloads, and activity-controller recreation.
- Select Open in Device Hub and run DuoLayoutUITests and DuoBrowsingUITests for rotation, playback, settings, groups, playlists, and lyrics/export-name drafts. Xcode 27.1 Beta may report an XCTest orientation change without rotating the actual display. In that case, set `TEST_RUNNER_DUO_INTERACTIVE_ORIENTATION_TESTS=1` and rotate in Device Hub when `DuoOrientationStep` appears in the log. The tests wait for the actual scene dimensions to change; the orientation notification alone does not pass the check.
- Run DuoFoldTransitionUITests with `TEST_RUNNER_DUO_INTERACTIVE_POSE_TESTS=1` in the xcodebuild environment. Follow `DuoPostureStep` logs to select Closed → Book → Open in Device Hub. XCTest exposes no public fold-posture operation, so this test needs an operator.
- The DEBUG `--ui-testing-duo-layout` diagnostics record View dimensions, size classes, safe areas, reserved regions, and playback state. `--ui-testing-compact-layout` is a forced layout for existing iPhone suites; it does not verify real Duo folding.
- If the UI runner cannot deliver input, launch the DEBUG app with `--ui-testing-phone-layout --ui-testing-duo-layout --ui-testing-duo-autoplay-probe --ui-testing-audible-layout --ui-testing-duo-long-playback`. It plays the first fixture track once and prints `DuoPlaybackMetrics` to stdout every second. Change the actual posture in Device Hub and check item, queue, generation, advancing time, and both RMS values. This verifies playback across real folds separately from starting playback or editing through the UI.
- Build macOS, iPad, and an iPhone running iOS 27.0, then run the relevant operation tests. Run `scripts/lint.sh` and `git diff --check`.

Results, measured geometry, and unverified conditions are recorded in the [GitHub Wiki implementation record](https://github.com/log5r/simple-media-player/wiki/iPhone-Duo-Implementation-Plan).

## Apple References

The implementation follows [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Adapt custom layouts](https://developer.apple.com/videos/play/tech-talks/111463/), [Adapt tab bars and toolbars](https://developer.apple.com/videos/play/tech-talks/111462/), and [Displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/).
