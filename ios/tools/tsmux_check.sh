#!/usr/bin/env bash
# Check TSMuxer against ffmpeg, which is the same demuxer OBS uses.
#
# Asserts the rules the muxer has to hold to, not a byte snapshot:
#   * every access unit in comes back out as a packet
#   * ffmpeg decodes the whole thing without a single error
#   * PTS land exactly on the designed cadence (the muxer's PCR lead, then 1/fps)
#   * H.264 and HEVC both round-trip, at 4K vertical
#
# Needs ffmpeg and a Swift toolchain. Run: ./tsmux_check.sh
# No pipefail: `head` closing a pipe early makes ffprobe exit on SIGPIPE.
set -eu
cd "$(dirname "$0")"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FAIL=0

swiftc -O ../GoblinCam/TSMuxer.swift tsmux_harness.swift -o "$WORK/muxtest"

# The lead PTS holds over PCR is a design constant in the muxer; read it from
# there so the test follows the design rather than a number copied once.
LEAD=$(sed -n 's/.*ptsLeadTicks: Int64 = \([0-9_]*\).*/\1/p' ../GoblinCam/TSMuxer.swift | tr -d _)
[ -n "$LEAD" ] || { echo "could not read ptsLeadTicks from TSMuxer.swift"; exit 1; }
WANT_PTS="$LEAD,$((LEAD + 3000)),$((LEAD + 6000))"   # then 1/30 s at 90 kHz

check() {
  local name=$1 codec=$2 size=$3 encoder=$4 bsf=$5 frames=$6
  ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=$size:rate=30" \
    -t $(echo "scale=3; $frames/30" | bc) -c:v "$encoder" -g 30 -bf 0 \
    -bsf:v "$bsf" -f "$codec" "$WORK/in" -y
  "$WORK/muxtest" "$WORK/in" "$WORK/out.ts" "$codec" 2>"$WORK/mux.log"

  local got_frames got_wh
  got_frames=$(ffprobe -v error -count_packets -select_streams v:0 \
      -show_entries stream=nb_read_packets -of csv=p=0 "$WORK/out.ts" | head -1)
  got_wh=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
      -of csv=p=0 "$WORK/out.ts" | head -1 | tr ',' 'x')

  local errs
  errs=$(ffmpeg -hide_banner -v error -i "$WORK/out.ts" -f null - 2>&1 | wc -l | tr -d ' ')
  local pts
  pts=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 \
      "$WORK/out.ts" | head -3 | tr -d ',' | paste -sd, -)

  local ok=1
  [ "$got_frames" = "$frames" ] || { echo "  frames: want $frames, got $got_frames"; ok=0; }
  [ "$got_wh" = "${size/x/x}" ] || { echo "  size: want $size, got $got_wh"; ok=0; }
  [ "$errs" = "0" ] || { echo "  decode reported $errs error lines"; ok=0; }
  [ "$pts" = "$WANT_PTS" ] || { echo "  pts: want $WANT_PTS, got $pts"; ok=0; }

  if [ $ok = 1 ]; then echo "ok   $name  ($got_wh, $got_frames frames, $(sed -n 's/.*keyframes \([0-9]*\).*/\1/p' "$WORK/mux.log") keyframes)"
  else echo "FAIL $name"; FAIL=1; fi
}

check "h264 1080p vertical" h264 1080x1920 libx264 "h264_metadata=aud=insert" 60
check "hevc 4K vertical"    hevc 2160x3840 hevc_videotoolbox "hevc_metadata=aud=insert" 60

# The checks must be able to fail: a mangled stream has to break the decode.
"$WORK/muxtest" "$WORK/in" "$WORK/out.ts" hevc 2>/dev/null
python3 -c "
d=bytearray(open('$WORK/out.ts','rb').read())
# Scramble payload but leave every 4-byte TS header intact, so the demuxer still
# parses cleanly and only the decoder can notice. Zeroing whole packets instead
# would just make the demuxer resync in silence, which proves nothing.
start=(len(d)//188//2)*188
for pkt in range(start, start+188*50, 188):
    for i in range(pkt+4, pkt+188): d[i] ^= 0xFF
open('$WORK/mutant.ts','wb').write(d)"
if [ "$(ffmpeg -hide_banner -v error -i "$WORK/mutant.ts" -f null - 2>&1 | wc -l | tr -d ' ')" = "0" ]; then
  echo "FAIL mutation check: a corrupted stream still decoded clean"; FAIL=1
else
  echo "ok   mutation check  (corrupt stream is rejected, so the checks have teeth)"
fi

[ $FAIL = 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
