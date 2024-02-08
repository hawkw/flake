# shellcheck shell=bash
rsync \
    -Cazh \
    --exclude="target/*" \
    --exclude="out/*" \
    --delete \
    --progress \
    . "${USER}@atrium.eng.oxide.computer:/home/${USER}/${PWD##*/}"