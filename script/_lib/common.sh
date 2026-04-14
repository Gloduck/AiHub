#!/usr/bin/env bash

lib_dir() {
  cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd
}

script_root() {
  cd -P "$(lib_dir)/.." >/dev/null 2>&1 && pwd
}

repo_root() {
  cd -P "$(script_root)/.." >/dev/null 2>&1 && pwd
}

resolve_from_cwd() {
  local raw_path="$1"

  if [[ "$raw_path" = /* ]]; then
    realpath -m "$raw_path"
    return
  fi

  realpath -m "$PWD/$raw_path"
}

resolve_from_repo() {
  local root
  root="$(repo_root)"
  realpath -m "$root/$1"
}

ensure_parent_dir() {
  mkdir -p "$(dirname "$1")"
}

trim_whitespace() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*" >&2
}

debug() {
  if [[ "${SCRIPT_VERBOSE:-0}" = "1" ]]; then
    log "DEBUG" "$@"
  fi
}

info() {
  log "INFO" "$@"
}

warn() {
  log "WARN" "$@"
}

die() {
  log "ERROR" "$@"
  exit 1
}

require_cmd() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
}
