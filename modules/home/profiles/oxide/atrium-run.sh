# shellcheck shell=bash

# sync the current working dir with Atrium.
atrium-sync

# build the command line to run on Atrium.
# source the `.bashrc` because we are essentially pretending to be an
# interactive shell, and set CARGO_TERM_COLOR, so that cargo also realizes that
# we are pretending to be an interactive shell.
CMD="source ~/.bashrc && \
    export CARGO_TERM_COLOR=always && \
    cd /home/${USER}/${PWD##*/} && \
    $*"

# we disable SC2029 because shellcheck (rightly!) warns us that "$@" is expanded
# on the client side, rather than on the server. but, we *want* that here -- we
# want to forward the arguments to this script as a command to run on the remote
# box.
# shellcheck disable=SC2029
ssh "${USER}@atrium" "${CMD}"
