#!/usr/bin/env bash
# Renders the looping wallpaper video (cosmos.mp4) and a matching still (cosmos.png).
# This is the only step that works the GPU hard, and it only runs when you call it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W=2880; H=1864        # native resolution of the built-in display
FPS=30; SECONDS_=48   # one seamless loop

mkdir -p "$DIR/build"
swiftc -O "$DIR/render.swift" -o "$DIR/build/render"

"$DIR/build/render" "$DIR/scene.metal" $W $H $FPS $SECONDS_ all |
  ffmpeg -hide_banner -loglevel error -y \
    -f rawvideo -pix_fmt rgba64le -s ${W}x${H} -r $FPS -i - \
    -vf "scale=out_color_matrix=bt709:out_range=tv,format=p010le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv" \
    -c:v hevc_videotoolbox -profile:v main10 -b:v 24M -g 60 -tag:v hvc1 \
    -bsf:v hevc_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1 \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
    -movflags +faststart+write_colr "$DIR/build/cosmos.tmp.mp4"

"$DIR/build/render" "$DIR/scene.metal" $W $H $FPS $SECONDS_ 0 |
  ffmpeg -hide_banner -loglevel error -y \
    -f rawvideo -pix_fmt rgba64le -s ${W}x${H} -i - -frames:v 1 -pix_fmt rgb24 "$DIR/build/cosmos.tmp.png"

# Swap the new files in at once, so a running wallpaper keeps playing the old copy until restarted.
mv "$DIR/build/cosmos.tmp.mp4" "$DIR/cosmos.mp4"
mv "$DIR/build/cosmos.tmp.png" "$DIR/cosmos.png"

echo "Wrote $DIR/cosmos.mp4 and $DIR/cosmos.png. Run ./wallpaper.sh install to show them."
