# Third-party audio notices

The WMA, WavPack, Monkey's Audio, and Musepack support uses these packages:

| Package | Version | Source | License information |
| --- | --- | --- | --- |
| SFBAudioEngine | 0.14.0 | https://github.com/sbooth/SFBAudioEngine | MIT; bundled `SFBAudioEngine-MIT.txt` |
| FFmpegBuild | 3.6.0 | https://github.com/superuser404notfound/FFmpegBuild | LGPL 2.1 or later and component licenses; bundled `FFmpeg-*` texts |

License texts from `SimpleMediaPlayer/ThirdPartyNotices` are copied into the app bundle's Resources directory. SFBAudioEngine's transitive packages and their pinned versions are listed in `Package.resolved`; their own license terms also apply. The package's `LICENSES` notices are bundled here. The FFmpegBuild frameworks are dynamic so users can replace them with compatible modified versions; its build scripts and patches are available at the source link above. Verify all transitive license notices and relinking requirements before distributing a release build.

The APE test fixture is `tone_lr_equal.ape` from the synthetic [OxideAV APE test fixtures](https://github.com/OxideAV/oxideav-ape/tree/main/tests/fixtures). WMA and WavPack test fixtures are generated from a one-second sine wave. Musepack is generated from the repository's existing WAV fixture during the test.
