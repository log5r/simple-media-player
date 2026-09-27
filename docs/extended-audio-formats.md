# Extended audio formats

**English** | [日本語](extended-audio-formats.ja.md)

| Format | File extension | Decoder | Verified sample |
| --- | --- | --- | --- |
| Windows Media Audio | `.wma` | FFmpegBuild 3.6.0 | WMA Standard (WMAv2) |
| WavPack | `.wv` | SFBAudioEngine 0.14.0 | Standard WavPack |
| Monkey's Audio | `.ape` | SFBAudioEngine 0.14.0 | APE |
| Musepack | `.mpc` | SFBAudioEngine 0.14.0 | Musepack SV8 |

The app copies the original file into its managed library. It reads duration, common text tags, lyrics, and a primary attached picture when the decoder exposes them. Playback, seeking, equalizer, rate, pitch, loudness normalization, music analysis, and transformed export use a decoded CAF copy. Exporting the original preserves the encoded file and its embedded tags. Editing embedded tags for these four formats is not supported; changes to the library record do not rewrite the original file.

The decoded copy is stored under the app's Caches/CompatibleAudio directory. The cache key includes the managed file path, size, and modification date, so a changed source is decoded again. Each decoded file is limited to 4 GiB, and least recently used files are removed when the cache exceeds 8 GiB. Import validates the file by decoding it; a corrupt, unsupported, encrypted, or over-limit file fails import without registering a library item. Decoding can be cancelled, and incomplete cache files are removed. Deleting a library item removes its current decoded copy. The original is never replaced by the cache.

WMA support covers the standard sample above. Other WMA profiles may depend on the bundled FFmpeg decoders and have not been verified. DRM-protected WMA is unsupported. WavPack hybrid correction sidecar files (`.wvc`) are not imported alongside `.wv`; the `.wv` file is played on its own. Extended-format metadata varies by file and tag version.

The project builds with Xcode 27 for macOS and iOS/iPadOS. The four decoder tests ran on macOS 27. The app also builds for a generic iOS Simulator target, but decoding on a physical iPhone or iPad has not been verified here. The bundled dynamic frameworks add about 29 MB to the macOS Debug app's Frameworks directory; release and iOS sizes vary. See [third-party notices](third-party-audio-notices.md) for licenses and source locations.
