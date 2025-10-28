#!/bin/bash
set -euo pipefail

## 🧠 Load secrets from macOS Keychain
load_secrets() {
  RESTIC_PASSWORD="$(security find-generic-password -a restic -s restic-password -w 2>/dev/null || true)"
  B2_ACCOUNT_ID="$(security find-generic-password -a restic -s b2-account-id -w 2>/dev/null || true)"
  B2_ACCOUNT_KEY="$(security find-generic-password -a restic -s b2-account-key -w 2>/dev/null || true)"

  if [[ -z "$RESTIC_PASSWORD" ]]; then
    echo "❌ Missing RESTIC_PASSWORD for profile '$profile'" >&2
    exit 1
  fi

  export RESTIC_PASSWORD B2_ACCOUNT_ID B2_ACCOUNT_KEY
}

## CONFIG
SOURCE_DIR="$HOME"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <saturn|b2>" >&2
  exit 2
fi

PROFILE="$1"
load_secrets "$PROFILE"

if [[ "$PROFILE" == 'saturn' ]]; then
  export RESTIC_REPOSITORY='sftp:john@saturn:/srv/backup/restic'
elif [[ "$PROFILE" == 'b2' ]]; then
  export RESTIC_REPOSITORY='b2:jl-restic'
else
  echo 'Attribute options are "saturn" or "b2"' >&2
  exit 1
fi

SNAPSHOT_LABEL="mars-$(date +%Y%m%d-%H%M%S)"

## 🧼 Snapshot ZFS repo on Debian before backup
ssh john@saturn "zfs snapshot spool/backup/restic@$SNAPSHOT_LABEL"

## 🧯 Run restic backup
restic backup "$SOURCE_DIR" \
    --exclude-file ~/.local/etc/backup-excludes.txt \
    --host "mars" \
    --verbose \
    --exclude-caches \
    --one-file-system \
    --tag "John's MacBook Pro"

info() { printf "\n%s %s\n\n" "$( date )" "$*" >&2; }
trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM

backup_exit=$?

info "Pruning repository"

restic forget \
    --keep-last     1 \
    --keep-hourly   2 \
    --keep-daily    7 \
    --keep-weekly   4 \
    --keep-monthly  6 \
    --keep-yearly   2 \
    --prune

prune_exit=$?

global_exit=$(( backup_exit > prune_exit ? backup_exit : prune_exit ))

if [ ${global_exit} -eq 0 ]; then
    info "Backup and Prune finished successfully"
elif [ ${global_exit} -eq 1 ]; then
    info "Backup and/or Prune finished with warnings"
else
    info "Backup and/or Prune finished with errors"
fi

exit ${global_exit}
