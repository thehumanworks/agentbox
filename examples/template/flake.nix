{
  description = "My agentbox image and host configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agentbox = {
      url = "github:thehumanworks/agentbox";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      agentbox,
      ...
    }:
    let
      # The machine you run agentbox on.
      hostSystem = "aarch64-darwin"; # or x86_64-linux, aarch64-linux, …
      # Containers run Linux on the same CPU architecture.
      imageSystem = agentbox.lib.linuxSystemFor hostSystem;
      isDarwin = nixpkgs.lib.hasSuffix "darwin" hostSystem;

      containerHome = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${imageSystem};
        modules = [
          agentbox.homeModules.container
          ./container-home.nix
        ];
      };
    in
    {
      # `agentbox build` builds this. macOS cannot run the streaming script,
      # so it gets a .tar.gz instead (built by a Linux builder).
      packages.${hostSystem}.agent-image = agentbox.lib.mkImage {
        pkgs = nixpkgs.legacyPackages.${imageSystem};
        home = containerHome;
        stream = !isDarwin;
      };

      # Import into your own Home Manager configuration, or use as is:
      #   home-manager switch --flake .#me
      homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${hostSystem};
        modules = [
          agentbox.homeModules.default
          {
            home.username = "me";
            home.homeDirectory = if isDarwin then "/Users/me" else "/home/me";
            home.stateVersion = "25.11";

            programs.agentbox = {
              enable = true;
              # A string: the image is built by `agentbox build`, not here.
              image.flakeRef = "/path/to/this/flake#agent-image";
              # Variable name -> file holding the value, read at delivery.
              secrets.environment = { };
              copyFiles = [ ".pi/agent/auth.json" ];
            };
          }
        ];
      };
    };
}
