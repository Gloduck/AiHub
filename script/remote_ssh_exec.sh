#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=_lib/common.sh
source "$SCRIPT_DIR/_lib/common.sh"

HOST_ENV="REMOTE_SSH_HOST"
PORT_ENV="REMOTE_SSH_PORT"
USER_ENV="REMOTE_SSH_USER"
PASSWORD_ENV="REMOTE_SSH_PASSWORD"

usage() {
  cat <<'EOF'
Usage: remote_ssh_exec.sh [-h] [--host HOST] [--port PORT] [--user USER] [--password PASSWORD] [--command COMMAND] [--command-file COMMAND_FILE] [--accept-host-key] [--tty] [--verbose]

Description:
  Execute remote Linux bash commands over SSH and stream output in real time.

Options:
  -h, --help                 Show this help message and exit.
  --host HOST                Target Linux server address. Fallback env: REMOTE_SSH_HOST.
  --port PORT                SSH port. Default: 22. Fallback env: REMOTE_SSH_PORT.
  --user USER                SSH username. Fallback env: REMOTE_SSH_USER.
  --password PASSWORD        SSH password. Optional when using ssh key auth. Fallback env: REMOTE_SSH_PASSWORD.
  --command COMMAND          Remote Linux bash command to run. Can be provided multiple times.
  --command-file COMMAND_FILE
                             Local file containing remote Linux bash commands. Can be provided multiple times.
  --accept-host-key          Set StrictHostKeyChecking=accept-new.
  --tty                      Allocate a remote TTY for interactive commands like top.
  --verbose                  Print debug logs.

Required inputs:
  --host, --user, and at least one --command or --command-file

Behavior:
  Commands from repeated --command flags are appended in order.
  Commands from --command-file are appended after inline commands.
  Remote Linux commands run as: bash -se
  Remote stdout/stderr is streamed directly to the local console in real time.
  Use --tty for interactive commands such as top.
  This script runs remote Linux bash commands over SSH. It does not execute local Windows cmd or PowerShell commands.
  If --password and REMOTE_SSH_PASSWORD are both omitted, ssh key or ssh-agent authentication is used.

Notes:
  --tty requires exactly one --command and does not support --command-file.

Requirements:
  Requires local shell and local ssh client.
  No interactive prompts are used.

Environment variables:
  REMOTE_SSH_HOST
  REMOTE_SSH_PORT
  REMOTE_SSH_USER
  REMOTE_SSH_PASSWORD
EOF
}

quote_for_remote_shell() {
  local value="$1"
  value=${value//\'/\'\"\'\"\'}
  printf "'%s'" "$value"
}

create_askpass_script() {
  local askpass_path="$1"
  cat >"$askpass_path" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "${REMOTE_SSH_PASSWORD:-}"
EOF
  chmod +x "$askpass_path"
}

build_ssh_options() {
  ssh_options=(
    -o
    "StrictHostKeyChecking=$( (( accept_host_key )) && printf 'accept-new' || printf 'yes' )"
  )

  if [[ -n "$password" ]]; then
    ssh_options=(
      -o BatchMode=no
      -o PreferredAuthentications=password,keyboard-interactive
      -o PubkeyAuthentication=no
      -o NumberOfPasswordPrompts=1
      "${ssh_options[@]}"
    )
  else
    ssh_options=(
      -o BatchMode=yes
      "${ssh_options[@]}"
    )
  fi
}

host="${REMOTE_SSH_HOST:-}"
port="${REMOTE_SSH_PORT:-22}"
user_name="${REMOTE_SSH_USER:-}"
password="${REMOTE_SSH_PASSWORD:-}"
accept_host_key=0
tty=0
SCRIPT_VERBOSE=0
commands=()
command_files=()

while (( $# > 0 )); do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      host="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      port="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || die "--user requires a value"
      user_name="$2"
      shift 2
      ;;
    --password)
      [[ $# -ge 2 ]] || die "--password requires a value"
      password="$2"
      shift 2
      ;;
    --command)
      [[ $# -ge 2 ]] || die "--command requires a value"
      commands+=("$2")
      shift 2
      ;;
    --command-file)
      [[ $# -ge 2 ]] || die "--command-file requires a value"
      command_files+=("$(resolve_from_cwd "$2")")
      shift 2
      ;;
    --accept-host-key)
      accept_host_key=1
      shift
      ;;
    --tty)
      tty=1
      shift
      ;;
    --verbose)
      SCRIPT_VERBOSE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$host" ]] || die "--host is required or set $HOST_ENV"
[[ -n "$user_name" ]] || die "--user is required or set $USER_ENV"
[[ "$port" =~ ^[0-9]+$ ]] || die "invalid $PORT_ENV: $port"

(( ${#commands[@]} > 0 || ${#command_files[@]} > 0 )) || die "at least one --command or --command-file is required"

if (( tty )); then
  (( ${#command_files[@]} == 0 )) || die "--tty does not support --command-file; use a single --command"
  (( ${#commands[@]} == 1 )) || die "--tty requires exactly one --command"
fi

for command_file in "${command_files[@]}"; do
  [[ -f "$command_file" ]] || die "command file not found: $command_file"
done

require_cmd ssh
build_ssh_options

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/remote-exec.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

ssh_env=()
if [[ -n "$password" ]]; then
  askpass_path="$temp_dir/askpass.sh"
  create_askpass_script "$askpass_path"
  ssh_env+=(
    "$PASSWORD_ENV=$password"
    "SSH_ASKPASS=$askpass_path"
    "SSH_ASKPASS_REQUIRE=force"
    "DISPLAY=${DISPLAY:-remote-exec}"
  )
fi

info "connecting to $user_name@$host:$port"

if (( tty )); then
  tty_command_quoted="$(quote_for_remote_shell "${commands[0]}")"
  ssh_command=(
    ssh
    -tt
    -p "$port"
    "${ssh_options[@]}"
    "$user_name@$host"
    bash
    -lc
    "$tty_command_quoted"
  )
  debug "ssh command: ${ssh_command[*]}"

  set +e
  env "${ssh_env[@]}" "${ssh_command[@]}"
  exit_code=$?
  set -e
  exit "$exit_code"
fi

remote_script_file="$temp_dir/remote-script.sh"
for command in "${commands[@]}"; do
  printf '%s\n' "$command" >>"$remote_script_file"
done
for command_file in "${command_files[@]}"; do
  cat "$command_file" >>"$remote_script_file"
  printf '\n' >>"$remote_script_file"
done

ssh_command=(
  ssh
  -T
  -p "$port"
  "${ssh_options[@]}"
  "$user_name@$host"
  bash
  -se
)
debug "ssh command: ${ssh_command[*]}"
debug "command count: $(( ${#commands[@]} + ${#command_files[@]} ))"

set +e
env "${ssh_env[@]}" "${ssh_command[@]}" <"$remote_script_file"
exit_code=$?
set -e
exit "$exit_code"
