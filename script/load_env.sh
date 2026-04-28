#!/usr/bin/env bash

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_VERBOSE=0

usage() {
  cat <<EOF
Usage: source ${SCRIPT_NAME} [--file PATH] [--verbose]

Purpose:
  Load KEY=VALUE entries from env.ini into the current shell environment and print loaded keys.

Optional inputs:
  --file     custom env.ini path
  --verbose  print debug logs
  --help     show this message

Default env.ini lookup order when --file is omitted:
  1. script directory/env.ini
  2. current working directory/env.ini

Supported file format:
  - one KEY=VALUE entry per line
  - each line must contain exactly one =
  - value is loaded as-is

Notes:
  This script must be sourced, otherwise exported variables only affect a child shell.
EOF
}

is_sourced() {
  [[ "${BASH_SOURCE[0]}" != "$0" ]]
}

log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*" >&2
}

debug() {
  if [[ "$SCRIPT_VERBOSE" == "1" ]]; then
    log "DEBUG" "$@"
  fi
}

info() {
  log "INFO" "$@"
}

fail() {
  log "ERROR" "$@"
  return 1
}

resolve_env_file() {
  local raw_path="$1"

  if [[ -n "$raw_path" ]]; then
    if [[ "$raw_path" = /* ]]; then
      printf '%s\n' "$raw_path"
    else
      printf '%s\n' "$PWD/$raw_path"
    fi
    return
  fi

  if [[ -f "$SCRIPT_DIR/env.ini" ]]; then
    printf '%s\n' "$SCRIPT_DIR/env.ini"
    return
  fi

  if [[ -f "$PWD/env.ini" ]]; then
    printf '%s\n' "$PWD/env.ini"
    return
  fi

  printf '\n'
}

load_env_file() {
  local env_file="$1"
  local line
  local key
  local value
  local count=0
  local loaded_keys=()

  [[ -f "$env_file" ]] || fail "env file not found: $env_file" || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || fail "invalid line in env file: $line" || return 1
    [[ "${line#*=}" != *"="* ]] || fail "invalid line in env file: $line" || return 1

    key="${line%%=*}"
    value="${line#*=}"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "invalid env name: $key" || return 1

    export "$key=$value"
    debug "loaded $key"
    loaded_keys+=("$key")
    count=$((count + 1))
  done <"$env_file"

  info "loaded $count variables from $env_file"
  if [[ "$count" -gt 0 ]]; then
    info "loaded keys: ${loaded_keys[*]}"
  else
    info "loaded keys: (none)"
  fi
}

main() {
  local env_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)
        [[ $# -ge 2 ]] || fail "--file requires a value" || return 1
        env_file="$2"
        shift 2
        ;;
      --verbose)
        SCRIPT_VERBOSE=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        fail "unknown argument: $1" || return 1
        ;;
    esac
  done

  if ! is_sourced; then
    fail "this script must be sourced, for example: source ${SCRIPT_NAME} [--file PATH]" || return 1
  fi

  env_file="$(resolve_env_file "$env_file")"
  [[ -n "$env_file" ]] || fail "env.ini not found in script directory or current working directory" || return 1
  load_env_file "$env_file"
}

main "$@"
