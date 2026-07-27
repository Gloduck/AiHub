#!/usr/bin/env bash

set -euo pipefail

BASE_URL="${OPENLIST_BASE_URL:-}"
TOKEN="${OPENLIST_TOKEN:-}"
OUTPUT_JSON=0
RAW_RESPONSE=0
VERBOSE=0
DOWNLOAD_TMP=""
COMMAND_ARGS=()
GROUP_PARENTS=()
GROUP_NAMES=()
NORMALIZED_PATHS=()

usage() {
  cat <<'EOF'
Usage:
  script/openlist_cli.sh COMMAND [options]

Purpose:
  Manage OpenList v4 offline-download tasks and files through its HTTP API.

Commands:
  offline-tools   list configured offline-download tools
  offline-add     add one or more offline-download URLs
  offline-list    list download and/or transfer tasks
  offline-delete  delete task IDs, optionally canceling each one first
  offline-clear   clear completed or only succeeded tasks
  mkdir       create a cloud directory
  ls          list a cloud directory
  info        get cloud file or directory information
  search      search OpenList's configured index, not live storage contents
  rm          remove one or more cloud paths
  mv          move one or more cloud paths
  cp          copy one or more cloud paths
  rename      rename one or more cloud paths
  upload      upload one local regular file
  download    download one cloud file safely

Required and optional command inputs:
  offline-tools
  offline-add --dir PATH --url URL [--url URL ...]
      [--tool NAME, default aria2]
      [--delete-policy VALUE, default delete_never]
      Policies: delete_on_upload_succeed, delete_on_upload_failed,
      delete_never, delete_always, upload_download_stream
  offline-list [--phase download|transfer|all, default all]
      [--status undone|done|all, default all]
  offline-delete --id ID [--id ID ...]
      [--phase download|transfer, default download] [--cancel]
  offline-clear [--phase download|transfer|all, default all] [--succeeded-only]
  mkdir --dir PATH
  ls --dir PATH [--page N, default 1] [--limit N, default 100] [--refresh]
  info --path PATH
  search --dir PATH --keyword TEXT [--page N, default 1]
      [--limit N, default 100] [--scope all|dir|file, default all] [--all]
  rm --path PATH [--path PATH ...]
  mv --path PATH [--path PATH ...] --target-dir PATH
      [--overwrite] [--skip-existing]
  cp --path PATH [--path PATH ...] --target-dir PATH
      [--overwrite] [--skip-existing] [--merge]
  rename --path PATH --name NEW_NAME [--path PATH --name NEW_NAME ...]
      [--overwrite]
  upload --dir PATH --file LOCAL_PATH [--name FILE_NAME]
      [--as-task] [--no-overwrite]
  download --path PATH [--output LOCAL_PATH]

Common inputs:
  --base-url URL     OpenList base URL; fallback OPENLIST_BASE_URL
  --token TOKEN      OpenList token; fallback OPENLIST_TOKEN
  --json             emit stable simplified JSON for automation
  --raw-response     emit endpoint response JSON without simplification
  --verbose          log request progress to stderr without exposing the token
  --                 stop common-option extraction; use before a command value
                     beginning with -- (common options must appear before it)
  --help, -h         show this help

Authentication and defaults:
  - The base URL is required for every command and trailing slashes are removed.
  - The token is required except for public command offline-tools.
  - Authorization is sent exactly as "Authorization: TOKEN", never as Bearer.
  - Cloud paths must be absolute. Repeated slashes and dot segments are normalized.
  - search without --all fetches one page; --all fetches remaining pages and
    de-duplicates results by parent plus name.
  - search uses OpenList's configured search index and does not recursively scan
    storage in real time. Newly created files may not appear until the index is
    built or updated; this script currently has no live recursive-search mode.
  - download without --output writes the remote basename in the current directory.
  - download accepts HTTP(S), root-relative, and scheme-relative raw URLs. Relative
    forms resolve from the base URL origin, and download GETs never send Authorization.

Output:
  - Default output is concise human-readable text. Errors and verbose logs use stderr.
  - --json keeps stdout machine-readable and reports simplified command results.
  - --raw-response prints the exact JSON response for one API call. Commands making
    multiple calls print a JSON array containing the raw response objects.
  - download --raw-response still performs the download and prints its fs/get response.
  - --json and --raw-response are mutually exclusive.

Side effects and permissions:
  Mutating commands create, alter, transfer, or remove files/tasks. The supplied token
  must have the relevant OpenList mutation, task, and offline-download permissions.
  offline-delete does not cancel an active task unless --cancel is explicitly supplied.
  File copy/move and asynchronous upload may create OpenList background tasks.

Non-interactive and platform support:
  This script never prompts. It is designed for Linux and Git Bash and requires bash,
  curl, jq, mktemp, mv, rm, wc, dirname, basename, and basic POSIX utilities.
  On Git Bash, use POSIX-style local paths such as /c/work/file.txt; native backslash
  paths are not supported. Cloud paths always use absolute forward-slash paths.
EOF
}

log() {
  if [[ "$VERBOSE" == "1" ]]; then
    printf '%s\n' "$*" >&2
  fi
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${DOWNLOAD_TMP:-}" && -f "$DOWNLOAD_TMP" ]]; then
    rm -f -- "$DOWNLOAD_TMP"
  fi
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_deps() {
  local cmd
  for cmd in curl jq mktemp mv rm wc dirname basename; do
    require_cmd "$cmd"
  done
}

extract_common_options() {
  COMMAND_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-url)
        [[ $# -ge 2 ]] || die "missing value for --base-url"
        BASE_URL="$2"
        shift 2
        ;;
      --token)
        [[ $# -ge 2 ]] || die "missing value for --token"
        TOKEN="$2"
        shift 2
        ;;
      --json)
        OUTPUT_JSON=1
        shift
        ;;
      --raw-response)
        RAW_RESPONSE=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --)
        shift
        COMMAND_ARGS+=("$@")
        break
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        COMMAND_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

prepare_config() {
  local need_token="${1:-1}"
  [[ "$OUTPUT_JSON" == "0" || "$RAW_RESPONSE" == "0" ]] || die "--json and --raw-response cannot be used together"
  [[ -n "$BASE_URL" ]] || die "missing base URL: use --base-url or OPENLIST_BASE_URL"
  [[ "$BASE_URL" != *$'\n'* && "$BASE_URL" != *$'\r'* ]] || die "base URL cannot contain a line break"
  while [[ "$BASE_URL" == */ ]]; do
    BASE_URL="${BASE_URL%/}"
  done
  [[ -n "$BASE_URL" && "$BASE_URL" == *://* ]] || die "invalid base URL: $BASE_URL"
  if [[ "$need_token" == "1" ]]; then
    [[ -n "$TOKEN" ]] || die "missing token: use --token or OPENLIST_TOKEN"
    [[ "$TOKEN" != *$'\n'* && "$TOKEN" != *$'\r'* ]] || die "token cannot contain a line break"
  fi
}

require_value() {
  local option="$1"
  local count="$2"
  [[ "$count" -ge 2 ]] || die "missing value for $option"
}

require_positive_int() {
  local option="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value > 0 )) || die "$option must be a positive integer"
}

validate_component() {
  local label="$1"
  local value="$2"
  [[ -n "$value" ]] || die "$label cannot be empty"
  [[ "$value" != "." && "$value" != ".." && "$value" != */* && "$value" != *\\* ]] || die "$label must be a single file name"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$label cannot contain a line break"
}

normalize_cloud_path() {
  local path="$1"
  local part
  local output=""
  local -a parts=()
  local -a stack=()
  [[ "$path" == /* ]] || die "cloud path must be absolute: $path"
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || die "cloud path cannot contain a line break"
  IFS='/' read -r -a parts <<<"${path#/}"
  for part in "${parts[@]}"; do
    case "$part" in
      ""|.) ;;
      ..)
        [[ ${#stack[@]} -gt 0 ]] || die "cloud path escapes root: $path"
        unset "stack[$((${#stack[@]} - 1))]"
        ;;
      *) stack+=("$part") ;;
    esac
  done
  if [[ ${#stack[@]} -eq 0 ]]; then
    printf '/\n'
    return
  fi
  for part in "${stack[@]}"; do
    output+="/$part"
  done
  printf '%s\n' "$output"
}

cloud_parent() {
  local path
  path="$(normalize_cloud_path "$1")"
  [[ "$path" != "/" ]] || die "root path has no parent"
  path="${path%/*}"
  printf '%s\n' "${path:-/}"
}

cloud_basename() {
  local path
  path="$(normalize_cloud_path "$1")"
  [[ "$path" != "/" ]] || die "root path has no basename"
  printf '%s\n' "${path##*/}"
}

json_array() {
  jq -cn --args '$ARGS.positional' "$@"
}

validate_api_response() {
  local endpoint="$1"
  local response="$2"
  local message
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$response"; then
    die "invalid JSON response from $endpoint"
  fi
  if ! jq -e '.code == 200' >/dev/null 2>&1 <<<"$response"; then
    message="$(jq -r '.message // "unknown API error"' <<<"$response")"
    die "$endpoint: $message"
  fi
}

api_request() {
  local method="$1"
  local endpoint="$2"
  local body="${3-}"
  local authenticated="${4:-1}"
  local response
  local -a args=(-sS -X "$method" -H 'Accept: application/json')
  if [[ "$authenticated" == "1" ]]; then
    args+=(-H "Authorization: $TOKEN")
  fi
  if [[ $# -ge 3 && -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  log "$method $endpoint"
  if ! response="$(curl "${args[@]}" "$BASE_URL$endpoint")"; then
    die "request failed: $method $endpoint"
  fi
  validate_api_response "$endpoint" "$response"
  printf '%s\n' "$response"
}

upload_request() {
  local file_path="$1"
  local encoded_path="$2"
  local size="$3"
  local as_task="$4"
  local overwrite="$5"
  local response
  log "PUT /api/fs/put ($size bytes)"
  if ! response="$(curl -sS -X PUT \
    -H 'Accept: application/json' \
    -H "Authorization: $TOKEN" \
    -H "File-Path: $encoded_path" \
    -H "Content-Length: $size" \
    -H "As-Task: $as_task" \
    -H "Overwrite: $overwrite" \
    -H 'Content-Type:' \
    --data-binary "@$file_path" \
    "$BASE_URL/api/fs/put")"; then
    die "request failed: PUT /api/fs/put"
  fi
  validate_api_response "/api/fs/put" "$response"
  printf '%s\n' "$response"
}

emit_result() {
  local simplified="$1"
  local human="$2"
  shift 2
  if [[ "$RAW_RESPONSE" == "1" ]]; then
    if [[ $# -eq 1 ]]; then
      printf '%s\n' "$1"
    else
      printf '%s\n' "$@" | jq -s .
    fi
  elif [[ "$OUTPUT_JSON" == "1" ]]; then
    jq -c . <<<"$simplified"
  else
    printf '%s\n' "$human"
  fi
}

build_path_groups() {
  local input_path
  local path
  local parent
  local name
  local index
  local found
  local duplicate
  local existing
  GROUP_PARENTS=()
  GROUP_NAMES=()
  NORMALIZED_PATHS=()
  for input_path in "$@"; do
    path="$(normalize_cloud_path "$input_path")"
    [[ "$path" != "/" ]] || die "cannot operate on root path"
    duplicate=0
    for existing in "${NORMALIZED_PATHS[@]}"; do
      if [[ "$existing" == "$path" ]]; then
        duplicate=1
        break
      fi
    done
    [[ "$duplicate" == "0" ]] || continue
    parent="$(cloud_parent "$path")"
    name="$(cloud_basename "$path")"
    NORMALIZED_PATHS+=("$path")
    found=-1
    for index in "${!GROUP_PARENTS[@]}"; do
      if [[ "${GROUP_PARENTS[$index]}" == "$parent" ]]; then
        found="$index"
        break
      fi
    done
    if [[ "$found" == "-1" ]]; then
      GROUP_PARENTS+=("$parent")
      GROUP_NAMES+=("$(json_array "$name")")
    else
      GROUP_NAMES[$found]="$(jq -cn --argjson names "${GROUP_NAMES[$found]}" --arg name "$name" '$names + [$name]')"
    fi
  done
}

task_kind() {
  case "$1" in
    download) printf 'offline_download\n' ;;
    transfer) printf 'offline_download_transfer\n' ;;
    *) die "invalid task phase: $1" ;;
  esac
}

cmd_tools() {
  local response
  local simplified
  local human
  [[ $# -eq 0 ]] || die "offline-tools does not accept command-specific options"
  prepare_config 0
  response="$(api_request GET '/api/public/offline_download_tools' '' 0)"
  simplified="$(jq '{success:true,command:"offline-tools",tools:(.data // [])}' <<<"$response")"
  human="$(jq -r 'if ((.tools // []) | length) == 0 then "Offline-download tools: none" else "Offline-download tools:\n" + (.tools | map("- " + tostring) | join("\n")) end' <<<"$simplified")"
  emit_result "$simplified" "$human" "$response"
}

cmd_add() {
  local dir_path=""
  local tool="aria2"
  local policy="delete_never"
  local body
  local response
  local simplified
  local human
  local url
  local -a urls=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) require_value "$1" "$#"; dir_path="$2"; shift 2 ;;
      --url) require_value "$1" "$#"; urls+=("$2"); shift 2 ;;
      --tool) require_value "$1" "$#"; tool="$2"; shift 2 ;;
      --delete-policy) require_value "$1" "$#"; policy="$2"; shift 2 ;;
      *) die "unknown offline-add option: $1" ;;
    esac
  done
  prepare_config
  [[ -n "$dir_path" ]] || die "offline-add requires --dir"
  [[ ${#urls[@]} -gt 0 ]] || die "offline-add requires at least one --url"
  [[ -n "$tool" ]] || die "offline-add --tool cannot be empty"
  for url in "${urls[@]}"; do
    [[ -n "$url" ]] || die "offline-add --url cannot be empty"
    [[ "$url" != *$'\n'* && "$url" != *$'\r'* ]] || die "offline-add --url cannot contain a line break"
  done
  case "$policy" in
    delete_on_upload_succeed|delete_on_upload_failed|delete_never|delete_always|upload_download_stream) ;;
    *) die "invalid --delete-policy: $policy" ;;
  esac
  dir_path="$(normalize_cloud_path "$dir_path")"
  body="$(jq -cn --argjson urls "$(json_array "${urls[@]}")" --arg path "$dir_path" --arg tool "$tool" --arg policy "$policy" '{urls:$urls,path:$path,tool:$tool,delete_policy:$policy}')"
  response="$(api_request POST '/api/fs/add_offline_download' "$body")"
  simplified="$(jq --arg path "$dir_path" --arg tool "$tool" --arg policy "$policy" --argjson urls "$(json_array "${urls[@]}")" '
    {success:true,command:"offline-add",path:$path,tool:$tool,delete_policy:$policy,urls:$urls,
     tasks:((.data.tasks // []) | map({id:(.id // ""),name:(.name // ""),state:(.state // null),status:(.status // ""),progress:(.progress // 0)}))}' <<<"$response")"
  human="$(jq -r '"Added " + ((.urls|length)|tostring) + " URL(s) with " + .tool + "; tasks returned: " + ((.tasks|length)|tostring)' <<<"$simplified")"
  emit_result "$simplified" "$human" "$response"
}

cmd_list() {
  local phase="all"
  local status="all"
  local selected_phase
  local bucket
  local kind
  local response
  local tasks='[]'
  local simplified
  local human
  local -a phases=()
  local -a buckets=()
  local -a responses=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase) require_value "$1" "$#"; phase="$2"; shift 2 ;;
      --status) require_value "$1" "$#"; status="$2"; shift 2 ;;
      *) die "unknown offline-list option: $1" ;;
    esac
  done
  prepare_config
  case "$phase" in download) phases=(download) ;; transfer) phases=(transfer) ;; all) phases=(download transfer) ;; *) die "invalid --phase: $phase" ;; esac
  case "$status" in undone) buckets=(undone) ;; done) buckets=(done) ;; all) buckets=(undone done) ;; *) die "invalid --status: $status" ;; esac
  for selected_phase in "${phases[@]}"; do
    kind="$(task_kind "$selected_phase")"
    for bucket in "${buckets[@]}"; do
      response="$(api_request GET "/api/task/$kind/$bucket")"
      responses+=("$response")
      tasks="$(jq -cn --argjson current "$tasks" --argjson response "$response" --arg phase "$selected_phase" --arg bucket "$bucket" '
        $current + (($response.data // []) | map({
          id:(.id // ""), name:(.name // ""), phase:$phase, bucket:$bucket,
          state:(.state // null), status:(.status // ""), progress:(.progress // 0),
          total_bytes:(.total_bytes // 0), start_time:(.start_time // null),
          end_time:(.end_time // null), error:(.error // "")
        }))')"
    done
  done
  simplified="$(jq -cn --arg phase "$phase" --arg status "$status" --argjson tasks "$tasks" '{success:true,command:"offline-list",phase:$phase,status:$status,count:($tasks|length),tasks:$tasks}')"
  human="$(jq -r 'if .count == 0 then "Offline tasks: none" else "Offline tasks (" + (.count|tostring) + "):\n" + (.tasks | map("- [" + .phase + "/" + .bucket + "] " + .id + "  " + .name + "  " + ((.progress // 0)|tostring) + "%  " + (.status // "")) | join("\n")) end' <<<"$simplified")"
  emit_result "$simplified" "$human" "${responses[@]}"
}

cmd_delete() {
  local phase="download"
  local cancel=0
  local kind
  local id
  local encoded_id
  local ids_json
  local response
  local simplified
  local human
  local -a ids=()
  local -a responses=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) require_value "$1" "$#"; ids+=("$2"); shift 2 ;;
      --phase) require_value "$1" "$#"; phase="$2"; shift 2 ;;
      --cancel) cancel=1; shift ;;
      *) die "unknown offline-delete option: $1" ;;
    esac
  done
  prepare_config
  [[ ${#ids[@]} -gt 0 ]] || die "offline-delete requires at least one --id"
  for id in "${ids[@]}"; do
    [[ -n "$id" ]] || die "offline-delete --id cannot be empty"
    [[ "$id" != *$'\n'* && "$id" != *$'\r'* ]] || die "offline-delete --id cannot contain a line break"
  done
  kind="$(task_kind "$phase")"
  ids_json="$(json_array "${ids[@]}")"
  if [[ "$cancel" == "1" ]]; then
    for id in "${ids[@]}"; do
      encoded_id="$(jq -rn --arg value "$id" '$value | @uri')"
      response="$(api_request POST "/api/task/$kind/cancel?tid=$encoded_id" '{}')"
      responses+=("$response")
    done
  fi
  response="$(api_request POST "/api/task/$kind/delete_some" "$ids_json")"
  responses+=("$response")
  if jq -e '(.data | type) == "object" and (.data | length) > 0' >/dev/null <<<"$response"; then
    die "task deletion failed: $(jq -r '.data | to_entries | map(.key + ": " + (.value | tostring)) | join("; ")' <<<"$response")"
  fi
  simplified="$(jq -cn --arg phase "$phase" --argjson ids "$ids_json" --argjson canceled "$([[ "$cancel" == "1" ]] && printf true || printf false)" '{success:true,command:"offline-delete",phase:$phase,ids:$ids,canceled_first:$canceled,deleted_count:($ids|length)}')"
  human="Deleted ${#ids[@]} $phase task(s)$([[ "$cancel" == "1" ]] && printf ' after requesting cancellation' || true)"
  emit_result "$simplified" "$human" "${responses[@]}"
}

cmd_clear() {
  local phase="all"
  local succeeded_only=0
  local selected_phase
  local kind
  local action
  local response
  local simplified
  local human
  local -a phases=()
  local -a responses=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase) require_value "$1" "$#"; phase="$2"; shift 2 ;;
      --succeeded-only) succeeded_only=1; shift ;;
      *) die "unknown offline-clear option: $1" ;;
    esac
  done
  prepare_config
  case "$phase" in download) phases=(download) ;; transfer) phases=(transfer) ;; all) phases=(download transfer) ;; *) die "invalid --phase: $phase" ;; esac
  action="clear_done"
  [[ "$succeeded_only" == "0" ]] || action="clear_succeeded"
  for selected_phase in "${phases[@]}"; do
    kind="$(task_kind "$selected_phase")"
    response="$(api_request POST "/api/task/$kind/$action" '{}')"
    responses+=("$response")
  done
  simplified="$(jq -cn --arg phase "$phase" --argjson succeeded_only "$([[ "$succeeded_only" == "1" ]] && printf true || printf false)" --argjson request_count "${#responses[@]}" '{success:true,command:"offline-clear",phase:$phase,succeeded_only:$succeeded_only,request_count:$request_count}')"
  human="Cleared $phase task history (${#responses[@]} request(s))"
  emit_result "$simplified" "$human" "${responses[@]}"
}

cmd_mkdir() {
  local dir_path=""
  local body
  local response
  local simplified
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) require_value "$1" "$#"; dir_path="$2"; shift 2 ;;
      *) die "unknown mkdir option: $1" ;;
    esac
  done
  prepare_config
  [[ -n "$dir_path" ]] || die "mkdir requires --dir"
  dir_path="$(normalize_cloud_path "$dir_path")"
  [[ "$dir_path" != "/" ]] || die "cannot create root directory"
  body="$(jq -cn --arg path "$dir_path" '{path:$path}')"
  response="$(api_request POST '/api/fs/mkdir' "$body")"
  simplified="$(jq -cn --arg path "$dir_path" '{success:true,command:"mkdir",path:$path}')"
  emit_result "$simplified" "Created directory: $dir_path" "$response"
}

cmd_ls() {
  local dir_path=""
  local page="1"
  local limit="100"
  local refresh=0
  local body
  local response
  local simplified
  local human
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) require_value "$1" "$#"; dir_path="$2"; shift 2 ;;
      --page) require_value "$1" "$#"; page="$2"; shift 2 ;;
      --limit) require_value "$1" "$#"; limit="$2"; shift 2 ;;
      --refresh) refresh=1; shift ;;
      *) die "unknown ls option: $1" ;;
    esac
  done
  prepare_config
  [[ -n "$dir_path" ]] || die "ls requires --dir"
  require_positive_int --page "$page"
  require_positive_int --limit "$limit"
  page=$((10#$page)); limit=$((10#$limit))
  dir_path="$(normalize_cloud_path "$dir_path")"
  body="$(jq -cn --arg path "$dir_path" --argjson refresh "$([[ "$refresh" == "1" ]] && printf true || printf false)" --argjson page "$page" --argjson limit "$limit" '{path:$path,password:"",refresh:$refresh,page:$page,per_page:$limit}')"
  response="$(api_request POST '/api/fs/list' "$body")"
  simplified="$(jq --arg path "$dir_path" --argjson page "$page" --argjson limit "$limit" '
    {success:true,command:"ls",path:$path,page:$page,limit:$limit,total:(.data.total // 0),
     items:((.data.content // []) | map({name:(.name // ""),is_dir:(.is_dir // false),size:(.size // 0),modified:(.modified // null),created:(.created // null),type:(.type // null)}))}' <<<"$response")"
  human="$(jq -r 'if (.items|length) == 0 then "Directory is empty" else "Items (" + ((.items|length)|tostring) + "/" + (.total|tostring) + "):\n" + (.items | map((if .is_dir then "[D] " else "[F] " end) + .name + (if .is_dir then "" else "  " + (.size|tostring) + " bytes" end)) | join("\n")) end' <<<"$simplified")"
  emit_result "$simplified" "$human" "$response"
}

cmd_info() {
  local path=""
  local body
  local response
  local simplified
  local human
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path) require_value "$1" "$#"; path="$2"; shift 2 ;;
      *) die "unknown info option: $1" ;;
    esac
  done
  prepare_config
  [[ -n "$path" ]] || die "info requires --path"
  path="$(normalize_cloud_path "$path")"
  body="$(jq -cn --arg path "$path" '{path:$path,password:""}')"
  response="$(api_request POST '/api/fs/get' "$body")"
  simplified="$(jq --arg path "$path" '{success:true,command:"info",path:$path,item:{name:(.data.name // ""),is_dir:(.data.is_dir // false),size:(.data.size // 0),modified:(.data.modified // null),created:(.data.created // null),type:(.data.type // null),provider:(.data.provider // ""),raw_url:(.data.raw_url // "")}}' <<<"$response")"
  human="$(jq -r '"Path: " + .path + "\nType: " + (if .item.is_dir then "directory" else "file" end) + "\nSize: " + (.item.size|tostring) + " bytes\nModified: " + ((.item.modified // "")|tostring)' <<<"$simplified")"
  emit_result "$simplified" "$human" "$response"
}

cmd_search() {
  local dir_path=""
  local keyword=""
  local page="1"
  local limit="100"
  local scope="all"
  local scope_number=0
  local fetch_all=0
  local current_page
  local body
  local response
  local count
  local total
  local items='[]'
  local simplified
  local human
  local -a responses=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) require_value "$1" "$#"; dir_path="$2"; shift 2 ;;
      --keyword) require_value "$1" "$#"; keyword="$2"; shift 2 ;;
      --page) require_value "$1" "$#"; page="$2"; shift 2 ;;
      --limit) require_value "$1" "$#"; limit="$2"; shift 2 ;;
      --scope) require_value "$1" "$#"; scope="$2"; shift 2 ;;
      --all) fetch_all=1; shift ;;
      *) die "unknown search option: $1" ;;
    esac
  done
  prepare_config
  [[ -n "$dir_path" ]] || die "search requires --dir"
  [[ -n "$keyword" ]] || die "search requires --keyword"
  require_positive_int --page "$page"
  require_positive_int --limit "$limit"
  page=$((10#$page)); limit=$((10#$limit))
  case "$scope" in all) scope_number=0 ;; dir) scope_number=1 ;; file) scope_number=2 ;; *) die "invalid --scope: $scope" ;; esac
  dir_path="$(normalize_cloud_path "$dir_path")"
  current_page="$page"
  while :; do
    body="$(jq -cn --arg parent "$dir_path" --arg keywords "$keyword" --argjson scope "$scope_number" --argjson page "$current_page" --argjson limit "$limit" '{parent:$parent,keywords:$keywords,scope:$scope,page:$page,per_page:$limit,password:""}')"
    response="$(api_request POST '/api/fs/search' "$body")"
    responses+=("$response")
    items="$(jq -cn --argjson existing "$items" --argjson response "$response" '
      reduce (($existing + ($response.data.content // []))[]) as $item ([];
        if any(.[]; .parent == $item.parent and .name == $item.name) then . else . + [$item] end)')"
    [[ "$fetch_all" == "1" ]] || break
    count="$(jq -r '(.data.content // []) | length' <<<"$response")"
    total="$(jq -r '.data.total // 0' <<<"$response")"
    (( count == limit )) || break
    (( current_page * limit < total )) || break
    current_page=$((current_page + 1))
  done
  simplified="$(jq -cn --arg dir "$dir_path" --arg keyword "$keyword" --arg scope "$scope" --argjson page "$page" --argjson limit "$limit" --argjson items "$items" '
    {success:true,command:"search",dir:$dir,keyword:$keyword,scope:$scope,page:$page,limit:$limit,count:($items|length),
     items:($items | map({parent:(.parent // ""),name:(.name // ""),path:(if (.parent // "/") == "/" then "/" + (.name // "") else (.parent // "") + "/" + (.name // "") end),is_dir:(.is_dir // false),size:(.size // 0),type:(.type // null)}))}')"
  human="$(jq -r 'if .count == 0 then "Search results: none" else "Search results (" + (.count|tostring) + "):\n" + (.items | map((if .is_dir then "[D] " else "[F] " end) + .path + (if .is_dir then "" else "  " + (.size|tostring) + " bytes" end)) | join("\n")) end' <<<"$simplified")"
  emit_result "$simplified" "$human" "${responses[@]}"
}

cmd_rm() {
  local index
  local body
  local response
  local simplified
  local paths_json
  local -a paths=()
  local -a responses=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path) require_value "$1" "$#"; paths+=("$2"); shift 2 ;;
      *) die "unknown rm option: $1" ;;
    esac
  done
  prepare_config
  [[ ${#paths[@]} -gt 0 ]] || die "rm requires at least one --path"
  build_path_groups "${paths[@]}"
  for index in "${!GROUP_PARENTS[@]}"; do
    body="$(jq -cn --arg dir "${GROUP_PARENTS[$index]}" --argjson names "${GROUP_NAMES[$index]}" '{dir:$dir,names:$names}')"
    response="$(api_request POST '/api/fs/remove' "$body")"
    responses+=("$response")
  done
  paths_json="$(json_array "${NORMALIZED_PATHS[@]}")"
  simplified="$(jq -cn --argjson paths "$paths_json" --argjson request_count "${#responses[@]}" '{success:true,command:"rm",paths:$paths,removed_count:($paths|length),request_count:$request_count}')"
  emit_result "$simplified" "Removed ${#NORMALIZED_PATHS[@]} path(s) in ${#responses[@]} request(s)" "${responses[@]}"
}

cmd_mv_or_cp() {
  local command="$1"
  shift
  local target_dir=""
  local overwrite=0
  local skip_existing=0
  local merge=0
  local index
  local body
  local response
  local simplified
  local paths_json
  local -a paths=()
  local -a responses=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path) require_value "$1" "$#"; paths+=("$2"); shift 2 ;;
      --target-dir) require_value "$1" "$#"; target_dir="$2"; shift 2 ;;
      --overwrite) overwrite=1; shift ;;
      --skip-existing) skip_existing=1; shift ;;
      --merge)
        [[ "$command" == "cp" ]] || die "--merge is only valid for cp"
        merge=1
        shift
        ;;
      *) die "unknown $command option: $1" ;;
    esac
  done
  prepare_config
  [[ ${#paths[@]} -gt 0 ]] || die "$command requires at least one --path"
  [[ -n "$target_dir" ]] || die "$command requires --target-dir"
  [[ "$overwrite" == "0" || "$skip_existing" == "0" ]] || die "--overwrite and --skip-existing cannot be used together"
  target_dir="$(normalize_cloud_path "$target_dir")"
  build_path_groups "${paths[@]}"
  for index in "${!GROUP_PARENTS[@]}"; do
    body="$(jq -cn \
      --arg src_dir "${GROUP_PARENTS[$index]}" \
      --arg dst_dir "$target_dir" \
      --argjson names "${GROUP_NAMES[$index]}" \
      --argjson overwrite "$([[ "$overwrite" == "1" ]] && printf true || printf false)" \
      --argjson skip_existing "$([[ "$skip_existing" == "1" ]] && printf true || printf false)" \
      --argjson merge "$([[ "$merge" == "1" ]] && printf true || printf false)" \
      '{src_dir:$src_dir,dst_dir:$dst_dir,names:$names,overwrite:$overwrite,skip_existing:$skip_existing,merge:$merge}')"
    response="$(api_request POST "/api/fs/$([[ "$command" == "mv" ]] && printf move || printf copy)" "$body")"
    responses+=("$response")
  done
  paths_json="$(json_array "${NORMALIZED_PATHS[@]}")"
  simplified="$(jq -cn --arg command "$command" --argjson paths "$paths_json" --arg target_dir "$target_dir" --argjson overwrite "$([[ "$overwrite" == "1" ]] && printf true || printf false)" --argjson skip_existing "$([[ "$skip_existing" == "1" ]] && printf true || printf false)" --argjson merge "$([[ "$merge" == "1" ]] && printf true || printf false)" --argjson request_count "${#responses[@]}" '{success:true,command:$command,paths:$paths,target_dir:$target_dir,overwrite:$overwrite,skip_existing:$skip_existing,merge:$merge,item_count:($paths|length),request_count:$request_count}')"
  emit_result "$simplified" "$([[ "$command" == "mv" ]] && printf 'Moved' || printf 'Copied') ${#NORMALIZED_PATHS[@]} path(s) to $target_dir in ${#responses[@]} request(s)" "${responses[@]}"
}

cmd_rename() {
  local overwrite=0
  local index
  local path
  local name
  local body
  local response
  local renames='[]'
  local simplified
  local -a paths=()
  local -a names=()
  local -a responses=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path) require_value "$1" "$#"; paths+=("$2"); shift 2 ;;
      --name) require_value "$1" "$#"; names+=("$2"); shift 2 ;;
      --overwrite) overwrite=1; shift ;;
      *) die "unknown rename option: $1" ;;
    esac
  done
  prepare_config
  [[ ${#paths[@]} -gt 0 ]] || die "rename requires at least one --path"
  [[ ${#paths[@]} -eq ${#names[@]} ]] || die "rename requires equal numbers of --path and --name values"
  for index in "${!paths[@]}"; do
    path="$(normalize_cloud_path "${paths[$index]}")"
    [[ "$path" != "/" ]] || die "cannot rename root path"
    name="${names[$index]}"
    validate_component "rename --name" "$name"
    body="$(jq -cn --arg path "$path" --arg name "$name" --argjson overwrite "$([[ "$overwrite" == "1" ]] && printf true || printf false)" '{path:$path,name:$name,overwrite:$overwrite}')"
    response="$(api_request POST '/api/fs/rename' "$body")"
    responses+=("$response")
    renames="$(jq -cn --argjson renames "$renames" --arg path "$path" --arg name "$name" '$renames + [{path:$path,name:$name}]')"
  done
  simplified="$(jq -cn --argjson renames "$renames" --argjson overwrite "$([[ "$overwrite" == "1" ]] && printf true || printf false)" '{success:true,command:"rename",renames:$renames,overwrite:$overwrite,renamed_count:($renames|length)}')"
  emit_result "$simplified" "Renamed ${#paths[@]} path(s)" "${responses[@]}"
}

cmd_upload() {
  local dir_path=""
  local file_path=""
  local file_name=""
  local as_task=0
  local overwrite=1
  local destination
  local encoded_path
  local size
  local response
  local simplified
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) require_value "$1" "$#"; dir_path="$2"; shift 2 ;;
      --file) require_value "$1" "$#"; file_path="$2"; shift 2 ;;
      --name) require_value "$1" "$#"; file_name="$2"; shift 2 ;;
      --as-task) as_task=1; shift ;;
      --no-overwrite) overwrite=0; shift ;;
      *) die "unknown upload option: $1" ;;
    esac
  done
  prepare_config
  [[ -n "$dir_path" ]] || die "upload requires --dir"
  [[ -n "$file_path" ]] || die "upload requires --file"
  [[ -f "$file_path" ]] || die "upload source is not a regular file: $file_path"
  [[ -n "$file_name" ]] || file_name="$(basename -- "$file_path")"
  validate_component "upload --name" "$file_name"
  dir_path="$(normalize_cloud_path "$dir_path")"
  if [[ "$dir_path" == "/" ]]; then destination="/$file_name"; else destination="$dir_path/$file_name"; fi
  encoded_path="$(jq -rn --arg value "$destination" '$value | @uri')"
  size="$(wc -c <"$file_path")"
  size="${size//[[:space:]]/}"
  response="$(upload_request "$file_path" "$encoded_path" "$size" "$([[ "$as_task" == "1" ]] && printf true || printf false)" "$([[ "$overwrite" == "1" ]] && printf true || printf false)")"
  simplified="$(jq --arg dir "$dir_path" --arg file "$file_path" --arg name "$file_name" --arg path "$destination" --argjson size "$size" --argjson as_task "$([[ "$as_task" == "1" ]] && printf true || printf false)" --argjson overwrite "$([[ "$overwrite" == "1" ]] && printf true || printf false)" '{success:true,command:"upload",dir:$dir,local_file:$file,name:$name,path:$path,size:$size,as_task:$as_task,overwrite:$overwrite,task:(.data.task // null)}' <<<"$response")"
  emit_result "$simplified" "Uploaded $file_path to $destination ($size bytes)$([[ "$as_task" == "1" ]] && printf ' as a task' || true)" "$response"
}

absolute_local_path() {
  local path="$1"
  local dir
  local name
  case "$path" in
    /*|[A-Za-z]:[\\/]*) printf '%s\n' "$path" ;;
    *)
      dir="$(dirname -- "$path")"
      name="$(basename -- "$path")"
      dir="$(builtin cd "$dir" && pwd -P)"
      printf '%s/%s\n' "$dir" "$name"
      ;;
  esac
}

resolve_download_url() {
  local url="$1"
  local scheme
  local authority
  [[ "$url" != *$'\n'* && "$url" != *$'\r'* ]] || die "unsupported download URL returned by fs/get"
  if [[ "$url" =~ ^[Hh][Tt][Tt][Pp][Ss]?://[^/?#]+ ]]; then
    printf '%s\n' "$url"
    return
  fi
  if [[ "$url" == //* ]]; then
    [[ "$url" =~ ^//[^/?#]+ ]] || die "unsupported download URL returned by fs/get: $url"
    if [[ "$BASE_URL" =~ ^([Hh][Tt][Tt][Pp][Ss]?)://([^/?#]+) ]]; then
      scheme="${BASH_REMATCH[1]}"
      printf '%s:%s\n' "$scheme" "$url"
      return
    fi
    die "cannot resolve scheme-relative download URL from base URL: $BASE_URL"
  fi
  if [[ "$url" == /* ]]; then
    if [[ "$BASE_URL" =~ ^([Hh][Tt][Tt][Pp][Ss]?)://([^/?#]+) ]]; then
      scheme="${BASH_REMATCH[1]}"
      authority="${BASH_REMATCH[2]}"
      printf '%s://%s%s\n' "$scheme" "$authority" "$url"
      return
    fi
    die "cannot resolve root-relative download URL from base URL: $BASE_URL"
  fi
  die "unsupported download URL returned by fs/get: $url"
}

cmd_download() {
  local cloud_path=""
  local output_path=""
  local body
  local response
  local raw_url
  local is_dir
  local output_dir
  local final_path
  local size
  local simplified
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path) require_value "$1" "$#"; cloud_path="$2"; shift 2 ;;
      --output) require_value "$1" "$#"; output_path="$2"; shift 2 ;;
      *) die "unknown download option: $1" ;;
    esac
  done
  prepare_config
  [[ -n "$cloud_path" ]] || die "download requires --path"
  cloud_path="$(normalize_cloud_path "$cloud_path")"
  [[ "$cloud_path" != "/" ]] || die "cannot download root path"
  body="$(jq -cn --arg path "$cloud_path" '{path:$path,password:""}')"
  response="$(api_request POST '/api/fs/get' "$body")"
  is_dir="$(jq -r '.data.is_dir // false' <<<"$response")"
  [[ "$is_dir" != "true" ]] || die "download path is a directory: $cloud_path"
  raw_url="$(jq -r '.data.raw_url // empty' <<<"$response")"
  [[ -n "$raw_url" ]] || die "fs/get returned no raw_url for $cloud_path"
  raw_url="$(resolve_download_url "$raw_url")"
  [[ -n "$output_path" ]] || output_path="$(cloud_basename "$cloud_path")"
  [[ ! -d "$output_path" ]] || die "download output is a directory: $output_path"
  output_dir="$(dirname -- "$output_path")"
  [[ -d "$output_dir" ]] || die "download output directory does not exist: $output_dir"
  DOWNLOAD_TMP="$(mktemp "$output_dir/.openlist-download.XXXXXX")"
  log "GET raw_url -> $output_path"
  if ! curl -fL -sS "$raw_url" -o "$DOWNLOAD_TMP"; then
    die "download failed for $cloud_path"
  fi
  size="$(wc -c <"$DOWNLOAD_TMP")"
  size="${size//[[:space:]]/}"
  mv -f -- "$DOWNLOAD_TMP" "$output_path"
  DOWNLOAD_TMP=""
  final_path="$(absolute_local_path "$output_path")"
  simplified="$(jq -cn --arg path "$cloud_path" --arg output "$final_path" --argjson size "$size" '{success:true,command:"download",path:$path,output:$output,size:$size}')"
  emit_result "$simplified" "Downloaded $cloud_path to $final_path ($size bytes)" "$response"
}

main() {
  local command="${1:-}"
  if [[ -z "$command" || "$command" == "--help" || "$command" == "-h" ]]; then
    usage
    exit 0
  fi
  shift
  extract_common_options "$@"
  require_deps
  set -- "${COMMAND_ARGS[@]}"
  case "$command" in
    offline-tools) cmd_tools "$@" ;;
    offline-add) cmd_add "$@" ;;
    offline-list) cmd_list "$@" ;;
    offline-delete) cmd_delete "$@" ;;
    offline-clear) cmd_clear "$@" ;;
    mkdir) cmd_mkdir "$@" ;;
    ls) cmd_ls "$@" ;;
    info) cmd_info "$@" ;;
    search) cmd_search "$@" ;;
    rm) cmd_rm "$@" ;;
    mv|cp) cmd_mv_or_cp "$command" "$@" ;;
    rename) cmd_rename "$@" ;;
    upload) cmd_upload "$@" ;;
    download) cmd_download "$@" ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
