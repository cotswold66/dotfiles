#!/bin/bash

mode="dry-run"
[[ "$1" == "--commit" ]] && { mode="commit"; shift; }

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
  dir=$(dirname "$file")
  base="$proposed"
  count=1
  while [[ -e "$dir/$base" ]]; do
    base="${norm_date}_$count.${ext_lc}"
    ((count++))
  done

  # Output
  echo "FILE: $file"
  echo "→ Proposed filename: $base"
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
    # Embed original filename as metadata
    exiftool -overwrite_original \
             -XPComment="${file##*/}" \
             -UserComment="Original filename: ${file##*/}" \
             "$file"

    mv "$file" "$dir/$base"
    echo "✅ RENAMED"
  else
    echo "🧪 Dry-run: no changes made"
  fi
  echo
done
