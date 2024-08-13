# shellcheck shell=bash
# look at all Nexus logs.
#
# the first argument is the SSH host for the switch zone (e.g. madridswitch,
# londonswitch, etc), and the remainder is passed into `looker`
set -x
host=$1
shift

# we disable SC2029 because shellcheck (rightly!) warns us that "$cmd" is expanded
# on the client side, rather than on the server. but, we *want* that here -- we
# want to forward the arguments to this script as a command to run on the remote
# box.
# shellcheck disable=SC2029
ssh "$host" "pilot host exec -O -c '/opt/oxide/oxlog/oxlog zones | grep nexus | xargs -L 1 /opt/oxide/oxlog/oxlog logs --current | xargs -L 1 cat' 0-31 | looker $*"
