# Home Manager module for the configuration *inside* an agentbox image.
# Import it in the configuration you pass to agentbox.lib.mkImage.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.agentbox.container;
in
{
  options.agentbox.container.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Configure this Home Manager profile for an agentbox container.";
  };

  config = lib.mkIf cfg.enable {
    # The container's init is tini plus nix-daemon, not systemd.
    systemd.user.startServices = false;

    home.packages = [
      # For commands started without agentbox-enter: agent-env pi …
      (pkgs.writeShellScriptBin "agent-env" ''
        if [ -r /etc/agentbox/load-secrets.bash ]; then
          source /etc/agentbox/load-secrets.bash
        fi
        exec "$@"
      '')
    ];

    # Interactive shells pick up the latest secrets the CLI has delivered.
    programs.bash.initExtra = ''
      if [ -r /etc/agentbox/load-secrets.bash ]; then
        source /etc/agentbox/load-secrets.bash
      fi
    '';
  };
}
