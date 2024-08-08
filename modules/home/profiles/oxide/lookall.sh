# shellcheck shell=bash
# look at all Nexus logs.
#
# the first argument is the SSH host for the switch zone (e.g. madridswitch,
# londonswitch, etc), and the remainder is passed into `looker`

host=$1
shift

ssh "$host" pilot host exec \
    -c '/opt/oxide/oxlog/oxlog zones | grep nexus | xargs -L 1 /opt/oxide/oxlog/oxlog logs --current | xargs -L 1 cat' \
    0-31 \
    | looker "$@"
