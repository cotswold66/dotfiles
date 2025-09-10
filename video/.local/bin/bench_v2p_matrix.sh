#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Bench a matrix of settings for video_to_prores.sh
# - Times each run and parses the script's Summary line
# - Writes CSV results and prints a sorted summary

usage() {
  cat <<'USAGE'
bench_v2p_matrix.sh — run timing matrix for video_to_prores.sh

Usage:
  ./bench_v2p_matrix.sh [options] -- <v2p extra args>

Required:
  -i, --input DIR            Input directory (same arg you pass to v2p)

Optional (defaults shown):
  --v2p PATH                 Path to video_to_prores.sh (auto: ./video_to_prores.sh or in PATH)
  --jobs-set "1 2 3"         Space-separated JOBS values
  --ffmpeg-threads-set "auto"  Values for --ffmpeg-threads; special: "auto" computes per JOBS
  --filter-threads-set "1"   Values for --filter-threads
  --finalize-set "per-disk parallel"  Modes: per-disk | global | parallel
  --repeats N                Repeat each combo N times (default: 1)
  --force                    Pass --force to v2p (re-encode outputs)
  --tag NAME                 Tag string included in results filename
  --out DIR                  Output dir for logs and CSV (default: ./v2p_bench)

Environment overrides (alternate to flags):
  JOBS_SET, FFMPEG_THREADS_SET, FILTER_THREADS_SET, FINALIZE_SET

Notes:
  - Use -- to pass additional args to v2p (e.g., --mirror, --only-subdirs A,B)
  - If FFMPEG_THREADS_SET is "auto", we derive candidates per JOBS based on core count.
  - Results CSV columns: start,end,elapsed_s,jobs,ffmpeg_threads,filter_threads,finalize,files,created_prores,created_ffv1,skipped_whole,skipped_outputs,exit_code
USAGE
}

die() { echo "ERROR: $*" >&2; exit 2; }

INPUT_DIR=""
V2P_PATH=""
JOBS_SET_DEFAULT=(1 2 3)
FILTER_THREADS_SET_DEFAULT=(1)
FINALIZE_SET_DEFAULT=(per-disk parallel)
REPEATS=1
FORCE_FLAG=0
TAG=""
OUTDIR="./v2p_bench"

JOBS_SET=()
FFMPEG_THREADS_SET_RAW="auto"
FILTER_THREADS_SET=()
FINALIZE_SET=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input) shift; INPUT_DIR=${1:-}; [[ -n "$INPUT_DIR" ]] || die "--input requires a path" ;;
    --v2p) shift; V2P_PATH=${1:-} ;;
    --jobs-set) shift; IFS=' ' read -r -a JOBS_SET <<< "${1:-}" ;;
    --ffmpeg-threads-set) shift; FFMPEG_THREADS_SET_RAW=${1:-} ;;
    --filter-threads-set) shift; IFS=' ' read -r -a FILTER_THREADS_SET <<< "${1:-}" ;;
    --finalize-set) shift; IFS=' ' read -r -a FINALIZE_SET <<< "${1:-}" ;;
    --repeats) shift; REPEATS=${1:-1}; [[ "$REPEATS" =~ ^[0-9]+$ && $REPEATS -ge 1 ]] || die "--repeats must be >=1" ;;
    --force) FORCE_FLAG=1 ;;
    --tag) shift; TAG=${1:-} ;;
    --out) shift; OUTDIR=${1:-} ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
  shift
done

EXTRA_ARGS=("$@")

[[ -n "$INPUT_DIR" ]] || die "--input is required"

# Resolve v2p path
if [[ -z "$V2P_PATH" ]]; then
  if [[ -x ./video_to_prores.sh ]]; then V2P_PATH=./video_to_prores.sh
  else V2P_PATH=$(command -v video_to_prores.sh || true)
  fi
fi
[[ -n "$V2P_PATH" && -x "$V2P_PATH" ]] || die "video_to_prores.sh not found; use --v2p PATH"

mkdir -p "$OUTDIR"
STAMP=$(date +%Y%m%d_%H%M%S)
CSV="$OUTDIR/results_${TAG:+${TAG}_}$STAMP.csv"
LOGDIR="$OUTDIR/logs_${TAG:+${TAG}_}$STAMP"
mkdir -p "$LOGDIR"

# Build sets from env if provided
if [[ ${#JOBS_SET[@]} -eq 0 ]]; then
  if [[ -n "${JOBS_SET:-}" ]]; then :; else JOBS_SET=(${JOBS_SET_DEFAULT[@]}); fi
fi
if [[ ${#FILTER_THREADS_SET[@]} -eq 0 ]]; then
  if [[ -n "${FILTER_THREADS_SET:-}" ]]; then :; else FILTER_THREADS_SET=(${FILTER_THREADS_SET_DEFAULT[@]}); fi
fi
if [[ ${#FINALIZE_SET[@]} -eq 0 ]]; then
  if [[ -n "${FINALIZE_SET:-}" ]]; then :; else FINALIZE_SET=(${FINALIZE_SET_DEFAULT[@]}); fi
fi

# Core count
CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

echo "start,end,elapsed_s,jobs,ffmpeg_threads,filter_threads,finalize,files,created_prores,created_ffv1,skipped_whole,skipped_outputs,exit_code" > "$CSV"

run_once() {
  local jobs=$1 ffth=$2 fth=$3 finmode=$4 rep=$5
  local label="j${jobs}_t${ffth}_ft${fth}_fin${finmode}_r${rep}"
  local log="$LOGDIR/$label.log"
  local start_ts end_ts elapsed exit_code files cp cf sw so
  start_ts=$(date -Iseconds)

  # Build args
  local args=("$V2P_PATH" "${EXTRA_ARGS[@]}" "--jobs" "$jobs" "--ffmpeg-threads" "$ffth" "--filter-threads" "$fth")
  case "$finmode" in
    per-disk) args+=("--finalize-per-disk") ;;
    global)   args+=("--finalize-global") ;;
    parallel) args+=("--finalize-parallel") ;;
  esac
  (( FORCE_FLAG )) && args+=("--force")
  args+=("$INPUT_DIR")

  # Time the run
  if command -v /usr/bin/time >/dev/null 2>&1; then
    /usr/bin/time -f 'elapsed=%e' "${args[@]}" >"$log" 2>&1 || true
    exit_code=$?
    elapsed=$(sed -n 's/^elapsed=//p' "$log" | tail -1)
  else
    local t0 t1
    t0=$(date +%s)
    "${args[@]}" >"$log" 2>&1 || true
    exit_code=$?
    t1=$(date +%s)
    elapsed=$(( t1 - t0 ))
  fi
  end_ts=$(date -Iseconds)

  # Parse summary line
  files=$(sed -n 's/^.*Summary: files=\([0-9]\+\).*/\1/p' "$log" | tail -1)
  cp=$(sed -n 's/^.*created_prores=\([0-9]\+\).*/\1/p' "$log" | tail -1)
  cf=$(sed -n 's/^.*created_ffv1=\([0-9]\+\).*/\1/p' "$log" | tail -1)
  sw=$(sed -n 's/^.*skipped_whole=\([0-9]\+\).*/\1/p' "$log" | tail -1)
  so=$(sed -n 's/^.*skipped_outputs=\([0-9]\+\).*/\1/p' "$log" | tail -1)
  files=${files:-0}; cp=${cp:-0}; cf=${cf:-0}; sw=${sw:-0}; so=${so:-0}

  echo "$start_ts,$end_ts,$elapsed,$jobs,$ffth,$fth,$finmode,$files,$cp,$cf,$sw,$so,$exit_code" >> "$CSV"
  echo "Done: $label (elapsed=${elapsed}s, exit=$exit_code)"
}

# Build ffmpeg threads set per jobs
build_ffmpeg_threads_set() {
  local jobs=$1 raw="$FFMPEG_THREADS_SET_RAW"; local -a out=()
  if [[ "$raw" == "auto" ]]; then
    local base=$(( CORES / jobs ))
    (( base < 1 )) && base=1
    out=(0 "$base" $(( base-1 )))
    # dedupe and keep >=1 or 0
    local -A seen=()
    local -a uniq=()
    for v in "${out[@]}"; do
      [[ "$v" -lt 0 ]] && continue
      if [[ -z "${seen[$v]:-}" ]]; then uniq+=("$v"); seen[$v]=1; fi
    done
    printf '%s\n' "${uniq[@]}"
  else
    IFS=' ' read -r -a out <<< "$raw"
    printf '%s\n' "${out[@]}"
  fi
}

echo "CORES=$CORES" | tee "$OUTDIR/info_${TAG:+${TAG}_}$STAMP.txt"
printf 'JOBS_SET=%s\n' "${JOBS_SET[*]}" | tee -a "$OUTDIR/info_${TAG:+${TAG}_}$STAMP.txt"
printf 'FILTER_THREADS_SET=%s\n' "${FILTER_THREADS_SET[*]}" | tee -a "$OUTDIR/info_${TAG:+${TAG}_}$STAMP.txt"
printf 'FINALIZE_SET=%s\n' "${FINALIZE_SET[*]}" | tee -a "$OUTDIR/info_${TAG:+${TAG}_}$STAMP.txt"
printf 'FFMPEG_THREADS_SET_RAW=%s\n' "$FFMPEG_THREADS_SET_RAW" | tee -a "$OUTDIR/info_${TAG:+${TAG}_}$STAMP.txt"

for jobs in "${JOBS_SET[@]}"; do
  mapfile -t FFMPEG_THREADS_SET < <(build_ffmpeg_threads_set "$jobs")
  for fth in "${FILTER_THREADS_SET[@]}"; do
    for finmode in "${FINALIZE_SET[@]}"; do
      for ffth in "${FFMPEG_THREADS_SET[@]}"; do
        for ((r=1; r<=REPEATS; r++)); do
          run_once "$jobs" "$ffth" "$fth" "$finmode" "$r"
        done
      done
    done
  done
done

echo
echo "Top results (fastest first):"
awk -F, 'NR>1 {printf("%8.2fs  jobs=%-2s  t=%-3s  ft=%-2s  fin=%-8s  files=%-3s  cp=%-3s  cf=%-3s  sw=%-3s  so=%-3s  exit=%s\n", $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)}' "$CSV" | sort -n | sed -n '1,30p'

echo "CSV: $CSV"
echo "Logs: $LOGDIR/"

