{
  description = "agentbox: persistent, named Nix containers for coding agents (wslc, podman, docker, Apple container)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        # Apple container needs Apple silicon; nixpkgs dropped x86_64-darwin.
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # Containers run Linux; a Mac runs images for its own CPU architecture.
      linuxSystemFor = system: lib.replaceStrings [ "darwin" ] [ "linux" ] system;

      exampleHome =
        system:
        home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.${system};
          modules = [
            self.homeModules.container
            ./examples/home.nix
          ];
        };

      exampleImage =
        system: stream:
        self.lib.mkImage {
          pkgs = nixpkgs.legacyPackages.${system};
          home = exampleHome system;
          inherit stream;
        };
    in
    {
      lib = {
        # agentbox.lib.mkImage { pkgs; home; name?; tag?; nixpkgs?; caBundle?;
        #   extraPackages?; uid?; gid?; stream? }; see lib/image.nix.
        mkImage = import ./lib/image.nix;
        inherit linuxSystemFor;
      };

      homeModules = {
        # The host side: CLI plus ~/.config/agentbox/config.json.
        default = self.homeModules.host;
        host = import ./modules/host.nix self;
        # The configuration inside the image.
        container = ./modules/container.nix;
      };

      packages = forAllSystems (
        system: pkgs:
        let
          linux = linuxSystemFor system;
        in
        {
          agentbox = pkgs.callPackage ./package.nix { };
          default = self.packages.${system}.agentbox;
          # A small image (bash, git, ripgrep) for trying agentbox out. On
          # macOS this is the Linux .tar.gz and needs a Linux builder.
          example-image = exampleImage linux (system == linux);
        }
      );

      checks = forAllSystems (
        system: pkgs: {
          agentbox = self.packages.${system}.agentbox;
          cli = pkgs.runCommand "agentbox-cli-test" { nativeBuildInputs = [ pkgs.bash ]; } ''
            AGENTBOX=${lib.getExe self.packages.${system}.agentbox} \
              bash ${./tests/cli.sh}
            touch "$out"
          '';
        }
      );

      templates.default = {
        path = ./examples/template;
        description = "A flake with an agentbox image and host configuration";
      };

      formatter = forAllSystems (_: pkgs: pkgs.nixfmt);
    };
}
