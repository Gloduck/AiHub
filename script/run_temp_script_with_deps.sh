#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# shellcheck source=script/_lib/common.sh
source "$SCRIPT_DIR/_lib/common.sh"

SCRIPT_VERBOSE=0
SUBCOMMAND=""
SCRIPT_INPUT=""
DEPS=""
TEMP_DIR_INPUT=""
AUTO_CLEAN=0
WORK_DIR=""
ENTRY_PATH=""
SOURCE_FILE_PATH=""

usage() {
  cat <<EOF
Usage:
  script/${SCRIPT_NAME} python --script FILE_OR_TEXT [--deps "PKG..."] [--temp-dir PATH] [--auto-clean] [--verbose]
  script/${SCRIPT_NAME} node --script FILE_OR_TEXT [--deps "PKG..."] [--temp-dir PATH] [--auto-clean] [--verbose]

Purpose:
  Run a Python or Node script in a temporary working directory and optionally
  install third-party dependencies into that directory first.

Required inputs:
  python|node         language subcommand
  --script VALUE      source script file path or inline script text

Optional inputs:
  --deps "PKG..."     space-separated dependency list, same option name for both languages
  --temp-dir PATH     explicit temporary directory path
  --auto-clean        delete the temporary directory after execution
  --verbose           print debug logs
  --help              show this message

Default behavior:
  - When --temp-dir is omitted and --script points to an existing file, create
    a random temp directory beside that source file.
  - When --temp-dir is omitted and --script is inline text, create a random
    temp directory under the current working directory.
  - Default is to keep the temporary directory after execution.

Dependency notes:
  - Python installs deps into a local venv under the temp directory.
  - Node installs deps with npm into the temp directory.
  - Quote --deps when passing multiple packages.

Side effects:
  - Creates files under the temp directory.
  - Installs packages into the temp directory when --deps is used.
  - Deletes the temp directory only when --auto-clean is set.

Platform notes:
  - Designed for Linux shell and Git Bash.
EOF
}

cleanup_work_dir() {
  if [[ "$AUTO_CLEAN" == "1" && -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    debug "removing temp directory: $WORK_DIR"
    rm -rf -- "$WORK_DIR"
  fi
}

on_exit() {
  local exit_code="$1"

  if [[ "$exit_code" == "0" ]]; then
    cleanup_work_dir
    return
  fi

  if [[ "$AUTO_CLEAN" == "1" ]]; then
    cleanup_work_dir
  elif [[ -n "$WORK_DIR" ]]; then
    warn "temporary directory kept for inspection: $WORK_DIR"
  fi
}

make_random_work_dir() {
  local parent_dir="$1"
  mkdir -p "$parent_dir"
  mktemp -d "$parent_dir/temp_run_${SUBCOMMAND}.XXXXXX"
}

resolve_source_file_path() {
  local candidate_path

  if [[ "$SCRIPT_INPUT" == *$'\n'* || "$SCRIPT_INPUT" == *$'\r'* ]]; then
    printf '\n'
    return
  fi

  candidate_path="$(resolve_from_cwd "$SCRIPT_INPUT")"

  if [[ -f "$candidate_path" ]]; then
    printf '%s\n' "$candidate_path"
    return
  fi

  printf '\n'
}

prepare_work_dir() {
  local parent_dir

  if [[ -n "$TEMP_DIR_INPUT" ]]; then
    WORK_DIR="$(resolve_from_cwd "$TEMP_DIR_INPUT")"
    mkdir -p "$WORK_DIR"
    return
  fi

  if [[ -n "$SOURCE_FILE_PATH" ]]; then
    parent_dir="$(dirname "$SOURCE_FILE_PATH")"
  else
    parent_dir="$PWD"
  fi

  WORK_DIR="$(make_random_work_dir "$parent_dir")"
}

copy_or_write_entry() {
  local default_name="$1"
  local target_name="$default_name"

  if [[ -n "$SOURCE_FILE_PATH" ]]; then
    target_name="$(basename "$SOURCE_FILE_PATH")"
    cp "$SOURCE_FILE_PATH" "$WORK_DIR/$target_name"
  else
    printf '%s' "$SCRIPT_INPUT" >"$WORK_DIR/$target_name"
  fi

  ENTRY_PATH="$WORK_DIR/$target_name"
}

run_python_script() {
  local python_cmd

  python_cmd="$(command -v python3 || true)"
  if [[ -z "$python_cmd" ]]; then
    python_cmd="$(command -v python || true)"
  fi
  [[ -n "$python_cmd" ]] || die "missing command: python3 or python"

  copy_or_write_entry "main.py"

  if [[ -n "$DEPS" ]]; then
    debug "creating python venv in $WORK_DIR/.venv"
    "$python_cmd" -m venv "$WORK_DIR/.venv"
    # shellcheck disable=SC1091
    source "$WORK_DIR/.venv/bin/activate"
    python -m pip install $DEPS
    python "$ENTRY_PATH"
    deactivate
    return
  fi

  "$python_cmd" "$ENTRY_PATH"
}

run_node_script() {
  require_cmd node
  require_cmd npm

  copy_or_write_entry "main.js"

  if [[ -n "$DEPS" ]]; then
    debug "installing node packages into $WORK_DIR"
    npm --prefix "$WORK_DIR" init -y >/dev/null 2>&1
    npm --prefix "$WORK_DIR" install --no-save $DEPS >/dev/null
  fi

  (
    cd "$WORK_DIR"
    node "$ENTRY_PATH"
  )
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      python|node)
        [[ -z "$SUBCOMMAND" ]] || die "subcommand already set: $SUBCOMMAND"
        SUBCOMMAND="$1"
        ;;
      --script)
        shift
        [[ $# -gt 0 ]] || die "missing value for --script"
        SCRIPT_INPUT="$1"
        ;;
      --deps)
        shift
        [[ $# -gt 0 ]] || die "missing value for --deps"
        DEPS="$1"
        ;;
      --temp-dir)
        shift
        [[ $# -gt 0 ]] || die "missing value for --temp-dir"
        TEMP_DIR_INPUT="$1"
        ;;
      --auto-clean)
        AUTO_CLEAN=1
        ;;
      --verbose)
        SCRIPT_VERBOSE=1
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  [[ -n "$SUBCOMMAND" ]] || die "missing subcommand: python or node"
  [[ -n "$SCRIPT_INPUT" ]] || die "missing required argument: --script"

  SOURCE_FILE_PATH="$(resolve_source_file_path)"
  prepare_work_dir

  debug "language: $SUBCOMMAND"
  debug "temp directory: $WORK_DIR"
  if [[ -n "$SOURCE_FILE_PATH" ]]; then
    debug "source file: $SOURCE_FILE_PATH"
  else
    debug "source mode: inline text"
  fi

  case "$SUBCOMMAND" in
    python)
      run_python_script
      ;;
    node)
      run_node_script
      ;;
    *)
      die "unsupported subcommand: $SUBCOMMAND"
      ;;
  esac

  if [[ "$AUTO_CLEAN" == "0" ]]; then
    info "temporary directory kept at: $WORK_DIR"
  fi
}

trap 'on_exit "$?"' EXIT

main "$@"
