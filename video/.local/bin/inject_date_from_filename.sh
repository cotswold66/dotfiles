#!/bin/bash
set -euo pipefail

TARGET_DIR="${1:-.}"

echo "🔍 Dry-run: previewing DateTimeOriginal + OffsetTimeOriginal injection..."
exiftool -ext jpg -r -p '$FileName → ${FileName; s/^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})-([+-]\d{2})(\d{2})\.jpg$/$1:$2:$3 $4:$5:$6 (offset: $7:$8)/}' "$TARGET_DIR"

read -rp $'\nProceed with metadata injection? [y/N] ' CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "🛠️ Committing DateTimeOriginal + OffsetTimeOriginal injection..."
  exiftool -overwrite_original \
    '-DateTimeOriginal<${FileName; s/^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})-[+-]\d{4}\.jpg$/$1:$2:$3 $4:$5:$6/}' \
    '-OffsetTimeOriginal<${FileName; s/^.*-([+-]\d{2})(\d{2})\.jpg$/$1:$2/}' \
    '-CreateDate<DateTimeOriginal' \
    '-ModifyDate<DateTimeOriginal' \
    -ext jpg -r "$TARGET_DIR"
  echo "✅ Metadata injection complete."
else
  echo "❌ Aborted. No changes made."
fi
