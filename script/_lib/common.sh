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
  local normalized_path="$raw_path"
  local drive_letter

  if [[ "$raw_path" = /* ]]; then
    realpath -m "$raw_path"
    return
  fi

  if [[ "$raw_path" =~ ^[A-Za-z]:[\\/] ]]; then
    if command -v cygpath >/dev/null 2>&1; then
      normalized_path="$(cygpath -u "$raw_path")"
    else
      drive_letter="${raw_path:0:1}"
      drive_letter="${drive_letter,}"
      normalized_path="/$drive_letter/${raw_path:2}"
      normalized_path="${normalized_path//\\//}"
    fi
    realpath -m "$normalized_path"
    return
  fi

  if [[ ( "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || "${OSTYPE:-}" == win32* ) && "$raw_path" == *\\* ]]; then
    normalized_path="${raw_path//\\//}"
  fi

  realpath -m "$PWD/$normalized_path"
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
