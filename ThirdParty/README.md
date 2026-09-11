# Third-party audio tools

The CD Rip application source is MIT-licensed. These separately executed audio
tools and their libraries retain their upstream licenses; the MIT License does
not replace them.

| Component | Version | License | Upstream |
| --- | --- | --- | --- |
| FFmpeg / ffprobe | 9.0.1 | LGPL-2.1-or-later (this configuration) | https://ffmpeg.org |
| LAME | 4.0 | LGPL-2.0-or-later | https://lame.sourceforge.io |
| libcdio | 2.4.0 | GPL-3.0-or-later | https://www.gnu.org/software/libcdio/ |
| cd-paranoia / libcdio-paranoia | 10.2+2.0.2 | GPL-3.0-only | https://www.gnu.org/software/libcdio/ |

Copyright notices and complete license terms are retained in the upstream source
archives and accompanying license files. Tools are built from unmodified upstream
sources with `scripts/build-audio-tools.sh`; the pinned download URLs and SHA-256
checksums are in `scripts/audio-sources.json`. Build prerequisites: Xcode command
line tools, Python 3, make and pkgconf. See `docs/BUILDING-RELEASES.md`.

The release assets include `CD-Rip-0.4.0-audio-sources.tar.gz`, containing the exact
source archives and build/packaging scripts for the distributed tools:
https://github.com/all-software-tools/cd-rip/releases/tag/v0.4.0-beta.1

Libraries remain dynamically linked. You may modify and rebuild these components
under their respective licenses. A modified local bundle must be re-signed (an
ad-hoc signature is sufficient for local development); Mykey Digital's private
signing key is not required to rebuild or modify the code.

FFmpeg is configured without GPL or nonfree extensions, without networking and
with the audio/image formats used by CD Rip. cd-paranoia is a separate GPL program
invoked through its command-line interface. No provider CLI, Homebrew executable
or third-party music/artwork is included in the app.
