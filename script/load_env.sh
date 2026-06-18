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
  --verbose  print process information
  --help     show this message

Default env.ini lookup order when --file is omitted:
  1. script directory/env.ini
  2. current working directory/env.ini

Supported file format:
  - one KEY=VALUE entry per line
  - key is the text before the first =
  - value is loaded as-is and may contain =

Notes:
  This script must be sourced, otherwise exported variables only affect a child shell.
EOF
}

is_sourced() {
  [[ "${BASH_SOURCE[0]}" != "$0" ]]
}

verbose_log() {
  if [[ "$SCRIPT_VERBOSE" == "1" ]]; then
    printf '%s\n' "$*" >&2
  fi
}

error() {
  printf 'error: %s\n' "$*" >&2
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

  if [[ ! -f "$env_file" ]]; then
    error "env file not found: $env_file"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    [[ -z "$line" ]] && continue
    if [[ "$line" != *=* ]]; then
      error "invalid line in env file: $line"
      return 1
    fi

    key="${line%%=*}"
    value="${line#*=}"

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      error "invalid env name: $key"
      return 1
    fi

    export "$key=$value"
    verbose_log "loaded $key"
    loaded_keys+=("$key")
    count=$((count + 1))
  done <"$env_file"

  verbose_log "loaded $count variables from $env_file"
  if [[ "$count" -gt 0 ]]; then
    verbose_log "loaded keys: ${loaded_keys[*]}"
  else
    verbose_log "loaded keys: (none)"
  fi
}

main() {
  local env_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)
        if [[ $# -lt 2 ]]; then
          error "--file requires a value"
          return 1
        fi
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
        error "unknown argument: $1"
        return 1
        ;;
    esac
  done

  if ! is_sourced; then
    error "this script must be sourced, for example: source $SCRIPT_NAME [--file PATH]"
    return 1
  fi

  env_file="$(resolve_env_file "$env_file")"
  if [[ -z "$env_file" ]]; then
    error "env.ini not found in script directory or current working directory"
    return 1
  fi
  load_env_file "$env_file"
}

main "$@"
