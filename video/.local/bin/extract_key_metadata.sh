#!/bin/bash

INPUT_DIR="$(pwd)"
LOG_DIR="$INPUT_DIR/metadata_logs"
CSV_FILE="$LOG_DIR/summary.csv"

mkdir -p "$LOG_DIR"
echo "Filename,Model,Duration,Keys:CreationDate,FileCreationDate,MediaCreateDate,CreateDate_field,ModifyDate,DateTimeOriginal,InitialTimecode" > "$CSV_FILE"

for FILE in "$INPUT_DIR"/*; do
    [ -f "$FILE" ] || continue

    BASENAME=$(basename "$FILE")
    NAME="${BASENAME%.*}"

    # Full metadata log
    exiftool -a -u -g1 "$FILE" > "$LOG_DIR/${NAME}_metadata.txt"

    # Extract fields
    MODEL=$(exiftool -s -s -s -Model "$FILE")
    DURATION=$(exiftool -s -s -s -Duration "$FILE")
    KEYSDATE=$(exiftool -s -s -s -"Keys:CreationDate" "$FILE")
    FILECREATED=$(exiftool -s -s -s -FileCreationDate "$FILE")
    MEDIADATE=$(exiftool -s -s -s -MediaCreateDate "$FILE")
    CREATE_FIELD=$(exiftool -s -s -s -CreateDate "$FILE")
    MODIFY_FIELD=$(exiftool -s -s -s -ModifyDate "$FILE")
    ORIGINAL_FIELD=$(exiftool -s -s -s -DateTimeOriginal "$FILE")
    TIMECODE=$(exiftool -s -s -s -TimeCode "$FILE")

    # Append to CSV
    echo "\"$BASENAME\",\"$MODEL\",\"$DURATION\",\"$KEYSDATE\",\"$FILECREATED\",\"$MEDIADATE\",\"$CREATE_FIELD\",\"$MODIFY_FIELD\",\"$ORIGINAL_FIELD\",\"$TIMECODE\"" >> "$CSV_FILE"

    echo "📁 Logged with system creation date: $BASENAME"
done
