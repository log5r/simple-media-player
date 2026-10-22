# Test fixtures

## `known-stereo.wma`

This fixture is synthetic test audio, not a recording or other third-party source. Its PCM source matches `ExtendedAudioSignalFixture.expectedSample(frame:channel:)` in `ExtendedAudioSignalTestSupport.swift`: 44,137 stereo frames at 44,100 Hz, signed 16-bit little-endian PCM. For frames before `44,137 * 3 / 4`, the channels are rounded 10,000-amplitude sine waves at 440 Hz and 880 Hz; for later frames they use 1,760 Hz and 2,200 Hz. The first frame is `(8192, -4096)` and the last is `(-12288, 10240)`, matching the helper's explicit endpoint values after scaling by 32,768.

The recorded generation command used `/opt/homebrew/bin/ffmpeg`. The version used when the fixture was generated was not recorded; the executable currently available at that path reports FFmpeg 9.0.2 (Homebrew build). To reproduce it, create a temporary WAV with the PCM values above, then run:

```sh
/opt/homebrew/bin/ffmpeg -v error -i source.wav \
  -c:a wmav2 -b:a 128k -map_metadata -1 -y known-stereo.wma
```

The source WAV was generated with Python's `wave` module and `struct.pack('<h', sample)`, using `round(sin(2*pi*frequency*frame/44100) * 10000)` for non-endpoint samples. The output's SHA-256 is:

```text
0329ec0eae75e14afc74774438a1f13406bc698df82421672a7c3b341491387f  known-stereo.wma
```

`known-stereo.mpc` is a checked-in Musepack SV8 encoding of the same synthetic reference. Some concurrent runtime `AudioConverter` encodes produced incorrect PCM, also present when FFmpeg independently decoded those files. Tests therefore copy this fixed, independently verified asset. The app test checks both stereo frequencies, window energy, and the final 512-frame section. Independent FFmpeg decoding emits codec priming/padding frames; the app decoder trims to the 44,137 source frames. This fixture was generated with SFBAudioEngine 0.14.0 from `ExtendedAudioSignalFixture.writeReference`. Its SHA-256 is:

```text
fa5859ae1f15134d28a08b23d9719b69953eb954f380f938e4e69d42677f8675  known-stereo.mpc
```

`known-stereo-wma-reference.wav` is an independent PCM decode of `known-stereo.wma`. It is used as a tail-energy oracle so the WMA test checks the codec's real end-of-stream behavior instead of assuming a synthetic waveform survives lossy encoding unchanged. It was made with FFmpeg 9.0.2 (Homebrew build) using:

```sh
/opt/homebrew/bin/ffmpeg -v error -i known-stereo.wma -map_metadata -1 \
  -c:a pcm_s16le -y known-stereo-wma-reference.wav
```

The original source and encoder provenance for `extended-test.ape` are unknown. `extended-test-ape-reference.wav` is an independent PCM decode of the checked-in APE file, created with FFmpeg 9.0.2 (Homebrew build):

```sh
/opt/homebrew/bin/ffmpeg -v error -i extended-test.ape -map_metadata -1 \
  -c:a pcm_s16le -y extended-test-ape-reference.wav
```

The APE test compares every frame in both channels with this reference, including both endpoints. The APE file contains 13,230 stereo frames at 44,100 Hz. SHA-256 checksums:

```text
964c8b4481d3f1ab3eab6b29126ef4ad88ad9f66920f5e13e7632d812f546a61  extended-test.ape
44f980f96036fe9cc0bac5df75610cbd1490043e648b4f1d91764523444669fb  extended-test-ape-reference.wav
ee2a009146f23fab3e35bb074c17e73f48952489f76cb57cf62c7f3712d0d4b9  known-stereo-wma-reference.wav
```
