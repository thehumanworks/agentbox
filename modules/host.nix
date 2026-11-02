# Home Manager module for the host that runs agentbox containers.
# Writes ~/.config/agentbox/config.json and installs the CLI.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.agentbox;
  jsonFormat = pkgs.formats.json { };
in
{
  options.programs.agentbox = {
    enable = lib.mkEnableOption "agentbox, persistent Nix containers for coding agents";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.agentbox;
      defaultText = lib.literalExpression "agentbox.packages.\${system}.agentbox";
      description = "The agentbox CLI.";
    };

    backend = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "wslc"
        "podman"
        "docker"
        "apple"
      ];
      default = "auto";
      description = ''
        Container runtime. auto picks Apple container on macOS, wslc on WSL,
        then podman, then docker.
      '';
    };

    image = {
      flakeRef = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/etc/nixos#agent-image";
        description = ''
          Flake output built by `agentbox build`: an agentbox.lib.mkImage
          image for the matching Linux system. A string, so the image is
          built only on demand, never by a host rebuild. On macOS, point it
          at an aarch64-linux image built with `stream = false`.
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "agentbox:latest";
        description = "Image name and tag; must match mkImage's name and tag.";
      };
    };

    wslc.session = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "wslc session to use. Default: wslc-cli-<Windows user>.";
    };

    secrets.environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''
        { OPENAI_API_KEY = config.sops.secrets.openai_api_key.path; }
      '';
      description = ''
        Environment variables delivered to every container by default, as
        variable name to a file holding the value. Only paths are stored;
        agentbox reads the files at delivery time. Containers created with
        --no-default-secrets do not receive them.
      '';
    };

    copyFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ ".pi/agent/auth.json" ];
      description = ''
        $HOME-relative host files copied into each container's $HOME on start,
        shell and exec. A newer copy in the container is kept, so tokens an
        agent refreshed survive.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    xdg.configFile."agentbox/config.json".source = jsonFormat.generate "agentbox-config.json" {
      inherit (cfg) backend copyFiles;
      image = { inherit (cfg.image) flakeRef name; };
      wslc = { inherit (cfg.wslc) session; };
      secrets = { inherit (cfg.secrets) environment; };
    };
  };
}
