# shellcheck shell=bash
rsync \
    -Cazh \
    --exclude="target/*" \
    --exclude="out/*" \
    --delete \
    --progress \
    . "${USER}@atrium:/home/${USER}/${PWD##*/}"
