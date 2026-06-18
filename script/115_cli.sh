#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly API_LOGIN_CHECK="https://passportapi.115.com/app/1.0/web/1.0/check/sso"
readonly API_APP_VERSION="https://appversion.115.com/1/web/1.0/api/chrome"
readonly API_ADD_OFFLINE="https://lixian.115.com/lixianssp/?ac=add_task_urls"
readonly API_ADD_OFFLINE_SINGLE_WEB="https://115.com/web/lixian/?ct=lixian&ac=add_task_url"
readonly API_ADD_OFFLINE_MULTI_WEB="https://115.com/web/lixian/?ct=lixian&ac=add_task_urls"
readonly API_OFFLINE_SPACE="https://115.com/?ct=offline&ac=space"
readonly API_LIST_OFFLINE="https://lixian.115.com/lixian/?ct=lixian&ac=task_lists"
readonly API_DELETE_OFFLINE="https://lixian.115.com/lixian/?ct=lixian&ac=task_del"
readonly API_CLEAR_OFFLINE="https://lixian.115.com/lixian/?ct=lixian&ac=task_clear"
readonly API_DIR_ADD="https://webapi.115.com/files/add"
readonly API_DIR_ID="https://webapi.115.com/files/getid"
readonly API_FILE_LIST="https://webapi.115.com/files"
readonly API_FILE_INFO="https://webapi.115.com/files/get_info"
readonly API_FILE_SEARCH="https://webapi.115.com/files/search"
readonly API_FILE_DELETE="https://webapi.115.com/rb/delete"
readonly API_FILE_MOVE="https://webapi.115.com/files/move"
readonly API_FILE_COPY="https://webapi.115.com/files/copy"
readonly API_FILE_RENAME="https://webapi.115.com/files/batch_rename"
readonly DEFAULT_APP_VER="35.6.0.3"

SCRIPT_VERBOSE=0
RAW_RESPONSE=0
OUTPUT_JSON=0
COOKIE="${PAN115_COOKIE:-}"
TMP_DIR=""

usage() {
  cat <<'EOF'
Usage:
  script/115_cli.sh COMMAND [options]

Purpose:
  Call 115 Cloud private web/lixian APIs for offline cloud-download tasks.
  This script does not use 115 OpenAPI. Only upload uses python3/python for ec115 and OSS.

Commands:
  version                 get 115 app version used by add, no cookie required
  login-check             validate cookie and print login response
  add                     add one or more offline cloud-download URLs
  list                    list offline cloud-download tasks
  delete                  delete offline cloud-download tasks by info_hash
  clear                   clear offline cloud-download tasks by flag
  mkdir                   create a cloud directory by absolute path
  ls                      list a cloud directory by absolute path
  info                    get file or directory info by absolute path
  search                  search files under an absolute directory path
  rm                      delete file or directory by absolute path
  mv                      move file or directory to an absolute directory path
  cp                      copy file or directory to an absolute directory path
  rename                  rename file or directory by absolute path
  upload                  upload a local file by absolute cloud directory path

Required inputs:
  --cookie VALUE          115 cookie, usually UID=...;CID=...;SEID=...;KID=...
                          Can also be provided by PAN115_COOKIE.

Command-specific inputs:
  add --dir PATH --url URL [--url URL ...]
  list [--page N]
  delete --hash HASH [--hash HASH ...] [--delete-files]
  clear [--flag N]
  mkdir --dir PATH
  ls --dir PATH [--offset N] [--limit N, default 100]
  info --path PATH
  search --dir PATH --keyword TEXT [--offset N] [--limit N, default 100] [--type N] [--all]
  rm --path PATH [--path PATH ...]
  mv --path PATH [--path PATH ...] --target-dir PATH
  cp --path PATH [--path PATH ...] --target-dir PATH
  rename --path PATH --name NEW_NAME
  upload --dir PATH --file LOCAL_PATH [--name FILE_NAME] [--multipart-threshold BYTES] [--part-size BYTES]

Optional inputs:
  --offset N             ls/search: result offset; default 0
  --limit N              ls/search: page size; default 100
  --multipart-threshold   upload multipart threshold in bytes; default 10485760
  --part-size BYTES       upload multipart part size in bytes; default 10485760
  --json                  output JSON like the underlying API response
  --raw-response          print raw API response without formatting
  --all                   search only: fetch all de-duplicated results
  --verbose               print process information to stderr
  --help                  show this message

Environment fallback:
  PAN115_COOKIE

Dependencies:
  bash, curl, openssl, base64, jq, cat, date, dd, od, rm, sed, tr, wc, mktemp; upload also requires python3 or python

Default behavior:
  - add uses the 115 web offline-download form API with sign/time from the offline space API.
  - upload uses rapid upload first, then OSS PutObject for small files or serial OSS Multipart above threshold.
  - Commands that accept cloud directories require absolute paths and fail when any directory is missing.
  - search without --all returns one result page; use --all for complete de-duplicated results.
  - list/delete/clear call lixian APIs directly with the provided cookie.
  - stdout prints human-friendly text by default; use --json for JSON output.
  - stderr is used for logs and errors.

Side effects:
  Sends HTTP requests to 115 private web/lixian APIs and may create/delete/clear offline tasks.

Platform notes:
  Designed for Linux shell and Git Bash. OpenSSL must support rsa public encrypt and raw public verify.
EOF
}

log() {
  if [[ "$SCRIPT_VERBOSE" == "1" ]]; then
    printf '%s\n' "$*" >&2
  fi
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_deps() {
  local cmd
  for cmd in bash curl openssl base64 jq cat date dd od rm sed tr wc mktemp; do
    require_cmd "$cmd"
  done
}

make_tmp_dir() {
  TMP_DIR="$(mktemp -d)"
  trap '[[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"' EXIT
}

write_public_key() {
  cat >"$TMP_DIR/115_public.pem" <<'EOF'
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCGhpgMD1okxLnUMCDNLCJwP/P0
UHVlKQWLHPiPCbhgITZHcZim4mgxSWWb0SLDNZL9ta1HlErR6k02xrFyqtYzjDu2
rGInUC0BCZOsln0a7wDwyOA43i5NO8LsNory6fEKbx7aT3Ji8TZCDAfDMbhxvxOf
dPMBDjxP5X3zr7cWgwIDAQAB
-----END PUBLIC KEY-----
EOF
}

require_cookie() {
  [[ -n "$COOKIE" ]] || die "missing cookie: use --cookie or PAN115_COOKIE"
}

now_seconds() {
  date +%s
}

now_millis() {
  printf '%s000\n' "$(date +%s)"
}

curl_json() {
  curl -fsSL "$@"
}

cookie_curl() {
  curl_json -H "Cookie: $COOKIE" "$@"
}

get_app_version() {
  local response
  response="$(curl_json "$API_APP_VERSION")" || return 1
  printf '%s\n' "$response" | jq -r '.data.win.version_code // empty'
}

resolve_app_ver() {
  local ver
  if ver="$(get_app_version 2>/dev/null)" && [[ -n "$ver" ]]; then
    printf '%s\n' "$ver"
    return
  fi
  printf '%s\n' "$DEFAULT_APP_VER"
}

login_check_response() {
  local ts
  ts="$(now_seconds)"
  cookie_curl "${API_LOGIN_CHECK}?_=${ts}"
}

resolve_uid() {
  local response
  local uid
  response="$(login_check_response)"
  uid="$(printf '%s\n' "$response" | jq -r '.data.user_id // .data.uid // .user_id // empty')"
  [[ -n "$uid" && "$uid" != "null" ]] || die "failed to resolve uid from login-check response"
  printf '%s\n' "$uid"
}

offline_space_info() {
  cookie_curl --get --data-urlencode "_=$(now_millis)" "$API_OFFLINE_SPACE"
}

require_abs_path() {
  local path="$1"
  [[ "$path" == /* ]] || die "cloud path must be absolute: $path"
}

normalize_cloud_path() {
  local path="$1"
  require_abs_path "$path"
  path="$(printf '%s' "$path" | sed 's#//*#/#g')"
  if [[ "$path" != "/" ]]; then
    path="${path%/}"
  fi
  printf '%s\n' "$path"
}

cloud_parent_path() {
  local path
  path="$(normalize_cloud_path "$1")"
  [[ "$path" != "/" ]] || die "root path has no parent"
  local parent="${path%/*}"
  [[ -n "$parent" ]] || parent="/"
  printf '%s\n' "$parent"
}

cloud_basename() {
  local path
  path="$(normalize_cloud_path "$1")"
  [[ "$path" != "/" ]] || die "root path has no basename"
  printf '%s\n' "${path##*/}"
}

dir_id_by_path() {
  local path
  local current_id="0"
  local component
  local -a components
  local response
  local cid
  path="$(normalize_cloud_path "$1")"
  if [[ "$path" == "/" ]]; then
    printf '0\n'
    return
  fi
  IFS='/' read -r -a components <<<"${path#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    response="$(list_dir_by_id "$current_id" 0 1150)"
    cid="$(printf '%s\n' "$response" | jq -r --arg name "$component" 'first(.data[]? | select((.fid // "") == "" and (.cid // "") != "" and .n == $name) | .cid) // empty')"
    [[ -n "$cid" && "$cid" != "null" ]] || die "failed to resolve directory path: $path"
    current_id="$cid"
  done
  printf '%s\n' "$current_id"
}

list_dir_by_id() {
  local cid="$1"
  local offset="${2:-0}"
  local limit="${3:-100}"
  cookie_curl --get \
    --data-urlencode "aid=1" \
    --data-urlencode "cid=${cid}" \
    --data-urlencode "o=user_ptime" \
    --data-urlencode "asc=1" \
    --data-urlencode "offset=${offset}" \
    --data-urlencode "show_dir=1" \
    --data-urlencode "limit=${limit}" \
    --data-urlencode "snap=0" \
    --data-urlencode "natsort=0" \
    --data-urlencode "record_open_time=1" \
    --data-urlencode "format=json" \
    --data-urlencode "fc_mix=0" \
    "$API_FILE_LIST"
}

search_by_id() {
  local cid="$1"
  local keyword="$2"
  local offset="${3:-0}"
  local limit="${4:-100}"
  local type="${5:-0}"
  cookie_curl --get \
    --data-urlencode "aid=7" \
    --data-urlencode "cid=${cid}" \
    --data-urlencode "format=json" \
    --data-urlencode "offset=${offset}" \
    --data-urlencode "limit=${limit}" \
    --data-urlencode "search_value=${keyword}" \
    --data-urlencode "type=${type}" \
    --data-urlencode "count_folders=1" \
    --data-urlencode "o=file_name" \
    --data-urlencode "asc=1" \
    "$API_FILE_SEARCH"
}

normalize_paged_response() {
  local response="$1"
  local requested_offset="$2"
  printf '%s\n' "$response" | jq --argjson requested_offset "$requested_offset" '
    if ([.count // 0, .file_count // 0] | max | tonumber) <= $requested_offset then
      . + {data: [], offset: $requested_offset}
    else
      .
    end
  '
}

object_json_by_path() {
  local path
  local parent
  local name
  local parent_id
  local response
  local object
  path="$(normalize_cloud_path "$1")"
  if [[ "$path" == "/" ]]; then
    jq -cn '{cid:"0", n:"/", is_root:true}'
    return
  fi
  parent="$(cloud_parent_path "$path")"
  name="$(cloud_basename "$path")"
  parent_id="$(dir_id_by_path "$parent")"
  response="$(list_dir_by_id "$parent_id" 0 1150)"
  object="$(printf '%s\n' "$response" | jq -c --arg name "$name" 'first(.data[]? | select(.n == $name) | . + {resolved_id:(.fid // .cid // .file_id)})')"
  [[ -n "$object" ]] || die "failed to resolve cloud path: $path"
  printf '%s\n' "$object"
}

object_id_by_path() {
  object_json_by_path "$1" | jq -r '.resolved_id // .fid // .cid // .file_id // empty'
}

api_check_or_print() {
  local response="$1"
  local kind="${2:-generic}"
  if [[ "$RAW_RESPONSE" == "1" ]]; then
    printf '%s\n' "$response"
  elif [[ "$OUTPUT_JSON" == "1" ]]; then
    printf '%s\n' "$response" | jq .
  else
    friendly_output "$kind" "$response"
  fi
}

friendly_output() {
  local kind="$1"
  local response="$2"
  case "$kind" in
    version)
      printf 'Version: %s\n' "$(printf '%s\n' "$response" | jq -r '.version // empty')"
      ;;
    login)
      printf '%s\n' "$response" | jq -r 'if ((.state // 1) == 0 or (.state == true)) then "Login: ok (user_id=" + ((.data.user_id // .user_id // "unknown")|tostring) + ")" else "Login: failed - " + (.error // .message // "unknown error") end'
      ;;
    add)
      printf '%s\n' "$response" | jq -r 'if (.state == true) then "Added offline task: " + ((.info_hash // .result[0].info_hash // .result[0] // "unknown")|tostring) + (if .name then " (" + .name + ")" else "" end) else "Add failed: " + (.error // .message // "unknown error") end'
      ;;
    offline-list)
      printf '%s\n' "$response" | jq -r 'if (.state == false) then "List failed: " + (.error // .message // "unknown error") elif ((.tasks // [])|length) == 0 then "Offline tasks: none" else "Offline tasks:" end, ((.tasks // [])[] | "- " + ((.info_hash // "")|tostring) + "  " + ((.name // .url // "")|tostring) + "  " + ((.percentDone // .percent // 0)|tostring) + "%")'
      ;;
    ls|search)
      printf '%s\n' "$response" | jq -r 'if (.state == false) then "List failed: " + (.error // .message // "unknown error") elif ((.data // [])|length) == 0 then "No items" else (.data[] | (if (.fid // "") == "" then "[D] " else "[F] " end) + (.n // .name // "") + "  id=" + ((.fid // .cid // "")|tostring) + (if (.s // "") != "" then "  size=" + ((.s)|tostring) else "" end)) end'
      ;;
    info)
      printf '%s\n' "$response" | jq -r 'if (.state == false) then "Info failed: " + (.error // .message // "unknown error") else (.data.files[0] // .data[0] // .files[0] // .) as $f | "Name: " + (($f.n // $f.file_name // $f.name // "")|tostring) + "\nID: " + (($f.fid // $f.cid // $f.file_id // "")|tostring) + "\nPickCode: " + (($f.pc // $f.pick_code // "")|tostring) + "\nSHA1: " + (($f.sha // $f.sha1 // "")|tostring) end'
      ;;
    upload)
      printf '%s\n' "$response" | jq -r 'if (.state == true) then "Upload: ok (mode=" + (if .rapid_upload == true then "rapid_upload" else (.upload_mode // "unknown") end) + ")" else "Upload failed: " + (.error // .message // (.oss_result.message // "unknown error")) end'
      ;;
    *)
      printf '%s\n' "$response" | jq -r 'if (.state == true or (.errno // 0) == 0 or (.errNo // 0) == 0) then "Success" else "Failed: " + (.error // .message // .msg // "unknown error") end'
      ;;
  esac
}

bytes_to_hex() {
  od -An -v -tx1 "$1" | tr -d ' \n'
}

hex_to_file() {
  local hex="$1"
  local output="$2"
  local escaped
  escaped="$(printf '%s' "$hex" | sed 's/../\\x&/g')"
  printf '%b' "$escaped" >"$output"
}

reverse_hex() {
  local hex="$1"
  local out=""
  local i
  for ((i=${#hex}-2; i>=0; i-=2)); do
    out+="${hex:i:2}"
  done
  printf '%s\n' "$out"
}

derive_key_hex() {
  local seed_hex="$1"
  local size="$2"
  local seed_byte
  local value
  local i
  local -a xor_seed=(
    0xf0 0xe5 0x69 0xae 0xbf 0xdc 0xbf 0x8a 0x1a 0x45 0xe8 0xbe 0x7d 0xa6 0x73 0xb8
    0xde 0x8f 0xe7 0xc4 0x45 0xda 0x86 0xc4 0x9b 0x64 0x8b 0x14 0x6a 0xb4 0xf1 0xaa
    0x38 0x01 0x35 0x9e 0x26 0x69 0x2c 0x86 0x00 0x6b 0x4f 0xa5 0x36 0x34 0x62 0xa6
    0x2a 0x96 0x68 0x18 0xf2 0x4a 0xfd 0xbd 0x6b 0x97 0x8f 0x4d 0x8f 0x89 0x13 0xb7
    0x6c 0x8e 0x93 0xed 0x0e 0x0d 0x48 0x3e 0xd7 0x2f 0x88 0xd8 0xfe 0xfe 0x7e 0x86
    0x50 0x95 0x4f 0xd1 0xeb 0x83 0x26 0x34 0xdb 0x66 0x7b 0x9c 0x7e 0x9d 0x7a 0x81
    0x32 0xea 0xb6 0x33 0xde 0x3a 0xa9 0x59 0x34 0x66 0x3b 0xaa 0xba 0x81 0x60 0x48
    0xb9 0xd5 0x81 0x9c 0xf8 0x6c 0x84 0x77 0xff 0x54 0x78 0x26 0x5f 0xbe 0xe8 0x1e
    0x36 0x9f 0x34 0x80 0x5c 0x45 0x2c 0x9b 0x76 0xd5 0x1b 0x8f 0xcc 0xc3 0xb8 0xf5
  )
  for ((i=0; i<size; i++)); do
    seed_byte=$((16#${seed_hex:i*2:2}))
    value=$(((seed_byte + xor_seed[size * i]) & 255))
    value=$((value ^ xor_seed[size * (size - i - 1)]))
    printf '%02x' "$value"
  done
  printf '\n'
}

xor_transform_hex() {
  local data_hex="$1"
  local key_hex="$2"
  local data_size=$((${#data_hex} / 2))
  local key_size=$((${#key_hex} / 2))
  local mod=$((data_size % 4))
  local out=""
  local byte
  local key_index
  local key_byte
  local i
  for ((i=0; i<data_size; i++)); do
    byte=$((16#${data_hex:i*2:2}))
    if (( i < mod )); then
      key_index=$((i % key_size))
    else
      key_index=$(((i - mod) % key_size))
    fi
    key_byte=$((16#${key_hex:key_index*2:2}))
    printf -v out '%s%02x' "$out" "$((byte ^ key_byte))"
  done
  printf '%s\n' "$out"
}

rsa_public_encrypt_file() {
  local input="$1"
  local output="$2"
  local size
  local offset=0
  local chunk="$TMP_DIR/rsa_encrypt_chunk.bin"
  : >"$output"
  size="$(wc -c <"$input" | tr -d ' ')"
  while (( offset < size )); do
    dd if="$input" of="$chunk" bs=1 skip="$offset" count=117 status=none
    openssl rsautl -encrypt -pubin -inkey "$TMP_DIR/115_public.pem" -pkcs -in "$chunk" >>"$output" 2>/dev/null
    offset=$((offset + 117))
  done
}

rsa_public_recover_file() {
  local input="$1"
  local output="$2"
  local size
  local offset=0
  local chunk="$TMP_DIR/rsa_recover_chunk.bin"
  local raw="$TMP_DIR/rsa_recover_raw.bin"
  local raw_hex
  local stripped_hex
  local i
  : >"$output"
  size="$(wc -c <"$input" | tr -d ' ')"
  (( size % 128 == 0 )) || die "invalid encrypted response length: $size"
  while (( offset < size )); do
    dd if="$input" of="$chunk" bs=1 skip="$offset" count=128 status=none
    openssl rsautl -verify -raw -pubin -inkey "$TMP_DIR/115_public.pem" -in "$chunk" -out "$raw" 2>/dev/null
    raw_hex="$(bytes_to_hex "$raw")"
    stripped_hex=""
    for ((i=2; i<${#raw_hex}; i+=2)); do
      if [[ "${raw_hex:i:2}" == "00" ]]; then
        stripped_hex="${raw_hex:i+2}"
        break
      fi
    done
    [[ -n "$stripped_hex" ]] || die "failed to unpad encrypted response chunk"
    hex_to_file "$stripped_hex" "$TMP_DIR/rsa_recover_plain_part.bin"
    cat "$TMP_DIR/rsa_recover_plain_part.bin" >>"$output"
    offset=$((offset + 128))
  done
}

m115_encode() {
  local input_text="$1"
  local key_hex="$2"
  local input_file="$TMP_DIR/m115_plain.txt"
  local rsa_plain="$TMP_DIR/m115_rsa_plain.bin"
  local rsa_encrypted="$TMP_DIR/m115_rsa_encrypted.bin"
  local data_hex
  local data_key
  local client_key="7806ad4c33865d184c013f46"
  printf '%s' "$input_text" >"$input_file"
  data_hex="$(bytes_to_hex "$input_file")"
  data_key="$(derive_key_hex "$key_hex" 4)"
  data_hex="$(xor_transform_hex "$data_hex" "$data_key")"
  data_hex="$(reverse_hex "$data_hex")"
  data_hex="$(xor_transform_hex "$data_hex" "$client_key")"
  hex_to_file "${key_hex}${data_hex}" "$rsa_plain"
  rsa_public_encrypt_file "$rsa_plain" "$rsa_encrypted"
  base64 <"$rsa_encrypted" | tr -d '\r\n'
}

m115_decode() {
  local input_text="$1"
  local key_hex="$2"
  local encrypted_file="$TMP_DIR/m115_response_encrypted.bin"
  local recovered_file="$TMP_DIR/m115_response_recovered.bin"
  local output_file="$TMP_DIR/m115_response_plain.txt"
  local recovered_hex
  local server_key_hex
  local data_hex
  local data_key
  printf '%s' "$input_text" | base64 -d >"$encrypted_file"
  rsa_public_recover_file "$encrypted_file" "$recovered_file"
  recovered_hex="$(bytes_to_hex "$recovered_file")"
  [[ ${#recovered_hex} -ge 32 ]] || die "decoded response is too short"
  server_key_hex="${recovered_hex:0:32}"
  data_hex="${recovered_hex:32}"
  data_key="$(derive_key_hex "$server_key_hex" 12)"
  data_hex="$(xor_transform_hex "$data_hex" "$data_key")"
  data_hex="$(reverse_hex "$data_hex")"
  data_key="$(derive_key_hex "$key_hex" 4)"
  data_hex="$(xor_transform_hex "$data_hex" "$data_key")"
  hex_to_file "$data_hex" "$output_file"
  tr -d '\000' <"$output_file"
}

build_add_payload() {
  local dir_id="$1"
  local uid="$2"
  local app_ver="$3"
  shift 3
  local payload
  local index=0
  local uri
  payload="$(jq -cn --arg dir "$dir_id" --arg app "$app_ver" --arg uid "$uid" '{ac:"add_task_urls", wp_path_id:$dir, app_ver:$app, uid:$uid}')"
  for uri in "$@"; do
    payload="$(printf '%s\n' "$payload" | jq --arg key "url[$index]" --arg value "$uri" '. + {($key): $value}')"
    index=$((index + 1))
  done
  printf '%s\n' "$payload"
}

cmd_version() {
  local ver
  ver="$(get_app_version)" || die "failed to get app version"
  [[ -n "$ver" ]] || die "empty app version response"
  api_check_or_print "$(jq -cn --arg version "$ver" '{version:$version}')" version
}

cmd_login_check() {
  require_cookie
  api_check_or_print "$(login_check_response)" login
}

cmd_add() {
  local dir_path=""
  local dir_id=""
  local response
  local space_response
  local sign
  local sign_time
  local uid
  local api_url
  local index=0
  local -a post_args=()
  local -a urls=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 ]] || die "missing value for --dir"
        dir_path="$2"
        shift 2
        ;;
      --url)
        [[ $# -ge 2 ]] || die "missing value for --url"
        urls+=("$2")
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  [[ -n "$dir_path" ]] || die "add requires --dir absolute path"
  dir_id="$(dir_id_by_path "$dir_path")"
  [[ -n "$dir_id" ]] || die "add requires --dir absolute path"
  [[ ${#urls[@]} -gt 0 ]] || die "add requires at least one --url"
  uid="$(resolve_uid)"
  space_response="$(offline_space_info)"
  sign="$(printf '%s\n' "$space_response" | jq -r '.sign // .data.sign // empty')"
  sign_time="$(printf '%s\n' "$space_response" | jq -r '.time // .data.time // empty')"
  [[ -n "$sign" && "$sign" != "null" && -n "$sign_time" && "$sign_time" != "null" ]] || die "failed to get offline sign/time: $space_response"

  post_args+=(--data-urlencode "savepath=")
  post_args+=(--data-urlencode "wp_path_id=${dir_id}")
  post_args+=(--data-urlencode "uid=${uid}")
  post_args+=(--data-urlencode "sign=${sign}")
  post_args+=(--data-urlencode "time=${sign_time}")
  if [[ ${#urls[@]} -eq 1 ]]; then
    api_url="$API_ADD_OFFLINE_SINGLE_WEB"
    post_args+=(--data-urlencode "url=${urls[0]}")
  else
    api_url="$API_ADD_OFFLINE_MULTI_WEB"
    for url in "${urls[@]}"; do
      post_args+=(--data-urlencode "url[${index}]=${url}")
      index=$((index + 1))
    done
  fi
  response="$(cookie_curl -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
    -H 'Accept: application/json, text/javascript, */*; q=0.01' \
    -H 'Referer: https://115.com/?tab=offline&mode=wangpan' \
    "${post_args[@]}" \
    "$api_url")"
  api_check_or_print "$response" add
}

cmd_list() {
  local page="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --page)
        [[ $# -ge 2 ]] || die "missing value for --page"
        page="$2"
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  api_check_or_print "$(cookie_curl -X POST -H 'Content-Type: application/json;charset=UTF-8' "${API_LIST_OFFLINE}&page=${page}")" offline-list
}

cmd_delete() {
  local flag="0"
  local -a hashes=()
  local -a curl_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hash)
        [[ $# -ge 2 ]] || die "missing value for --hash"
        hashes+=("$2")
        shift 2
        ;;
      --delete-files)
        flag="1"
        shift
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  [[ ${#hashes[@]} -gt 0 ]] || die "delete requires at least one --hash"
  local hash
  for hash in "${hashes[@]}"; do
    curl_args+=(--data-urlencode "hash=${hash}")
  done
  curl_args+=(--data-urlencode "flag=${flag}")
  api_check_or_print "$(cookie_curl -X POST -H 'Content-Type: application/json;charset=UTF-8' "${curl_args[@]}" "$API_DELETE_OFFLINE")" delete-task
}

cmd_clear() {
  local flag="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flag)
        [[ $# -ge 2 ]] || die "missing value for --flag"
        flag="$2"
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  api_check_or_print "$(cookie_curl -X POST -H 'Content-Type: application/json;charset=UTF-8' --data-urlencode "flag=${flag}" "$API_CLEAR_OFFLINE")" clear
}

cmd_mkdir() {
  local dir_path=""
  local parent
  local name
  local parent_id
  local response
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 ]] || die "missing value for --dir"
        dir_path="$2"
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  [[ -n "$dir_path" ]] || die "mkdir requires --dir absolute path"
  dir_path="$(normalize_cloud_path "$dir_path")"
  [[ "$dir_path" != "/" ]] || die "cannot create root directory"
  parent="$(cloud_parent_path "$dir_path")"
  name="$(cloud_basename "$dir_path")"
  parent_id="$(dir_id_by_path "$parent")"
  response="$(cookie_curl -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "pid=${parent_id}" --data-urlencode "cname=${name}" "$API_DIR_ADD")"
  api_check_or_print "$response" mkdir
}

cmd_ls() {
  local dir_path="/"
  local offset="0"
  local limit="100"
  local dir_id
  local response
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 ]] || die "missing value for --dir"
        dir_path="$2"
        shift 2
        ;;
      --offset)
        [[ $# -ge 2 ]] || die "missing value for --offset"
        offset="$2"
        shift 2
        ;;
      --limit)
        [[ $# -ge 2 ]] || die "missing value for --limit"
        limit="$2"
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  dir_id="$(dir_id_by_path "$dir_path")"
  response="$(list_dir_by_id "$dir_id" "$offset" "$limit")"
  response="$(normalize_paged_response "$response" "$offset")"
  api_check_or_print "$response" ls
}

cmd_info() {
  local path=""
  local object_id
  local response
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        [[ $# -ge 2 ]] || die "missing value for --path"
        path="$2"
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  [[ -n "$path" ]] || die "info requires --path absolute path"
  object_id="$(object_id_by_path "$path")"
  response="$(cookie_curl --get --data-urlencode "file_id=${object_id}" "$API_FILE_INFO")"
  api_check_or_print "$response" info
}

cmd_search() {
  local dir_path="/"
  local keyword=""
  local offset="0"
  local limit="100"
  local type="0"
  local fetch_all="0"
  local dir_id
  local response
  local page_offset
  local max_count
  local data_len
  local -a responses=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 ]] || die "missing value for --dir"
        dir_path="$2"
        shift 2
        ;;
      --keyword)
        [[ $# -ge 2 ]] || die "missing value for --keyword"
        keyword="$2"
        shift 2
        ;;
      --offset)
        [[ $# -ge 2 ]] || die "missing value for --offset"
        offset="$2"
        shift 2
        ;;
      --limit)
        [[ $# -ge 2 ]] || die "missing value for --limit"
        limit="$2"
        shift 2
        ;;
      --type)
        [[ $# -ge 2 ]] || die "missing value for --type"
        type="$2"
        shift 2
        ;;
      --all)
        fetch_all="1"
        shift
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  [[ -n "$keyword" ]] || die "search requires --keyword"
  dir_id="$(dir_id_by_path "$dir_path")"
  if [[ "$fetch_all" == "0" ]]; then
    response="$(search_by_id "$dir_id" "$keyword" "$offset" "$limit" "$type")"
    response="$(normalize_paged_response "$response" "$offset")"
  else
    page_offset="$offset"
    max_count=0
    while :; do
      response="$(search_by_id "$dir_id" "$keyword" "$page_offset" "$limit" "$type")"
      responses+=("$response")
      data_len="$(printf '%s\n' "$response" | jq -r '(.data // []) | length')"
      max_count="$(printf '%s\n' "$response" | jq -r --argjson current "$max_count" '[($current), (.count // 0), (.file_count // 0)] | max')"
      (( data_len > 0 )) || break
      page_offset=$((page_offset + limit))
      (( page_offset < max_count )) || break
    done
    response="$(printf '%s\n' "${responses[@]}" | jq -s '
      .[0] as $first
      | (map(.data[]? | . + {__key: ((.fid // .cid // .file_id // .n) | tostring)}) | unique_by(.__key) | map(del(.__key))) as $data
      | $first + {
          data: $data,
          requested_all: true,
          collected_count: ($data | length),
          source_count: ([.[].count // 0] | max),
          source_file_count: ([.[].file_count // 0] | max),
          source_folder_count: ([.[].folder_count // 0] | max),
          count: ($data | length),
          file_count: ($data | map(select(has("fid"))) | length),
          folder_count: ($data | map(select(has("cid") and (has("fid") | not))) | length),
          offset: 0,
          page_count: 1
        }
    ')"
  fi
  api_check_or_print "$response" search
}

cmd_rm() {
  local -a paths=()
  local -a args=()
  local path
  local object_id
  local index=0
  local response
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        [[ $# -ge 2 ]] || die "missing value for --path"
        paths+=("$2")
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  [[ ${#paths[@]} -gt 0 ]] || die "rm requires at least one --path"
  for path in "${paths[@]}"; do
    [[ "$(normalize_cloud_path "$path")" != "/" ]] || die "cannot delete root path"
    object_id="$(object_id_by_path "$path")"
    args+=(--data-urlencode "fid[${index}]=${object_id}")
    index=$((index + 1))
  done
  response="$(cookie_curl -X POST -H 'Content-Type: application/x-www-form-urlencoded' "${args[@]}" "$API_FILE_DELETE")"
  api_check_or_print "$response" rm
}

cmd_mv_or_cp() {
  local mode="$1"
  shift
  local target_dir=""
  local target_id
  local -a paths=()
  local -a args=()
  local path
  local object_id
  local index=0
  local api_url
  local response
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        [[ $# -ge 2 ]] || die "missing value for --path"
        paths+=("$2")
        shift 2
        ;;
      --target-dir)
        [[ $# -ge 2 ]] || die "missing value for --target-dir"
        target_dir="$2"
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  [[ ${#paths[@]} -gt 0 ]] || die "$mode requires at least one --path"
  [[ -n "$target_dir" ]] || die "$mode requires --target-dir absolute path"
  target_id="$(dir_id_by_path "$target_dir")"
  args+=(--data-urlencode "pid=${target_id}")
  for path in "${paths[@]}"; do
    [[ "$(normalize_cloud_path "$path")" != "/" ]] || die "cannot operate on root path"
    object_id="$(object_id_by_path "$path")"
    args+=(--data-urlencode "fid[${index}]=${object_id}")
    index=$((index + 1))
  done
  if [[ "$mode" == "mv" ]]; then
    api_url="$API_FILE_MOVE"
  else
    api_url="$API_FILE_COPY"
  fi
  response="$(cookie_curl -X POST -H 'Content-Type: application/x-www-form-urlencoded' "${args[@]}" "$api_url")"
  api_check_or_print "$response" "$mode"
}

cmd_rename() {
  local path=""
  local new_name=""
  local object_id
  local response
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        [[ $# -ge 2 ]] || die "missing value for --path"
        path="$2"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || die "missing value for --name"
        new_name="$2"
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  [[ -n "$path" ]] || die "rename requires --path absolute path"
  [[ -n "$new_name" ]] || die "rename requires --name"
  [[ "$(normalize_cloud_path "$path")" != "/" ]] || die "cannot rename root path"
  object_id="$(object_id_by_path "$path")"
  response="$(cookie_curl -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "fid=${object_id}" \
    --data-urlencode "file_name=${new_name}" \
    --data-urlencode "files_new_name[${object_id}]=${new_name}" \
    "$API_FILE_RENAME")"
  api_check_or_print "$response" rename
}

cmd_upload() {
  local dir_path=""
  local file_path=""
  local file_name=""
  local multipart_threshold="10485760"
  local part_size="10485760"
  local dir_id
  local app_ver
  local py_bin=""
  local upload_response
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 ]] || die "missing value for --dir"
        dir_path="$2"
        shift 2
        ;;
      --file)
        [[ $# -ge 2 ]] || die "missing value for --file"
        file_path="$2"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || die "missing value for --name"
        file_name="$2"
        shift 2
        ;;
      --multipart-threshold)
        [[ $# -ge 2 ]] || die "missing value for --multipart-threshold"
        multipart_threshold="$2"
        shift 2
        ;;
      --part-size)
        [[ $# -ge 2 ]] || die "missing value for --part-size"
        part_size="$2"
        shift 2
        ;;
      *)
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
        ;;
    esac
  done
  require_cookie
  [[ -n "$dir_path" ]] || die "upload requires --dir absolute path"
  [[ -n "$file_path" ]] || die "upload requires --file local path"
  [[ -f "$file_path" ]] || die "local upload file not found: $file_path"
  if command -v python3 >/dev/null 2>&1; then
    py_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    py_bin="python"
  else
    die "upload requires python3 or python"
  fi
  dir_id="$(dir_id_by_path "$dir_path")"
  app_ver="$(resolve_app_ver)"
  upload_response="$(PAN115_UPLOAD_COOKIE="$COOKIE" \
  PAN115_UPLOAD_DIR_ID="$dir_id" \
  PAN115_UPLOAD_FILE="$file_path" \
  PAN115_UPLOAD_NAME="$file_name" \
  PAN115_UPLOAD_APP_VER="$app_ver" \
  PAN115_UPLOAD_RAW="$RAW_RESPONSE" \
  PAN115_UPLOAD_MULTIPART_THRESHOLD="$multipart_threshold" \
  PAN115_UPLOAD_PART_SIZE="$part_size" \
  "$py_bin" - <<'PY'
import base64
import binascii
import email.utils
import hashlib
import hmac
import json
import mimetypes
import os
import random
import secrets
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_UPLOAD_INFO = "https://proapi.115.com/app/uploadinfo"
API_UPLOAD_INIT = "https://uplb.115.com/4.0/initupload.php"
API_OSS_TOKEN = "https://uplb.115.com/3.0/gettoken.php"
OSS_ENDPOINT = "cn-shenzhen.oss.aliyuncs.com"
OSS_USER_AGENT = "aliyun-sdk-android/2.9.1"
MD5_SALT = "Qclm8MGWUv59TnrR0XPg"

P = int("ffffffffffffffffffffffffffffffff000000000000000000000001", 16)
A = P - 3
B = int("b4050a850c04b3abf54132565044b0b7d7bfd8ba270b39432355ffb4", 16)
GX = int("b70e0cbd6bb4bf7f321390b94a03c1d356c21122343280d6115c1d21", 16)
GY = int("bd376388b5f723fb4c22dfe6cd4375a05a07476444d5819985007e34", 16)
N = int("ffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3d", 16)
REMOTE_PUB = bytes([
    0x57, 0xA2, 0x92, 0x57, 0xCD, 0x23, 0x20, 0xE5, 0xD6, 0xD1, 0x43, 0x32, 0x2F, 0xA4, 0xBB, 0x8A,
    0x3C, 0xF9, 0xD3, 0xCC, 0x62, 0x3E, 0xF5, 0xED, 0xAC, 0x62, 0xB7, 0x67, 0x8A, 0x89, 0xC9, 0x1A,
    0x83, 0xBA, 0x80, 0x0D, 0x61, 0x29, 0xF5, 0x22, 0xD0, 0x34, 0xC8, 0x95, 0xDD, 0x24, 0x65, 0x24,
    0x3A, 0xDD, 0xC2, 0x50, 0x95, 0x3B, 0xEE, 0xBA,
])
CRC_SALT = b"^j>WD3Kr?J2gLFjD4W2y@"

cookie = os.environ["PAN115_UPLOAD_COOKIE"]
dir_id = os.environ["PAN115_UPLOAD_DIR_ID"]
file_path = os.environ["PAN115_UPLOAD_FILE"]
file_name = os.environ.get("PAN115_UPLOAD_NAME") or os.path.basename(file_path)
app_ver = os.environ["PAN115_UPLOAD_APP_VER"]
raw = os.environ.get("PAN115_UPLOAD_RAW") == "1"
multipart_threshold = int(os.environ.get("PAN115_UPLOAD_MULTIPART_THRESHOLD") or str(10 * 1024 * 1024))
part_size = int(os.environ.get("PAN115_UPLOAD_PART_SIZE") or str(10 * 1024 * 1024))

def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)

def http_json(url, method="GET", data=None, headers=None):
    headers = dict(headers or {})
    headers.setdefault("Cookie", cookie)
    headers.setdefault("User-Agent", "Mozilla/5.0 115Browser/" + app_ver)
    if isinstance(data, dict):
        data = urllib.parse.urlencode(data).encode()
        headers.setdefault("Content-Type", "application/x-www-form-urlencoded")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        body = e.read()
        fail(f"http {e.code} for {url}: {body[:500]!r}")
    try:
        return json.loads(body.decode())
    except Exception:
        fail(f"invalid json from {url}: {body[:500]!r}")

def http_bytes(url, method="GET", data=None, headers=None):
    headers = dict(headers or {})
    headers.setdefault("User-Agent", "Mozilla/5.0 115Browser/" + app_ver)
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=3600) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        body = e.read()
        fail(f"http {e.code} for {url}: {body[:1000]!r}")

def inv_mod(x, p):
    return pow(x, p - 2, p)

def point_add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        m = ((3 * x1 * x1 + A) * inv_mod(2 * y1 % P, P)) % P
    else:
        m = ((y2 - y1) * inv_mod((x2 - x1) % P, P)) % P
    x3 = (m * m - x1 - x2) % P
    y3 = (m * (x1 - x3) - y1) % P
    return x3, y3

def scalar_mult(k, point):
    result = None
    addend = point
    while k:
        if k & 1:
            result = point_add(result, addend)
        addend = point_add(addend, addend)
        k >>= 1
    return result

def openssl_aes_cbc(data, key, iv, decrypt=False):
    args = ["openssl", "enc", "-aes-128-cbc", "-K", key.hex(), "-iv", iv.hex(), "-nopad"]
    if decrypt:
        args.append("-d")
    p = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        fail("openssl aes failed: " + p.stderr.decode(errors="ignore"))
    return p.stdout

def openssl_aes_ecb_encrypt_block(data, key):
    p = subprocess.run(
        ["openssl", "enc", "-aes-128-ecb", "-K", key.hex(), "-nopad"],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if p.returncode != 0:
        fail("openssl aes-ecb failed: " + p.stderr.decode(errors="ignore"))
    return p.stdout

def pkcs7_pad(data, block=16):
    n = block - len(data) % block
    return data + bytes([n]) * n

def lz4_decompress_block(data):
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        token = data[i]
        i += 1
        lit_len = token >> 4
        if lit_len == 15:
            while i < n:
                b = data[i]
                i += 1
                lit_len += b
                if b != 255:
                    break
        out.extend(data[i:i + lit_len])
        i += lit_len
        if i >= n:
            break
        if i + 2 > n:
            fail("bad lz4 block offset")
        offset = data[i] | (data[i + 1] << 8)
        i += 2
        if offset == 0 or offset > len(out):
            fail("bad lz4 block match offset")
        match_len = (token & 0x0F) + 4
        if (token & 0x0F) == 15:
            while i < n:
                b = data[i]
                i += 1
                match_len += b
                if b != 255:
                    break
        start = len(out) - offset
        for j in range(match_len):
            out.append(out[start + j])
    return bytes(out)

class EC115:
    def __init__(self):
        remote = (int.from_bytes(REMOTE_PUB[:28], "big"), int.from_bytes(REMOTE_PUB[28:], "big"))
        priv = secrets.randbelow(N - 1) + 1
        pub = scalar_mult(priv, (GX, GY))
        secret = scalar_mult(priv, remote)[0].to_bytes(28, "big")
        x, y = pub
        self.pubkey = bytes([29, 0x03 if y & 1 else 0x02]) + x.to_bytes(28, "big")
        self.key = secret[:16]
        self.iv = secret[-16:]

    def encrypt(self, plain):
        data = pkcs7_pad(plain)
        xor_key = self.iv
        out = bytearray()
        for i in range(0, len(data), 16):
            block = bytes(a ^ b for a, b in zip(data[i:i + 16], xor_key))
            xor_key = openssl_aes_ecb_encrypt_block(block, self.key)
            out.extend(xor_key)
        return bytes(out)

    def decrypt(self, cipher):
        cipher = cipher[:len(cipher) - len(cipher) % 16]
        block = openssl_aes_cbc(cipher, self.key, self.iv, decrypt=True)
        length = block[0] + (block[1] << 8)
        return lz4_decompress_block(block[2:2 + length])

    def token(self, timestamp_ms):
        r1 = random.randrange(256)
        r2 = random.randrange(256)
        t = struct.pack(">I", timestamp_ms & 0xffffffff)
        tmp = bytearray()
        tmp.extend(b ^ r1 for b in self.pubkey[:15])
        tmp.extend([r1, 0x73 ^ r1])
        tmp.extend([r1] * 3)
        tmp.extend(r1 ^ b for b in t[::-1])
        tmp.extend(b ^ r2 for b in self.pubkey[15:])
        tmp.extend([r2, 0x01 ^ r2])
        tmp.extend([r2] * 3)
        crc = binascii.crc32(CRC_SALT + bytes(tmp)) & 0xffffffff
        tmp.extend(struct.pack(">I", crc)[::-1])
        return base64.b64encode(bytes(tmp)).decode()

def file_sha1s(path):
    full = hashlib.sha1()
    pre = hashlib.sha1()
    pre_left = 128 * 1024
    size = 0
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            full.update(chunk)
            if pre_left > 0:
                part = chunk[:pre_left]
                pre.update(part)
                pre_left -= len(part)
    return size, pre.hexdigest().upper(), full.hexdigest().upper()

def sha1_range(path, spec):
    start_s, end_s = spec.split("-", 1)
    start = int(start_s)
    end = int(end_s)
    h = hashlib.sha1()
    with open(path, "rb") as f:
        f.seek(start)
        left = end - start + 1
        while left > 0:
            chunk = f.read(min(left, 1024 * 1024))
            if not chunk:
                break
            h.update(chunk)
            left -= len(chunk)
    return h.hexdigest().upper()

def gen_sig(user_id, userkey, file_id, target):
    inner = hashlib.sha1((str(user_id) + file_id + target + "0").encode()).hexdigest()
    return hashlib.sha1((userkey + inner + "000000").encode()).hexdigest().upper()

def gen_token(user_id, file_id, pre_id, timestamp, size, sign_key, sign_val, variant=0):
    uid = str(user_id)
    uid_md5 = hashlib.md5(uid.encode()).hexdigest()
    if variant == 1:
        raw = MD5_SALT + file_id + pre_id + str(size) + sign_key + sign_val + uid + str(timestamp) + uid_md5 + app_ver
    elif variant == 2:
        raw = MD5_SALT + pre_id + file_id + str(size) + sign_key + sign_val + uid + str(timestamp) + uid_md5 + app_ver
    elif variant == 3:
        raw = MD5_SALT + file_id + str(size) + sign_key + sign_val + uid + str(timestamp) + uid_md5
    elif variant == 4:
        raw = MD5_SALT + file_id + str(size) + uid + str(timestamp) + uid_md5 + app_ver + sign_key + sign_val
    else:
        raw = MD5_SALT + file_id + str(size) + sign_key + sign_val + uid + str(timestamp) + uid_md5 + app_ver
    return hashlib.md5(raw.encode()).hexdigest()

def upload_info():
    info = http_json(API_UPLOAD_INFO, method="POST", headers={"Content-Type": "application/json;charset=UTF-8"})
    if not info.get("state"):
        fail("uploadinfo failed: " + json.dumps(info, ensure_ascii=False))
    return info

def init_upload(user_id, userkey, size, pre_sha1, full_sha1):
    ec = EC115()
    target = "U_1_" + dir_id
    sign_key = ""
    sign_val = ""
    token_variants = [0, 1, 2, 3, 4]
    variant_index = 0
    while True:
        ts = int(time.time() * 1000)
        form = {
            "appid": "0",
            "appversion": app_ver,
            "userid": str(user_id),
            "filename": file_name,
            "filesize": str(size),
            "fileid": full_sha1,
            "preid": pre_sha1,
            "target": target,
            "sig": gen_sig(user_id, userkey, full_sha1, target),
            "topupload": "true",
            "t": str(ts),
            "token": gen_token(user_id, full_sha1, pre_sha1, ts, size, sign_key, sign_val, token_variants[variant_index]),
        }
        if sign_key and sign_val:
            form["sign_key"] = sign_key
            form["sign_val"] = sign_val
        body = urllib.parse.urlencode(sorted(form.items())).encode()
        encrypted = ec.encrypt(body)
        url = API_UPLOAD_INIT + "?" + urllib.parse.urlencode({"k_ec": ec.token(ts)})
        resp_bytes = http_bytes(url, method="POST", data=encrypted, headers={"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"})
        try:
            decoded = json.loads(ec.decrypt(resp_bytes).decode())
        except Exception as e:
            fail("failed to decode initupload response: " + str(e))
        if raw:
            print(json.dumps({"event": "initupload_try", "token_variant": token_variants[variant_index], "status": decoded.get("status"), "statuscode": decoded.get("statuscode"), "statusmsg": decoded.get("statusmsg")}, ensure_ascii=False), file=sys.stderr)
        decoded["sha1"] = full_sha1
        if decoded.get("status") == 7:
            sign_key = decoded.get("sign_key", "")
            sign_val = sha1_range(file_path, decoded.get("sign_check", ""))
            variant_index = 0
            continue
        if decoded.get("statuscode") == 400 and "token invalid" in decoded.get("statusmsg", "") and variant_index + 1 < len(token_variants):
            variant_index += 1
            continue
        return decoded

def oss_token():
    token = http_json(API_OSS_TOKEN, headers={"Content-Type": "application/json;charset=UTF-8"})
    if token.get("StatusCode") != "200":
        fail("get oss token failed: " + json.dumps(token, ensure_ascii=False))
    return token

def oss_put(params, token):
    bucket = params["bucket"]
    obj = params["object"]
    callback = params["callback"]["callback"]
    callback_var = params["callback"]["callback_var"]
    content_type = mimetypes.guess_type(file_name)[0] or "application/octet-stream"
    date = email.utils.formatdate(usegmt=True)
    headers = {
        "Date": date,
        "Content-Type": content_type,
        "User-Agent": OSS_USER_AGENT,
        "x-oss-security-token": token["SecurityToken"],
        "x-oss-callback": base64.b64encode(callback.encode()).decode(),
        "x-oss-callback-var": base64.b64encode(callback_var.encode()).decode(),
    }
    canonical_oss = "".join(f"{k}:{headers[k]}\n" for k in sorted(h for h in headers if h.startswith("x-oss-")))
    resource = f"/{bucket}/{obj}"
    string_to_sign = "PUT\n\n" + content_type + "\n" + date + "\n" + canonical_oss + resource
    access_key_id = token.get("AccessKeyID") or token.get("AccessKeyId")
    sig = base64.b64encode(hmac.new(token["AccessKeySecret"].encode(), string_to_sign.encode(), hashlib.sha1).digest()).decode()
    headers["Authorization"] = "OSS " + access_key_id + ":" + sig
    url = "https://" + bucket + "." + OSS_ENDPOINT + "/" + urllib.parse.quote(obj, safe="/")
    with open(file_path, "rb") as f:
        data = f.read()
    return http_bytes(url, method="PUT", data=data, headers=headers)

def oss_headers(token, content_type="", extra=None):
    headers = {
        "Date": email.utils.formatdate(usegmt=True),
        "User-Agent": OSS_USER_AGENT,
        "x-oss-security-token": token["SecurityToken"],
    }
    if content_type:
        headers["Content-Type"] = content_type
    if extra:
        headers.update(extra)
    return headers

def oss_signed_request(method, bucket, obj, token, query="", data=None, headers=None, content_type=""):
    headers = dict(headers or {})
    date = headers.get("Date") or email.utils.formatdate(usegmt=True)
    headers["Date"] = date
    if content_type:
        headers["Content-Type"] = content_type
    canonical_oss = "".join(f"{k.lower()}:{headers[k]}\n" for k in sorted(headers, key=str.lower) if k.lower().startswith("x-oss-"))
    resource = f"/{bucket}/{obj}"
    if query:
        resource += "?" + query
    string_to_sign = method + "\n\n" + (headers.get("Content-Type", "")) + "\n" + date + "\n" + canonical_oss + resource
    access_key_id = token.get("AccessKeyID") or token.get("AccessKeyId")
    sig = base64.b64encode(hmac.new(token["AccessKeySecret"].encode(), string_to_sign.encode(), hashlib.sha1).digest()).decode()
    headers["Authorization"] = "OSS " + access_key_id + ":" + sig
    url = "https://" + bucket + "." + OSS_ENDPOINT + "/" + urllib.parse.quote(obj, safe="/")
    if query:
        url += "?" + query
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=3600) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        body = e.read()
        fail(f"oss {method} http {e.code}: {body[:1000]!r}")

def oss_multipart(params, token):
    if part_size < 100 * 1024:
        fail("--part-size must be at least 102400 bytes for OSS multipart")
    bucket = params["bucket"]
    obj = params["object"]
    callback = params["callback"]["callback"]
    callback_var = params["callback"]["callback_var"]
    _, _, init_body = oss_signed_request(
        "POST",
        bucket,
        obj,
        token,
        query="sequential&uploads&x-oss-enable-sha1",
        data=None,
        headers=oss_headers(token),
    )
    upload_id = None
    text = init_body.decode(errors="replace")
    start = text.find("<UploadId>")
    end = text.find("</UploadId>")
    if start >= 0 and end > start:
        upload_id = text[start + len("<UploadId>"):end]
    if not upload_id:
        fail("failed to parse OSS UploadId: " + text[:500])

    parts = []
    total = os.path.getsize(file_path)
    uploaded = 0
    part_number = 1
    with open(file_path, "rb") as f:
        while True:
            chunk = f.read(part_size)
            if not chunk:
                break
            query = urllib.parse.urlencode({"partNumber": str(part_number), "uploadId": upload_id})
            last_error = None
            for _ in range(3):
                try:
                    _, resp_headers, _ = oss_signed_request(
                        "PUT",
                        bucket,
                        obj,
                        token,
                        query=query,
                        data=chunk,
                        headers=oss_headers(token),
                        content_type="application/octet-stream",
                    )
                    etag = resp_headers.get("ETag")
                    if not etag:
                        fail("OSS UploadPart response missing ETag")
                    parts.append((part_number, etag.strip('"')))
                    uploaded += len(chunk)
                    print(json.dumps({"event": "upload_part", "part": part_number, "uploaded": uploaded, "total": total}, ensure_ascii=False), file=sys.stderr)
                    break
                except SystemExit:
                    raise
                except Exception as e:
                    last_error = e
                    time.sleep(1)
            else:
                fail(f"failed to upload part {part_number}: {last_error}")
            part_number += 1

    complete_xml = "<CompleteMultipartUpload>" + "".join(
        f"<Part><PartNumber>{num}</PartNumber><ETag>{etag}</ETag></Part>" for num, etag in parts
    ) + "</CompleteMultipartUpload>"
    callback_headers = oss_headers(token, "application/xml", {
        "x-oss-callback": base64.b64encode(callback.encode()).decode(),
        "x-oss-callback-var": base64.b64encode(callback_var.encode()).decode(),
    })
    _, _, body = oss_signed_request(
        "POST",
        bucket,
        obj,
        token,
        query=urllib.parse.urlencode({"uploadId": upload_id}),
        data=complete_xml.encode(),
        headers=callback_headers,
        content_type="application/xml",
    )
    return body

size, pre_sha1, full_sha1 = file_sha1s(file_path)
info = upload_info()
limit = int(info.get("file_size_limit", 0) or info.get("size_limit", 0) or info.get("file_size", 0) or 0)
meta = info.get("upload_meta_info") or {}
if meta.get("size_limit"):
    limit = int(meta["size_limit"])
if limit and size > limit:
    fail(f"file too large for 115 upload limit: {size} > {limit}")
user_id = info.get("user_id")
userkey = info.get("userkey")
if not user_id or not userkey:
    fail("uploadinfo response missing user_id/userkey: " + json.dumps(info, ensure_ascii=False))
init = init_upload(user_id, userkey, size, pre_sha1, full_sha1)
if raw:
    print(json.dumps({"initupload": init}, ensure_ascii=False))
if init.get("status") == 2:
    print(json.dumps({"state": True, "rapid_upload": True, "initupload": init}, ensure_ascii=False))
    sys.exit(0)
if "bucket" not in init or "object" not in init or "callback" not in init:
    fail("initupload did not return oss params: " + json.dumps(init, ensure_ascii=False))
token = oss_token()
if size > multipart_threshold:
    body = oss_multipart(init, token)
    upload_mode = "multipart"
else:
    body = oss_put(init, token)
    upload_mode = "put_object"
try:
    result = json.loads(body.decode())
except Exception:
    result = {"raw": body.decode(errors="replace")}
print(json.dumps({"state": True, "rapid_upload": False, "upload_mode": upload_mode, "oss_result": result, "initupload": init}, ensure_ascii=False))
PY
)"
  api_check_or_print "$upload_response" upload
}

PARSED_SHIFT=0
parse_common_option() {
  case "$1" in
    --cookie)
      [[ $# -ge 2 ]] || die "missing value for --cookie"
      COOKIE="$2"
      PARSED_SHIFT=2
      ;;
    --raw-response)
      RAW_RESPONSE=1
      PARSED_SHIFT=1
      ;;
    --json)
      OUTPUT_JSON=1
      PARSED_SHIFT=1
      ;;
    --verbose)
      SCRIPT_VERBOSE=1
      PARSED_SHIFT=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
}

main() {
  local command="${1:-}"
  if [[ -z "$command" || "$command" == "--help" || "$command" == "-h" ]]; then
    usage
    exit 0
  fi
  shift
  require_deps
  make_tmp_dir
  write_public_key
  case "$command" in
    version)
      while [[ $# -gt 0 ]]; do
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
      done
      cmd_version
      ;;
    login-check)
      while [[ $# -gt 0 ]]; do
        parse_common_option "$@"
        shift "$PARSED_SHIFT"
      done
      cmd_login_check
      ;;
    add)
      cmd_add "$@"
      ;;
    list)
      cmd_list "$@"
      ;;
    delete)
      cmd_delete "$@"
      ;;
    clear)
      cmd_clear "$@"
      ;;
    mkdir)
      cmd_mkdir "$@"
      ;;
    ls)
      cmd_ls "$@"
      ;;
    info)
      cmd_info "$@"
      ;;
    search)
      cmd_search "$@"
      ;;
    rm)
      cmd_rm "$@"
      ;;
    mv)
      cmd_mv_or_cp mv "$@"
      ;;
    cp)
      cmd_mv_or_cp cp "$@"
      ;;
    rename)
      cmd_rename "$@"
      ;;
    upload)
      cmd_upload "$@"
      ;;
    *)
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
