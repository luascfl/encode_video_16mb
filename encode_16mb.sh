#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./encode_16mb.sh -i INPUT [-o OUTPUT] [-t TARGET_MB] [-a AUDIO_KBPS] [--keep-logs]
Encodes INPUT to a 720p H.264/AAC MP4 aiming between 15–16 MB (default target 15.5 MB).

Flags:
  -i, --input PATH        Source video (required)
  -o, --output PATH       Output file (default: INPUT basename + "-16mb.mp4")
  -t, --target-mb N       Target size in MB (default: 15.5)
  -a, --audio-kbps N      Audio bitrate in kbps (default: 96)
      --keep-logs         Keep ffmpeg two-pass logs
  -h, --help              Show this help
EOF
}

input=""
output=""
target_mb="15.5"
audio_kbps="96"
keep_logs=0
passlog="ffmpeg2pass-16mb"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input) input="$2"; shift 2;;
    -o|--output) output="$2"; shift 2;;
    -t|--target-mb) target_mb="$2"; shift 2;;
    -a|--audio-kbps) audio_kbps="$2"; shift 2;;
    --keep-logs) keep_logs=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$input" ]]; then
  echo "Missing -i/--input" >&2
  usage
  exit 1
fi

if [[ ! -f "$input" ]]; then
  echo "Input not found: $input" >&2
  exit 1
fi

if [[ -z "$output" ]]; then
  base="${input%.*}"
  output="${base}-16mb.mp4"
fi

for dep in ffmpeg ffprobe python3; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "Missing dependency: $dep" >&2
    exit 1
  fi
done

duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input")"

if [[ -z "$duration" ]]; then
  echo "Could not read duration from input." >&2
  exit 1
fi

read total_kbps video_kbps buf_kbps <<<"$(python3 - "$duration" "$target_mb" "$audio_kbps" <<'PY'
import sys, math
duration = float(sys.argv[1])
target_mb = float(sys.argv[2])
audio_kbps = float(sys.argv[3])

if duration <= 0:
    print("0 0 0")
    sys.exit(0)

# ffmpeg uses SI kilobits (1000), while size is in MiB.
total_kbps = target_mb * 8388.608 / duration  # (MB * 1024*1024*8) / 1000 / duration
video_kbps = max(total_kbps - audio_kbps, 200.0)  # keep a floor so the encode does not collapse
buf_kbps = math.ceil(video_kbps * 2)

print(f"{total_kbps:.2f} {video_kbps:.0f} {buf_kbps}")
PY
)"

if python3 - <<PY; then
import sys
val = float("${total_kbps}")
sys.exit(0 if val > 0 else 1)
PY
  :
else
  echo "Bitrate calculation failed (check duration/target)." >&2
  exit 1
fi

echo "Duration: ${duration}s"
echo "Target size: ${target_mb} MB"
echo "Bitrates: total ~${total_kbps} kbps, video ~${video_kbps} kbps, audio ${audio_kbps} kbps"

ffmpeg -y -hide_banner -loglevel error \
  -i "$input" \
  -vf "scale=-2:720" \
  -c:v libx264 -preset medium -b:v "${video_kbps}k" \
  -maxrate "${video_kbps}k" -bufsize "${buf_kbps}k" \
  -pass 1 -passlogfile "$passlog" \
  -an -f mp4 /dev/null

ffmpeg -y -hide_banner -loglevel error \
  -i "$input" \
  -vf "scale=-2:720" \
  -c:v libx264 -preset medium -b:v "${video_kbps}k" \
  -maxrate "${video_kbps}k" -bufsize "${buf_kbps}k" \
  -pass 2 -passlogfile "$passlog" \
  -c:a aac -b:a "${audio_kbps}k" -ac 2 -ar 48000 \
  -pix_fmt yuv420p -movflags +faststart \
  "$output"

if [[ $keep_logs -eq 0 ]]; then
  rm -f "${passlog}-0.log" "${passlog}-0.log.mbtree"
fi

filesize_bytes="$(stat -c %s "$output")"
filesize_mb="$(python3 - <<'PY' "$filesize_bytes"
import sys
size = int(sys.argv[1])
print(f"{size/1024/1024:.2f}")
PY
)"

echo "Output: $output (${filesize_mb} MB)"

status="$(python3 - <<'PY' "$filesize_mb"
import sys
sz = float(sys.argv[1])
if sz > 16:
    print("above")
elif sz < 15:
    print("below")
else:
    print("within")
PY
)"

case "$status" in
  above) echo "Warning: above 16 MB. Lower target with -t or reduce audio kbps."; exit 0;;
  below) echo "Note: below 15 MB. Raise target with -t if you want more quality."; exit 0;;
  within) echo "✅ Within 15–16 MB window."; exit 0;;
esac
