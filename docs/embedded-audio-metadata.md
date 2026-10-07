# Embedded audio metadata support

**English** | [日本語](embedded-audio-metadata.ja.md)

This document describes the scope of Issue #3. The implementation requires no external libraries or commands installed on the user's system. It checks the file extension and the container signature at the start of the file. For Ogg, it also checks the identification packet to distinguish Vorbis from Opus. Edits are written to a temporary file in the source directory; the source is replaced only after writing completes. Cancellation or a write error leaves the source file intact.

| Format | Reading and writing | Artwork | Lyrics | Export after conversion |
| --- | --- | --- | --- | --- |
| FLAC (`.flac`) | Vorbis Comment; preserves unknown comments and metadata blocks | FLAC PICTURE blocks; also reads existing artwork stored in comments | Reads `LYRICS` and `UNSYNCEDLYRICS`; writes `LYRICS` | Supported |
| Ogg Vorbis (`.ogg`, `.oga`) | Vorbis Comment; preserves unknown comments | Base64-encoded `METADATA_BLOCK_PICTURE`; also reads existing `COVERART` | Same as FLAC | Not supported |
| Ogg Opus (`.opus`, `.ogg`, `.oga`) | OpusTags; preserves unknown comments | Same as Ogg Vorbis | Same as FLAC | Not supported |
| WAV (`.wav`) | RIFF INFO and ID3v2 chunks; prefers ID3v2 when reading both and updates both when saving | ID3v2 `APIC` | ID3v2 `USLT` | Supported |

The editable fields shared across formats are title, artist, album, genre, year, track number, comment, album artist, composer, disc number, compilation, artwork, and lyrics. Saving lyrics only in the app and embedding them in the file remain separate actions. Empty strings and removal of artwork or lyrics delete the corresponding tags from the file. In WAV files, RIFF INFO stores the basic text fields, while ID3v2 stores all fields. Unknown RIFF chunks and audio data are copied unchanged.

Lyrics edits are recorded in the library, including an empty value, and survive reopening the app. Automatic embedded-lyrics loading applies only to unedited tracks. After a text metadata edit, editors and bulk edits prioritize the stored editable text fields, including empty values, over embedded fallback values. Lyrics-only edits do not mark text metadata as edited. ID3 lyrics edits remove both unsynchronized (`USLT`/`ULT`) and synchronized (`SYLT`/`SLT`) frames. MP4 text edits remove the corresponding sort fields (`sonm`, `soar`, `soal`, `soaa`, `soco`); lyrics-only and artwork-only edits preserve them. Existing libraries migrate with the edit markers unset because earlier deletions cannot be distinguished from missing metadata.

Ogg editing supports a single logical stream. It rebuilds the header pages containing comments and updates their CRCs and page sequence numbers while preserving the audio payload and granule positions of subsequent pages. Chained streams, multiplexed streams, and Ogg FLAC are outside the editing scope. WAV support covers standard RIFF/WAVE, but not RF64 or RIFX. FLAC artwork is saved in standard PICTURE blocks. Ogg Vorbis and Opus artwork is saved as `METADATA_BLOCK_PICTURE` in Vorbis comments. Images other than the front cover and unknown trailing comment data are preserved.

On macOS, MP4-family audio imports can recover display metadata from Music when Music is already running. The app reads one library snapshot per import operation and matches each source by file location, then by sort title, artist, album, and duration. Music values keep their existing import priority over MP4/AVFoundation values. An unavailable library or denied automation access falls back to embedded metadata. Importing does not launch Music. Metadata editors and bulk edits read the managed file and library item without querying Music, so Music cannot restore an old value after an edit or deletion. iPhone and iPad use embedded metadata without this Music lookup.

Verification used 0.35 seconds of synthetic audio. Automated tests on macOS 27.0 covered saving, deleting, and reimporting tags, artwork, and lyrics in all four formats; matching PCM audio; preservation of unknown chunks; preservation of the source when processing a damaged file; cancellation; artwork spanning multiple Ogg pages; and export after conversion to FLAC or WAV. Existing unit tests, including those for MP3, M4A, and AIFF, also passed.

On an iOS/iPadOS 27 simulator, reimporting and editing tags passed for FLAC, Ogg Opus, and WAV. Writing and deleting Ogg Vorbis tags passed, but iOS 27's `AVAudioFile` could not open the test `.ogg` file, so Ogg Vorbis cannot be imported or played through the current path. Adding a decoder is outside the scope of Issue #3. The iOS app build passed. The minimum supported macOS version, 26.5, and physical iPhone and iPad devices have not been tested.

Specifications: [FLAC format](https://xiph.org/flac/format.html), [Vorbis Comment](https://www.xiph.org/vorbis/doc/v-comment.html), [Ogg framing](https://xiph.org/ogg/doc/framing.html), [Opus in Ogg](https://www.rfc-editor.org/rfc/rfc7845).
