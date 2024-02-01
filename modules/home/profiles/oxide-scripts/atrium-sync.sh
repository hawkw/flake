# shellcheck shell=bash
rsync \
    -Cazh \
    --exclude="target/*" \
    --delete \
    --progress \
    . "${USER}@atrium.eng.oxide.computer:/home/${USER}/${PWD##*/}"