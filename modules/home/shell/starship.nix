{ config, lib, ... }:
let
  cfg = config.programs.starship;
in
with lib; {
  config = mkIf cfg.enable {
    programs.starship.settings = {
      # Replace the "❯" symbol in the prompt with ":;"

      # why use ":;" as the prompt character? it is a no-op in most (all?) unix shells, so copying and
      # pasting a command including the prompt character will still work
      character = {
        success_symbol = "[\\$](bold green)";
        error_symbol = "[\\$](bold red)";
      };

      hostname = {
        format = "@[$hostname]($style)";
        ssh_only = false;
      };

      username = {
        format = "[$user]($style)";
        show_always = true;
      };

      directory = {
        truncate_to_repo = false;
        truncation_length = 5;
        truncation_symbol = "…/";
      };

      direnv = {
        disabled = false;
        symbol = "env ";
        format = "$symbol[$loaded$allowed]($style) ";
        style = "bold blue";
        allowed_msg = "";
        not_allowed_msg = " (not allowed)";
      };

      # nodejs.disabled = true;

      kubernetes = {
        # disabled = false;
        format = "on [$symbol$context(\\($namespace\\))]($style) ";
        context_aliases = {
          # OpenShift contexts carry the namespace and user in the kube context: `namespace/name/user`:
          ".*/(?P<var_cluster>[\\w-]+)/.*" = "$var_cluster";

          # Contexts from GKE, AWS and other cloud providers usually carry additional information, like the region/zone.
          # The following entry matches on the GKE format (`gke_projectname_zone_cluster-name`)
          # and renames every matching kube context into a more readable format (`gke-cluster-name`):
          "gke_.*_(?P<var_cluster>[\\w-]+)" = "gke-$var_cluster";
        };
        # detect_files = [ "*.yml" "*.yaml" ];
        detect_folders = [ "linkerd2" "linkerd2-proxy" ];
      };

      rust = {
        symbol = "⚙️ ";
        # i don't like "via" as a way to state the toolchain version.
        format = "using [$symbol($version )]($style)";
      };

      # package.symbol = "";

      # unfortunately, the `sudo` module for starship doesn't work nicely with
      # sudo-rs :(
      # TODO(eliza): sudo-rs.enable is part of the NixOS config, not
      # home-manager...
      # sudo.disabled = config.security.sudo-rs.enable;
      sudo.disabled = true;

      nix_shell = {
        symbol = "❄️ ";
        impure_msg = "[\\(]($style)[±](bold red)[\\)]($style)";
        pure_msg = "";
        format = "in [$symbol$name$state]($style) ";
        # heuristic = true;
      };

      time = {
        disabled = false;
        # style = "bold fg:bright-black bg:green";
        format = "⏲ [$time]($style) ";
      };

      git_branch = {
        # Unicode "alternative key symbol" works nicely as a "git branch"
        # symbol but doesn't require patched fonts.
        symbol = "⎇  ";
      };

      status = {
        disabled = false;
        map_symbol = true;
        pipestatus = true;
        # symbol = "❌";
        not_executable_symbol = "🚫";
        sigint_symbol = "❗";
        not_found_symbol = "❓";

        format = "[$symbol( $common_meaning)( SIG$signal_name)( $maybe_int)]($style)";
        pipestatus_separator = " | ";
        pipestatus_format = "\\[ $pipestatus \\] → [$symbol($common_meaning)(SIG$signal_name)($maybe_int)]($style)";
      };

      format = lib.concatStrings [
        # Start the first line with a shell comment so that the entire prompt
        # can be copied and pasted.
        "# "
        # "[](fg:black bg:green)"
        # "[ ](bg:green)"
        "$time"
        # "[](fg:green) "
        # "[](bg:#DA627D fg:#9A348E)"
        "$direnv"
        "$nix_shell"
        # "[](fg:#DA627D bg:#FCA17D)"
        "$git"
        # "[](fg:#FCA17D bg:#86BBD8)"
        "$all"
        "$kubernetes"
        # "[](fg:#86BBD8 bg:#06969A)"
        "$cmd_duration"
        "$status"
        "$line_break"
        "$username"
        "$hostname"
        " "
        "$directory"
        "$character"
      ];

    };
  };
}
