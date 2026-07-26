{ config, pkgs, lib, ... }:

let
  cfg = config.profiles.git;
  enable1PasswordSshAgent = config.programs._1password-gui.enableSshAgent;
in
with lib; {
  options = {
    profiles.git = {
      enable = mkEnableOption "custom git configs";
      user = {
        name = mkOption {
          type = with types; uniq str;
          description = "Git user name";
        };
        email = mkOption {
          type = with types; uniq str;
          description = "Git user email";
        };
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [{
    programs = {
      # GitHub CLI tool
      gh = {
        enable = true;
        # settings = {
        #   # use ssh whenever possible
        #   git_protocol = "ssh";
        #   aliases = {
        #     co = "pr checkout";
        #     pv = "pr view";
        #   };
        # };

      };

      git = {
        enable = true;
        settings = {
          user = {
            name = cfg.user.name;
            email = cfg.user.email;
          };

          # use rebase in `git pull` to avoid gross merge commits.
          pull.rebase = true;
          push.autoSetupRemote = true;
          # when fetching, prune unreachable objects in the local repository.
          fetch.prune = true;
          # differentiate between moved and added lines in diffs
          diff.colorMoved = "zebra";
          core = {
            # Assembly-style commit message comments (`;` as the comment delimiter).
            # Why use `;`?
            # - The default character, `#`, conflicts with both Markdown headings
            #   and with GitHub issue links beginning a line (which I need to be
            #   able to use in commit messages).
            # - `*` conflicts with Markdown lists
            # - Git only supports a single character comment delimiter, so C-style
            #   line comments (`//`) are out...
            # - I can't think of any compelling reason to begin a line with `;`...
            commentchar = ";";
            editor = lib.mkDefault config.home.sessionVariables.EDITOR;
          };
          # Set the default branch name to `main`.
          init.defaultBranch = "main";
          commit.gpgsign = true;
        };

        # aliases
        settings.alias = {
          # list all aliases
          aliases = "config --get-regexp '^alias.'";

          ### short aliases for common commands ###
          co = "checkout";
          ci = "commit";
          rb = "rebase";
          rbct = "rebase --continue";
          please = "push --force-with-lease";
          commend = "commit --amend --no-edit";

          ### nicer commit and branch verbs ###
          squash = "merge --squash";
          # Get the current branch name (not so useful in itself, but used in
          # other aliases)
          branch-name = "!git rev-parse --abbrev-ref HEAD";
          # Push the current branch to the remote "origin", and set it to track
          # the upstream branch
          publish = "!git push -u origin $(git branch-name)";
          # Delete the remote version of the current branch
          unpublish = "!git push origin :$(git branch-name)";
          # sign the last commit
          sign = "commit --amend --reuse-message=HEAD -sS";
          uncommit = "reset --hard HEAD";
          # XXX(eliza) AGH THIS DOESNT WORK
          # # Gets the parent of the current branch.
          # parent = ''
          #   show-branch -a \
          #     | grep '\*' \
          #     | grep -v `git rev-parse --abbrev-ref HEAD` \
          #     | head -n1 \
          #     | sed 's/.*\[\(.*\)\].*/\1/' \
          #     | sed 's/[\^~].*//'
          # '';

          ### various git log aliases ###
          # `ls` and `ll` are broken under the latest git for reasons i don't
          # really understand...fortunately i don'tactually use them.
          # ls =
          # "log --pretty=format:'%C(yellow)%h%Cred%d\\ %Creset%s%Cblue\\ [%cn]' --decorate";
          # ll =
          # "log --pretty=format:'%C(yellow)%h%Cred%d\\ %Creset%s%Cblue\\ [%cn]' --decorate --numstat";
          lt = "log --graph --oneline --decorate --all";
          summarize-branch = ''
            log --pretty=format:'* %h %s%n%n%w(72,2,2)%bz' --decorate
          '';
          lol = "log --graph --decorate --pretty=oneline --abbrev-commit";
          lola =
            "log --graph --decorate --pretty=oneline --abbrev-commit --all";

          ### status ###
          st = "status --short --branch";
          stu = "status -uno";

          pr =
            "!pr() { git fetch origin pull/$1/head:pr-$1; git checkout pr-$1; }; pr";
        };

        # default gitignores for all repos
        ignores = [
          ".cargo/"
          ".direnv/"
        ];

        signing = {
          format = "ssh";
          # The 1Password SSH key. Only set this as the signing key if 1Password
          # ssh agent is enabled, since otherwise, it won't exist. When this is
          # not enabled, git falls back to gpg.ssh.defaultKeyCommand, which
          # picks a YubiKey (below).
          key = mkIf enable1PasswordSshAgent
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICNWunZTkQnvkKi6gbeRfOXaIg4NL0OiE0SIXosxRP6s";
        };
      };
    };
  }
    (mkIf enable1PasswordSshAgent (
      let
        signingScript =
          with pkgs; writeShellApplication {
            name = "ssh-sign";
            runtimeInputs = [ _1password-gui ];
            # If we're not in a SSH session, use `op-ssh-sign` to sign commits.
            # Otherwise, use `ssh-keygen` to sign commits with a forwarded key
            # in `SSH_AUTH_SOCK`.
            text = ''
              if [ -z "''${SSH_CONNECTION-}" ]; then
                exec "op-ssh-sign" "$@"
              else
                exec ssh-keygen "$@"
              fi
            '';
          };
      in
      {
        home.packages = [ signingScript ];
        programs.git.settings.gpg."ssh".program = "ssh-sign";
      }
    ))
    # YubiKey commit signing.
    #
    # Any enrolled YubiKey may be plugged into any machine, so the signing key
    # cannot be pinned statically. Instead, we use `gpg.ssh.defaultKeyCommand`
    # to pick one at signing time. Git runs this command when user.signingKey is
    # unset, and expects `ssh-add -L`-shaped output.
    #
    # This script selects keys in the following order of presence:
    #
    #   1. A key that is *physically present* and whose handle file is present
    #      in ~/.ssh. If the handle isn't in the ssh agent yet, it is
    #      `ssh-add`ed first, prompting for the keyfile passphrase exactly as
    #      AddKeysToAgent does on first ssh. This is necessary because git
    #      signing uses the ssh-agent.
    #   2. Otherwise, any enrolled key already in the agent. This is the
    #      case when the agent is forwarded to a remote host.
    #   3. Otherwise, fail with instructions.
    (mkIf (!enable1PasswordSshAgent) (
      let
        yubikeys = import ../../../lib/yubikeys.nix { inherit lib; };
        # "<type> <blob>" per enrolled key, one per line, for matching
        # against `ssh-add -L` output (comments differ between agent and
        # repo, so match on the first two fields only).
        registeredKeys =
          let
            typeAndBlob = k: concatStringsSep " " (take 2 (splitString " " k));
            keyLines = map typeAndBlob yubikeys.ssh.pubkeys;
          in
          concatStringsSep "\n" keyLines;
        # `serial) handle=...; pubkey=...;;` stanzas for the case statement.
        serialCases =
          let
            mkCase = (serial: key: ''
              ${serial})
                handle=${escapeShellArg key.privkeyFilename}
                pubkey=${escapeShellArg key.pubkey}
                ;;
            '');
            cases = mapAttrsToList mkCase yubikeys.ssh.bySerial;
          in
          concatStrings cases;
        signingKeyCommand = pkgs.writeShellApplication {
          name = "yk-git-signing-key";
          runtimeInputs = with pkgs; [ openssh coreutils gnugrep ];
          text = ''
            ${yubikeys.usb.serialFunctions}

            # Which enrolled YubiKeys are physically present?
            present_serials() {
              local d
              # first, try to detect which keys are present using the
              # /dev/yubikeys/ symlinks
              if [ -d /dev/yubikeys ]; then
                for d in /dev/yubikeys/*; do
                  [ -e "$d" ] || continue
                  basename "$d"
                done
                return 0
              fi
              # if nothing's there, fall back to walking sysfs in case the udev
              # rule is messed up.
              sysfs_yk_serials
            }

            AGENT_KEYS="$(ssh-add -L 2>/dev/null | cut -d' ' -f1,2)" || AGENT_KEYS=""

            in_agent() {
              [ -n "$AGENT_KEYS" ] && grep -qxF "$1" <<< "$AGENT_KEYS"
            }

            # 1. A plugged-in enrolled key whose handle is present here.
            for serial in $(present_serials); do
              handle=""
              pubkey=""
              case "$serial" in
                ${serialCases}
                *) continue;;
              esac
              if [ ! -f "$HOME/.ssh/$handle" ]; then
                echo "yk-git-signing-key: YubiKey $serial is plugged in, but ~/.ssh/$handle" >&2
                echo "is not on this machine; restore it from 1Password to sign with it." >&2
                continue
              fi
              if ! in_agent "$(cut -d' ' -f1,2 <<< "$pubkey")"; then
                # Load the handle into the agent (prompts for the keyfile
                # passphrase).
                ssh-add "$HOME/.ssh/$handle" >&2 || continue
              fi
              printf '%s\n' "$pubkey"
              exit 0
            done

            # 2. Any enrolled key already in the agent (ForwardAgent case).
            while read -r keyline; do
              [ -n "$keyline" ] || continue
              if grep -qxF "$keyline" <<< ${escapeShellArg registeredKeys}; then
                printf '%s\n' "$keyline"
                exit 0
              fi
            done <<< "$AGENT_KEYS"

            echo "yk-git-signing-key: no YubiKey SSH key available for signing." >&2
            echo "either plug in an enrolled YubiKey (with its key handle restored" >&2
            echo "to ~/.ssh), or connect with a forwarded agent that holds one." >&2
            exit 1
          '';
        };
      in
      {
        home.packages = [ signingKeyCommand ];
        programs.git.settings.gpg."ssh".defaultKeyCommand = getExe signingKeyCommand;
      }
    ))]);
}
