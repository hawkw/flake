
# test if SSH connection
if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    SESSION_TYPE=remote/ssh
else
    case $(ps -o comm= -p "$PPID") in
        sshd|*/sshd) SESSION_TYPE=remote/ssh;;
    esac
fi

# Import colorscheme from 'wal' asynchronously, if it exists and is readable and
# the current session is not a SSH session. Honor XDG_CACHE_HOME, falling back
# to $HOME/.cache only when it is unset.
SEQUENCES="${XDG_CACHE_HOME:-$HOME/.cache}/wal/sequences"
if [[ -z "${SESSION_TYPE+x}" ]] && [[ -r "$SEQUENCES" ]]; then
    (cat "$SEQUENCES" &)
fi
