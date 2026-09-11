#!/bin/bash
# Build redistributable audio tools from pinned upstream sources. Xcode/CLT required.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
arch="${1:?Usage: build-audio-tools.sh arm64|x86_64 [work-directory-without-spaces]}"
case "$arch" in arm64|x86_64) ;; *) exit 2 ;; esac
work="${2:-/private/tmp/cdrip-audio}"
case "$work" in *' '*) echo 'Use a build directory without spaces for Autotools.' >&2; exit 2 ;; esac
mkdir -p "$work/sources" "$work/src" "$work/$arch" "$work/logs"
python3 - "$project_root/scripts/audio-sources.json" "$work/sources" <<'PY'
import sys,json,pathlib,urllib.request,hashlib
for item in json.load(open(sys.argv[1])):
    path=pathlib.Path(sys.argv[2])/item['archive']
    if not path.exists():
        path.write_bytes(urllib.request.urlopen(item['url'],timeout=120).read())
    if hashlib.sha256(path.read_bytes()).hexdigest()!=item['sha256']:
        raise SystemExit('Checksum mismatch: '+item['name'])
PY
for archive in "$work"/sources/*; do tar -xf "$archive" -C "$work/src"; done
prefix="$work/$arch/install"
mkdir -p "$prefix"
export MACOSX_DEPLOYMENT_TARGET=14.0
export SDKROOT="$(xcrun --show-sdk-path)"
export CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)"
export CFLAGS="-O2 -arch $arch -mmacosx-version-min=14.0"
export CXXFLAGS="$CFLAGS" LDFLAGS="-arch $arch -mmacosx-version-min=14.0"
export PKG_CONFIG="${CDRIP_PKG_CONFIG:-$(command -v pkg-config || true)}"
[ -x "$PKG_CONFIG" ] || { echo "Install pkgconf or set CDRIP_PKG_CONFIG." >&2; exit 1; }
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
build_host="$($work/src/libcdio-2.4.0/config.guess)"
host="$arch-apple-darwin"
[ "$arch" != arm64 ] || host=aarch64-apple-darwin
jobs="${CDRIP_BUILD_JOBS:-6}"
build_autotools() {
    local name="$1"; shift
    mkdir -p "$work/$arch/$name"
    (
        cd "$work/$arch/$name"
        "$work/src/$name/configure" --prefix="$prefix" --host="$host" --build="$build_host" --disable-static --enable-shared "$@" || exit 1
        make -j "$jobs" || exit 1
        make install
    ) > "$work/logs/$arch-$name.log" 2>&1 || { tail -60 "$work/logs/$arch-$name.log"; return 1; }
    echo "Built $name ($arch)"
}
build_autotools lame-4.0 --disable-decoder --disable-frontend --disable-gtktest
build_autotools libcdio-2.4.0 --disable-cxx --disable-example-progs --disable-cddb --disable-vcd-info --without-cd-drive --without-cd-info --without-cdda-player --without-cd-read --without-iso-info --without-iso-read
export LIBCDIO_CFLAGS="-I$prefix/include" LIBCDIO_LIBS="-L$prefix/lib -lcdio -liconv -framework IOKit -framework CoreFoundation"
build_autotools libcdio-paranoia-10.2+2.0.2 --disable-example-progs
mkdir -p "$work/$arch/ffmpeg"
(
    cd "$work/$arch/ffmpeg"
    "$work/src/ffmpeg-9.0.1/configure" --prefix="$prefix" --cc="$CC" --arch="$arch" --target-os=darwin --enable-cross-compile \
        --extra-cflags="$CFLAGS -I$prefix/include" --extra-ldflags="$LDFLAGS -L$prefix/lib" \
        --disable-autodetect --disable-static --enable-shared --disable-doc --disable-debug --disable-network --disable-x86asm \
        --disable-everything --enable-ffmpeg --enable-ffprobe --disable-ffplay --enable-libmp3lame --enable-zlib \
        --enable-protocol=file,pipe --enable-demuxer=wav,mp3,flac,image2,png_pipe,jpeg_pipe \
        --enable-muxer=mp3,flac,wav,pcm_s16le,hash,image2 --enable-decoder=pcm_s16le,pcm_s16be,mp3,mp3float,flac,png,mjpeg \
        --enable-encoder=libmp3lame,flac,pcm_s16le,png,mjpeg --enable-parser=mpegaudio,flac,png,mjpeg \
        --enable-filter=aresample,aformat,anull --enable-swresample --disable-avdevice || exit 1
    make -j "$jobs" || exit 1
    make install
) > "$work/logs/$arch-ffmpeg.log" 2>&1 || { tail -60 "$work/logs/$arch-ffmpeg.log"; exit 1; }
echo "Audio tools ready: $prefix"
