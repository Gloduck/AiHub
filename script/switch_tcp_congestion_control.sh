#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=_lib/common.sh
source "$SCRIPT_DIR/_lib/common.sh"

SCRIPT_VERBOSE=0
algorithm=""
sysctl_config_file="/etc/sysctl.d/99-tcp-congestion-control.conf"
module_config_file="/etc/modules-load.d/tcp_bbr.conf"
legacy_sysctl_config_file="/etc/sysctl.d/99-bbr.conf"
legacy_module_config_file="/etc/modules-load.d/bbr.conf"

usage() {
  cat <<'USAGE'
Usage: switch_tcp_congestion_control.sh --algorithm NAME [--verbose]

Purpose:
  Switch the system TCP congestion control algorithm.

Required inputs:
  --algorithm   bbr | cubic | reno

Optional inputs:
  --verbose     print debug logs
  --help        show this message

Default behavior:
  No interactive mode. The script fails if --algorithm is missing.

Side effects:
  Writes /etc/sysctl.d/99-tcp-congestion-control.conf.
  When --algorithm bbr is used, writes /etc/modules-load.d/tcp_bbr.conf and loads tcp_bbr.
  When --algorithm cubic or reno is used, removes the tcp_bbr module auto-load file.
  Legacy files /etc/sysctl.d/99-bbr.conf and /etc/modules-load.d/bbr.conf are removed if present.

Examples:
  sudo script/switch_tcp_congestion_control.sh --algorithm bbr
  sudo script/switch_tcp_congestion_control.sh --algorithm cubic
USAGE
}

validate_algorithm() {
  case "$1" in
    bbr|cubic|reno) ;;
    *)
      die "unsupported algorithm: $1"
      ;;
  esac
}

require_root_user() {
  if [[ "$EUID" -ne 0 ]]; then
    die "this script must be run as root, for example: sudo $0 --algorithm ${algorithm:-bbr}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --algorithm)
        [[ $# -ge 2 ]] || die "--algorithm requires a value"
        algorithm="$2"
        shift 2
        ;;
      --verbose)
        SCRIPT_VERBOSE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$algorithm" ]] || die "--algorithm is required"
  validate_algorithm "$algorithm"
}

ensure_supported_algorithm() {
  local available

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  [[ " $available " == *" $algorithm "* ]] || die "algorithm not available in kernel: $algorithm"
}

remove_legacy_configs() {
  rm -f "$legacy_sysctl_config_file" "$legacy_module_config_file"
}

configure_bbr_module() {
  if [[ "$algorithm" == "bbr" ]]; then
    require_cmd modprobe
    modprobe tcp_bbr
    printf 'tcp_bbr\n' > "$module_config_file"
  else
    rm -f "$module_config_file"
  fi
}

write_sysctl_config() {
  cat > "$sysctl_config_file" <<EOF2
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$algorithm
EOF2
}

apply_runtime_settings() {
  require_cmd sysctl
  sysctl -w net.core.default_qdisc=fq >/dev/null
  sysctl -w net.ipv4.tcp_congestion_control="$algorithm" >/dev/null
}

print_status() {
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_available_congestion_control
}

main() {
  parse_args "$@"
  require_root_user
  debug "selected algorithm: $algorithm"
  configure_bbr_module
  ensure_supported_algorithm
  remove_legacy_configs
  write_sysctl_config
  apply_runtime_settings
  print_status
}

main "$@"
