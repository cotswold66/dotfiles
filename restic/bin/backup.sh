#!/bin/bash

# Setting this, so the repo does not need to be given on the commandline:
if [ $1 == 'saturn' ]
then
  export RESTIC_REPOSITORY='rest:http://192.168.1.2:8000/'
elif [ $1 == 'b2' ]
then
  export RESTIC_REPOSITORY='b2:jl-restic'
  export B2_ACCOUNT_ID=$(pass b2/ID)
  export B2_ACCOUNT_KEY=$(pass b2/KEY)
else
  echo 'Attibute options are "saturn" or "b2"'
  exit 1
fi
export RESTIC_PASSWORD_COMMAND='pass backup/pluto'

# some helpers and error handling:
info() { printf "\n%s %s\n\n" "$( date )" "$*" >&2; }
trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM

info "Starting backup"

# Backup the most important directories into an archive named after
# the machine this script is currently running on:

restic backup                                          \
    --verbose                                          \
    --exclude-caches                                   \
    --exclude-file=$HOME/bin/excludes.txt \
    $HOME/ 

backup_exit=$?


info "Pruning repository"

# Use the `prune` subcommand to maintain 2 hourly, 7 daily, 4 weekly, 6 monthly, and 2 yearly
# archives of THIS machine. The '{hostname}-' prefix is very important to
# limit prune's operation to this machine's archives and not apply to
# other machines' archives also:

restic forget                       \
    --keep-last     1               \
    --keep-hourly   2               \
    --keep-daily    7               \
    --keep-weekly   4               \
    --keep-monthly  6               \
    --keep-yearly   2               \
    --prune                         \

prune_exit=$?

# use highest exit code as global exit code
global_exit=$(( backup_exit > prune_exit ? backup_exit : prune_exit ))

if [ ${global_exit} -eq 0 ]; then
    info "Backup and Prune finished successfully"
elif [ ${global_exit} -eq 1 ]; then
    info "Backup and/or Prune finished with warnings"
else
    info "Backup and/or Prune finished with errors"
fi

exit ${global_exit}
