#!/bin/bash

# rename_media_files.sh — rename media files based on their EXIF timestamps.
#
# Usage: rename_media_files.sh [--commit] <directory>
#   • Without --commit (default dry-run) it walks the tree, reports proposed
#     filenames, destination folders, and highlights metadata sources or gaps.
#   • With --commit it creates codec/format folders (dv, mpeg2, h264, hevc,
#     prores422hq, prores, jpg, png, dng, heic) under the target directory and
#     moves renamed files into them.
#
# The script inspects MOV/MP4/DNG/JPG/JPEG/PNG/HEIC/HEIF files, preferring
# creation/original timestamp tags and embedded timezone offsets when present,
# and falls back to each file's modified timestamp if metadata is missing.
# Output filenames follow YYYYMMDD_HHMMSS-OFFF.ext, de-duped with counters.


mode="dry-run"
[[ "$1" == "--commit" ]] && { mode="commit"; shift; }

root_dir="${1:-.}"
if [[ ! -d "$root_dir" ]]; then
  echo "ERROR: Target must be a directory (got: $root_dir)" >&2
  exit 1
fi
root_dir=$(cd "$root_dir" && pwd)

find "$root_dir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.mov' -o -iname '*.mp4' -o -iname '*.dng' -o -iname '*.heic' -o -iname '*.heif' \) -print0 | \
while IFS= read -r -d '' file; do
  ext="${file##*.}"
  ext_lc=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  # Initialize
  datetime=""
  offset=""
  tag_used=""
  offset_tag=""
  raw_datetime=""
  raw_offset=""
  codec=""
  category=""

  case "$ext_lc" in
    mov|mp4)
      datetime=$(exiftool -CreationDate "$file")
      tag_used="CreationDate"
      [[ -z "$datetime" || "$datetime" == *"CreationDate"* && "$datetime" == *": "* ]] && {
        datetime=$(exiftool -ContentCreateDate "$file")
        tag_used="ContentCreateDate"
      }
      raw_datetime=$(echo "$datetime" | awk -F': ' '{print $2}')
      raw_offset=$(echo "$raw_datetime" | grep -oE '[+-][0-9]{2}:[0-9]{2}$')
      offset_tag="$tag_used (embedded)"
      codec=$(exiftool -s3 -VideoCodec "$file")
      [[ -z "$codec" ]] && codec=$(exiftool -s3 -CodecID "$file")
      [[ -z "$codec" ]] && codec=$(exiftool -s3 -CompressorName "$file")
      ;;
    dng|jpg|jpeg|png)
      datetime=$(exiftool -DateTimeOriginal "$file")
      offset=$(exiftool -OffsetTimeOriginal "$file")
      tag_used="DateTimeOriginal"
      offset_tag="OffsetTimeOriginal"
      raw_datetime=$(echo "$datetime" | awk -F': ' '{print $2}')
      raw_offset=$(echo "$offset" | awk -F': ' '{print $2}')
      ;;
    heic|heif)
      for tag in SubSecDateTimeOriginal SubSecCreateDate SubSecModifyDate; do
        datetime=$(exiftool -"$tag" "$file")
        [[ -n "$datetime" ]] && { tag_used="$tag"; break; }
      done
      if [[ -z "$datetime" ]]; then
        datetime=$(exiftool -CreationDate "$file")
        tag_used="CreationDate"
      fi
      raw_datetime=$(echo "$datetime" | awk -F': ' '{print $2}')
      raw_offset=$(echo "$raw_datetime" | grep -oE '[+-][0-9]{2}:[0-9]{2}$')
      offset_tag="$tag_used (embedded)"
      ;;
    *)
      echo "SKIP: Unsupported extension for $file"
      continue
      ;;
  esac

  # Fallback: use file modified time when metadata is missing
  if [[ -z "$raw_datetime" ]]; then
    fallback_datetime=$(date -r "$file" "+%Y:%m:%d %H:%M:%S" 2>/dev/null)
    if [[ -n "$fallback_datetime" ]]; then
      fallback_offset_raw=$(date -r "$file" "+%z" 2>/dev/null)
      if [[ -n "$fallback_offset_raw" ]]; then
        fallback_offset="${fallback_offset_raw:0:3}:${fallback_offset_raw:3:2}"
        raw_offset="$fallback_offset"
        raw_datetime="$fallback_datetime $fallback_offset"
      else
        raw_datetime="$fallback_datetime"
      fi
      datetime="FileModifyDate: $raw_datetime"
      tag_used="FileModifyDate"
      offset_tag="FileModifyDate (derived)"
    fi
  fi

  # Skip if no timestamp
  if [[ -z "$raw_datetime" ]]; then
    echo "SKIP: No timestamp found for $file"
    continue
  fi

  # Extract date and time parts
  date_part=$(echo "$raw_datetime" | awk '{print $1}' | sed 's/://g')
  time_part=$(echo "$raw_datetime" | awk '{print $2}' | cut -d'-' -f1 | sed 's/://g')
  # If time_part includes a dot (e.g. 144750.937), strip subseconds
  if [[ "$time_part" =~ ^[0-9]{6}\.[0-9]+$ ]]; then
      time_part="${time_part%%.*}"
  fi

  # Normalize offset: ±ZZZZ
  norm_offset=$(echo "$raw_offset" | sed 's/://; s/^+//; s/^-//')

  # Final filename
  norm_date="${date_part}_${time_part}-${norm_offset}"
  proposed="${norm_date}.${ext_lc}"

  # Collision-safe renaming
  case "$ext_lc" in
    mov|mp4)
      codec_lc_raw=$(echo "$codec" | tr '[:upper:]' '[:lower:]')
      codec_lc=${codec_lc_raw//[[:space:]]/}
      if [[ "$codec_lc" == *"hevc"* || "$codec_lc" == *"h.265"* || "$codec_lc" == *"h265"* || "$codec_lc" == *"x265"* || "$codec_lc" == *"hvc1"* || "$codec_lc" == *"hev1"* || "$codec_lc" == *"highefficiency"* ]]; then
        category="hevc"
      elif [[ "$codec_lc" == *"h.264"* || "$codec_lc" == *"avc"* || "$codec_lc" == *"x264"* || "$codec_lc" == *"avc1"* || "$codec_lc" == *"avc2"* || "$codec_lc" == *"h264"* ]]; then
        category="h264"
      elif [[ "$codec_lc" == *"422hq"* || "$codec_lc" == *"apch"* ]]; then
        category="prores422hq"
      elif [[ "$codec_lc" == *"prores"* || "$codec_lc" == *"apcn"* || "$codec_lc" == *"apcs"* || "$codec_lc" == *"apco"* || "$codec_lc" == *"ap4h"* ]]; then
        category="prores"
      elif [[ "$codec_lc" == *"mpeg-2"* || "$codec_lc" == *"mpeg 2"* || "$codec_lc" == *"mpeg2"* ]]; then
        category="mpeg2"
      elif [[ "$codec_lc" == *"dv"* || "$codec_lc" == *"dvcpro"* || "$codec_lc" == *"dvc"* ]]; then
        category="dv"
      fi
      if [[ -z "$category" ]]; then
        if [[ "$ext_lc" == "mov" ]]; then
          category="prores"
        else
          category="h264"
        fi
      fi
      ;;
    jpg|jpeg)
      category="jpg"
      ;;
    png)
      category="png"
      ;;
    dng)
      category="dng"
      ;;
    heic|heif)
      category="heic"
      ;;
    *)
      category="other"
      ;;
  esac

  dest_dir="$root_dir/$category"
  base="$proposed"
  count=1
  while [[ -e "$dest_dir/$base" ]]; do
    base="${norm_date}_$count.${ext_lc}"
    ((count++))
  done

  # Output
  echo "FILE: $file"
  echo "→ Proposed filename: $base"
  echo "→ Destination folder: $dest_dir"
  [[ -n "$codec" ]] && echo "→ Detected codec: $codec"
  echo "→ Timestamp tag used: $tag_used"
  echo "$time_part"
  echo "$datetime"
  if [[ -n "$offset" ]]; then
    echo "→ Offset tag used: $offset_tag"
    echo "$offset"
  elif [[ -n "$raw_offset" ]]; then
    echo "→ Offset embedded in timestamp"
  else
    echo "⚠️  No timezone offset found — timestamp may be local time only"
  fi

  # Rename if in commit mode
  if [[ "$mode" == "commit" ]]; then
    mkdir -p "$dest_dir"
    mv "$file" "$dest_dir/$base"
    echo "✅ RENAMED"
  else
    echo "🧪 Dry-run: no changes made"
  fi
  echo
done
