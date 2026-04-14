#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=_lib/common.sh
source "$SCRIPT_DIR/_lib/common.sh"

SCRIPT_VERBOSE=0

usage() {
  cat <<'EOF'
Usage:
  tar_path_map.sh pack --archive FILE (--map RULE | --map-file FILE) [--verbose]
  tar_path_map.sh unpack --archive FILE (--output DIR | --map RULE | --map-file FILE) [--verbose]

Purpose:
  Pack or unpack tar archives with archive-to-local path mapping rules.
  Supports Linux shells and Git Bash on Windows.

Direct mapping format:
  archive/path|/real/path
  archive/path|C:\\real\\path

Rule file format:
  include(archive/path|/real/path)
  exclude(archive/path|/real/path/pattern)

Behavior:
  For pack, directory sources are packed as the contents under the archive path.
  For pack, file or symlink sources are packed to the exact archive path.
  For pack, tar reads sources directly and writes the archive without creating a full snapshot copy.
  For pack, exclude rules only affect include rules with the same archive path prefix.
  For unpack, --output extracts the whole archive to one directory.
  For unpack, --map and --map-file extract selected archive paths to selected local paths.

Required inputs:
  pack:   --archive and at least one --map or --map-file
  unpack: --archive and either --output, or at least one --map/--map-file

Optional inputs:
  --map RULE         Mapping rule in archive/path|/real/path format. Can be repeated.
  --map-file FILE    Text file with include(...) and optional exclude(...) rules.
  --output DIR       Extract the whole archive to this directory. Only for unpack.
  --verbose          Print debug logs.
  --help             Show this message and exit.

Default behavior:
  No interactive mode.
  Supported archive extensions: .tar, .tar.gz, .tgz.

Requirements:
  Requires tar and cp. Writing .tar.gz or .tgz also requires gzip.

Examples:
  script/tar_path_map.sh pack --archive backup.tar.gz --map code|/home/gloduck/code
  script/tar_path_map.sh pack --archive backup.tar.gz --map code|C:\\work\\code
  script/tar_path_map.sh pack --archive backup.tar.gz --map software/opencode.sh|/software/opencode.sh
  script/tar_path_map.sh pack --archive backup.tar.gz --map-file ./mapping.txt
  script/tar_path_map.sh unpack --archive backup.tar.gz --output ./restore
  script/tar_path_map.sh unpack --archive backup.tar.gz --map code|.\\restore\\code
  script/tar_path_map.sh unpack --archive backup.tar.gz --map code|./restore/code
EOF
}

normalize_archive_path() {
  local raw_path="$1"
  local normalized_path="$raw_path"
  local part
  local -a parts=()

  [[ -n "$normalized_path" ]] || die "archive path cannot be empty"
  [[ "$normalized_path" != /* ]] || die "archive path must be relative: $raw_path"

  while [[ "$normalized_path" == */ && "$normalized_path" != "/" ]]; do
    normalized_path="${normalized_path%/}"
  done

  IFS='/' read -r -a parts <<< "$normalized_path"
  (( ${#parts[@]} > 0 )) || die "archive path is invalid: $raw_path"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || die "archive path contains empty segment: $raw_path"
    [[ "$part" != "." ]] || die "archive path contains unsupported segment '.': $raw_path"
    [[ "$part" != ".." ]] || die "archive path contains unsupported segment '..': $raw_path"
  done

  printf '%s\n' "$normalized_path"
}

normalize_listed_member() {
  local member_name="$1"
  local normalized="$member_name"
  local part
  local -a parts=()

  while [[ "$normalized" == ./* ]]; do
    normalized="${normalized#./}"
  done
  while [[ "$normalized" == */ && "$normalized" != "/" ]]; do
    normalized="${normalized%/}"
  done

  [[ -n "$normalized" ]] || return 0
  [[ "$normalized" != /* ]] || die "archive contains absolute path: $member_name"

  IFS='/' read -r -a parts <<< "$normalized"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || die "archive contains empty segment: $member_name"
    [[ "$part" != "." ]] || die "archive contains unsupported segment '.': $member_name"
    [[ "$part" != ".." ]] || die "archive contains unsupported segment '..': $member_name"
  done

  printf '%s\n' "$normalized"
}

parse_mapping() {
  local raw_mapping="$1"
  local -n archive_out="$2"
  local -n filesystem_out="$3"
  local archive_part="${raw_mapping%%|*}"
  local filesystem_part="${raw_mapping#*|}"

  [[ "$raw_mapping" == *'|'* ]] || die "mapping must look like archive/path|/real/path: $raw_mapping"
  [[ -n "$filesystem_part" ]] || die "mapping must look like archive/path|/real/path: $raw_mapping"

  archive_part="$(trim_whitespace "$archive_part")"
  filesystem_part="$(trim_whitespace "$filesystem_part")"

  archive_out="$(normalize_archive_path "$archive_part")"
  filesystem_out="$(resolve_from_cwd "$filesystem_part")"
}

parse_rule_line() {
  local line="$1"
  local file_path="$2"
  local line_number="$3"
  local body

  if [[ "$line" == include\(*\) ]]; then
    body="${line#include(}"
    body="${body%)}"
    mapping_rules+=("$body")
    return
  fi

  if [[ "$line" == exclude\(*\) ]]; then
    body="${line#exclude(}"
    body="${body%)}"
    exclude_rules+=("$body")
    return
  fi

  die "invalid rule in $file_path:$line_number: $line"
}

load_rule_file() {
  local raw_file_path="$1"
  local file_path
  local line
  local line_number=0

  file_path="$(resolve_from_cwd "$raw_file_path")"
  [[ -f "$file_path" ]] || die "map file not found: $file_path"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="$(trim_whitespace "$line")"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    parse_rule_line "$line" "$file_path" "$line_number"
  done < "$file_path"
}

collect_rule_inputs() {
  mapping_rules=()
  exclude_rules=()
  local raw_file_path

  mapping_rules=("${cli_mapping_rules[@]}")
  for raw_file_path in "${mapping_rule_files[@]}"; do
    load_rule_file "$raw_file_path"
  done

  (( ${#mapping_rules[@]} > 0 )) || die "at least one --map or --map-file is required"
}

require_pack_inputs() {
  [[ -n "$archive_file" ]] || die "--archive is required"
  collect_rule_inputs
}

require_unpack_inputs() {
  [[ -n "$archive_file" ]] || die "--archive is required"
  archive_file="$(resolve_from_cwd "$archive_file")"
  [[ -f "$archive_file" ]] || die "archive not found: $archive_file"

  if [[ -n "$output_dir" ]]; then
    (( ${#cli_mapping_rules[@]} == 0 )) || die "use either --output or mapping rules for unpack, not both"
    (( ${#mapping_rule_files[@]} == 0 )) || die "use either --output or mapping rules for unpack, not both"
    return
  fi

  collect_rule_inputs
}

collect_exclude_patterns_for_mapping() {
  local archive_root="$1"
  local filesystem_root="$2"
  local exclude_rule
  local exclude_archive_path
  local exclude_filesystem_path
  local source_parent

  current_exclude_patterns=()
  source_parent="$(dirname "$filesystem_root")"

  for exclude_rule in "${exclude_rules[@]}"; do
    parse_mapping "$exclude_rule" exclude_archive_path exclude_filesystem_path
    [[ "$exclude_archive_path" == "$archive_root" ]] || continue

    case "$exclude_filesystem_path" in
      "$source_parent"/*)
        current_exclude_patterns+=("${exclude_filesystem_path#"$source_parent"/}")
        ;;
      *)
        die "exclude path is outside include source: $exclude_filesystem_path"
        ;;
    esac
  done
}

escape_sed_replacement() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  printf '%s\n' "$value"
}

escape_sed_pattern() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//./\\.}"
  value="${value//[/\\[}"
  value="${value//]/\\]}"
  value="${value//^/\\^}"
  value="${value//\$/\\$}"
  value="${value//\*/\\*}"
  printf '%s\n' "$value"
}

run_tar_pack_command() {
  local archive_path="$1"
  local filesystem_path="$2"
  local output_tar="$3"
  local tar_mode="$4"
  local source_parent
  local source_name
  local escaped_source_pattern
  local escaped_source_name
  local escaped_archive_path
  local transform_rule
  local exclude_pattern
  local tar_exit_code
  local -a tar_command=()

  source_parent="$(dirname "$filesystem_path")"
  source_name="$(basename "$filesystem_path")"
  escaped_source_pattern="$(escape_sed_pattern "$source_name")"
  escaped_source_name="$(escape_sed_replacement "$source_name")"
  escaped_archive_path="$(escape_sed_replacement "$archive_path")"
  transform_rule="s#^${escaped_source_pattern}\$#${escaped_archive_path}#;s#^${escaped_source_pattern}/#${escaped_archive_path}/#"

  tar_command=(
    tar
    -C "$source_parent"
    --transform "$transform_rule"
    -${tar_mode}f "$output_tar"
  )

  collect_exclude_patterns_for_mapping "$archive_path" "$filesystem_path"
  for exclude_pattern in "${current_exclude_patterns[@]}"; do
    tar_command+=(--exclude "$exclude_pattern")
  done

  tar_command+=(-- "$source_name")
  debug "tar command: ${tar_command[*]}"

  set +e
  "${tar_command[@]}"
  tar_exit_code=$?
  set -e

  case "$tar_exit_code" in
    0) ;;
    1)
      warn "tar reported changed or vanished files while packing: $filesystem_path"
      ;;
    *)
      die "tar failed while packing: $filesystem_path"
      ;;
  esac
}

remove_path_if_exists() {
  local path="$1"

  if [[ -L "$path" || -f "$path" ]]; then
    rm -f "$path"
    return
  fi
  if [[ -d "$path" ]]; then
    rm -rf "$path"
  fi
}

copy_path_once() {
  local source_path="$1"
  local target_path="$2"

  mkdir -p "$(dirname "$target_path")"
  cp -a "$source_path" "$target_path"
}

copy_path_replace() {
  local source_path="$1"
  local target_path="$2"

  remove_path_if_exists "$target_path"
  copy_path_once "$source_path" "$target_path"
}

merge_directory_contents() {
  local source_dir="$1"
  local target_dir="$2"
  local entry
  local base_name
  local target_path
  local -a entries=()

  mkdir -p "$target_dir"
  shopt -s dotglob nullglob
  entries=("$source_dir"/*)
  shopt -u dotglob nullglob

  for entry in "${entries[@]}"; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    base_name="$(basename "$entry")"
    target_path="$target_dir/$base_name"

    if [[ -d "$entry" && ! -L "$entry" ]]; then
      if [[ -e "$target_path" && ! -d "$target_path" ]]; then
        remove_path_if_exists "$target_path"
      fi
      merge_directory_contents "$entry" "$target_path"
      continue
    fi

    copy_path_replace "$entry" "$target_path"
  done
}

pack_archive() {
  local raw_rule
  local archive_path
  local filesystem_path
  local temp_dir
  local temp_tar
  local tar_mode="c"

  require_pack_inputs
  archive_file="$(resolve_from_cwd "$archive_file")"

  for raw_rule in "${mapping_rules[@]}"; do
    parse_mapping "$raw_rule" archive_path filesystem_path
    [[ -e "$filesystem_path" || -L "$filesystem_path" ]] || die "source not found: $filesystem_path"
  done

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/archive-path-map.XXXXXX")"
  trap "rm -rf \"$temp_dir\"" EXIT
  temp_tar="$temp_dir/archive.tar"

  for raw_rule in "${mapping_rules[@]}"; do
    parse_mapping "$raw_rule" archive_path filesystem_path
    info "packing $filesystem_path -> $archive_path"
    run_tar_pack_command "$archive_path" "$filesystem_path" "$temp_tar" "$tar_mode"
    tar_mode="r"
  done

  info "creating archive: $archive_file"
  ensure_parent_dir "$archive_file"
  case "$archive_file" in
    *.tar)
      mv "$temp_tar" "$archive_file"
      ;;
    *.tar.gz|*.tgz)
      gzip -c "$temp_tar" > "$archive_file"
      ;;
    *)
      die "unsupported archive extension: $archive_file"
      ;;
  esac
  info "archive created: $archive_file"
}

read_archive_members() {
  local archive_path="$1"
  local member

  archive_members=()
  while IFS= read -r member; do
    archive_members+=("$member")
  done < <(tar -tf "$archive_path")
}

extract_whole_archive() {
  local destination_dir
  local member

  destination_dir="$(resolve_from_cwd "$output_dir")"
  read_archive_members "$archive_file"
  for member in "${archive_members[@]}"; do
    normalize_listed_member "$member" >/dev/null
  done

  mkdir -p "$destination_dir"
  info "extracting archive to: $destination_dir"
  tar -xf "$archive_file" -C "$destination_dir"
}

extract_selected_mappings() {
  local raw_rule
  local archive_path
  local filesystem_path
  local member
  local normalized_member
  local exact_member=""
  local exact_is_directory=0
  local temp_dir
  local list_file
  local extracted_root
  local -a selected_members=()
  local -a descendant_members=()

  read_archive_members "$archive_file"
  for member in "${archive_members[@]}"; do
    normalize_listed_member "$member" >/dev/null
  done

  for raw_rule in "${mapping_rules[@]}"; do
    parse_mapping "$raw_rule" archive_path filesystem_path
    selected_members=()
    descendant_members=()
    exact_member=""
    exact_is_directory=0
    for member in "${archive_members[@]}"; do
      normalized_member="$(normalize_listed_member "$member")"
      [[ -n "$normalized_member" ]] || continue
      if [[ "$normalized_member" == "$archive_path" ]]; then
        exact_member="$member"
        if [[ "$member" == */ ]]; then
          exact_is_directory=1
        fi
        continue
      fi
      if [[ "${normalized_member#"$archive_path"/}" != "$normalized_member" ]]; then
        descendant_members+=("$member")
      fi
    done

    if [[ -n "$exact_member" ]]; then
      selected_members+=("$exact_member")
      if (( exact_is_directory == 0 )); then
        (( ${#descendant_members[@]} == 0 )) || die "archive path is both file and directory prefix: $archive_path"
      fi
    else
      selected_members=("${descendant_members[@]}")
    fi

    (( ${#selected_members[@]} > 0 )) || die "archive path not found: $archive_path"

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/archive-path-map-extract.XXXXXX")"
    list_file="$temp_dir/members.list"
    printf '%s\0' "${selected_members[@]}" > "$list_file"
    tar --null -xf "$archive_file" -C "$temp_dir" -T "$list_file"

    extracted_root="$temp_dir/$archive_path"
    [[ -e "$extracted_root" || -L "$extracted_root" ]] || die "failed to extract archive path: $archive_path"

    if [[ -d "$extracted_root" && ! -L "$extracted_root" ]]; then
      merge_directory_contents "$extracted_root" "$filesystem_path"
    else
      if [[ -d "$filesystem_path" && ! -L "$filesystem_path" ]]; then
        die "destination path is a directory, expected a file path: $filesystem_path"
      fi
      copy_path_replace "$extracted_root" "$filesystem_path"
    fi

    rm -rf "$temp_dir"
  done
}

unpack_archive() {
  require_unpack_inputs

  if [[ -n "$output_dir" ]]; then
    extract_whole_archive
    info "archive extracted: $archive_file"
    return
  fi

  extract_selected_mappings
  info "selected archive paths extracted: $archive_file"
}

(( $# > 0 )) || {
  usage
  exit 1
}

subcommand="$1"
shift

case "$subcommand" in
  pack|unpack) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    die "subcommand must be pack or unpack"
    ;;
esac

archive_file=""
output_dir=""
cli_mapping_rules=()
mapping_rule_files=()
mapping_rules=()
exclude_rules=()
current_exclude_patterns=()
archive_members=()

while (( $# > 0 )); do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || die "--archive requires a value"
      archive_file="$2"
      shift 2
      ;;
    --map)
      [[ $# -ge 2 ]] || die "--map requires a value"
      cli_mapping_rules+=("$2")
      shift 2
      ;;
    --map-file)
      [[ $# -ge 2 ]] || die "--map-file requires a value"
      mapping_rule_files+=("$2")
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      output_dir="$2"
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

require_cmd tar
require_cmd cp
if [[ "$subcommand" == "pack" && ( "$archive_file" == *.tar.gz || "$archive_file" == *.tgz ) ]]; then
  require_cmd gzip
fi

case "$subcommand" in
  pack)
    pack_archive
    ;;
  unpack)
    unpack_archive
    ;;
esac
