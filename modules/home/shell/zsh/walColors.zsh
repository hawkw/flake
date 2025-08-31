
# test if SSH connection
if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    SESSION_TYPE=remote/ssh
else
    case $(ps -o comm= -p "$PPID") in
        sshd|*/sshd) SESSION_TYPE=remote/ssh;;
    esac
fi

 # Import colorscheme from 'wal' asynchronously, if the terminal is
 # alacritty, and the current session is not a SSH session.
 if [[ -z "${SESSION_TYPE+x}" ]]; then
     (cat "${HOME}/.cache/wal/sequences" &)
 fi
