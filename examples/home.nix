# A minimal container profile: the user, a shell and a few tools.
{ pkgs, ... }:

{
  home.username = "agent";
  home.homeDirectory = "/home/agent";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;
  programs.bash.enable = true;
  programs.git.enable = true;
  home.packages = [
    pkgs.ripgrep
    pkgs.jq
  ];
}
