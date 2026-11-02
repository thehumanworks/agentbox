# Everything agents get inside the container: shell, editors, tools, dotfiles.
# Nix works inside too, so agents can `nix shell nixpkgs#…` anything else.
{ pkgs, ... }:

{
  home.username = "agent";
  home.homeDirectory = "/home/agent";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;
  programs.bash.enable = true;
  programs.git.enable = true;
  home.packages = with pkgs; [
    ripgrep
    fd
    jq
    nodejs
    python3
  ];
}
