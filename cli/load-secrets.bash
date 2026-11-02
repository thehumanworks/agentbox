# Sourced inside agentbox containers (agentbox-enter, interactive bash). The
# CLI writes /run/agent-secrets/env (tmpfs, mode 0600) as NAME<TAB>BASE64
# lines; nothing in it is evaluated.
_agentbox_load_secrets() {
  local _agentbox_restore_xtrace=0
  case $- in
    *x*) _agentbox_restore_xtrace=1; set +x ;;
  esac

  local _agentbox_file=${AGENTBOX_SECRETS_FILE:-/run/agent-secrets/env}
  local _agentbox_name _agentbox_encoded _agentbox_value
  if [[ -r "$_agentbox_file" ]]; then
    while IFS=$'\t' read -r _agentbox_name _agentbox_encoded; do
      [[ $_agentbox_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      if _agentbox_value=$(printf '%s' "$_agentbox_encoded" | base64 -d); then
        # Quoted export treats values as data, even if they contain shell syntax.
        export "$_agentbox_name=$_agentbox_value"
      else
        printf 'agentbox: could not decode secret %s\n' "$_agentbox_name" >&2
      fi
    done < "$_agentbox_file"
  fi

  if (( _agentbox_restore_xtrace )); then
    set -x
  fi
  return 0
}

_agentbox_load_secrets
unset -f _agentbox_load_secrets
