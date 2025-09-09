#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# video_to_prores.sh — DV/MPEG-2 + iPhone pipeline with ARCHIVE-ONLY / PRORES-ONLY
# • iPhone clips (h264/hevc/prores): per-file CFR = nearest of 29.97 or 59.94
# • DV/MPEG-2: deinterlace → 59.94p (DV pillarbox to 1920x1080; HDV to 1920x1080)
# • Basenames preserved; strict filename time YYYYMMDD_HHMMSS-ZZZZ
# • MOV tagging uses YOUR EXACT exiftool block (LargeFileSupport + QuickTimeUTC)
# • --archive-only → FFV1 MKV only
# • --prores-only  → ProRes MOV only
#
# Usage (quick):
#   Mirror (default when only <input_dir> is given):
#     ./video_to_prores.sh [options] <input_dir>
#   Non-mirror (explicit edit/archive output dirs):
#     ./video_to_prores.sh [options] <input_dir> <edit_out_dir> <archive_out_dir>
#
# Key options:
#   --rate 29.97|59.94     Default target CFR (per-file logic may override for iPhone clips)
#   --mirror               Force mirror mode (assumed automatically when only <input_dir> supplied)
#   --orig-root PATH       Originals root for mirror mapping (default: /srv/videos/originals)
#   --trans-root PATH      Transcoded root for mirror mapping (default: /srv/videos/transcoded)
#   --only-subdirs a,b     Limit mirror processing to listed subdirectories under <input_dir>
#   --auto-rate            For non-iPhone progressive, auto-pick 29.97 vs 59.94 by folder max fps
#   --bits-per-mb N        ProRes encoder slice budget (default: 4000)
#   --jobs N               Process up to N files concurrently (default: 1)
#   --filter-threads N     ffmpeg filter graph threads (default: auto)
#   --ffmpeg-threads N     ffmpeg encoder threads per process (0=auto; default: 0)
#   --finalize-per-disk     Serialize finalize per destination mount (default)
#   --finalize-global       Serialize finalize globally (one at a time)
#   --finalize-parallel     Do not serialize finalize (parallel copies)
#   --archive-only         Produce only FFV1 MKV (no ProRes)
#   --prores-only          Produce only ProRes MOV (no FFV1)
#   --force                Overwrite existing outputs (default is to skip existing)
#   --dry-run              Print commands without executing (safe preview)
#   -h, --help             Show this help text
#
# Notes:
# - Safety: encodes stage to NVMe /scratch as *.partial, then background-copy
#   to final volume as *.partial and atomically move into place; partials are
#   cleaned on error. Staging to /scratch is mandatory.
# - Resumability: existing outputs are skipped by default; final summary reports created/skipped counts.
# - Requirements: bash 4+, ffmpeg/ffprobe, exiftool, mkvpropedit, GNU coreutils, GNU date.
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# ---- Usage (detailed) ----
usage() {
  cat <<'USAGE'
video_to_prores.sh — DV/MPEG-2 + iPhone pipeline

Mirror (default when only <input_dir> is given):
  ./video_to_prores.sh [options] <input_dir>

Non-mirror:
  ./video_to_prores.sh [options] <input_dir> <edit_out_dir> <archive_out_dir>

Options:
  --rate 29.97|59.94     Default target CFR (per-file logic may override for iPhone clips)
  --mirror               Force mirror mode (assumed automatically when only <input_dir> supplied)
  --orig-root PATH       Originals root for mirror mapping (default: /srv/videos/originals)
  --trans-root PATH      Transcoded root for mirror mapping (default: /srv/videos/transcoded)
  --only-subdirs a,b     Limit mirror processing to listed subdirectories
  --auto-rate            For non-iPhone progressive, auto-pick 29.97 vs 59.94 by folder max fps
  --bits-per-mb N        ProRes encoder slice budget (default: 4000)
  --jobs N               Process up to N files concurrently (default: 1)
  --filter-threads N     ffmpeg filter graph threads (default: auto)
  --ffmpeg-threads N     ffmpeg encoder threads per process (0=auto; default: 0)
  --finalize-per-disk     Serialize finalize per destination mount (default)
  --finalize-global       Serialize finalize globally (one at a time)
  --finalize-parallel     Do not serialize finalize (parallel copies)
  --archive-only         Produce only FFV1 MKV (no ProRes)
  --prores-only          Produce only ProRes MOV (no FFV1)
  --force                Overwrite existing outputs (default is to skip existing)
  --dry-run              Print commands without executing (safe preview)
  -h, --help             Show this help text

Examples:
  # Mirror under transcode roots (auto-assumed with one arg)
  ./video_to_prores.sh --auto-rate /ingest/2024-08

  # Non-mirror explicit destinations
  ./video_to_prores.sh --rate 59.94 /ingest/clipdir /edit_out /archive_out

Behavior:
  - Atomic writes to *.partial then move into place; partials cleaned on error.
  - Skips existing outputs by default; use --force to re-encode.
  - Prints a final summary with created/skipped counts.
USAGE
}

# ---- Defaults / flags ----
TARGET_FPS_NUM=60000
TARGET_FPS_DEN=1001
TARGET_FPS_LABEL="59.94"

MIRROR=0
ORIG_ROOT="/srv/videos/originals"
TRANS_ROOT="/srv/videos/transcoded"
ONLY_SUBDIRS=""
AUTO_RATE=0              # optional fallback for non-iPhone progressive
BITS_PER_MB=4000         # ProRes encoder slice budget
ARCHIVE_ONLY=0           # FFV1 only
PRORES_ONLY=0            # ProRes only
SKIP_EXISTING=1          # Default: skip when outputs already exist
FORCE=0                  # If set, overwrite even if outputs exist
DRY_RUN=0                # If set, print commands without executing
RETIME_THRESH=0.005      # Speed-change threshold (relative, e.g. 0.005 = 0.5%)
JOBS=1                   # Parallelism (files processed concurrently)
FILTER_THREADS=0         # ffmpeg -filter_threads (0 means unset)
FFMPEG_THREADS=0         # ffmpeg -threads per process (0 = auto/all cores)
FINALIZE_LOCK_MODE="none"  # one of: per-disk | global | none
HAVE_FLOCK=0
if command -v flock >/dev/null 2>&1; then HAVE_FLOCK=1; fi
FF_HAS_FILTER_THREADS=0  # detected at runtime
FF_HAS_FPS_MODE=0        # detected at runtime

# Counters for resumability summary
TOTAL_FILES=0
SKIPPED_WHOLE=0
CREATED_PRORES=0
CREATED_FFV1=0
SKIPPED_EXISTING_OUTPUTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rate) shift
      case ${1:-} in
        29.97) TARGET_FPS_NUM=30000; TARGET_FPS_DEN=1001; TARGET_FPS_LABEL="29.97" ;;
        59.94) TARGET_FPS_NUM=60000; TARGET_FPS_DEN=1001; TARGET_FPS_LABEL="59.94" ;;
        *) echo "ERROR: --rate must be 29.97 or 59.94" >&2; exit 2 ;;
      esac ;;
    --mirror)        MIRROR=1 ;;
    --orig-root)     shift; ORIG_ROOT="${1:?}";;
    --trans-root)    shift; TRANS_ROOT="${1:?}";;
    --only-subdirs)  shift; ONLY_SUBDIRS="${1:?}";;   # comma-separated
    --auto-rate)     AUTO_RATE=1 ;;
    --bits-per-mb)   shift; BITS_PER_MB="${1:?}";;
    --archive-only)  ARCHIVE_ONLY=1 ;;
    --prores-only)   PRORES_ONLY=1 ;;
    --force)         FORCE=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    --jobs)          shift; JOBS=${1:?}; [[ $JOBS =~ ^[0-9]+$ && $JOBS -ge 1 ]] || { echo "ERROR: --jobs must be >=1" >&2; exit 2; } ;;
    --filter-threads) shift; FILTER_THREADS=${1:?}; [[ $FILTER_THREADS =~ ^[0-9]+$ && $FILTER_THREADS -ge 0 ]] || { echo "ERROR: --filter-threads must be >=0" >&2; exit 2; } ;;
    --ffmpeg-threads) shift; FFMPEG_THREADS=${1:?}; [[ $FFMPEG_THREADS =~ ^[0-9]+$ && $FFMPEG_THREADS -ge 0 ]] || { echo "ERROR: --ffmpeg-threads must be >=0" >&2; exit 2; } ;;
    --finalize-per-disk) FINALIZE_LOCK_MODE="per-disk" ;;
    --finalize-global)   FINALIZE_LOCK_MODE="global" ;;
    --finalize-parallel) FINALIZE_LOCK_MODE="none" ;;
    -h|--help)       usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done

# Mutual exclusion
if (( ARCHIVE_ONLY && PRORES_ONLY )); then
  echo "ERROR: --archive-only and --prores-only are mutually exclusive." >&2
  exit 2
fi

# ---- Traps & cleanup for partial files and background jobs ----
declare -a PARTIALS       # scratch partial files to delete on failure
declare -a SCRATCH_DIRS   # scratch dirs to delete on failure
declare -a PIDS           # encode worker PIDs (declared again later for scope safety)

_kill_bg_jobs() {
  local pid
  # Kill encode workers
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill -INT "$pid" 2>/dev/null || true
  done
}

_cleanup_partials() {
  local p d
  for p in "${PARTIALS[@]:-}"; do
    [[ -n "$p" && -e "$p" ]] && rm -f -- "$p" || true
  done
  for d in "${SCRATCH_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d" || true
  done
}

_on_interrupt() {
  log "Aborted by signal; stopping workers and cleaning partials"
  _kill_bg_jobs
  # Give children a moment to exit cleanly
  sleep 0.5 || true
  _cleanup_partials
  # Cleanup temp tracking files
  [[ -n "${STATS_FILE:-}" && -f "$STATS_FILE" ]] && rm -f "$STATS_FILE" || true
  exit 130
}

_on_error() {
  local code=$?
  log "Error occurred (exit $code); stopping workers and cleaning partials"
  _kill_bg_jobs
  _cleanup_partials
  [[ -n "${STATS_FILE:-}" && -f "$STATS_FILE" ]] && rm -f "$STATS_FILE" || true
  exit "$code"
}

trap _on_interrupt INT TERM
trap _on_error ERR

run() { if (( DRY_RUN )); then printf "[DRY-RUN] "; printf "%q " "$@"; printf "\n"; else "$@"; fi; }
log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
stat_log() { [[ -n "${STATS_FILE:-}" ]] && printf "%s\n" "$1" >> "$STATS_FILE" || true; }
debug() { if [[ "${V2P_DEBUG:-0}" == "1" ]]; then log "DEBUG: $*"; fi }

# ---- NVMe scratch staging (mandatory) ----
# All encodes write temporary outputs to /scratch, then a finalize step copies
# to the final filesystem and tags metadata. This reduces HDD contention.
SCRATCH_ROOT="/scratch"
SCRATCH_NS="v2p"
if [[ ! -d "$SCRATCH_ROOT" ]]; then
  echo "ERROR: scratch volume not found at $SCRATCH_ROOT (required)." >&2
  exit 2
fi
run mkdir -p -- "$SCRATCH_ROOT/$SCRATCH_NS"

# Finalize: tag on scratch (faster), then copy -> final.partial and mv to final (synchronous)
# Args: scratch_path final_path kind iso_local_w_space iso_local iso_utc
_finalize_to_dest() {
  local scratch_path="$1" final_path="$2" kind="$3" iso_local_w_space="$4" iso_local="$5" iso_utc="$6"
  set -euo pipefail
  local final_tmp="${final_path}.partial"
  local scratch_dir
  scratch_dir=$(dirname -- "$scratch_path")
  trap 'rm -f -- "$final_tmp" "$scratch_path" 2>/dev/null || true; rmdir -- "$scratch_dir" 2>/dev/null || true' INT TERM ERR
  run mkdir -p -- "$(dirname -- "$final_tmp")"
  # Tag on scratch for performance and single HDD write
  if [[ "$kind" == mov ]]; then
    mov_tag_dates_exact "$scratch_path" "$iso_local_w_space" "$iso_local" "$iso_utc"
  else
    mkv_tag_dates "$scratch_path" "$iso_utc"
  fi
  # Copy the fully tagged file to destination and finalize, with optional per-disk/global serialization
  local lock_root lockfile locks_dir
  locks_dir="$SCRATCH_ROOT/$SCRATCH_NS/locks"
  case "$FINALIZE_LOCK_MODE" in
    per-disk)
      # derive mount point of destination directory for per-disk lock
      lock_root=$(stat -f -c %m "$(dirname -- "$final_tmp")" 2>/dev/null || df -P "$(dirname -- "$final_tmp")" | tail -1 | awk '{print $6}')
      lockfile="$locks_dir/$(printf "%s" "$lock_root" | sed 's|/|_|g').lock"
      ;;
    global)
      lockfile="$locks_dir/global.lock"
      ;;
    none)
      lockfile=""
      ;;
    *)
      lockfile=""
      ;;
  esac

  if [[ -n "$lockfile" ]]; then
    run mkdir -p -- "$locks_dir"
    if (( HAVE_FLOCK )); then
      # Use flock to serialize just the copy+move
      # Place `--` before the lockfile to end option parsing for flock
      # (using it after the file makes flock try to execute `--`).
      run flock -x -- "$lockfile" bash -c 'cp -f -- "$1" "$2"; mv -f -- "$2" "$3"' -- "$scratch_path" "$final_tmp" "$final_path"
    else
      # Fallback: poor-man lock via mkdir loop
      local lockdir="${lockfile}.d"
      while ! mkdir "$lockdir" 2>/dev/null; do sleep 0.1; done
      run cp -f -- "$scratch_path" "$final_tmp"
      run mv -f -- "$final_tmp" "$final_path"
      rmdir "$lockdir" 2>/dev/null || true
    fi
  else
    run cp -f -- "$scratch_path" "$final_tmp"
    run mv -f -- "$final_tmp" "$final_path"
  fi
  # Stats after finalize
  if [[ "$kind" == mov ]]; then stat_log "created_prores"; else stat_log "created_ffv1"; fi
  rm -f -- "$scratch_path" || true
  rmdir -- "$scratch_dir" 2>/dev/null || true
}

# Assume --mirror if only <input_dir> is provided
if (( MIRROR )); then
  [[ $# -ge 1 ]] || { echo "Usage: $(basename "$0") --mirror [--only-subdirs a,b] <input_dir>" >&2; exit 2; }
else
  if   [[ $# -eq 1 ]]; then MIRROR=1
  elif [[ $# -eq 3 ]]; then :
  else
    echo "Usage: $(basename "$0") [--rate 29.97|59.94] [--force] <input_dir> <edit_out_dir> <archive_out_dir>" >&2
    echo "Hint: providing only <input_dir> assumes --mirror mode by default" >&2
    exit 2
  fi
fi

input_dir=$1
edit_out_dir=${2:-}
archive_out_dir=${3:-}
(( MIRROR )) || run mkdir -p "$edit_out_dir" "$archive_out_dir"

# Detect ffmpeg capabilities (older ffmpeg may not support some flags)
if ffmpeg -hide_banner -h full 2>&1 | grep -q -- '-filter_threads'; then
  FF_HAS_FILTER_THREADS=1
else
  FF_HAS_FILTER_THREADS=0
fi
if ffmpeg -hide_banner -h full 2>&1 | grep -q -- '-fps_mode'; then
  FF_HAS_FPS_MODE=1
else
  FF_HAS_FPS_MODE=0
fi

 

# ---- Time helpers (STRICT filename pattern) ----
# Input must match: ^YYYYMMDD_HHMMSS[-+]ZZZZ
# Prints:
#   1: iso_local_w_space → "YYYY-MM-DD HH:MM:SS±HH:MM"
#   2: iso_local         → "YYYY-MM-DDTHH:MM:SS±HH:MM"
#   3: iso_utc           → "YYYY-MM-DDTHH:MM:SSZ"
extract_times_from_name() {
  local f=$1 base tz ymd hms local_dt tz_fmt local_w_space iso_local iso_utc
  base=$(basename "$f")
  if [[ $base =~ ^([0-9]{8})_([0-9]{6})([-+][0-9]{4}) ]]; then
    ymd=${BASH_REMATCH[1]}
    hms=${BASH_REMATCH[2]}
    tz=${BASH_REMATCH[3]}
    local_dt="${ymd:0:4}-${ymd:4:2}-${ymd:6:2} ${hms:0:2}:${hms:2:2}:${hms:4:2}"
    tz_fmt="${tz:0:3}:${tz:3:2}"
    local_w_space="${local_dt}${tz_fmt}"
    iso_local="${local_dt/T /T}${tz_fmt}"
    iso_utc=$(date -u -d "$local_w_space" "+%Y-%m-%dT%H:%M:%SZ")
    printf "%s\n%s\n%s\n" "$local_w_space" "$iso_local" "$iso_utc"
  else
    echo "ERROR: filename does not match YYYYMMDD_HHMMSS-ZZZZ: $base" >&2
    exit 2
  fi
}

probe_timecode() {
  local f=$1 tc
  tc=$(ffprobe -v error -select_streams v:0 -show_entries stream_tags=timecode -of default=nw=1:nk=1 "$f" || true)
  [[ -z "$tc" ]] && tc="00:00:00:00"
  echo "$tc"
}

# Count audio streams (returns integer)
audio_stream_count() {
  local f=$1
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" | awk 'END{print NR}'
}

# Return space-separated list of global stream indices for valid audio (codec_name != none)
valid_audio_global_indices() {
  local f=$1
  ffprobe -v error -select_streams a -show_entries stream=index,codec_name -of csv=p=0 "$f" \
    | awk -F, '$2!="none" {print $1}'
}

# Return codec kind
source_kind() {
  local f=$1 codec
  codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$f" || true)
  case "$codec" in
    dvvideo)    echo dv ;;
    mpeg2video) echo mpeg2 ;;
    h264)       echo h264 ;;
    hevc)       echo hevc ;;
    prores)     echo prores ;;
    *)          echo other ;;
  esac
}

# Probe float fps (avg→r fallback)
probe_fps_float() {
  local f=$1 afr
  afr=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$f" 2>/dev/null || echo "0/1")
  [[ "$afr" == "0/0" || -z "$afr" ]] && afr=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$f" 2>/dev/null || echo "0/1")
  awk -v n="${afr%/*}" -v d="${afr#*/}" 'BEGIN{ if(d==0||d=="") d=1; printf("%.6f", n/d) }'
}

# Probe colors (per first video stream); empty if unavailable
probe_color_primaries() { ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$1" 2>/dev/null | sed -n '1p' | tr -d '\r\n' || true; }
probe_color_trc()       { ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer  -of default=nw=1:nk=1 "$1" 2>/dev/null | sed -n '1p' | tr -d '\r\n' || true; }
probe_color_space()     { ffprobe -v error -select_streams v:0 -show_entries stream=color_space    -of default=nw=1:nk=1 "$1" 2>/dev/null | sed -n '1p' | tr -d '\r\n' || true; }
probe_color_range()     { ffprobe -v error -select_streams v:0 -show_entries stream=color_range    -of default=nw=1:nk=1 "$1" 2>/dev/null | sed -n '1p' | tr -d '\r\n' || true; }

# Normalize/validate color tag tokens from ffprobe to avoid accidental concatenation
normalize_color_tag() {
  # prints empty string if unknown; otherwise a canonical token
  local v="$1"
  # strip any whitespace or stray control chars
  v=$(printf "%s" "$v" | tr -d '\r\n\t ')
  case "$v" in
    bt709|smpte170m|bt470bg|bt470m|smpte240m|bt2020|bt2020nc|arib-std-b67|smpte2084|iec61966-2-1|unspecified)
      printf "%s" "$v" ;;
    *)
      printf "" ;;
  esac
}
probe_pix_fmt()         { ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt        -of default=nw=1:nk=1 "$1" 2>/dev/null | tr -d '\n' || true; }

safe_basename_noext() { local f=$1 b; b=$(basename "$f"); echo "${b%.*}"; }

# ---- Tagging (YOUR EXACT exiftool block for MOVs) ----
mov_tag_dates_exact() {
  # $1 MOV path
  # $2 iso_local_w_space : "YYYY-MM-DD HH:MM:SS-07:00"
  # $3 iso_local         : "YYYY-MM-DDTHH:MM:SS-07:00"
  # $4 iso_utc           : "YYYY-MM-DDTHH:MM:SSZ"
  local mov="$1" iso_local_w_space="$2" iso_local="$3" iso_utc="$4"
  run exiftool -overwrite_original_in_place -api LargeFileSupport=1 -api QuickTimeUTC=1 \
      -Keys:CreationDate="$iso_local" \
      -QuickTime:CreateDate="$iso_utc" \
      -QuickTime:ModifyDate="$iso_utc" \
      -CreateDate="$iso_utc" \
      -ModifyDate="$iso_utc" \
      -DateTimeOriginal="$iso_utc" \
      -XMP:CreateDate="$iso_utc" \
      -XMP:ModifyDate="$iso_utc" \
      -XMP:MetadataDate="$iso_utc" \
      -XMP:DateTimeOriginal="$iso_utc" \
      "$mov" >/dev/null
}

# MKV: Segment Date in UTC
mkv_tag_dates() {
  local mkv="$1" iso_utc="$2"
  run mkvpropedit "$mkv" --edit info --set "date=$iso_utc" >/dev/null
}

# ---- Encoding helpers ----
make_ffv1_archive() {
  # in_f base iso_local_w_space iso_local iso_utc tc kind
  local in_f=$1 base=$2 iso_local_w_space=$3 iso_local=$4 iso_utc=$5 tc=$6 kind=$7
  # Guard against empty output dir (would cause ffmpeg to see a blank filename)
  if [[ -z "${archive_out_dir:-}" ]]; then
    echo "ERROR: archive_out_dir is empty for input: $in_f (kind=$kind). In mirror mode ensure the input lives under ORIG_ROOT=$ORIG_ROOT, or provide an explicit archive_out_dir." >&2
    return 2
  fi
  local out_mkv="$archive_out_dir/${base}.mkv"
  # NVMe scratch partial path
  local scratch_dir
  scratch_dir=$(mktemp -d -p "$SCRATCH_ROOT/$SCRATCH_NS" ffv1_XXXXXX)
  SCRATCH_DIRS+=("$scratch_dir")
  local out_tmp_scr="${scratch_dir}/${base}.mkv.partial"

  # Ensure scratch cleanup on interruption/error within this worker
  trap 'rm -f -- "$out_tmp_scr" 2>/dev/null || true; rmdir -- "$scratch_dir" 2>/dev/null || true' INT TERM ERR

  if (( SKIP_EXISTING )) && (( !FORCE )) && [[ -f "$out_mkv" ]]; then
    log "Skipping existing archive: $out_mkv"
    (( ++SKIPPED_EXISTING_OUTPUTS ))
    stat_log "skipped_output"
    return 0
  fi

  local color_args=()
  if [[ "$kind" == dv ]]; then
    color_args=(-color_primaries smpte170m -color_trc smpte170m -colorspace smpte170m)
  else
    # Preserve source color tags, including HDR/HLG
    local cp ct cs
    cp=$(normalize_color_tag "$(probe_color_primaries "$in_f" || true)")
    ct=$(normalize_color_tag "$(probe_color_trc "$in_f" || true)")
    cs=$(normalize_color_tag "$(probe_color_space "$in_f" || true)")
    # Only attach if non-empty; common HDR values: bt2020, arib-std-b67 (HLG), smpte2084 (PQ), bt2020nc
    if [[ -n "$cp" && -n "$ct" && -n "$cs" ]]; then
      color_args=(-color_primaries "$cp" -color_trc "$ct" -colorspace "$cs")
    fi
  fi
  # Avoid deprecated yuvj* formats by mapping to non-j and preserving range tag
  local pixfmt_args=() range_flag=()
  local src_pix src_range
  src_pix=$(probe_pix_fmt "$in_f" || true)
  src_range=$(probe_color_range "$in_f" || true)
  case "$src_pix" in
    yuvj420p) pixfmt_args=(-pix_fmt yuv420p) ;;
    yuvj422p) pixfmt_args=(-pix_fmt yuv422p) ;;
    yuvj444p) pixfmt_args=(-pix_fmt yuv444p) ;;
    *)        pixfmt_args=() ;;
  esac
  if [[ "$src_range" == pc || "$src_range" == tv ]]; then
    range_flag=(-color_range "$src_range")
  fi
  local audio_maps=() audio_codec=()
  read -r -a _aidx <<< "$(valid_audio_global_indices "$in_f")"
  if (( ${#_aidx[@]} > 0 )); then
    for idx in "${_aidx[@]}"; do audio_maps+=(-map "0:${idx}"); done
    audio_codec=(-c:a copy)
  fi

  PARTIALS+=("$out_tmp_scr")
  local threading_args=(-threads "$FFMPEG_THREADS")
  if (( FILTER_THREADS > 0 )) && (( FF_HAS_FILTER_THREADS )); then threading_args+=(-filter_threads "$FILTER_THREADS"); fi
  # Ensure scratch directory exists
  run mkdir -p -- "$(dirname -- "$out_tmp_scr")"
  run ffmpeg -hide_banner -y -probesize 50M -analyzeduration 200M -discard:d all -i "$in_f" \
    "${threading_args[@]}" \
    -map 0:v:0 -c:v ffv1 -level 3 -g 1 -slices 24 -slicecrc 1 -coder 1 -context 1 \
    "${color_args[@]}" "${range_flag[@]}" "${pixfmt_args[@]}" \
    "${audio_maps[@]}" \
    "${audio_codec[@]}" \
    -map_metadata 0 -metadata "timecode=$tc" \
    -metadata creation_time="$iso_utc" \
    -metadata date="$iso_local" \
    -f matroska "$out_tmp_scr"

  # Finalize to destination: copy to final, tag, cleanup
  _finalize_to_dest "$out_tmp_scr" "$out_mkv" mkv "$iso_local_w_space" "$iso_local" "$iso_utc"
  # Remove from PARTIALS tracking (background job owns cleanup now)
  for i in "${!PARTIALS[@]}"; do
    [[ "${PARTIALS[$i]}" == "$out_tmp_scr" ]] && unset 'PARTIALS[$i]' && break
  done
  # Clear trap for this section now that cleanup is handled
  trap - INT TERM ERR
}

make_prores_edit() {
  # in_f base iso_local_w_space iso_local iso_utc tc kind
  local in_f=$1 base=$2 iso_local_w_space=$3 iso_local=$4 iso_utc=$5 tc=$6 kind=$7
  # ensure optional arrays are defined to avoid empty-string args
  local -a add_vsync=()
  # Guard against empty output dir (would cause ffmpeg to see a blank filename)
  if [[ -z "${edit_out_dir:-}" ]]; then
    echo "ERROR: edit_out_dir is empty for input: $in_f (kind=$kind). In mirror mode ensure the input lives under ORIG_ROOT=$ORIG_ROOT, or provide an explicit edit_out_dir." >&2
    return 2
  fi
  local out_mov="$edit_out_dir/${base}.mov"
  # NVMe scratch partial path
  local scratch_dir2
  scratch_dir2=$(mktemp -d -p "$SCRATCH_ROOT/$SCRATCH_NS" prores_XXXXXX)
  SCRATCH_DIRS+=("$scratch_dir2")
  local out_tmp_scr2="${scratch_dir2}/${base}.mov.partial"

  # Ensure scratch cleanup on interruption/error within this worker
  trap 'rm -f -- "$out_tmp_scr2" 2>/dev/null || true; rmdir -- "$scratch_dir2" 2>/dev/null || true' INT TERM ERR

  if (( SKIP_EXISTING )) && (( !FORCE )) && [[ -f "$out_mov" ]]; then
    log "Skipping existing edit: $out_mov"
    (( ++SKIPPED_EXISTING_OUTPUTS ))
    stat_log "skipped_output"
    return 0
  fi

  local vf
  case "$kind" in
    dv)
      vf="bwdif=mode=1:parity=auto:deint=all,fps=${TARGET_FPS_NUM}/${TARGET_FPS_DEN},scale=1440:1080:flags=lanczos,setsar=1,pad=1920:1080:240:0:color=black,format=yuv422p10le"
      ;;
    mpeg2)
      vf="bwdif=mode=1:parity=auto:deint=all,fps=${TARGET_FPS_NUM}/${TARGET_FPS_DEN},scale=iw*sar:ih:flags=lanczos,setsar=1,scale=1920:1080:flags=lanczos,format=yuv422p10le"
      ;;
    h264|hevc|prores)
      # Progressive sources: prefer retime (setpts) when very close to target CFR.
      # Also: keep 4K/native resolution; ensure sub‑HD upscales to at least 1920x1080.
      # We first normalize SAR, then apply scale with force_original_aspect_ratio=increase
      # so inputs >= HD are left unchanged, while sub‑HD scales up to HD minimum.
      src_fps=$(probe_fps_float "$in_f")
      rel_diff=$(awk -v s="$src_fps" -v tn="$TARGET_FPS_NUM" -v td="$TARGET_FPS_DEN" 'BEGIN{t=tn/td; d=s-t; if(d<0) d=-d; printf("%.6f", d/t)}')
      use_retime=0
      if awk -v d="$rel_diff" -v th="$RETIME_THRESH" 'BEGIN{exit (d<=th)?0:1}'; then use_retime=1; fi
      # Normalize to square pixels, orientation-aware HD minimum, preserve AR, then force SAR 1:1
      # - If portrait (ih>=iw), use a 1080x1920 box; otherwise 1920x1080
      # - Use :increase so >=HD sources (including 4K) are left unchanged
      # If source is full range (pc), convert to tv during first scale to avoid deprecated yuvj* semantics
      local cr_in
      cr_in=$(probe_color_range "$in_f" || true)
      local range_params=""
      if [[ "$cr_in" == pc ]]; then range_params=":in_range=pc:out_range=tv"; fi
      vf_scale="scale=iw*sar:ih:flags=lanczos${range_params},setsar=1,scale=w=if(gte(ih\,iw)\,1080\,1920):h=if(gte(ih\,iw)\,1920\,1080):flags=lanczos:force_original_aspect_ratio=increase:force_divisible_by=2,setsar=1,format=yuv422p10le"
      if (( use_retime )); then
        # setpts factor slows/speeds video so output CFR matches target without dup/drop
        pts_factor=$(awk -v s="$src_fps" -v tn="$TARGET_FPS_NUM" -v td="$TARGET_FPS_DEN" 'BEGIN{printf("%.9f", s/(tn/td))}')
        vf="setpts=${pts_factor}*PTS,${vf_scale}"
        # Force modern fps control; expect ffmpeg with -fps_mode support
        add_vsync=(-fps_mode cfr -r ${TARGET_FPS_NUM}/${TARGET_FPS_DEN})
      else
        vf="fps=${TARGET_FPS_NUM}/${TARGET_FPS_DEN},${vf_scale}"
        add_vsync=()
      fi
      ;;
    *)
      vf="bwdif=mode=1:parity=auto:deint=all,fps=${TARGET_FPS_NUM}/${TARGET_FPS_DEN},format=yuv422p10le"
      ;;
  esac

  local color_args=()
  if [[ "$kind" == dv ]]; then
    color_args=(-color_primaries smpte170m -color_trc smpte170m -colorspace smpte170m -color_range tv)
  else
    # Preserve source color tags, including HDR/HLG
    local cp2 ct2 cs2
    cp2=$(normalize_color_tag "$(probe_color_primaries "$in_f" || true)")
    ct2=$(normalize_color_tag "$(probe_color_trc "$in_f" || true)")
    cs2=$(normalize_color_tag "$(probe_color_space "$in_f" || true)")
    if [[ -n "$cp2" && -n "$ct2" && -n "$cs2" ]]; then
      color_args=(-color_primaries "$cp2" -color_trc "$ct2" -colorspace "$cs2" -color_range tv)
    else
      color_args=(-color_range tv)
    fi
  fi
  local audio_maps=() audio_codec=() audio_filter=()
  read -r -a _aidx2 <<< "$(valid_audio_global_indices "$in_f")"
  if (( ${#_aidx2[@]} > 0 )); then
    for idx in "${_aidx2[@]}"; do audio_maps+=(-map "0:${idx}"); done
    audio_codec=(-c:a pcm_s16le)
    # If we chose retime for progressive sources, apply matching atempo per output audio stream
    if [[ "$kind" =~ ^(h264|hevc|prores)$ ]] && (( ${#add_vsync[@]} > 0 )); then
      atempo_factor=$(awk -v s="${src_fps:-0}" -v tn="$TARGET_FPS_NUM" -v td="$TARGET_FPS_DEN" 'BEGIN{t=tn/td; if(s==0) s=t; printf("%.9f", t/s)}')
      # Apply per audio stream to ensure all mapped audios are retimed
      for ((i=0; i<${#_aidx2[@]}; i++)); do
        audio_filter+=( -filter:a:${i} "atempo=${atempo_factor}" )
      done
    fi
  fi

  PARTIALS+=("$out_tmp_scr2")
  local threading_args2=(-threads "$FFMPEG_THREADS")
  if (( FILTER_THREADS > 0 )) && (( FF_HAS_FILTER_THREADS )); then threading_args2+=(-filter_threads "$FILTER_THREADS"); fi
  # Ensure scratch directory exists
  run mkdir -p -- "$(dirname -- "$out_tmp_scr2")"
  debug "edit_out_dir='$edit_out_dir' base='$base' out_mov='$out_mov' out_tmp='$out_tmp_scr2'"
  debug "About to run ffmpeg → $out_tmp_scr2"
  run ffmpeg -hide_banner -y -probesize 50M -analyzeduration 200M -discard:d all -i "$in_f" \
    "${threading_args2[@]}" \
    -map 0:v:0 -vf "$vf" -c:v prores_ks -profile:v 3 -bits_per_mb "$BITS_PER_MB" -pix_fmt yuv422p10le "${color_args[@]}" "${add_vsync[@]}" \
    "${audio_maps[@]}" \
    "${audio_codec[@]}" "${audio_filter[@]}" \
    -map_metadata 0 -metadata "timecode=$tc" \
    -metadata creation_time="$iso_utc" \
    -metadata date="$iso_local" \
    -metadata com.apple.quicktime.creationdate="$iso_local" \
    -f mov "$out_tmp_scr2"

  # Finalize to destination: copy to final, tag, cleanup
  _finalize_to_dest "$out_tmp_scr2" "$out_mov" mov "$iso_local_w_space" "$iso_local" "$iso_utc"
  # Remove from PARTIALS tracking (background job owns cleanup now)
  for i in "${!PARTIALS[@]}"; do
    [[ "${PARTIALS[$i]}" == "$out_tmp_scr2" ]] && unset 'PARTIALS[$i]' && break
  done
  # Clear trap for this section now that cleanup is handled
  trap - INT TERM ERR
}

# Processors with mode gating
process_dv() {
  (( PRORES_ONLY )) || make_ffv1_archive "$1" "$2" "$3" "$4" "$5" "$6" dv
  (( ARCHIVE_ONLY )) || make_prores_edit   "$1" "$2" "$3" "$4" "$5" "$6" dv
}
process_mpeg2() {
  (( PRORES_ONLY )) || make_ffv1_archive "$1" "$2" "$3" "$4" "$5" "$6" mpeg2
  (( ARCHIVE_ONLY )) || make_prores_edit   "$1" "$2" "$3" "$4" "$5" "$6" mpeg2
}
process_h264() {
  (( PRORES_ONLY )) || make_ffv1_archive "$1" "$2" "$3" "$4" "$5" "$6" h264
  (( ARCHIVE_ONLY )) || make_prores_edit   "$1" "$2" "$3" "$4" "$5" "$6" h264
}
process_hevc() {
  (( PRORES_ONLY )) || make_ffv1_archive "$1" "$2" "$3" "$4" "$5" "$6" hevc
  (( ARCHIVE_ONLY )) || make_prores_edit   "$1" "$2" "$3" "$4" "$5" "$6" hevc
}
process_prores() {
  (( PRORES_ONLY )) || make_ffv1_archive "$1" "$2" "$3" "$4" "$5" "$6" prores
  (( ARCHIVE_ONLY )) || make_prores_edit   "$1" "$2" "$3" "$4" "$5" "$6" prores
}
process_other() {
  (( PRORES_ONLY )) || make_ffv1_archive "$1" "$2" "$3" "$4" "$5" "$6" other
  (( ARCHIVE_ONLY )) || make_prores_edit   "$1" "$2" "$3" "$4" "$5" "$6" other
}

# ---- File list ----
search_roots=("$input_dir")
if (( MIRROR )) && [[ -n "$ONLY_SUBDIRS" ]]; then
  IFS=',' read -r -a _subs <<< "$ONLY_SUBDIRS"
  search_roots=(); for s in "${_subs[@]}"; do search_roots+=("$input_dir/$s"); done
fi

files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(
  find "${search_roots[@]}" -type f \
    \( -iname "*.dv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.mp4" \
       -o -iname "*.m2t" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.m2ts" \) \
    -print0 | sort -z
)
[[ ${#files[@]} -gt 0 ]] || { log "No input files found under: $input_dir"; exit 0; }

# ---- Optional folder auto-rate for non-iPhone ----
if (( AUTO_RATE )); then
  max_fps=0
  for ftest in "${files[@]}"; do
    k=$(source_kind "$ftest")
    [[ "$k" == dv || "$k" == mpeg2 ]] && continue
    fps=$(probe_fps_float "$ftest")
    if awk -v a="$fps" -v b="$max_fps" 'BEGIN{exit (a>b)?0:1}'; then max_fps="$fps"; fi
  done
  if awk -v v="$max_fps" 'BEGIN{exit (v>=50)?0:1}'; then
    FOLDER_NUM=60000; FOLDER_DEN=1001; FOLDER_LABEL="59.94"
  else
    FOLDER_NUM=30000; FOLDER_DEN=1001; FOLDER_LABEL="29.97"
  fi
  log "Auto-rate (non-iPhone default): folder max fps ≈ $max_fps → $FOLDER_LABEL"
fi

# ---- Main loop ----
log "Starting pipeline; default rate: ${TARGET_FPS_LABEL} fps (iPhone clips choose nearest CFR). ARCHIVE_ONLY=${ARCHIVE_ONLY} PRORES_ONLY=${PRORES_ONLY} JOBS=${JOBS} FFMPEG_THREADS=${FFMPEG_THREADS} FILTER_THREADS=${FILTER_THREADS} FINALIZE_MODE=${FINALIZE_LOCK_MODE}"

# Concurrency: force single-threaded when dry-run to keep output readable
if (( DRY_RUN )); then JOBS=1; fi

# Stats aggregation (always use a temp file)
STATS_FILE=$(mktemp -t v2prores_stats.XXXXXX)

# PID-based concurrency (no dependence on bash job control)
declare -a PIDS=()
wait_for_slot() {
  while (( ${#PIDS[@]} >= JOBS )); do
    # Wait for the oldest PID to complete and remove it
    if [[ -n "${PIDS[0]:-}" ]]; then
      wait "${PIDS[0]}" || true
      PIDS=("${PIDS[@]:1}")
    else
      break
    fi
  done
}

for f in "${files[@]}"; do
  (( ++TOTAL_FILES ))
  wait_for_slot
  {
    base=$(safe_basename_noext "$f")

  # Mirror mapping → decide output dirs
  if (( MIRROR )); then
    case "$f" in
      "$ORIG_ROOT"/*)
        rel_all=${f#"$ORIG_ROOT/"}; tail=${rel_all#*/}; rel_dir=$(dirname "$tail")
        # Only create what we will actually use:
        if (( !PRORES_ONLY )); then
          archive_out_dir="$TRANS_ROOT/ffv1/$rel_dir"; run mkdir -p "$archive_out_dir"
        fi
        if (( !ARCHIVE_ONLY )); then
          edit_out_dir="$TRANS_ROOT/prores422hq/$rel_dir"; run mkdir -p "$edit_out_dir"
        fi
        ;;
      *)
        # Non-mirror mode requires both dirs provided initially; here we allow either
        if (( PRORES_ONLY )); then
          [[ -n "$edit_out_dir" ]] || { echo "ERROR: --prores-only requires edit_out_dir." >&2; exit 2; }
        elif (( ARCHIVE_ONLY )); then
          [[ -n "$archive_out_dir" ]] || { echo "ERROR: --archive-only requires archive_out_dir." >&2; exit 2; }
        else
          [[ -n "$edit_out_dir" && -n "$archive_out_dir" ]] || { echo "ERROR: both output dirs required." >&2; exit 2; }
        fi
        ;;
    esac
    # Validate mirror mapping produced required dirs
    if (( PRORES_ONLY )); then
      [[ -n "$edit_out_dir" ]] || { echo "ERROR: Mirror mapping failed to set edit_out_dir for input: $f; ensure it lives under ORIG_ROOT=$ORIG_ROOT" >&2; exit 2; }
    elif (( ARCHIVE_ONLY )); then
      [[ -n "$archive_out_dir" ]] || { echo "ERROR: Mirror mapping failed to set archive_out_dir for input: $f; ensure it lives under ORIG_ROOT=$ORIG_ROOT" >&2; exit 2; }
    else
      [[ -n "$edit_out_dir" && -n "$archive_out_dir" ]] || { echo "ERROR: Mirror mapping failed to set output dirs for input: $f; ensure it lives under ORIG_ROOT=$ORIG_ROOT" >&2; exit 2; }
    fi
  fi

  # Early resumability check: if all required outputs exist, skip file
  need_archive=$(( PRORES_ONLY ? 0 : 1 ))
  need_prores=$(( ARCHIVE_ONLY ? 0 : 1 ))
  out_mkv_candidate="$archive_out_dir/${base}.mkv"
  out_mov_candidate="$edit_out_dir/${base}.mov"
  have_archive=0; [[ -f "$out_mkv_candidate" ]] && have_archive=1
  have_prores=0; [[ -f "$out_mov_candidate" ]] && have_prores=1
  if (( SKIP_EXISTING )) && (( !FORCE )); then
    if (( (!need_archive || have_archive) && (!need_prores || have_prores) )); then
      log "Already complete; skipping: $f"
      (( ++SKIPPED_WHOLE ))
      stat_log "skipped_whole"
      exit 0
    fi
  fi

  # Only now do expensive probes and time extraction
  mapfile -t t < <(extract_times_from_name "$f")
  iso_local_w_space="${t[0]}"; iso_local="${t[1]}"; iso_utc="${t[2]}"
  tc=$(probe_timecode "$f")
  kind=$(source_kind "$f")

  # Decide CFR per file
  __OLD_NUM=$TARGET_FPS_NUM; __OLD_DEN=$TARGET_FPS_DEN; __OLD_LABEL=$TARGET_FPS_LABEL

  if [[ "$kind" == dv || "$kind" == mpeg2 ]]; then
    TARGET_FPS_NUM=60000; TARGET_FPS_DEN=1001; TARGET_FPS_LABEL="59.94"
  elif [[ "$kind" == h264 || "$kind" == hevc || "$kind" == prores ]]; then
    src_fps=$(probe_fps_float "$f")
    diff30=$(awk -v a="$src_fps" 'BEGIN{print (a>29.97003)?a-29.97003:29.97003-a}')
    diff60=$(awk -v a="$src_fps" 'BEGIN{print (a>59.94006)?a-59.94006:59.94006-a}')
    if awk -v d30="$diff30" -v d60="$diff60" 'BEGIN{exit (d30<=d60)?0:1}'; then
      TARGET_FPS_NUM=30000; TARGET_FPS_DEN=1001; TARGET_FPS_LABEL="29.97"
    else
      TARGET_FPS_NUM=60000; TARGET_FPS_DEN=1001; TARGET_FPS_LABEL="59.94"
    fi
  else
    if (( AUTO_RATE )); then
      TARGET_FPS_NUM=${FOLDER_NUM:-$TARGET_FPS_NUM}; TARGET_FPS_DEN=${FOLDER_DEN:-$TARGET_FPS_DEN}; TARGET_FPS_LABEL=${FOLDER_LABEL:-$TARGET_FPS_LABEL}
    fi
  fi

  log "Processing: $f (kind=$kind, target_fps=$TARGET_FPS_LABEL)"

  case "$kind" in
    dv)      process_dv     "$f" "$base" "$iso_local_w_space" "$iso_local" "$iso_utc" "$tc" ;;
    mpeg2)   process_mpeg2  "$f" "$base" "$iso_local_w_space" "$iso_local" "$iso_utc" "$tc" ;;
    h264)    process_h264   "$f" "$base" "$iso_local_w_space" "$iso_local" "$iso_utc" "$tc" ;;
    hevc)    process_hevc   "$f" "$base" "$iso_local_w_space" "$iso_local" "$iso_utc" "$tc" ;;
    prores)  process_prores "$f" "$base" "$iso_local_w_space" "$iso_local" "$iso_utc" "$tc" ;;
    *)       process_other  "$f" "$base" "$iso_local_w_space" "$iso_local" "$iso_utc" "$tc" ;;
  esac

  TARGET_FPS_NUM=$__OLD_NUM; TARGET_FPS_DEN=$__OLD_DEN; TARGET_FPS_LABEL=$__OLD_LABEL
  } & pid=$!
  PIDS+=("$pid")
done

# Wait for all remaining encode PIDs
for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done

# Aggregate stats from temp file
if [[ -f "$STATS_FILE" ]]; then
  CREATED_PRORES=$(grep -c '^created_prores$' "$STATS_FILE" || true)
  CREATED_FFV1=$(grep -c '^created_ffv1$' "$STATS_FILE" || true)
  SKIPPED_WHOLE=$(grep -c '^skipped_whole$' "$STATS_FILE" || true)
  SKIPPED_EXISTING_OUTPUTS=$(grep -c '^skipped_output$' "$STATS_FILE" || true)
  rm -f "$STATS_FILE" || true
fi

# Summary
if (( MIRROR )); then
  if   (( PRORES_ONLY )); then log "Done. ProRes MOVs under: $TRANS_ROOT/prores422hq/..."; 
  elif (( ARCHIVE_ONLY )); then log "Done. FFV1 MKVs under: $TRANS_ROOT/ffv1/..."; 
  else log "Done. Outputs mirrored under: $TRANS_ROOT/{prores422hq,ffv1}/..."; fi
else
  if   (( PRORES_ONLY )); then log "Done. ProRes → $edit_out_dir";
  elif (( ARCHIVE_ONLY )); then log "Done. FFV1 → $archive_out_dir";
  else log "Done. ProRes → $edit_out_dir, FFV1 → $archive_out_dir"; fi
fi

# Resumability summary
log "Summary: files=${TOTAL_FILES} created_prores=${CREATED_PRORES} created_ffv1=${CREATED_FFV1} skipped_whole=${SKIPPED_WHOLE} skipped_outputs=${SKIPPED_EXISTING_OUTPUTS}"
