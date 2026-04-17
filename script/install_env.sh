#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=_lib/common.sh
source "$SCRIPT_DIR/_lib/common.sh"

usage() {
  cat <<'EOF'
Usage: install_env.sh [--env NAME] [--version VERSION] [--install-dir PATH] [--arch ARCH] [--config PATH] [--force] [--no-profile] [--verbose]

Required inputs:
  --env          node | maven | java | python | golang
  --version      package version from config json
  --install-dir  install target directory

Optional inputs:
  --arch         x64 | arm64, override detected machine arch
  --config       custom config json path, defaults to script/install_env_sources.json
  --force        overwrite target directory if it already exists
  --no-profile   skip writing /etc/profile.d
  --verbose      print debug logs
  --help         show this message

If any required input is missing, the script switches to interactive mode
and prompts for the missing values.
EOF
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'x64\n'
      ;;
    aarch64|arm64)
      printf 'arm64\n'
      ;;
    *)
      die "unsupported architecture: $(uname -m)"
      ;;
  esac
}

validate_env_name() {
  case "$1" in
    node|maven|java|python|golang) ;;
    *)
      die "unsupported env: $1"
      ;;
  esac
}

validate_arch() {
  case "$1" in
    x64|arm64) ;;
    *)
      die "unsupported arch: $1"
      ;;
  esac
}

prompt_required() {
  local message="$1"
  local answer
  read -r -p "$message: " answer
  printf '%s\n' "$answer"
}

prompt_numbered_choice() {
  local prompt_message="$1"
  shift
  local options=("$@")
  local index=1
  local answer

  for option in "${options[@]}"; do
    printf '%d. %s\n' "$index" "$option" >&2
    index=$((index + 1))
  done

  read -r -p "$prompt_message: " answer
  [[ "$answer" =~ ^[0-9]+$ ]] || die "invalid selection: $answer"
  (( answer >= 1 && answer <= ${#options[@]} )) || die "selection out of range: $answer"
  printf '%s\n' "${options[$((answer - 1))]}"
}

prompt_env_numbered() {
  env_name="$(prompt_numbered_choice "Please select env" node maven java python golang)"
}

prompt_version_numbered() {
  mapfile -t versions < <(print_versions)
  (( ${#versions[@]} > 0 )) || die "no versions available for env=$env_name os=linux arch=$arch"
  version="$(prompt_numbered_choice "Please select version" "${versions[@]}")"
}

prompt_no_profile_numbered() {
  local choice
  choice="$(prompt_numbered_choice "Please select profile mode" write-profile skip-profile)"
  if [[ "$choice" == "skip-profile" ]]; then
    no_profile=1
  else
    no_profile=0
  fi
}

print_versions() {
  jq -r \
    --arg env_name "$env_name" \
    --arg os_arch "linux-$arch" \
    --arg os_any "linux-any" \
    '.[$env_name].version // {}
      | to_entries
      | map(select((.value[$os_arch] // .value[$os_any]) != null))
      | map(.key)
      | sort[]' \
    "$config_path"
}

lookup_url() {
  jq -cer \
    --arg env_name "$env_name" \
    --arg version "$version" \
    --arg os_arch "linux-$arch" \
    --arg os_any "linux-any" \
    '.[$env_name].version[$version][$os_arch] // .[$env_name].version[$version][$os_any]' \
    "$config_path"
}

detect_archive_type_from_url() {
  local url="$1"

  case "$url" in
    *.tar.gz)
      printf 'tar.gz\n'
      ;;
    *.tgz)
      printf 'tgz\n'
      ;;
    *.tar.xz)
      printf 'tar.xz\n'
      ;;
    *.zip)
      printf 'zip\n'
      ;;
    *)
      die "unsupported archive type in url: $url"
      ;;
  esac
}

extract_archive() {
  local archive_path="$1"
  local archive_type="$2"
  local target_dir="$3"

  case "$archive_type" in
    tar.gz|tgz)
      require_cmd tar
      tar -xzf "$archive_path" -C "$target_dir"
      ;;
    tar.xz)
      require_cmd tar
      tar -xJf "$archive_path" -C "$target_dir"
      ;;
    zip)
      require_cmd unzip
      unzip -q "$archive_path" -d "$target_dir"
      ;;
    *)
      die "unsupported archive type: $archive_type"
      ;;
  esac
}

copy_payload() {
  local extract_dir="$1"
  local target_dir="$2"
  local source_dir="$extract_dir"

  shopt -s dotglob nullglob
  local items=("$extract_dir"/*)

  if (( ${#items[@]} == 1 )) && [[ -d "${items[0]}" ]]; then
    source_dir="${items[0]}"
  fi

  mkdir -p "$target_dir"
  cp -a "$source_dir"/. "$target_dir"/
  shopt -u dotglob nullglob
}

print_env_hints() {
  printf '\nInstalled %s %s to %s\n' "$env_name" "$version" "$install_dir"
  if [[ "$no_profile" == "1" ]]; then
    printf 'Profile update skipped\n'
  else
    printf 'Profile updated: %s\n' "$profile_file"
  fi
  printf 'Open a new terminal to use the updated environment.\n'
}

is_graalvm_java() {
  [[ "$env_name" == "java" && "$version" == graalvm-* ]]
}

check_profile_permissions() {
  [[ "$no_profile" == "1" ]] && return

  if [[ ! -d "/etc/profile.d" ]]; then
    die "/etc/profile.d does not exist"
  fi

  if [[ ! -w "/etc/profile.d" ]]; then
    die "/etc/profile.d is not writable, rerun with sufficient privileges"
  fi
}

write_profile_script() {
  local target_file="$1"

  check_profile_permissions

  case "$env_name" in
    node)
      cat >"$target_file" <<EOF
#!/usr/bin/env sh
export PATH="$install_dir/bin:\$PATH"
EOF
      ;;
    maven)
      cat >"$target_file" <<EOF
#!/usr/bin/env sh
export M2_HOME="$install_dir"
export PATH="$install_dir/bin:\$PATH"
EOF
      ;;
    java)
      if is_graalvm_java; then
        cat >"$target_file" <<EOF
#!/usr/bin/env sh
export JAVA_HOME="$install_dir"
export GRAALVM_HOME="$install_dir"
export PATH="$install_dir/bin:\$PATH"
EOF
      else
        cat >"$target_file" <<EOF
#!/usr/bin/env sh
export JAVA_HOME="$install_dir"
export PATH="$install_dir/bin:\$PATH"
EOF
      fi
      ;;
    python)
      cat >"$target_file" <<EOF
#!/usr/bin/env sh
export PATH="$install_dir/bin:\$PATH"
EOF
      ;;
    golang)
      cat >"$target_file" <<EOF
#!/usr/bin/env sh
export GOROOT="$install_dir"
export PATH="$install_dir/bin:\$PATH"
EOF
      ;;
  esac

  chmod 644 "$target_file"
}

env_name=""
version=""
arch=""
install_dir=""
force=0
no_profile=0
no_profile_specified=0
interactive_mode=0
config_path="$SCRIPT_DIR/install_env_sources.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      env_name="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      version="$2"
      shift 2
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || die "--install-dir requires a value"
      install_dir="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires a value"
      arch="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || die "--config requires a value"
      config_path="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    --no-profile)
      no_profile=1
      no_profile_specified=1
      shift
      ;;
    --verbose)
      export SCRIPT_VERBOSE=1
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

require_cmd curl
require_cmd jq
require_cmd realpath
require_cmd mktemp

config_path="$(resolve_from_cwd "$config_path")"
[[ -f "$config_path" ]] || die "config file not found: $config_path"

if [[ -z "$env_name" ]]; then
  interactive_mode=1
  prompt_env_numbered
fi
validate_env_name "$env_name"

detected_arch="$(detect_arch)"
if [[ -z "$arch" ]]; then
  arch="$detected_arch"
fi
validate_arch "$arch"

if [[ -z "$version" ]]; then
  interactive_mode=1
  printf 'Available versions for %s (%s):\n' "$env_name" "$arch"
  prompt_version_numbered
fi
[[ -n "$version" ]] || die "version is required"

if [[ -z "$install_dir" ]]; then
  interactive_mode=1
  install_dir="$(prompt_required "Please input install dir")"
fi
[[ -n "$install_dir" ]] || die "install dir is required"

if [[ "$interactive_mode" == "1" && "$no_profile_specified" != "1" ]]; then
  prompt_no_profile_numbered
fi

install_dir="$(resolve_from_cwd "$install_dir")"
profile_file="/etc/profile.d/${env_name}.sh"
check_profile_permissions

package_url="$(lookup_url)" || die "no package found for env=$env_name version=$version os=linux arch=$arch"
archive_type="$(detect_archive_type_from_url "$package_url")"

if [[ -e "$install_dir" ]]; then
  if [[ "$force" == "1" ]]; then
    rm -rf "$install_dir"
  else
    die "install dir already exists: $install_dir, use --force to overwrite"
  fi
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
archive_path="$tmp_dir/package.${archive_type##*.}"
extract_dir="$tmp_dir/extract"
mkdir -p "$extract_dir"

info "downloading $package_url"
curl -fL "$package_url" -o "$archive_path"
extract_archive "$archive_path" "$archive_type" "$extract_dir"
copy_payload "$extract_dir" "$install_dir"
if [[ "$no_profile" != "1" ]]; then
  write_profile_script "$profile_file"
fi
print_env_hints
