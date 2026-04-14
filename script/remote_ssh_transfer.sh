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
Usage: remote_ssh_transfer.sh [-h] upload|download [--host HOST] [--port PORT] [--user USER] [--password PASSWORD] [--source SOURCE] --destination DESTINATION [--accept-host-key] [--verbose]

Description:
  Transfer files or directories between local and remote Linux hosts over SSH.

Options:
  -h, --help                    Show this help message and exit.
  upload|download               Transfer direction.
  --host HOST                   Target Linux server address. Fallback env: REMOTE_SSH_HOST.
  --port PORT                   SSH port. Default: 22. Fallback env: REMOTE_SSH_PORT.
  --user USER                   SSH username. Fallback env: REMOTE_SSH_USER.
  --password PASSWORD           SSH password. Optional when using ssh key auth. Fallback env: REMOTE_SSH_PASSWORD.
  --source SOURCE               Source file or directory. Can be provided multiple times.
  --destination DESTINATION     Destination directory. Created automatically if missing.
  --accept-host-key             Set StrictHostKeyChecking=accept-new.
  --verbose                     Print debug logs.

Required inputs:
  upload|download, --host, --user, --destination, and at least one --source

Behavior:
  Repeated --source values are transferred in order.
  Sources can be files or directories.
  For upload, local sources are copied into the remote destination directory.
  For download, remote sources are copied into the local destination directory.
  The destination directory is created automatically when missing.
  Transferred sources keep their source basenames.
  If --password and REMOTE_SSH_PASSWORD are both omitted, ssh key or ssh-agent authentication is used.


Requirements:
  Requires local shell, local ssh client, and local scp client.
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

(( $# > 0 )) || {
  usage
  exit 1
}

direction="$1"
shift

case "$direction" in
  upload|download) ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    die "direction must be upload or download"
    ;;
esac

host="${REMOTE_SSH_HOST:-}"
port="${REMOTE_SSH_PORT:-22}"
user_name="${REMOTE_SSH_USER:-}"
password="${REMOTE_SSH_PASSWORD:-}"
destination=""
accept_host_key=0
SCRIPT_VERBOSE=0
sources=()

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
    --source)
      [[ $# -ge 2 ]] || die "--source requires a value"
      sources+=("$2")
      shift 2
      ;;
    --destination)
      [[ $# -ge 2 ]] || die "--destination requires a value"
      destination="$2"
      shift 2
      ;;
    --accept-host-key)
      accept_host_key=1
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
[[ -n "$destination" ]] || die "--destination is required"
[[ "$port" =~ ^[0-9]+$ ]] || die "invalid $PORT_ENV: $port"
(( ${#sources[@]} > 0 )) || die "at least one --source is required"

require_cmd ssh
require_cmd scp
build_ssh_options

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/remote-transfer.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

ssh_env=()
if [[ -n "$password" ]]; then
  askpass_path="$temp_dir/askpass.sh"
  create_askpass_script "$askpass_path"
  ssh_env+=(
    "$PASSWORD_ENV=$password"
    "SSH_ASKPASS=$askpass_path"
    "SSH_ASKPASS_REQUIRE=force"
    "DISPLAY=${DISPLAY:-remote-$direction}"
  )
fi

info "connecting to $user_name@$host:$port"

if [[ "$direction" == "upload" ]]; then
  upload_sources=()
  for source in "${sources[@]}"; do
    source_path="$(resolve_from_cwd "$source")"
    [[ -e "$source_path" ]] || die "source not found: $source_path"
    upload_sources+=("$source_path")
  done

  mkdir_command="mkdir -p -- $(quote_for_remote_shell "$destination")"
  mkdir_ssh_command=(
    ssh
    -p "$port"
    "${ssh_options[@]}"
    "$user_name@$host"
    "$mkdir_command"
  )
  upload_target="$user_name@$host:$destination"
  scp_command=(
    scp
    -r
    -P "$port"
    "${ssh_options[@]}"
    "${upload_sources[@]}"
    "$upload_target"
  )

  info "uploading ${#upload_sources[@]} source(s) to $destination"
  debug "mkdir command: ${mkdir_ssh_command[*]}"
  debug "scp command: ${scp_command[*]}"

  set +e
  env "${ssh_env[@]}" "${mkdir_ssh_command[@]}"
  mkdir_exit_code=$?
  set -e
  (( mkdir_exit_code == 0 )) || exit "$mkdir_exit_code"

  set +e
  env "${ssh_env[@]}" "${scp_command[@]}"
  scp_exit_code=$?
  set -e
  exit "$scp_exit_code"
fi

download_destination="$(resolve_from_cwd "$destination")"
mkdir -p "$download_destination"
[[ -d "$download_destination" ]] || die "destination is not a directory: $download_destination"

download_sources=()
for source in "${sources[@]}"; do
  download_sources+=("$user_name@$host:$source")
done

scp_command=(
  scp
  -r
  -P "$port"
  "${ssh_options[@]}"
  "${download_sources[@]}"
  "$download_destination"
)

info "downloading ${#download_sources[@]} source(s) to $download_destination"
debug "scp command: ${scp_command[*]}"

set +e
env "${ssh_env[@]}" "${scp_command[@]}"
scp_exit_code=$?
set -e
exit "$scp_exit_code"
