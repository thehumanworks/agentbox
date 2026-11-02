# shellcheck shell=bash
# agentbox: named, persistent containers built from a Nix flake, for running
# coding agents in isolation. Backends: wslc (WSL), podman or docker (Linux),
# Apple container (macOS, Virtualization framework).

readonly label_key=io.agentbox
readonly secrets_dir=/run/agent-secrets
state_root=${XDG_STATE_HOME:-$HOME/.local/state}/agentbox
cache_root=${XDG_CACHE_HOME:-$HOME/.cache}/agentbox
config_file=${AGENTBOX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agentbox/config.json}

die() {
  printf 'agentbox: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'agentbox: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: agentbox <command> [arguments]

Persistent, named containers built from your Nix flake. Each container NAME has
its own $HOME volume (NAME-home) and Nix store; nothing on the host is mounted.

Commands:
  build                         Build the image from the flake and load it
  create NAME [options]         Create and start a container
      -p, --publish PORT[:CPORT]  Publish container port CPORT (default PORT) on
                                  127.0.0.1:PORT; the server must bind 0.0.0.0
      --clone DIR               Copy DIR into ~/<basename> (repeatable)
      --secrets FILE            Also deliver KEY=VALUE lines from FILE (repeatable)
      --no-default-secrets      Do not deliver the configured default secrets
      --cpus N, --memory SIZE   Resource limits
  shell NAME [-- CMD...]        Interactive login shell (or CMD) as the user
  exec NAME -- CMD...           Run CMD as the user, secrets in its environment
  clone NAME DIR [DEST]         Copy DIR into the container (default ~/<basename>)
      --exclude PATTERN         tar exclusion pattern (repeatable)
  secrets NAME [--secrets FILE]... [--no-default-secrets | --default-secrets]
                                Re-deliver secrets; options replace the saved set
  forward NAME PORT [HOSTPORT]  Forward 127.0.0.1:HOSTPORT to the container's
                                127.0.0.1:PORT until interrupted
  start NAME | stop NAME | logs NAME
  list                          List agentbox containers
  upgrade NAME                  Recreate NAME from the current image, keeping $HOME
  rm NAME [--volume]            Remove the container (and its $HOME volume)
  backend                       Print the selected backend

Secrets live only in a tmpfs inside the container and are re-sent on start,
shell and exec. Configured copy files (e.g. ~/.pi/agent/auth.json) are copied
into $HOME at the same points unless the container's copy is newer.

Configuration: ~/.config/agentbox/config.json (written by the Home Manager
module). Environment overrides: AGENTBOX_CONFIG, AGENTBOX_BACKEND
(wslc|podman|docker|apple), AGENTBOX_IMAGE, AGENTBOX_IMAGE_REF,
AGENTBOX_WSLC_SESSION, AGENTBOX_CONTAINER_CLI.
EOF
}

# --- configuration -----------------------------------------------------------

config_get() {
  # jq expression over the config file; prints nothing when absent.
  [[ -r $config_file ]] || return 0
  jq -r "($1) // empty" "$config_file"
}

load_config() {
  backend=${AGENTBOX_BACKEND:-$(config_get .backend)}
  backend=${backend:-auto}
  image_name=${AGENTBOX_IMAGE:-$(config_get .image.name)}
  image_name=${image_name:-agentbox:latest}
  image_ref=${AGENTBOX_IMAGE_REF:-$(config_get .image.flakeRef)}
  wslc_session=${AGENTBOX_WSLC_SESSION:-$(config_get .wslc.session)}
  mapfile -t copy_files < <(config_get '.copyFiles[]?')
  # NAME<TAB>PATH lines.
  mapfile -t default_secrets < <(config_get '.secrets.environment // {} | to_entries[] | "\(.key)\t\(.value)"')
}

# --- backends ----------------------------------------------------------------

is_wsl() {
  [[ -n ${WSL_DISTRO_NAME:-} || -e /proc/sys/fs/binfmt_misc/WSLInterop ]]
}

find_wslc() {
  if command -v wslc.exe >/dev/null 2>&1; then
    command -v wslc.exe
  elif [[ -x "/mnt/c/Program Files/WSL/wslc.exe" ]]; then
    printf '%s\n' "/mnt/c/Program Files/WSL/wslc.exe"
  fi
}

find_apple() {
  if [[ $(uname -s) == Darwin ]]; then
    if command -v container >/dev/null 2>&1; then
      command -v container
    elif [[ -x /usr/local/bin/container ]]; then
      printf '%s\n' /usr/local/bin/container
    fi
  fi
}

select_backend() {
  local found
  if [[ $backend == auto ]]; then
    if [[ -n $(find_apple) ]]; then
      backend=apple
    elif is_wsl && [[ -n $(find_wslc) ]]; then
      backend=wslc
    elif command -v podman >/dev/null 2>&1; then
      backend=podman
    elif command -v docker >/dev/null 2>&1; then
      backend=docker
    elif [[ $(uname -s) == Darwin ]]; then
      die "no backend: install Apple container (https://github.com/apple/container)"
    else
      die "no backend: install podman (or docker)"
    fi
  fi
  case $backend in
    wslc) found=$(find_wslc) ;;
    apple) found=$(find_apple) ;;
    podman | docker) found=$(command -v "$backend" || true) ;;
    *) die "unknown backend '$backend' (wslc, podman, docker or apple)" ;;
  esac
  runtime_bin=${AGENTBOX_CONTAINER_CLI:-$found}
  [[ -n $runtime_bin ]] || die "backend $backend selected but its CLI was not found"

  runtime_args=()
  if [[ $backend == wslc ]]; then
    # wslc picks a session per caller (elevated callers get an admin one);
    # pin it so images and containers are always found in the same place.
    if [[ -z $wslc_session ]]; then
      local windows_user
      windows_user=$(cd / && cmd.exe /d /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r')
      [[ -n $windows_user ]] || die "cannot determine the Windows user; set AGENTBOX_WSLC_SESSION"
      wslc_session=wslc-cli-$windows_user
    fi
    runtime_args=(--session "$wslc_session")
  fi
}

rt() {
  if [[ $backend == wslc ]]; then
    # Windows executables warn about a UNC working directory; / maps cleanly.
    (cd / && "$runtime_bin" "${runtime_args[@]}" "$@")
  else
    "$runtime_bin" "${runtime_args[@]}" "$@"
  fi
}

rt_prepare() {
  if [[ $backend == apple ]] && ! rt system status >/dev/null 2>&1; then
    note "starting Apple container services"
    rt system start >/dev/null
  fi
}

# Prints the container status (running, exited, stopped, created…) or nothing.
rt_status() {
  local json
  case $backend in
    apple) json=$(rt inspect "$1" 2>/dev/null) || return 0 ;;
    wslc) json=$(rt inspect -t container -f json "$1" 2>/dev/null) || return 0 ;;
    *) json=$(rt inspect --type container "$1" 2>/dev/null) || return 0 ;;
  esac
  jq -r '.[0] | (.State.Status // .status // empty)' <<<"$json" 2>/dev/null || true
}

rt_image_present() {
  case $backend in
    wslc) rt inspect -t image -f json "$image_name" >/dev/null 2>&1 ;;
    *) rt image inspect "$image_name" >/dev/null 2>&1 ;;
  esac
}

rt_list() {
  case $backend in
    apple)
      rt list --all --format json | jq -r --arg key "$label_key" '
        ["NAME", "STATUS", "IMAGE", "ADDRESS"],
        (.[] | select(.configuration.labels[$key] == "1")
          | [.configuration.id, .status,
             (.configuration.image.reference // "-"),
             ((.networks // [])[0].address // "-")])
        | @tsv' | column -t -s $'\t'
      ;;
    wslc) rt list --all --filter "label=$label_key=1" ;;
    *) rt ps --all --filter "label=$label_key=1" ;;
  esac
}

rt_create() {
  local name=$1
  shift
  local -a args=(--name "$name" --label "$label_key=1"
    --volume "$name-home:$container_home" --tmpfs "$secrets_dir")
  if [[ $backend == apple ]]; then
    # Named volumes must exist before use.
    rt volume inspect "$name-home" >/dev/null 2>&1 || rt volume create "$name-home" >/dev/null
  else
    args+=(--hostname "$name")
  fi
  rt create "${args[@]}" "$@" "$image_name" >/dev/null
}

rt_remove() {
  case $backend in
    apple) rt delete --force "$1" >/dev/null ;;
    *) rt rm -f "$1" >/dev/null ;;
  esac
}

rt_volume_remove() {
  case $backend in
    apple) rt volume delete "$1" >/dev/null ;;
    *) rt volume rm "$1" >/dev/null ;;
  esac
}

# Loads an image archive (docker-archive, optionally gzip-compressed).
rt_load_archive() {
  local archive=$1 work
  case $backend in
    wslc) rt load -i "$(wslpath -w "$archive")" ;;
    apple)
      # Apple container loads only OCI layouts whose index carries the media
      # type and image name.
      work=$(mktemp -d "$cache_root/oci.XXXXXX")
      skopeo copy --quiet --dest-compress-format gzip \
        "docker-archive:$archive" "oci:$work/layout:$image_name"
      jq '.mediaType = "application/vnd.oci.image.index.v1+json"
        | .manifests |= map(.annotations["org.opencontainers.image.ref.name"] = $name)' \
        --arg name "$image_name" "$work/layout/index.json" >"$work/index.json"
      mv -f "$work/index.json" "$work/layout/index.json"
      tar -C "$work/layout" -cf "$work/image.tar" .
      rt image load --input "$work/image.tar"
      rm -rf "$work"
      ;;
    *) rt load -i "$archive" ;;
  esac
}

# --- helpers -----------------------------------------------------------------

check_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
    die "invalid container name '$1' (letters, digits, '_', '.', '-')"
}

state_dir() {
  printf '%s/%s\n' "$state_root" "$1"
}

require_container() {
  local status
  status=$(rt_status "$1")
  [[ -n $status ]] || die "no container named '$1' (agentbox create $1)"
  printf '%s\n' "$status"
}

# $HOME inside the image, from its label (set by agentbox.lib.mkImage).
image_home() {
  local user
  case $backend in
    apple) user=$(rt image inspect "$image_name" 2>/dev/null |
      jq -r '[.. | objects | .Labels? // .labels? | objects | .["io.agentbox.user"]? // empty][0] // empty') ;;
    wslc) user=$(rt inspect -t image -f json "$image_name" 2>/dev/null |
      jq -r '.[0] | (.Config.Labels // .Labels // {})["io.agentbox.user"] // empty') ;;
    *) user=$(rt image inspect "$image_name" 2>/dev/null |
      jq -r '.[0] | (.Config.Labels // .Labels // {})["io.agentbox.user"] // empty') ;;
  esac
  [[ -n $user ]] || die "image $image_name lacks the io.agentbox.user label; was it built with agentbox.lib.mkImage?"
  container_home=/home/$user
  [[ $user == root ]] && container_home=/root
  return 0
}

# --- build -------------------------------------------------------------------

cmd_build() {
  local out tmp
  [[ -n $image_ref ]] ||
    die "no image flake reference: set programs.agentbox.image.flakeRef or AGENTBOX_IMAGE_REF"
  command -v nix >/dev/null 2>&1 || die "nix is required to build the image"
  note "building $image_ref"
  out=$(nix build --no-link --print-out-paths "$image_ref")
  mkdir -p "$cache_root"
  if [[ -x $out && ! -d $out && $backend != apple && $backend != wslc ]]; then
    # podman and docker read the stream directly: no temporary archive.
    note "streaming image into $backend"
    "$out" | rt load
    return
  fi
  if [[ -x $out && ! -d $out ]]; then
    tmp=$(mktemp -d "$cache_root/build.XXXXXX")
    # shellcheck disable=SC2064 # Expand now: tmp is local.
    trap "rm -rf '$tmp'" EXIT
    note "writing image archive"
    "$out" >"$tmp/image.tar"
    note "loading into $backend"
    rt_load_archive "$tmp/image.tar"
    rm -rf "$tmp"
    trap - EXIT
  elif [[ -f $out ]]; then
    note "loading $out into $backend"
    rt_load_archive "$out"
  else
    die "$image_ref did not produce an image (expected mkImage output)"
  fi
}

# --- secrets and files -------------------------------------------------------

# Reads dotenv-style KEY=VALUE lines; prints NAME<TAB>BASE64 lines.
encode_env_file() {
  local file=$1 line name value number=0
  [[ -r $file ]] || die "secrets file not readable: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    line=${line#"${line%%[![:space:]]*}"}
    line=${line#export }
    [[ $line == *=* ]] || die "$file:$number: expected KEY=VALUE"
    name=${line%%=*}
    value=${line#*=}
    name=${name%"${name##*[![:space:]]}"}
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$file:$number: invalid name '$name'"
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
      value=${BASH_REMATCH[1]}
    fi
    printf '%s\t%s\n' "$name" "$(printf '%s' "$value" | base64 -w0)"
  done <"$file"
}

encode_default_secrets() {
  local entry name file
  for entry in "${default_secrets[@]}"; do
    name=${entry%%$'\t'*}
    file=${entry#*$'\t'}
    [[ -r $file ]] || die "secret for $name unavailable at $file"
    printf '%s\t%s\n' "$name" "$(base64 -w0 <"$file")"
  done
}

# Per-container choices: "defaults" (yes|no) and "secret-files" (one per line).
save_secret_choice() {
  local dir use_defaults=$2
  dir=$(state_dir "$1")
  shift 2
  mkdir -p "$dir"
  printf '%s\n' "$use_defaults" >"$dir/defaults"
  if (($# > 0)); then
    printf '%s\n' "$@" >"$dir/secret-files"
  else
    : >"$dir/secret-files"
  fi
}

push_secrets() {
  local name=$1 dir payload file use_defaults=yes
  dir=$(state_dir "$name")
  [[ -r $dir/defaults ]] && use_defaults=$(<"$dir/defaults")
  # Build the whole payload first: no partial file on a read error.
  payload=$(
    set -e
    if [[ $use_defaults == yes ]]; then
      encode_default_secrets
    fi
    if [[ -r $dir/secret-files ]]; then
      while IFS= read -r file; do
        [[ -n $file ]] && encode_env_file "$file"
      done <"$dir/secret-files"
    fi
    # Never empty, so the receiver always replaces the previous set.
    printf '\n'
  ) || die "secrets not delivered to $name"
  # Values travel over stdin only, never in argv or the container config.
  printf '%s\n' "$payload" | rt exec -i "$name" agentbox-receive-secrets
}

# Copies configured $HOME-relative files that exist on the host into the
# container's $HOME. A newer container copy wins: agents refresh OAuth tokens.
copy_home_files() {
  local name=$1 file
  local -a present=()
  for file in "${copy_files[@]}"; do
    [[ -f $HOME/$file ]] && present+=("$file")
  done
  ((${#present[@]} > 0)) || return 0
  tar -C "$HOME" -cf - -- "${present[@]}" |
    rt exec -i "$name" agentbox-enter bash -c \
      'umask 077 && tar --keep-newer-files --warning=no-ignore-newer -xf -' ||
    note "could not copy ${present[*]} into $name"
}

wait_ready() {
  local name=$1 i
  for ((i = 0; i < 300; i++)); do
    if rt exec "$name" test -e /run/agentbox-ready >/dev/null 2>&1; then
      return 0
    fi
    if ((i == 10)); then
      note "waiting for $name to finish Home Manager activation"
    fi
    sleep 1
  done
  die "$name did not become ready; see: agentbox logs $name"
}

ensure_running() {
  local name=$1 status
  status=$(require_container "$name")
  if [[ $status != running ]]; then
    rt start "$name" >/dev/null
  fi
  wait_ready "$name"
  push_secrets "$name"
  copy_home_files "$name"
}

# --- commands ----------------------------------------------------------------

cmd_start() {
  (($# == 1)) || die "usage: agentbox start NAME"
  check_name "$1"
  ensure_running "$1"
}

clone_into() {
  local name=$1 src=$2 dest=$3
  shift 3
  [[ -d $src ]] || die "not a directory: $src"
  src=$(realpath "$src")
  # Relative destinations resolve against the container user's $HOME.
  [[ -n $dest ]] || dest=$(basename "$src")
  note "cloning $src -> $name:$dest"
  # shellcheck disable=SC2016 # Expanded by the container's bash.
  tar -C "$src" "$@" -cf - . |
    rt exec -i "$name" agentbox-enter bash -c '
      set -e
      mkdir -p "$1"
      tar -C "$1" --no-same-owner -xf -
    ' agentbox "$dest"
}

cmd_clone() {
  local name="" src="" dest=""
  local -a excludes=()
  while (($# > 0)); do
    case $1 in
      --exclude)
        (($# >= 2)) || die "--exclude needs a pattern"
        excludes+=("--exclude=$2")
        shift 2
        ;;
      -*) die "unknown clone option: $1" ;;
      *)
        if [[ -z $name ]]; then
          name=$1
        elif [[ -z $src ]]; then
          src=$1
        elif [[ -z $dest ]]; then
          dest=$1
        else
          die "usage: agentbox clone NAME DIR [DEST]"
        fi
        shift
        ;;
    esac
  done
  [[ -n $name && -n $src ]] || die "usage: agentbox clone NAME DIR [DEST]"
  check_name "$name"
  ensure_running "$name"
  clone_into "$name" "$src" "$dest" "${excludes[@]}"
}

cmd_create() {
  local name="" use_defaults=yes spec dir
  local -a create_args=() clones=() secret_files=()
  while (($# > 0)); do
    case $1 in
      -p | --publish)
        (($# >= 2)) || die "$1 needs PORT[:CPORT]"
        spec=$2
        [[ $spec =~ ^[0-9]+(:[0-9]+)?$ ]] || die "invalid port spec '$spec'"
        [[ $spec == *:* ]] || spec="$spec:$spec"
        create_args+=(--publish "127.0.0.1:$spec")
        shift 2
        ;;
      --cpus | --memory)
        (($# >= 2)) || die "$1 needs a value"
        create_args+=("$1" "$2")
        shift 2
        ;;
      --clone)
        (($# >= 2)) || die "--clone needs a directory"
        [[ -d $2 ]] || die "not a directory: $2"
        clones+=("$(realpath "$2")")
        shift 2
        ;;
      --secrets)
        (($# >= 2)) || die "--secrets needs a file"
        [[ -r $2 ]] || die "secrets file not readable: $2"
        secret_files+=("$(realpath "$2")")
        shift 2
        ;;
      --no-default-secrets)
        use_defaults=no
        shift
        ;;
      -*) die "unknown create option: $1" ;;
      *)
        [[ -z $name ]] || die "usage: agentbox create NAME [options]"
        name=$1
        shift
        ;;
    esac
  done
  [[ -n $name ]] || die "usage: agentbox create NAME [options]"
  check_name "$name"
  [[ -z $(rt_status "$name") ]] || die "container '$name' already exists"
  rt_image_present || cmd_build
  image_home

  dir=$(state_dir "$name")
  mkdir -p "$dir"
  if ((${#create_args[@]} > 0)); then
    printf '%s\n' "${create_args[@]}" >"$dir/create-args"
  else
    : >"$dir/create-args"
  fi
  save_secret_choice "$name" "$use_defaults" "${secret_files[@]}"

  rt_create "$name" "${create_args[@]}"
  note "created $name (home volume $name-home)"
  ensure_running "$name"
  local src
  for src in "${clones[@]}"; do
    clone_into "$name" "$src" ""
  done
  note "ready: agentbox shell $name"
}

cmd_shell() {
  local name=${1:-}
  [[ -n $name ]] || die "usage: agentbox shell NAME [-- CMD...]"
  check_name "$name"
  shift
  [[ ${1:-} == -- ]] && shift
  ensure_running "$name"
  if (($# == 0)); then
    rt exec -it "$name" agentbox-enter bash -l
  else
    rt exec -it "$name" agentbox-enter "$@"
  fi
}

cmd_exec() {
  local name=${1:-}
  local -a flags=(-i)
  [[ -n $name ]] || die "usage: agentbox exec NAME -- CMD..."
  check_name "$name"
  shift
  [[ ${1:-} == -- ]] && shift
  (($# > 0)) || die "usage: agentbox exec NAME -- CMD..."
  [[ -t 0 && -t 1 ]] && flags+=(-t)
  ensure_running "$name"
  rt exec "${flags[@]}" "$name" agentbox-enter "$@"
}

cmd_secrets() {
  local name=${1:-} dir use_defaults="" changed=no
  local -a secret_files=()
  [[ -n $name ]] || die "usage: agentbox secrets NAME [--secrets FILE]... [--no-default-secrets|--default-secrets]"
  check_name "$name"
  shift
  while (($# > 0)); do
    case $1 in
      --secrets)
        (($# >= 2)) || die "--secrets needs a file"
        [[ -r $2 ]] || die "secrets file not readable: $2"
        secret_files+=("$(realpath "$2")")
        changed=yes
        shift 2
        ;;
      --no-default-secrets)
        use_defaults=no
        changed=yes
        shift
        ;;
      --default-secrets)
        use_defaults=yes
        changed=yes
        shift
        ;;
      *) die "unknown secrets option: $1" ;;
    esac
  done
  if [[ $changed == yes ]]; then
    dir=$(state_dir "$name")
    if [[ -z $use_defaults ]]; then
      use_defaults=yes
      [[ -r $dir/defaults ]] && use_defaults=$(<"$dir/defaults")
    fi
    save_secret_choice "$name" "$use_defaults" "${secret_files[@]}"
  fi
  ensure_running "$name"
  note "secrets delivered to $name; open a new shell to load them"
}

cmd_forward() {
  local name=${1:-} port=${2:-} host_port=${3:-}
  [[ -n $name && -n $port ]] || die "usage: agentbox forward NAME PORT [HOSTPORT]"
  check_name "$name"
  [[ $port =~ ^[0-9]+$ ]] || die "invalid port '$port'"
  host_port=${host_port:-$port}
  [[ $host_port =~ ^[0-9]+$ ]] || die "invalid port '$host_port'"
  [[ $(require_container "$name") == running ]] || die "$name is not running"
  note "forwarding 127.0.0.1:$host_port -> $name:127.0.0.1:$port (Ctrl-C to stop)"
  # One exec per connection, so ports need no publishing at create.
  exec socat "TCP-LISTEN:$host_port,bind=127.0.0.1,reuseaddr,fork" \
    "EXEC:$0 _pipe $name $port"
}

# Internal: stdio <-> container TCP port, for forward.
cmd_pipe() {
  rt exec -i "$1" socat - "TCP:127.0.0.1:$2"
}

cmd_stop() {
  (($# == 1)) || die "usage: agentbox stop NAME"
  check_name "$1"
  require_container "$1" >/dev/null
  rt stop "$1" >/dev/null
}

cmd_logs() {
  (($# == 1)) || die "usage: agentbox logs NAME"
  check_name "$1"
  rt logs "$1"
}

cmd_upgrade() {
  local name=${1:-} dir
  local -a create_args=()
  [[ -n $name ]] || die "usage: agentbox upgrade NAME"
  check_name "$name"
  require_container "$name" >/dev/null
  rt_image_present || die "image $image_name missing; run agentbox build"
  image_home
  dir=$(state_dir "$name")
  if [[ -r $dir/create-args ]]; then
    mapfile -t create_args <"$dir/create-args"
  fi
  note "recreating $name; \$HOME ($name-home) is kept, /nix resets to the image"
  rt stop "$name" >/dev/null 2>&1 || true
  rt_remove "$name"
  rt_create "$name" "${create_args[@]}"
  ensure_running "$name"
}

cmd_rm() {
  local name=${1:-} volume=no
  [[ -n $name ]] || die "usage: agentbox rm NAME [--volume]"
  check_name "$name"
  [[ ${2:-} == --volume ]] && volume=yes
  if [[ -n $(rt_status "$name") ]]; then
    rt_remove "$name"
  fi
  if [[ $volume == yes ]]; then
    rt_volume_remove "$name-home"
    rm -rf "$(state_dir "$name")"
    note "removed $name and its home volume"
  else
    note "removed $name; home volume $name-home kept (rm $name --volume to delete)"
  fi
}

main() {
  local command=${1:-help}
  (($# > 0)) && shift
  case $command in
    help | -h | --help)
      usage
      return
      ;;
    _encode-env)
      # Internal, for tests: the secrets file parser.
      encode_env_file "$1"
      return
      ;;
  esac
  load_config
  select_backend
  rt_prepare
  mkdir -p "$cache_root"
  case $command in
    backend) printf '%s %s\n' "$backend" "$runtime_bin" ;;
    build) cmd_build "$@" ;;
    create) cmd_create "$@" ;;
    start) cmd_start "$@" ;;
    shell) cmd_shell "$@" ;;
    exec) cmd_exec "$@" ;;
    clone) cmd_clone "$@" ;;
    secrets) cmd_secrets "$@" ;;
    forward) cmd_forward "$@" ;;
    _pipe) cmd_pipe "$@" ;;
    stop) cmd_stop "$@" ;;
    logs) cmd_logs "$@" ;;
    list | ls) rt_list ;;
    upgrade) cmd_upgrade "$@" ;;
    rm) cmd_rm "$@" ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
