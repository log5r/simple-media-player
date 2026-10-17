# Signalsmith Stretch

The pitch-only Audio Unit uses unmodified headers from these official sources:

- [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch), tag `1.4.0`, commit `a670068d9aeb64913331d5cc29337b19a457a7df`.
- [Signalsmith Linear](https://github.com/Signalsmith-Audio/linear), tag `0.6.4`, commit `de55e6a50ffcf6f8f43f649692d94691c7025151` (the dependency pinned by Stretch's CMake configuration).

Both libraries use the MIT license. Their notices are retained in `LICENSE-Stretch.txt` and `LICENSE-Linear.txt`. The vendored Linear subset contains the STFT, FFT, and Accelerate implementation needed by Stretch. Unused platforms and command-line utilities are omitted.

Stretch's `version` constant still reports `1.3.2` in the `1.4.0` tag; use the tag and commit above to identify this source. The adapter enables `SIGNALSMITH_USE_ACCELERATE`, uses the default preset without split computation, and processes equal input/output frame counts. It keeps the same delay at zero pitch. Compile `PitchShiftAudioUnit.mm` with optimization even in Debug configurations, as recommended by upstream.
