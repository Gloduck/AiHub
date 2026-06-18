#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
BASE_URL="${MXECY_TORRENT_BASE_URL:-https://tool.mxecy.cn}"
COMMAND=""
KEYWORD=""
SOURCE=""
ID=""
HASH=""
PAGE_INDEX="1"
PAGE_SIZE="50"
SORT_FIELD=""
SORT_ORDER=""
SORT=""
OUTPUT_JSON=0
RAW_RESPONSE=0
SCRIPT_VERBOSE=0

usage() {
  cat <<EOF
Usage:
  script/${SCRIPT_NAME} sources [options]
  script/${SCRIPT_NAME} search --keyword TEXT --source SOURCE [options]
  script/${SCRIPT_NAME} detail --source SOURCE --id ID [options]
  script/${SCRIPT_NAME} magnet (--hash HASH | --source SOURCE --id ID) [options]

Purpose:
  Query mxecy aggregate magnet/torrent search APIs under tool.mxecy.cn/torrent.

Commands:
  sources               list available aggregate search sources
  search                search torrents by keyword and source
  detail                query one torrent detail by source and item id
  magnet                print magnet link from a hash, or from detail by source/id

Required inputs:
  search --keyword TEXT --source SOURCE
  detail --source SOURCE --id ID
  magnet --hash HASH, or magnet --source SOURCE --id ID

Optional inputs:
  --page-index N        search page index; default 1
  --page-size N         search page size; default 50
  --sort FIELD-ORDER    search sort shortcut, for example uploadTime-desc
  --sort-field FIELD    search sort field supported by the selected handler
  --sort-order ORDER    search sort order: asc or desc
  --base-url URL        API site base URL; default https://tool.mxecy.cn or MXECY_TORRENT_BASE_URL
  --json                print raw API response JSON instead of human-friendly text
  --raw-response        alias of --json
  --verbose             print request information to stderr
  --help                show this message

Environment fallback:
  MXECY_TORRENT_BASE_URL

Dependencies:
  bash, curl, jq

Default behavior:
  - sources calls /api/torrent/listHandlers.
  - search calls /api/torrent/search with pageIndex, pageSize, source, keyword, and optional sort values.
  - If sort is specified but the source does not support it, a warning is printed and sort values are omitted.
  - detail and magnet with source/id call /api/torrent/queryDetail.
  - stdout prints human-friendly text by default; use --json for raw API JSON.
  - stderr is used for logs and errors.

Side effects:
  Sends HTTP GET requests to the configured mxecy torrent API. It does not modify local files.

Platform notes:
  Designed for Linux shell and Git Bash.
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

warn() {
  printf 'warn: %s\n' "$*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_deps() {
  require_cmd curl
  require_cmd jq
}

normalize_base_url() {
  BASE_URL="${BASE_URL%/}"
  [[ -n "$BASE_URL" ]] || die "empty --base-url"
}

api_get() {
  local path="$1"
  shift
  normalize_base_url
  log "GET ${BASE_URL}${path}"
  curl -fsSL --get "$BASE_URL$path" "$@"
}

check_response() {
  local response="$1"
  local code
  code="$(printf '%s\n' "$response" | jq -r '.code // empty')"
  [[ "$code" == "200" ]] || die "API returned code ${code:-unknown}: $(printf '%s\n' "$response" | jq -r '.msg // .message // "unknown error"')"
}

print_response() {
  local response="$1"
  if [[ "$RAW_RESPONSE" == "1" || "$OUTPUT_JSON" == "1" ]]; then
    printf '%s\n' "$response"
  fi
}

format_sources() {
  local response="$1"
  if [[ "$RAW_RESPONSE" == "1" || "$OUTPUT_JSON" == "1" ]]; then
    print_response "$response"
    return
  fi
  jq -r '
    "source\tavailable\turl\ttags\tsupportSortFields",
    (.data[] | [
      .code,
      (.available | tostring),
      (.url // ""),
      ((.tags // []) | join(",")),
      ((.supportSortFields // []) | join(","))
    ] | @tsv)
  ' <<<"$response"
}

format_search() {
  local response="$1"
  if [[ "$RAW_RESPONSE" == "1" || "$OUTPUT_JSON" == "1" ]]; then
    print_response "$response"
    return
  fi
  jq -r '
    def sizefmt:
      if . == null then "-"
      elif . >= 1099511627776 then ((. / 1099511627776 * 100 | round / 100 | tostring) + " TiB")
      elif . >= 1073741824 then ((. / 1073741824 * 100 | round / 100 | tostring) + " GiB")
      elif . >= 1048576 then ((. / 1048576 * 100 | round / 100 | tostring) + " MiB")
      elif . >= 1024 then ((. / 1024 * 100 | round / 100 | tostring) + " KiB")
      else (. | tostring) + " B" end;
    def timefmt:
      if . == null then "-" else ((. / 1000) | strftime("%Y-%m-%d %H:%M:%S")) end;
    "pageIndex: \(.data.index // "-")",
    "hasNext: \(.data.hasNext // false)",
    "items:",
    ((.data.items // [])[] | "- name: \(.name // "-")\n  id: \(.id // "-")\n  hash: \(.hash // "-")\n  magnet: \(if .hash then "magnet:?xt=urn:btih:" + .hash else "-" end)\n  size: \(.size | sizefmt)\n  uploadTime: \(.uploadTime | timefmt)\n  fileCount: \(.fileCount // "-")")
  ' <<<"$response"
}

format_detail() {
  local response="$1"
  if [[ "$RAW_RESPONSE" == "1" || "$OUTPUT_JSON" == "1" ]]; then
    print_response "$response"
    return
  fi
  jq -r '
    def sizefmt:
      if . == null then "-"
      elif . >= 1099511627776 then ((. / 1099511627776 * 100 | round / 100 | tostring) + " TiB")
      elif . >= 1073741824 then ((. / 1073741824 * 100 | round / 100 | tostring) + " GiB")
      elif . >= 1048576 then ((. / 1048576 * 100 | round / 100 | tostring) + " MiB")
      elif . >= 1024 then ((. / 1024 * 100 | round / 100 | tostring) + " KiB")
      else (. | tostring) + " B" end;
    def timefmt:
      if . == null then "-" else ((. / 1000) | strftime("%Y-%m-%d %H:%M:%S")) end;
    .data as $d
    | "name: \($d.name // "-")",
      "id: \($d.id // "-")",
      "hash: \($d.hash // "-")",
      "magnet: \(if $d.hash then "magnet:?xt=urn:btih:" + $d.hash else "-" end)",
      "size: \($d.size | sizefmt)",
      "uploadTime: \($d.uploadTime | timefmt)",
      "fileCount: \($d.fileCount // "-")",
      "files:",
      (($d.files // [])[] | "- \(.name // "-")\t\(.size | sizefmt)")
  ' <<<"$response"
}

cmd_sources() {
  local response
  response="$(api_get "/api/torrent/listHandlers")"
  check_response "$response"
  format_sources "$response"
}

source_info_response() {
  local response
  response="$(api_get "/api/torrent/listHandlers")"
  check_response "$response"
  printf '%s\n' "$response"
}

normalize_sort_args() {
  if [[ -n "$SORT" ]]; then
    SORT_FIELD="${SORT%-*}"
    SORT_ORDER="${SORT##*-}"
    [[ "$SORT_FIELD" != "$SORT" && -n "$SORT_FIELD" && -n "$SORT_ORDER" ]] || die "invalid --sort value, expected FIELD-asc or FIELD-desc"
  fi
  [[ -z "$SORT_ORDER" || "$SORT_ORDER" == "asc" || "$SORT_ORDER" == "desc" ]] || die "invalid --sort-order: $SORT_ORDER"
}

sort_is_supported() {
  local source_response="$1"
  local source="$2"
  local field="$3"
  local order="$4"
  jq -e --arg source "$source" --arg field "$field" --arg order "$order" '
    .data[]?
    | select(.code == $source)
    | (.supportSortFields // []) as $fields
    | any($fields[]?;
        . == $field
        or (. == ("+" + $field) and $order == "asc")
        or (. == ("-" + $field) and $order == "desc")
      )
  ' >/dev/null <<<"$source_response"
}

source_exists() {
  local source_response="$1"
  local source="$2"
  jq -e --arg source "$source" '.data[]? | select(.code == $source)' >/dev/null <<<"$source_response"
}

append_sort_args_if_supported() {
  local -n target_args="$1"
  normalize_sort_args
  if [[ -z "$SORT_FIELD" && -z "$SORT_ORDER" ]]; then
    return 0
  fi
  [[ -n "$SORT_FIELD" && -n "$SORT_ORDER" ]] || die "--sort-field and --sort-order must be specified together"

  local response
  response="$(source_info_response)"
  if ! source_exists "$response" "$SOURCE"; then
    warn "source '$SOURCE' was not found while validating sort support; sort values are omitted"
    return
  fi
  if ! sort_is_supported "$response" "$SOURCE" "$SORT_FIELD" "$SORT_ORDER"; then
    warn "source '$SOURCE' does not support sort '$SORT_FIELD-$SORT_ORDER'; sort values are omitted"
    return
  fi
  target_args+=(--data-urlencode "sortField=$SORT_FIELD" --data-urlencode "sortOrder=$SORT_ORDER")
}

cmd_search() {
  [[ -n "$KEYWORD" ]] || die "missing --keyword"
  [[ -n "$SOURCE" ]] || die "missing --source"
  local args=(
    --data-urlencode "pageIndex=$PAGE_INDEX"
    --data-urlencode "pageSize=$PAGE_SIZE"
    --data-urlencode "code=$SOURCE"
    --data-urlencode "keyword=$KEYWORD"
  )
  append_sort_args_if_supported args
  local response
  response="$(api_get "/api/torrent/search" "${args[@]}")"
  check_response "$response"
  format_search "$response"
}

query_detail_response() {
  [[ -n "$SOURCE" ]] || die "missing --source"
  [[ -n "$ID" ]] || die "missing --id"
  api_get "/api/torrent/queryDetail" --data-urlencode "code=$SOURCE" --data-urlencode "id=$ID"
}

cmd_detail() {
  local response
  response="$(query_detail_response)"
  check_response "$response"
  format_detail "$response"
}

cmd_magnet() {
  if [[ -n "$HASH" ]]; then
    printf 'magnet:?xt=urn:btih:%s\n' "$HASH"
    return
  fi
  local response hash
  response="$(query_detail_response)"
  check_response "$response"
  hash="$(printf '%s\n' "$response" | jq -r '.data.hash // empty')"
  [[ -n "$hash" ]] || die "detail response does not contain hash"
  printf 'magnet:?xt=urn:btih:%s\n' "$hash"
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi
  COMMAND="$1"
  shift
  case "$COMMAND" in
    sources|search|detail|magnet) ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown command: $COMMAND" ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keyword)
        [[ $# -ge 2 ]] || die "missing value for --keyword"
        KEYWORD="$2"
        shift 2
        ;;
      --source)
        [[ $# -ge 2 ]] || die "missing value for --source"
        SOURCE="$2"
        shift 2
        ;;
      --id)
        [[ $# -ge 2 ]] || die "missing value for --id"
        ID="$2"
        shift 2
        ;;
      --hash)
        [[ $# -ge 2 ]] || die "missing value for --hash"
        HASH="$2"
        shift 2
        ;;
      --page-index)
        [[ $# -ge 2 ]] || die "missing value for --page-index"
        PAGE_INDEX="$2"
        shift 2
        ;;
      --page-size)
        [[ $# -ge 2 ]] || die "missing value for --page-size"
        PAGE_SIZE="$2"
        shift 2
        ;;
      --sort)
        [[ $# -ge 2 ]] || die "missing value for --sort"
        SORT="$2"
        shift 2
        ;;
      --sort-field)
        [[ $# -ge 2 ]] || die "missing value for --sort-field"
        SORT_FIELD="$2"
        shift 2
        ;;
      --sort-order)
        [[ $# -ge 2 ]] || die "missing value for --sort-order"
        SORT_ORDER="$2"
        shift 2
        ;;
      --base-url)
        [[ $# -ge 2 ]] || die "missing value for --base-url"
        BASE_URL="$2"
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
        SCRIPT_VERBOSE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_deps
  case "$COMMAND" in
    sources) cmd_sources ;;
    search) cmd_search ;;
    detail) cmd_detail ;;
    magnet) cmd_magnet ;;
  esac
}

main "$@"
