# Third-party audio notices

Audio decoding and pitch processing use these libraries:

| Package | Version | Source | License information |
| --- | --- | --- | --- |
| SFBAudioEngine | 0.14.0 | https://github.com/sbooth/SFBAudioEngine | MIT; bundled `SFBAudioEngine-MIT.txt` |
| FFmpegBuild | 3.6.0 | https://github.com/superuser404notfound/FFmpegBuild | LGPL 2.1 or later and component licenses; bundled `FFmpeg-*` texts |
| Signalsmith Stretch | 1.4.0 (`a670068d9aeb64913331d5cc29337b19a457a7df`) | https://github.com/Signalsmith-Audio/signalsmith-stretch | MIT; bundled `LICENSE-Stretch.txt` |
| Signalsmith Linear | 0.6.4 (`de55e6a50ffcf6f8f43f649692d94691c7025151`) | https://github.com/Signalsmith-Audio/linear | MIT; bundled `LICENSE-Linear.txt` |

License texts from `SimpleMediaPlayer/ThirdPartyNotices` are copied into the app bundle's Resources directory. SFBAudioEngine's transitive packages and their pinned versions are listed in `Package.resolved`; their own license terms also apply. The package's `LICENSES` notices are bundled here. The FFmpegBuild frameworks are dynamic so users can replace them with compatible modified versions; its build scripts and patches are available at the source link above. Verify all transitive license notices and relinking requirements before distributing a release build.

The APE test fixture is `tone_lr_equal.ape` from the synthetic [OxideAV APE test fixtures](https://github.com/OxideAV/oxideav-ape/tree/main/tests/fixtures). WMA and WavPack test fixtures are generated from a one-second sine wave. Musepack is generated from the repository's existing WAV fixture during the test.

Pitch shifting uses the vendored Signalsmith headers in `SimpleMediaPlayer/Vendor/SignalsmithStretch`. Stretch's tag `1.4.0` retains a `1.3.2` version constant in its header; the tag and commit above identify the adopted source. Linear is the version pinned by that tag. Both license texts are copied into the app bundle. Tempo changes use Apple's audio framework.
