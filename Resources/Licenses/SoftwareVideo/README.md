# Bundled software video libraries

Ring links these libraries statically. No FFmpeg program, Homebrew installation,
codec executable, or non-system dynamic library is required at runtime.

Exact source URLs and SHA-256 values are recorded in `dependencies.lock.json`
and `Vendor/video-dependencies.lock.json`. Rebuild with
`Tools/build-video-codecs.sh`, after building the image codecs with both AOM
encoding and decoding enabled. The shared libaom source/license is recorded in
`Vendor/dependencies.lock.json` and `Resources/Licenses/libaom-3.15.2`.

| Library | Pinned source | Upstream terms |
| --- | --- | --- |
| FFmpeg | 9.0 | GPL version 2 or later in this configuration (`--enable-gpl`) |
| x264 | stable commit 31e19f92f00c7003fa115047ce50978bc98c3a0d | GPL version 2 or later |
| x265 | 3.4 | GPL version 2 or later |
| SVT-AV1 | 4.2.0 | BSD 3-Clause Clear; see its PATENTS.md |
| Opus | 1.5.2 | BSD-style; see COPYING |

The GPL-enabled FFmpeg and x264/x265 combination carries GPL obligations for a
linked distribution; bundling notices alone does not fulfill corresponding
source obligations. This change performs local builds only and does not publish
a binary or establish a license for Ring's own source. A distribution must make
the complete corresponding source, local changes, and build instructions
available under the applicable terms.

Ring changes FFmpeg's WebM/Matroska muxer using
`Tools/patches/ffmpeg-9-webm-nanosecond-timestamps.patch`: timestamps use
nanosecond precision instead of millisecond rounding, related duration units
match that precision, and displayed Opus duration excludes codec delay. This
preserves variable-frame-rate presentation timing. The fine timebase requires
more clusters and can add container overhead. Codec implementations otherwise
use the pinned upstream sources.

All upstream copyright and license texts are reproduced in the library folders.
