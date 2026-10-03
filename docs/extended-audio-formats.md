# Extended audio formats

**English** | [日本語](extended-audio-formats.ja.md)

| Format | File extension | Decoder | Verified sample |
| --- | --- | --- | --- |
| Windows Media Audio | `.wma` | FFmpegBuild 3.6.0 | WMA Standard (WMAv2) |
| WavPack | `.wv` | SFBAudioEngine 0.14.0 | Standard WavPack |
| Monkey's Audio | `.ape` | SFBAudioEngine 0.14.0 | APE |
| Musepack | `.mpc` | SFBAudioEngine 0.14.0 | Musepack SV8 |

The app copies the original file into its managed library. It reads duration, common text tags, lyrics, and a primary attached picture when the decoder exposes them. Playback, seeking, equalizer, rate, pitch, loudness normalization, music analysis, and transformed export use a decoded CAF copy. Exporting the original preserves the encoded file and its embedded tags. Editing embedded tags for these four formats is not supported; changes to the library record do not rewrite the original file.

Import validates the entire encoded stream, including the decoder's final output, and discards the decoded samples. It creates no PCM cache. To enforce the same 4 GiB total-file limit as conversion, it measures a header-only CAF for each distinct output format and reuses that overhead measurement. A corrupt, unsupported, encrypted, or over-limit file fails import without registering a library item. Validation still requires decoding CPU time; it avoids writing PCM for tracks that may never be played.

Playback, loudness normalization, music analysis, and transformed export create the decoded copy when needed, under the app's Caches/CompatibleAudio directory. The cache key includes the managed file path, size, and modification date, so a changed source is decoded again. Each decoded file is limited to 4 GiB. Consumers acquire a readable-file handle and retain it until they finish using the CAF; capacity pruning cannot remove that file during this interval. Least recently used unused files are removed when the cache exceeds 8 GiB. Active readers can temporarily keep the cache above that budget, and releasing a handle schedules capacity pruning in the background.

Concurrent requests for the same source share one conversion; conversion runs outside the cache lock, so another track's cached copy can be read while it runs. Cache checks, publication, and pruning are serialized. Pruning also removes abandoned temporary CAF files from interrupted app runs. Temporary files still being written are tracked separately from requests and preserved, even if their request has already been invalidated.

Validation and conversion can be cancelled, and incomplete cache files are removed. A completed conversion is published only while its request and source identity remain valid. Deleting a library item invalidates its pending conversion before removing the original and removes its current decoded copy, including one retained by a reader. Callers cancel or reject obsolete work when an item is deleted. Background deletion checks the removal request's generation so it cannot remove a newer conversion for the same destination. The original is never replaced by the cache.

WMA support covers the standard sample above. Other WMA profiles may depend on the bundled FFmpeg decoders and have not been verified. DRM-protected WMA is unsupported. WavPack hybrid correction sidecar files (`.wvc`) are not imported alongside `.wv`; the `.wv` file is played on its own. Extended-format metadata varies by file and tag version.

The project builds with Xcode 27 for macOS and iOS/iPadOS. Decoder/cache regression tests and cached-track playback during a 256-file import passed on macOS 27 and the iPhone 18 Pro and iPad Pro 11-inch (M5) simulators running iOS 27. The playback test checks audio-engine output and advancing playback time while import remains active. Physical iPhone/iPad playback continuity and battery use have not been verified here. The bundled dynamic frameworks add about 29 MB to the macOS Debug app's Frameworks directory; release and iOS sizes vary. See [third-party notices](third-party-audio-notices.md) for licenses and source locations.

The repeatable [cache benchmark](../scripts/benchmark-extended-audio-cache.sh) compares the old import conversion with current validation using all four format fixtures and a reduced 512 KiB cache budget. It reports elapsed time, CPU time, logical CAF bytes written, process disk-write counters, and first-track playback preparation after the batch exceeds that budget. Fixture preparation, managed-file copying, import metadata merging, and database registration are excluded; these figures do not measure the full app import or physical-device battery use.
