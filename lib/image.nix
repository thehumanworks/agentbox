# OCI image for agentbox: a Home Manager configuration plus a working Nix
# daemon, with no systemd and no special privileges.
#
# tini is PID 1 and runs agentbox-init: it starts nix-daemon as root (no build
# sandbox, since container runtimes grant only default capabilities) and
# activates Home Manager as the configured user. The agentbox CLI enters the
# container through /bin/agentbox-enter, which drops to that user.
{
  # Linux package set for the image (x86_64-linux or aarch64-linux).
  pkgs,
  # A Home Manager configuration that imports agentbox.homeModules.container.
  home,
  name ? "agentbox",
  tag ? "latest",
  # Pinned as `nixpkgs` in the container's flake registry and NIX_PATH.
  nixpkgs ? pkgs.path,
  # PEM bundle installed as /etc/ssl/certs/ca-bundle.crt.
  caBundle ? "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt",
  # Added to the base userland in /bin.
  extraPackages ? [ ],
  uid ? 1000,
  gid ? 100,
  # true: a script that streams the image (Linux hosts only).
  # false: a .tar.gz in the store, usable from macOS.
  stream ? true,
}:

let
  inherit (pkgs) lib;

  user = home.config.home.username;
  homeDirectory = home.config.home.homeDirectory;
  uidStr = toString uid;
  gidStr = toString gid;

  # A conventional Linux userland, linked into /bin and /usr/bin as well as
  # PATH, so scripts with a fixed PATH or #!/usr/bin/… still find their tools.
  base = pkgs.buildEnv {
    name = "agentbox-base";
    paths =
      with pkgs;
      [
        # GNU base system
        bashInteractive
        bash-completion
        coreutils-full
        findutils
        diffutils
        gnugrep
        gnused
        gawk
        gnupatch
        gnumake
        gnutar
        gzip
        bzip2
        xz
        zstd
        zip
        unzip
        which
        time
        file
        less
        man
        # Terminal: clear, reset, tput, tset, plus the terminfo database.
        ncurses
        # Processes, users and system
        procps
        psmisc
        util-linux
        getent
        hostname-debian
        shadow
        # Network
        iproute2
        iputils
        curl
        wget
        openssh
        rsync
        dnsutils
        netcat-openbsd
        socat
        cacert
        # Tooling agentbox itself relies on
        git
        nix
        tini
      ]
      ++ extraPackages;
    pathsToLink = [
      "/bin"
      "/sbin"
      "/share"
      "/etc/bash_completion.d"
    ];
    ignoreCollisions = true;
  };

  nixConf = pkgs.writeText "nix.conf" ''
    experimental-features = nix-command flakes
    # No nixbld users or namespaces in the container: the root daemon builds
    # directly. Substitutes from cache.nixos.org cover most installs.
    build-users-group =
    sandbox = false
    trusted-users = root ${user}
    max-jobs = auto
    ssl-cert-file = /etc/ssl/certs/ca-bundle.crt
  '';

  # nixpkgs#… and <nixpkgs> resolve to the pinned nixpkgs, so agents get the
  # same revision (and binary cache hits) without a registry fetch.
  registry = pkgs.writeText "registry.json" (
    builtins.toJSON {
      version = 2;
      flakes = [
        {
          from = {
            type = "indirect";
            id = "nixpkgs";
          };
          to = {
            type = "path";
            path = "${nixpkgs}";
          };
        }
      ];
    }
  );

  userPath = lib.concatStringsSep ":" [
    "${homeDirectory}/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "${base}/bin"
    "/bin"
    "/usr/bin"
  ];

  loadSecrets = pkgs.writeTextFile {
    name = "agentbox-load-secrets.bash";
    text = builtins.readFile ../cli/load-secrets.bash;
    checkPhase = ''
      ${pkgs.bash}/bin/bash -n "$out"
      ${pkgs.shellcheck}/bin/shellcheck --shell=bash "$out"
    '';
  };

  etc = pkgs.runCommand "agentbox-etc" { } ''
    mkdir -p "$out/etc/nix" "$out/etc/ssl/certs" "$out/etc/agentbox"
    cat > "$out/etc/passwd" <<'EOF'
    root:x:0:0:root:/root:${pkgs.bashInteractive}/bin/bash
    ${user}:x:${uidStr}:${gidStr}::${homeDirectory}:${pkgs.bashInteractive}/bin/bash
    nobody:x:65534:65534:nobody:/var/empty:${pkgs.coreutils}/bin/false
    EOF
    cat > "$out/etc/group" <<'EOF'
    root:x:0:
    users:x:${gidStr}:${user}
    nogroup:x:65534:
    EOF
    cat > "$out/etc/profile" <<'EOF'
    # Login shells: restore the standard PATH entries if a caller cleared them.
    for d in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin"; do
      case ":$PATH:" in *":$d:"*) ;; *) PATH="$d''${PATH:+:$PATH}" ;; esac
    done
    for d in ${base}/bin /bin /usr/bin; do
      case ":$PATH:" in *":$d:"*) ;; *) PATH="$PATH:$d" ;; esac
    done
    export PATH
    export TERMINFO_DIRS="''${TERMINFO_DIRS:-$HOME/.nix-profile/share/terminfo:${base}/share/terminfo}"
    EOF
    cat > "$out/etc/nsswitch.conf" <<'EOF'
    passwd: files
    group: files
    hosts: files dns
    EOF
    ln -s ${nixConf} "$out/etc/nix/nix.conf"
    ln -s ${registry} "$out/etc/nix/registry.json"
    ln -s ${caBundle} "$out/etc/ssl/certs/ca-bundle.crt"
    ln -s ${caBundle} "$out/etc/ssl/certs/ca-certificates.crt"
    ln -s ${pkgs.iana-etc}/etc/services "$out/etc/services"
    ln -s ${pkgs.iana-etc}/etc/protocols "$out/etc/protocols"
    ln -s ${loadSecrets} "$out/etc/agentbox/load-secrets.bash"
  '';

  # Runs at every container start, so an upgraded image re-links $HOME.
  init = pkgs.writeShellScriptBin "agentbox-init" ''
    set -euo pipefail
    export PATH=${base}/bin

    mkdir -p /tmp /var/tmp /root /run/agent-secrets /run/user/${uidStr} \
      ${homeDirectory} \
      /nix/var/nix/profiles/per-user/${user} \
      /nix/var/nix/gcroots/per-user/${user}
    chmod 1777 /tmp /var/tmp
    # $HOME is a fresh named volume on first start.
    chown ${uidStr}:${gidStr} ${homeDirectory} /run/agent-secrets /run/user/${uidStr} \
      /nix/var/nix/profiles/per-user/${user} \
      /nix/var/nix/gcroots/per-user/${user}
    chmod 0700 /run/agent-secrets /run/user/${uidStr}
    rm -f /run/agentbox-ready

    # The image sets NIX_REMOTE=daemon for clients; the daemon itself must
    # use the local store, or it connects to itself.
    env -u NIX_REMOTE nix-daemon --store local &
    daemon=$!
    trap 'kill -TERM "$daemon" 2>/dev/null || true' TERM INT
    for _ in $(seq 100); do
      [ -S /nix/var/nix/daemon-socket/socket ] && break
      sleep 0.1
    done

    if ! setpriv --reuid=${uidStr} --regid=${gidStr} --init-groups \
      env -i HOME=${homeDirectory} USER=${user} LOGNAME=${user} \
        PATH=${userPath} NIX_REMOTE=daemon \
        XDG_RUNTIME_DIR=/run/user/${uidStr} \
        HOME_MANAGER_BACKUP_EXT=hm-backup \
        ${home.activationPackage}/activate; then
      echo "agentbox-init: Home Manager activation failed" >&2
    fi
    touch /run/agentbox-ready

    # Return when the daemon exits, including after the TERM trap.
    while kill -0 "$daemon" 2>/dev/null; do
      wait "$daemon" || true
    done
  '';

  # `agentbox-enter CMD…` (run as root by the CLI): CMD as the user, in $HOME,
  # with the delivered secrets in its environment.
  enter = pkgs.writeShellScriptBin "agentbox-enter" ''
    set -euo pipefail
    cd ${homeDirectory}
    export HOME=${homeDirectory} USER=${user} LOGNAME=${user} \
      SHELL=${pkgs.bashInteractive}/bin/bash XDG_RUNTIME_DIR=/run/user/${uidStr}
    if [ "$(${pkgs.coreutils}/bin/id -u)" = 0 ]; then
      exec ${pkgs.util-linux}/bin/setpriv --reuid=${uidStr} --regid=${gidStr} --init-groups \
        ${pkgs.bashInteractive}/bin/bash -c 'source /etc/agentbox/load-secrets.bash; exec "$@"' agentbox-enter "$@"
    fi
    source /etc/agentbox/load-secrets.bash
    exec "$@"
  '';

  # Root side of secret delivery: NAME<TAB>BASE64 lines on stdin replace the
  # previous set atomically. Values never appear in argv or the image config.
  receiveSecrets = pkgs.writeShellScriptBin "agentbox-receive-secrets" ''
    set -euo pipefail
    umask 077
    tmp=$(mktemp /run/agent-secrets/.env.XXXXXX)
    cat > "$tmp"
    chown ${uidStr}:${gidStr} "$tmp"
    mv -f "$tmp" /run/agent-secrets/env
  '';

  build = if stream then pkgs.dockerTools.streamLayeredImage else pkgs.dockerTools.buildLayeredImage;
in
assert lib.assertMsg (home.config.agentbox.container.enable or false
) "agentbox.lib.mkImage: the Home Manager configuration must import agentbox.homeModules.container";
build {
  inherit name tag;
  # Registers every store path below, so nix in the container knows them.
  includeNixDB = true;
  contents = [
    base
    etc
    init
    enter
    receiveSecrets
  ];
  extraCommands = ''
    mkdir -p tmp var/tmp root home usr
    chmod 1777 tmp var/tmp
    # FHS paths resolve to the base userland (/bin comes from contents).
    ln -s ../bin usr/bin
    ln -s ../bin usr/sbin
    ln -s ${base}/share usr/share
  '';
  config = {
    Entrypoint = [
      "${pkgs.tini}/bin/tini"
      "--"
      "${init}/bin/agentbox-init"
    ];
    WorkingDir = homeDirectory;
    Env = [
      "PATH=${userPath}"
      "NIX_PATH=nixpkgs=${nixpkgs}"
      "NIX_REMOTE=daemon"
      "LANG=C.UTF-8"
      "TERMINFO_DIRS=${homeDirectory}/.nix-profile/share/terminfo:${base}/share/terminfo"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    Labels = {
      "io.agentbox.image" = "1";
      "io.agentbox.user" = user;
    };
  };
}
