# iPhone Layout Design (Option B: LED Dock)

**English** | [日本語](iphone-layout.ja.md)

This document defines the screen layout used on iPhone.
It covers the portrait, compact-width layout on iPhone.
[iPhone Duo](iphone-duo.md) uses this layout on its compact outer display and a shared desktop-style layout on its regular-width inner display.
The macOS layout stays as it is; iPad uses the shared expanded layout with touch controls.
Mockups are on the [design canvas](https://claude.ai/artifact/TVYKLHj5PkKKAhv8iCYpNL) (viewing it requires sharing access).

## Current Problems

The iOS build shows the macOS layout scaled down.
Launching it on iPhone 17 Pro (iOS 27 Simulator) shows the following problems.

- Info.plist does not specify a launch screen (`UILaunchScreen`), so the whole app runs in the 3:2 compatibility mode of the iPhone 4, with black bars above and below.
- The bottom panel has a fixed height of 170 pt and gives half its width each to the LED display and the controls. The transport buttons need about 213 pt and run past the right edge of the screen.
- The transport buttons are 34 pt tall and the volume step buttons are 24 pt wide, below the recommended 44 pt touch target.
- The lyrics and details panel sits beside the list with a minimum width of 280 pt, which crushes the list when it is shown. The toolbar also shows every button that macOS shows.

Adding `INFOPLIST_KEY_UILaunchScreen_Generation = YES` to the build settings fixes the launch screen problem.
That fix is independent of the layout design, so it lands before the layout changes.

## Why Option B

Three options were considered.
Option A (standard iOS) follows the usual artwork-centered music app layout. It is the easiest to build, but the LED display shrinks to a few labels.
Option C (portable device) treats the playback screen as a device with hardware-style keys and puts the library in a sheet that slides up from the bottom.
Option B leaves library browsing to standard iOS navigation and gathers the LED display into the now-playing views.

Option B was chosen because it keeps the app's distinctive LED display, indicator lamps, and ribbed volume display while handling a large library, multiple editing, and playlist management with standard controls.
The existing LED display view also takes its height and corner shape as parameters, so it can be reused at new sizes.

## Screen Structure

### Navigation

The top level is a `TabView` with Library, Playlists, and Videos tabs plus a search tab.
The Library tab is a `NavigationStack` that goes from a list of categories (All Songs, Albums, Artists, Genres) to each list.
The current sidebar (`NavigationSplitView`) is not used on iPhone.

### Now-playing Dock (Mockup B-1)

While there is a current item, a dock appears above the tab bar using `tabViewBottomAccessory`, available in iOS 26 and later.
The accessory supplies the system's Liquid Glass background.
The dock shows the title and elapsed time in standard fonts that support Dynamic Type; long titles truncate to fit.
When the text size prevents both rows from fitting, the dock omits the visible elapsed time and retains the complete title and playback time in its accessibility value.
Tapping the title and time opens the deck, while separate Play/Pause and Next Track buttons use standard SF Symbols.
Each button has a hit region of at least 44 × 44 pt, with at least 8 pt between controls.
The dock has no custom panel background or circular button decoration; the detailed LED display and visualizer remain on the deck's Display page.

The flexible text and familiar playback controls follow Apple's [Layout](https://developer.apple.com/design/human-interface-guidelines/layout) and [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) guidance on adaptable layouts, recognizable actions, and sufficient touch targets.
Apple's [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) guidance shows a now-playing accessory above the tab bar, supporting this placement.
Following [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), the dock relies on the system accessory background and avoids adding custom backgrounds that can interfere with it.

### Deck (Mockup B-2)

The deck is a full-screen cover (`fullScreenCover`) that shows, from top to bottom:

1. A close button, the name of the playing list, and a More menu
2. The LED display (full width, about 300 pt tall): track number, file format, title, artist and album, elapsed time, KEY, BPM, song structure with the playback position, and the spectrum
3. A seek bar with elapsed and remaining time
4. The EQ, KEY, and SPEED indicator lamps. They are display-only on macOS; on iPhone they become buttons that open the adjustment sheet
5. Transport controls: Stop (small), Previous Track, Play/Pause (large), Next Track, and output device
6. Volume: the ribbed volume display turned into a horizontal slider
7. Page switcher: Display, Lyrics, Info, and Up Next

The More menu holds Save adjusted copy, Create AAC Version, and Edit Information….

### Lyrics Page (Mockup B-3)

On the Lyrics page, the LED display shrinks to a strip about 90 pt tall, and the lyrics fill the space it frees.
The strip retains the title, elapsed time, and key-change indicator and omits the visualizer, whose normal layout does not fit the compact area.
Time-tagged lyrics highlight the current line and scroll it to the center.
Compact transport controls stay at the bottom, and Edit Lyrics at the top right opens the existing editor.
The Info page uses the same arrangement and reuses the existing information view (enlarged artwork, Edit Information).

### Adjustment Sheet

The indicator lamps open a sheet with detents.
It holds step buttons and the current value for key and speed, and the EQ on/off switch, presets, 10 band sliders, and reverb.
It combines the contents of the macOS key and speed popovers and the EQ panel.

### Video Playback

During video playback, the deck replaces the LED display area with the video and adds a full-screen button.
Key and speed cannot be changed for video, so those lamps appear disabled.

## Where Each Feature Lives

The following table shows where each existing feature is operated on iPhone.

| Feature | Location on iPhone |
|---|---|
| Import | Library More menu, Import... |
| Export to Finder | More menu. It currently does nothing on iOS and needs to be replaced with a save dialog or the share sheet |
| Search and filters | Search tab. Filters are in the search screen's navigation bar |
| Sorting | Menu in the list's navigation bar |
| Multiple editing | Select in the list's More menu enters edit mode, and Edit Selected in the bottom toolbar opens the editor |
| Get Info, Create AAC Version, Add to Playlist, New Playlist, Delete from Library | Long-press menu on a track. Delete is also available by swiping |
| Reordering and removing playlist tracks | Dragging and deleting in edit mode. Move Up and Move Down stay in the long-press menu |
| Creating, renaming, and deleting playlists | Playlists tab |
| Adding tracks to a playlist | Add button in the playlist detail's navigation bar |
| Play, Pause, Previous Track, Next Track | Play/Pause and Next Track in the dock; all four in the deck |
| Stop, seek, volume | Deck |
| Key, speed, EQ, Save adjusted copy | Adjustment sheet opened from the deck's lamps. Save is also in the deck's More menu |
| Music analysis (KEY, BPM, song structure) | LED display in the deck |
| Visualizer | Deck Display page; omitted from the dock and compact LED strip |
| VU meters | Not shown in portrait |
| Viewing and editing lyrics | Lyrics page of the deck |
| Details, Edit Information, enlarged artwork | Info page of the deck |
| Settings | Sheet opened from the Library More menu |

The LED placement settings (Panel Layout, LED Position, LED Corners) and the list column settings do not apply to the iPhone layout and are hidden there.
The import and export progress panels move to a position that does not overlap the dock.

## Reusing and Changing Existing Views

The LED display (`LEDDisplayView`), the music analysis strip, the visualizer, the seven-segment time display, the scrolling text, and the bottom panel palette can be reused as they are.
The following views need changes or iPhone-specific replacements.

- The indicator lamps (`IndicatorColumnView`) are display-only, so a version laid out as tappable buttons is needed.
- The volume display (`VolumeSlotView`) is a private, vertical-only type, so it needs to be extracted into a form that can also draw horizontally.
- The transport buttons (`TransportButtonsView`) are a 34 pt segmented strip, so the deck needs a new layout with larger buttons.
- The lyrics and info panel (`LyricsPanelView`) switches between two contents, so each needs to be shown on its own as a deck page.

## Light Mode

The bottom panel palette already has light (silver) and dark (gunmetal) variants, and the deck's frames and buttons follow it.
The dock uses the system accessory's Liquid Glass background and standard foreground colors, which adapt to the appearance and accessibility settings.
The LED display colors are independent of the appearance mode and follow the Display Style setting.
With the default Dark style, the display stays white on black even in light mode; with Backlit, it shows black on a yellow-green backlight.
The library screens use the standard iOS light and dark colors.

## Open Questions

- Landscape: whether to adopt Option C's C-3 (a full deck with the LED display and VU meters side by side) as the deck's landscape layout.
- Output device button: a button for choosing AirPlay and other outputs (`AVRoutePickerView`) does not exist in the app today; whether to add it.
- Export: how to export on iOS (save dialog or share sheet), and whether to handle it in this issue or a separate one.
- Up Next page: whether it only shows the playing list (the filtered list) or also allows reordering.

## Completion Criteria and Verification

| Criterion | Verification |
|---|---|
| The compatibility mode is gone | Take a screenshot in the iPhone Simulator and confirm there are no black bars and the app fills the screen |
| Controls fit on screen | Confirm nothing overflows or is cut off on the narrowest iPhone (iPhone 17e class) and the widest (Pro Max) |
| Touch targets are at least 44 pt | Check the sizes of the dock, deck, and adjustment sheet buttons with Accessibility Inspector |
| Long titles and large text do not overlap in the dock | Run UI tests at normal, `.xxxLarge`, and `.accessibility5` sizes, then inspect saved screenshots for clipped text and background gaps |
| Every operation in the feature table is reachable | Operate each row of the table on iPhone |
| Layout holds in light and dark with both LED display styles | Check all four combinations of the two appearance modes and the two LED display styles |
| iPad and macOS layouts are unchanged | Build both and run UI tests limited to the main screen operations |
| VoiceOver and UI text match in English and Japanese | Check added strings in `Localizable.xcstrings` and listen to VoiceOver in both languages |
