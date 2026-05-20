#!/usr/bin/env bash

set -euo pipefail

source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/_lib/common.sh"

readonly SCRIPT_NAME="$(basename "$0")"
readonly IMGBB_AUTH_URL="https://imgbb.com/"
readonly IMGBB_UPLOAD_URL="https://imgbb.com/json"
readonly POSTIMAGES_UPLOAD_URL="https://postimages.org/json"

SCRIPT_VERBOSE=0

selected_site=""
expire_value=""
expire_seconds=""
output_format="text"
raw_response=0
declare -a input_files=()

print_help() {
  cat <<'EOF'
Usage:
  script/upload_images_to_image_server.sh [--site postimages|imgbb] [--expire VALUE] [--raw-response] [--verbose] FILE...

Purpose:
  Upload one or more local image files to Postimages or ImgBB and print the image name,
  original_url, and display_url for each file on stdout. When --site is omitted, the script
  tries ImgBB first and then Postimages for each file until one succeeds.

Required inputs:
  FILE...                  one or more local image file paths

Optional inputs:
  --site NAME              upload backend: postimages or imgbb
  --expire VALUE           auto-delete time like 300s, 30m, 1d; omitted means no expiration
  --raw-response           output JSON instead of text blocks
  --verbose                print debug logs to stderr
  --help                   show this message

Default behavior:
  - Without --site, the script tries backends in this order: imgbb, postimages.
  - Stdout prints one result block per input file, in the same order as the input files.
  - With --raw-response, stdout prints a JSON array of result objects instead.
  - Stderr is used only for logs and errors.

Expiration notes:
  - Supported units are s, m, and d. Examples: 30m, 1d, 7d, 30d.
  - Postimages receives the mapped second value directly.
  - ImgBB website uploads still support only a fixed set of durations.
  - When --site is omitted and the requested expiration is unsupported by ImgBB, the script skips
    ImgBB for that file and falls back to Postimages.

Side effects:
  - Sends HTTP upload requests to the selected image host.
  - Uploaded images become publicly reachable through the returned original_url and display_url.

Platform notes:
  - Designed for Linux shell and Git Bash.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --site)
        [[ $# -ge 2 ]] || die "missing value for --site"
        selected_site="$2"
        shift 2
        ;;
      --expire)
        [[ $# -ge 2 ]] || die "missing value for --expire"
        expire_value="$2"
        shift 2
        ;;
      --raw-response)
        raw_response=1
        shift
        ;;
      --verbose)
        SCRIPT_VERBOSE=1
        shift
        ;;
      --help)
        print_help
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          input_files+=("$1")
          shift
        done
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        input_files+=("$1")
        shift
        ;;
    esac
  done
}

validate_site() {
  case "$1" in
    ""|postimages|imgbb)
      ;;
    *)
      die "unsupported site: $1"
      ;;
  esac
}

parse_expire_to_seconds() {
  local raw_value="$1"
  local amount
  local unit

  if [[ -z "$raw_value" ]]; then
    expire_seconds=0
    printf '%s\n' "$expire_seconds"
    return
  fi

  [[ "$raw_value" =~ ^([0-9]+)([smd])$ ]] || die "--expire must look like 300s, 30m, or 1d"
  amount="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"

  case "$unit" in
    s)
      expire_seconds="$amount"
      ;;
    m)
      expire_seconds=$((amount * 60))
      ;;
    d)
      expire_seconds=$((amount * 86400))
      ;;
    *)
      die "unsupported expire unit: $unit"
      ;;
  esac

  printf '%s\n' "$expire_seconds"
}

imgbb_expiration_from_seconds() {
  case "$1" in
    0) printf '%s\n' "" ;;
    300) printf '%s\n' "PT5M" ;;
    900) printf '%s\n' "PT15M" ;;
    1800) printf '%s\n' "PT30M" ;;
    3600) printf '%s\n' "PT1H" ;;
    10800) printf '%s\n' "PT3H" ;;
    21600) printf '%s\n' "PT6H" ;;
    43200) printf '%s\n' "PT12H" ;;
    86400) printf '%s\n' "P1D" ;;
    172800) printf '%s\n' "P2D" ;;
    259200) printf '%s\n' "P3D" ;;
    345600) printf '%s\n' "P4D" ;;
    432000) printf '%s\n' "P5D" ;;
    518400) printf '%s\n' "P6D" ;;
    604800) printf '%s\n' "P1W" ;;
    1209600) printf '%s\n' "P2W" ;;
    1814400) printf '%s\n' "P3W" ;;
    2592000) printf '%s\n' "P1M" ;;
    5184000) printf '%s\n' "P2M" ;;
    7776000) printf '%s\n' "P3M" ;;
    10368000) printf '%s\n' "P4M" ;;
    12960000) printf '%s\n' "P5M" ;;
    15552000) printf '%s\n' "P6M" ;;
    *) return 1 ;;
  esac
}

unescape_json_slashes() {
  printf '%s\n' "${1//\\\//\/}"
}

extract_json_string_field() {
  local json_text="$1"
  local field_name="$2"
  local value

  value="$(printf '%s\n' "$json_text" | sed -n "s/.*\"$field_name\":\"\([^\"]*\)\".*/\1/p" | head -n 1)"
  [[ -n "$value" ]] || return 1
  unescape_json_slashes "$value"
}

extract_json_string_with_pattern() {
  local json_text="$1"
  local sed_pattern="$2"
  local value

  value="$(printf '%s\n' "$json_text" | sed -n "$sed_pattern" | head -n 1)"
  [[ -n "$value" ]] || return 1
  unescape_json_slashes "$value"
}

extract_postimages_original_url() {
  local page_html="$1"
  local value

  value="$(printf '%s\n' "$page_html" | tr '\n' ' ' | sed -n 's/.*<input[^>]*id="direct"[^>]*value="\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  value="$(printf '%s\n' "$page_html" | tr '\n' ' ' | sed -n 's/.*<meta[^>]*property="og:image"[^>]*content="\([^"]*\)".*/\1/p' | head -n 1)"
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

extract_postimages_display_url() {
  local page_html="$1"
  local value

  value="$(printf '%s\n' "$page_html" | tr '\n' ' ' | sed -n 's/.*class="card-img-top object-fit-cover"[^>]*src="\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  value="$(printf '%s\n' "$page_html" | tr '\n' ' ' | sed -n 's/.*<img[^>]*src="\(https:\/\/i\.postimg\.cc\/[^"]*\)"[^>]*class="card-img-top object-fit-cover".*/\1/p' | head -n 1)"
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

build_result() {
  local image_name="$1"
  local original_url="$2"
  local display_url="$3"

  printf 'name=%s\noriginal_url=%s\ndisplay_url=%s\n' "$image_name" "$original_url" "$display_url"
}

extract_result_field() {
  local result_text="$1"
  local field_name="$2"

  printf '%s\n' "$result_text" | sed -n "s/^$field_name=//p" | head -n 1
}

print_text_result() {
  local result_text="$1"
  local image_name
  local original_url
  local display_url

  image_name="$(extract_result_field "$result_text" 'name')"
  original_url="$(extract_result_field "$result_text" 'original_url')"
  display_url="$(extract_result_field "$result_text" 'display_url')"

  printf '%s\n' "$image_name"
  printf 'original_url: %s\n' "$original_url"
  printf 'display_url: %s\n' "$display_url"
}

print_json_results() {
  local -n json_results_ref=$1
  local index
  local result_text
  local image_name
  local original_url
  local display_url

  printf '[\n'
  for index in "${!json_results_ref[@]}"; do
    result_text="${json_results_ref[$index]}"
    image_name="$(extract_result_field "$result_text" 'name')"
    original_url="$(extract_result_field "$result_text" 'original_url')"
    display_url="$(extract_result_field "$result_text" 'display_url')"

    printf '  {\n'
    printf '    "name": "%s",\n' "$(json_escape "$image_name")"
    printf '    "original_url": "%s",\n' "$(json_escape "$original_url")"
    printf '    "display_url": "%s"\n' "$(json_escape "$display_url")"
    if [[ "$index" -lt $((${#json_results_ref[@]} - 1)) ]]; then
      printf '  },\n'
    else
      printf '  }\n'
    fi
  done
  printf ']\n'
}

imgbb_auth_token=""

get_imgbb_auth_token() {
  if [[ -n "$imgbb_auth_token" ]]; then
    printf '%s\n' "$imgbb_auth_token"
    return
  fi

  local homepage_html
  homepage_html="$(curl -sS --fail "$IMGBB_AUTH_URL")" || return 1
  imgbb_auth_token="$(printf '%s\n' "$homepage_html" | sed -n 's/.*PF\.obj\.config\.auth_token="\([a-f0-9][a-f0-9]*\)".*/\1/p' | head -n 1)" || return 1
  [[ -n "$imgbb_auth_token" ]] || return 1

  printf '%s\n' "$imgbb_auth_token"
}

upload_to_imgbb() {
  local file_path="$1"
  local expire_value="$2"
  local expire_seconds_value
  local expiration_token=""
  local auth_token
  local response
  local original_url
  local display_url
  local image_name

  expire_seconds_value="$(parse_expire_to_seconds "$expire_value")"
  if ! expiration_token="$(imgbb_expiration_from_seconds "$expire_seconds_value")"; then
    warn "ImgBB does not support expire=$expire_value for website uploads"
    return 1
  fi

  auth_token="$(get_imgbb_auth_token)" || {
    warn "failed to fetch ImgBB auth token"
    return 1
  }

  debug "uploading via ImgBB: $file_path"
  if [[ -n "$expiration_token" ]]; then
    response="$(curl -sS --fail "$IMGBB_UPLOAD_URL" \
      -H 'Accept: application/json' \
      -F "source=@$file_path" \
      -F 'type=file' \
      -F 'action=upload' \
      -F "timestamp=$(date +%s%3N)" \
      -F "auth_token=$auth_token" \
      -F "expiration=$expiration_token")" || {
      warn "ImgBB upload failed for $file_path"
      return 1
    }
  else
    response="$(curl -sS --fail "$IMGBB_UPLOAD_URL" \
      -H 'Accept: application/json' \
      -F "source=@$file_path" \
      -F 'type=file' \
      -F 'action=upload' \
      -F "timestamp=$(date +%s%3N)" \
      -F "auth_token=$auth_token")" || {
      warn "ImgBB upload failed for $file_path"
      return 1
    }
  fi

  image_name="$(basename "$file_path")"
  original_url="$(extract_json_string_with_pattern "$response" 's/.*"image":{"filename":"[^"]*","name":"[^"]*","mime":"[^"]*","extension":"[^"]*","url":"\([^"]*\)".*/\1/p' 2>/dev/null || true)"
  if [[ -z "$original_url" ]]; then
    original_url="$(extract_json_string_field "$response" 'url' 2>/dev/null || true)"
  fi

  display_url="$(extract_json_string_field "$response" 'display_url' 2>/dev/null || true)"
  if [[ -z "$display_url" ]]; then
    display_url="$original_url"
  fi

  [[ -n "$original_url" ]] || {
    warn "ImgBB response did not include an original URL for $file_path"
    return 1
  }

  build_result "$image_name" "$original_url" "$display_url"
}

upload_to_postimages() {
  local file_path="$1"
  local expire_value="$2"
  local expire_seconds_value
  local response
  local detail_url
  local page_html
  local original_url
  local display_url
  local upload_session
  local image_name

  expire_seconds_value="$(parse_expire_to_seconds "$expire_value")"
  upload_session="$(date +%s%3N).${RANDOM}${RANDOM}"

  debug "uploading via Postimages: $file_path"
  response="$(curl -sS --fail "$POSTIMAGES_UPLOAD_URL" \
    -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36' \
    -H 'Accept: application/json' \
    -H 'Accept-Language: en-US,en;q=0.9' \
    -H 'Cache-Control: no-cache' \
    -H 'Pragma: no-cache' \
    -H 'Origin: https://postimages.org' \
    -H 'Referer: https://postimages.org/' \
    -H 'X-Requested-With: XMLHttpRequest' \
    -F 'gallery=' \
    -F 'optsize=0' \
    -F "expire=$expire_seconds_value" \
    -F 'numfiles=1' \
    -F "upload_session=$upload_session" \
    -F "file=@$file_path")" || {
    warn "Postimages upload failed for $file_path"
    return 1
  }

  detail_url="$(extract_json_string_field "$response" 'image' 2>/dev/null || true)"
  if [[ -z "$detail_url" ]]; then
    detail_url="$(extract_json_string_field "$response" 'url' 2>/dev/null || true)"
  fi

  [[ -n "$detail_url" ]] || {
    warn "Postimages response did not include an image page for $file_path"
    return 1
  }

  page_html="$(curl -sS --fail "$detail_url")" || {
    warn "failed to fetch Postimages image page for $file_path"
    return 1
  }

  image_name="$(basename "$file_path")"
  original_url="$(extract_postimages_original_url "$page_html" 2>/dev/null || true)"
  [[ -n "$original_url" ]] || {
    warn "failed to extract Postimages original URL for $file_path"
    return 1
  }

  display_url="$(extract_postimages_display_url "$page_html" 2>/dev/null || true)"
  if [[ -z "$display_url" ]]; then
    display_url="$original_url"
  fi

  build_result "$image_name" "$original_url" "$display_url"
}

resolve_input_files() {
  local raw_path
  local resolved_path
  local -a resolved_files=()

  [[ ${#input_files[@]} -gt 0 ]] || die "at least one FILE is required"

  for raw_path in "${input_files[@]}"; do
    resolved_path="$(resolve_from_cwd "$raw_path")"
    [[ -f "$resolved_path" ]] || die "file not found: $raw_path"
    resolved_files+=("$resolved_path")
  done

  input_files=("${resolved_files[@]}")
}

candidate_sites_for_file() {
  if [[ -n "$selected_site" ]]; then
    printf '%s\n' "$selected_site"
    return
  fi

  printf '%s\n' "imgbb"
  printf '%s\n' "postimages"
}

upload_one_file() {
  local file_path="$1"
  local site_name
  local upload_result=""

  while IFS= read -r site_name; do
    [[ -n "$site_name" ]] || continue

    case "$site_name" in
      imgbb)
        upload_result="$(upload_to_imgbb "$file_path" "$expire_value" || true)"
        ;;
      postimages)
        upload_result="$(upload_to_postimages "$file_path" "$expire_value" || true)"
        ;;
      *)
        die "internal error: unsupported site $site_name"
        ;;
    esac

    if [[ -n "$upload_result" ]]; then
      debug "uploaded $file_path via $site_name"
      printf '%s\n' "$upload_result"
      return 0
    fi
  done < <(candidate_sites_for_file)

  return 1
}

main() {
  local file_path
  local upload_result
  local -a results=()

  parse_args "$@"
  validate_site "$selected_site"
  resolve_input_files

  require_cmd curl
  for file_path in "${input_files[@]}"; do
    upload_result="$(upload_one_file "$file_path")" || die "all upload backends failed for $file_path"
    results+=("$upload_result")
  done

  if [[ "$raw_response" -eq 1 ]]; then
    print_json_results results
    return
  fi

  for file_path in "${!results[@]}"; do
    print_text_result "${results[$file_path]}"
    if [[ "$file_path" -lt $((${#results[@]} - 1)) ]]; then
      printf '\n'
    fi
  done
}

main "$@"
