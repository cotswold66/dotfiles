#!/bin/bash

find "$1" -type f  -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.mov' -o -iname '*.mp4' -o -iname '*.dng' -o -iname '*.heic' -o -iname '*.heif'  | while read -r file; do
  ext="${file##*.}"
  ext_lc=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  # Initialize
  datetime=""
  offset=""
  tag_used=""
  offset_tag=""
  raw_datetime=""
  raw_offset=""

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
      # Try composite tags first
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

  # Skip if no timestamp
  if [[ -z "$raw_datetime" ]]; then
    echo "SKIP: No timestamp found for $file"
    continue
  fi

  # Normalize timestamp: YYYYMMDD_HHMMSS
  norm_date=$(echo "$raw_datetime" | sed 's/:/-/;s/:/-/' | awk '{print $1 "_" $2}' | sed 's/-//g;s/://g')

  # Normalize offset: ±ZZZZ
  norm_offset=$(echo "$raw_offset" | sed 's/://')

  # Proposed filename
  proposed="${norm_date}${norm_offset}"

  # Output
  echo "FILE: $file"
  echo "→ Proposed filename: $proposed"
  echo "→ Timestamp tag used: $tag_used"
  echo "$datetime"
  if [[ -n "$offset" ]]; then
    echo "→ Offset tag used: $offset_tag"
    echo "$offset"
  elif [[ -n "$raw_offset" ]]; then
    echo "→ Offset embedded in timestamp"
  else
    echo "⚠️  No timezone offset found — timestamp may be local time only"
  fi
  echo
done
