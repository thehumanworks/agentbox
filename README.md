# agentbox

Persistent, named Linux containers for coding agents, built from your own
Nix flake and Home Manager configuration.

- **Your environment, isolated.** The image is a Home Manager configuration
  plus a base userland. Nothing on the host is mounted; directories are
  *cloned* in.
- **Nix works inside.** A root `nix-daemon` runs in every container, so agents
  can `nix shell nixpkgs#…` or `nix profile add` whatever they need. The
  `nixpkgs` registry entry is pinned to the image's nixpkgs.
- **Persistent.** Each container `NAME` keeps `$HOME` in a named volume
  (`NAME-home`) that survives `stop`, `start` and `upgrade`.
- **Secrets stay out of configs.** Values travel over stdin into a tmpfs inside
  the container. They never appear in argv, image layers, container config or
  your global shell. They are re-sent on every start, `shell` and `exec`.
- **Web servers are reachable.** Publish ports at create time
  (`-p 3000`), or `forward` any port later, including ones bound to the
  container's `127.0.0.1`.
- **No privileges.** No systemd, `--privileged` or extra capabilities.
  `tini` is PID 1.

| Host          | Backend                                                  | Notes                                     |
| ------------- | -------------------------------------------------------- | ----------------------------------------- |
| Windows (WSL) | [`wslc`](https://learn.microsoft.com/windows/wsl/)       | Containers run in the WSL container VM    |
| Linux         | [podman](https://podman.io), daemonless; docker fallback | Rootless or rootful podman                |
| macOS         | [Apple container](https://github.com/apple/container)    | One lightweight VM per container (Virtualization framework); Apple silicon, macOS 26+ |

`auto` (the default) picks Apple container on macOS, then wslc on WSL, then
podman, then docker. Override it with `programs.agentbox.backend` or
`AGENTBOX_BACKEND`.

## Quick start

```sh
nix flake init -t github:thehumanworks/agentbox
# edit flake.nix (hostSystem, username, image.flakeRef) and container-home.nix
home-manager switch --flake .#me

agentbox build                       # build the image and load it
agentbox create work -p 3000 --clone ~/src/myapp
agentbox shell work                  # login shell as the container user
agentbox exec work -- pi             # or run an agent directly
```

## Using it from an existing flake

```nix
{
  inputs.agentbox = {
    url = "github:thehumanworks/agentbox";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.home-manager.follows = "home-manager";
  };

  outputs = { self, nixpkgs, home-manager, agentbox, ... }: {
    # 1. The configuration inside the container.
    homeConfigurations.agent = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ agentbox.homeModules.container ./agent-home.nix ];
    };

    # 2. The image built from it.
    packages.x86_64-linux.agent-image = agentbox.lib.mkImage {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      home = self.homeConfigurations.agent;
      name = "agentbox";            # image name; tag defaults to "latest"
      # caBundle = ./corp-ca.pem;   # e.g. for TLS-intercepting proxies
    };
  };
}
```

3. Add the CLI to the host's Home Manager configuration:

```nix
{
  imports = [ inputs.agentbox.homeModules.default ];

  programs.agentbox = {
    enable = true;
    image.flakeRef = "/path/to/flake#agent-image";
    image.name = "agentbox:latest";
    # Variable name -> file holding the value (sops-nix, agenix, …).
    secrets.environment.OPENAI_API_KEY = config.sops.secrets.openai.path;
    copyFiles = [ ".pi/agent/auth.json" ];
  };
}
```

`image.flakeRef` is a string, so a host rebuild never builds the image. Only
`agentbox build` does.

### `lib.mkImage` arguments

| Argument        | Default                    | Meaning                                                                  |
| --------------- | -------------------------- | ------------------------------------------------------------------------ |
| `pkgs`          | required                   | Linux package set for the image                                          |
| `home`          | required                   | Home Manager configuration importing `homeModules.container`             |
| `name`, `tag`   | `"agentbox"`, `"latest"`   | Image reference                                                          |
| `nixpkgs`       | `pkgs.path`                | Pinned as `nixpkgs` in the registry and `NIX_PATH`                       |
| `caBundle`      | nixpkgs `cacert`           | `/etc/ssl/certs/ca-bundle.crt`                                           |
| `extraPackages` | `[ ]`                      | Added to the base userland in `/bin`                                     |
| `uid`, `gid`    | `1000`, `100`              | Container user's ids; the name and `$HOME` come from `home`              |
| `stream`        | `true`                     | `true`: streaming script (Linux hosts); `false`: `.tar.gz` (needed on macOS) |

### macOS

The image must be built for `aarch64-linux`, with `stream = false`. This needs
a Linux builder, such as nix-darwin's `nix.linux-builder` or Determinate
Nix's native Linux builder. `agentbox build` converts the archive to the OCI
layout Apple container loads. That conversion uses skopeo, which the macOS
package includes.

## Commands

```
agentbox build                         build and load the image
agentbox create NAME [-p PORT[:CPORT]] [--clone DIR]... [--secrets FILE]...
                     [--no-default-secrets] [--cpus N] [--memory SIZE]
agentbox shell NAME [-- CMD...]        interactive shell (or CMD)
agentbox exec NAME -- CMD...           run CMD as the user, with secrets
agentbox clone NAME DIR [DEST] [--exclude PATTERN]...
agentbox secrets NAME [--secrets FILE]... [--no-default-secrets|--default-secrets]
agentbox forward NAME PORT [HOSTPORT]  forward 127.0.0.1:HOSTPORT to the container
agentbox start|stop|logs NAME
agentbox list
agentbox upgrade NAME                  recreate from the current image; keeps $HOME
agentbox rm NAME [--volume]
agentbox backend                       show the selected backend
```

Published ports (`-p`) listen on the host's `127.0.0.1`, so the server inside
must bind `0.0.0.0`. `forward` needs no publishing: it runs one
`exec … socat` per connection, so it also reaches servers bound to the
container's `127.0.0.1`.

`--secrets FILE` takes dotenv-style `KEY=VALUE` lines. agentbox saves the
*path* and re-reads the file at each delivery. Secrets appear in new shells
and `exec` commands. Inside the container, `agent-env CMD` loads them for
commands started some other way.

## Notes

- `upgrade` resets `/nix` to the new image. Anything installed with
  `nix profile` is re-fetched from the cache when next used. `$HOME`,
  including clones, is kept.
- The build sandbox is off inside containers, because no backend grants the
  namespaces it needs. Builds run as root in the container.
- wslc sessions are per Windows user, and elevated callers get a separate
  session. agentbox pins `wslc-cli-<Windows user>`; set
  `programs.agentbox.wslc.session` to choose another.

## Development

```sh
nix flake check          # shellcheck + offline CLI tests
nix build .#example-image && AGENTBOX_IMAGE_REF=.#example-image agentbox build
```

## License

MIT
