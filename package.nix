{
  lib,
  stdenv,
  writeShellApplication,
  coreutils,
  gnutar,
  jq,
  socat,
  skopeo,
  util-linux,
}:

writeShellApplication {
  name = "agentbox";
  # nix and the container CLI (wslc.exe, podman, docker, container) come from
  # the host: they must match its daemon or system services.
  runtimeInputs = [
    coreutils
    gnutar
    jq
    socat
  ]
  # Apple container loads OCI archives only; skopeo converts Nix's images.
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ skopeo ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ util-linux ];
  text = builtins.readFile ./cli/agentbox.sh;
  meta = {
    description = "Persistent, named Nix containers for coding agents (wslc, podman, docker, Apple container)";
    homepage = "https://github.com/thehumanworks/agentbox";
    mainProgram = "agentbox";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
