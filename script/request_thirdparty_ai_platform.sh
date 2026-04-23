#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# shellcheck source=script/_lib/common.sh
source "$SCRIPT_DIR/_lib/common.sh"

SCRIPT_VERBOSE=0
FORMAT=""
FORMAT_EXPLICIT=0
MODEL=""
PROMPT=""
BASE_URL=""
API_KEY=""
MAX_TOKENS=""
TEMPERATURE=""
DECLARE_RESPONSE_PATH=""
RAW_RESPONSE=0
DRY_RUN=0
LIST_MODELS=0
SUBCOMMAND=""
IMAGE_PATHS=()
TEMP_FILES=()

usage() {
  cat <<EOF
Usage:
  script/${SCRIPT_NAME} message PROMPT --model MODEL [options]
  script/${SCRIPT_NAME} models [options]
  script/${SCRIPT_NAME} --format openai|claude (--model MODEL [options] | --list-models [options])

Purpose:
  Send a prompt to a third-party AI API using the official OpenAI or Claude request format,
  or query the upstream /v1/models endpoint for available models.

Required inputs:
  message          send one prompt request
  models           fetch available models from the upstream /v1/models endpoint
  --format         request format: openai or claude; when omitted, infer from env
  --model          model name passed to the upstream API; required for message

Operation:
  --list-models    legacy alias for models

Prompt inputs:
  PROMPT               first positional argument after message
                      required with message

Optional inputs:
  --image PATH         attach an image; may be provided multiple times
  --base-url URL       upstream base URL only; path is appended automatically
  --api-key KEY        API key; defaults to environment variables
  --max-tokens N       max output tokens
  --temperature N      sampling temperature
  --raw-response       output raw JSON response instead of AI text
  --output PATH        write the selected output content to file instead of stdout
  --dry-run            print request metadata and JSON payload, do not send
  --verbose            print debug logs
  --help               show this message

Environment variable lookup order:
  Format:  THIRDPARTY_AI_PLATFORM_FORMAT -> OPENAI_BASE_URL -> ANTHROPIC_BASE_URL/CLAUDE_BASE_URL
  Generic: THIRDPARTY_AI_PLATFORM_API_KEY, THIRDPARTY_AI_PLATFORM_BASE_URL
  OpenAI:  OPENAI_API_KEY, OPENAI_BASE_URL
  Claude:  ANTHROPIC_API_KEY, CLAUDE_API_KEY, ANTHROPIC_BASE_URL, CLAUDE_BASE_URL

Format inference when --format is omitted:
  1. THIRDPARTY_AI_PLATFORM_FORMAT
  2. OPENAI_BASE_URL -> openai
  3. ANTHROPIC_BASE_URL or CLAUDE_BASE_URL -> claude
  4. If only THIRDPARTY_AI_PLATFORM_BASE_URL is set, provide --format or THIRDPARTY_AI_PLATFORM_FORMAT

Default endpoints appended to --base-url:
  openai -> /v1/chat/completions, or /v1/models with models
  claude -> /v1/messages, or /v1/models with models

Notes:
  - Images are embedded as base64 in the official provider-specific payload shape.
  - If you store values in env.ini, load them first with: source script/load_env.sh
  - Side effect: sends an HTTP request unless --dry-run is used.
  - Normal output prints AI text, or newline-separated model IDs with models, unless --raw-response is used.
EOF
}

trim_trailing_slashes() {
  local value="$1"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

infer_mime_type() {
  local image_path="$1"
  local extension="${image_path##*.}"

  if command -v file >/dev/null 2>&1; then
    file --mime-type -b "$image_path"
    return
  fi

  case "${extension,,}" in
    jpg|jpeg)
      printf 'image/jpeg\n'
      ;;
    png)
      printf 'image/png\n'
      ;;
    gif)
      printf 'image/gif\n'
      ;;
    webp)
      printf 'image/webp\n'
      ;;
    *)
      die "unable to infer mime type for image: $image_path"
      ;;
  esac
}

encode_base64() {
  local file_path="$1"

  if base64 --help 2>/dev/null | grep -q -- '--wrap'; then
    base64 --wrap=0 "$file_path"
  else
    base64 "$file_path" | tr -d '\n'
  fi
}

make_temp_file() {
  local temp_file

  temp_file="$(mktemp "${TMPDIR:-/tmp}/${SCRIPT_NAME}.XXXXXX")"
  TEMP_FILES+=("$temp_file")
  printf '%s\n' "$temp_file"
}

cleanup_temp_files() {
  local temp_file

  for temp_file in "${TEMP_FILES[@]}"; do
    [[ -n "$temp_file" && -e "$temp_file" ]] && rm -f -- "$temp_file"
  done
}

read_prompt() {
  [[ -n "$PROMPT" ]] || die "missing prompt: use message \"...\""
  printf '%s' "$PROMPT"
}

resolve_api_key() {
  if [[ -n "$API_KEY" ]]; then
    printf '%s\n' "$API_KEY"
    return
  fi

  case "$FORMAT" in
    openai)
      printf '%s\n' "${THIRDPARTY_AI_PLATFORM_API_KEY:-${OPENAI_API_KEY:-}}"
      ;;
    claude)
      printf '%s\n' "${THIRDPARTY_AI_PLATFORM_API_KEY:-${ANTHROPIC_API_KEY:-${CLAUDE_API_KEY:-}}}"
      ;;
    *)
      die "unsupported format: $FORMAT"
      ;;
  esac
}

infer_format() {
  if [[ "$FORMAT_EXPLICIT" == "1" ]]; then
    printf '%s\n' "$FORMAT"
    return
  fi

  if [[ -n "${THIRDPARTY_AI_PLATFORM_FORMAT:-}" ]]; then
    printf '%s\n' "$THIRDPARTY_AI_PLATFORM_FORMAT"
    return
  fi

  if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
    printf 'openai\n'
    return
  fi

  if [[ -n "${ANTHROPIC_BASE_URL:-}" || -n "${CLAUDE_BASE_URL:-}" ]]; then
    printf 'claude\n'
    return
  fi

  if [[ -n "${THIRDPARTY_AI_PLATFORM_BASE_URL:-}" ]]; then
    die "missing format: use --format or set THIRDPARTY_AI_PLATFORM_FORMAT"
  fi

  die "missing required argument: --format"
}

resolve_base_url() {
  if [[ -n "$BASE_URL" ]]; then
    printf '%s\n' "$(trim_trailing_slashes "$BASE_URL")"
    return
  fi

  case "$FORMAT" in
    openai)
      printf '%s\n' "$(trim_trailing_slashes "${THIRDPARTY_AI_PLATFORM_BASE_URL:-${OPENAI_BASE_URL:-https://api.openai.com}}")"
      ;;
    claude)
      printf '%s\n' "$(trim_trailing_slashes "${THIRDPARTY_AI_PLATFORM_BASE_URL:-${ANTHROPIC_BASE_URL:-${CLAUDE_BASE_URL:-https://api.anthropic.com}}}")"
      ;;
    *)
      die "unsupported format: $FORMAT"
      ;;
  esac
}

build_openai_content() {
  local prompt_text="$1"
  local image_path
  local mime_type
  local content_file
  local next_content_file
  local encoded_image_file

  content_file="$(make_temp_file)"
  jq -n --arg text "$prompt_text" '[{type:"text", text:$text}]' >"$content_file"

  for image_path in "${IMAGE_PATHS[@]}"; do
    [[ -f "$image_path" ]] || die "image file not found: $image_path"
    mime_type="$(infer_mime_type "$image_path")"
    encoded_image_file="$(make_temp_file)"
    encode_base64 "$image_path" >"$encoded_image_file"
    next_content_file="$(make_temp_file)"
    jq -n \
      --rawfile content_raw "$content_file" \
      --arg mime_type "$mime_type" \
      --rawfile encoded_image "$encoded_image_file" \
      '($content_raw | fromjson) + [{type:"image_url", image_url:{url:("data:" + $mime_type + ";base64," + $encoded_image)}}]' >"$next_content_file"
    content_file="$next_content_file"
  done

  printf '%s\n' "$content_file"
}

build_claude_content() {
  local prompt_text="$1"
  local image_path
  local mime_type
  local content_file
  local next_content_file
  local encoded_image_file

  content_file="$(make_temp_file)"
  jq -n --arg text "$prompt_text" '[{type:"text", text:$text}]' >"$content_file"

  for image_path in "${IMAGE_PATHS[@]}"; do
    [[ -f "$image_path" ]] || die "image file not found: $image_path"
    mime_type="$(infer_mime_type "$image_path")"
    encoded_image_file="$(make_temp_file)"
    encode_base64 "$image_path" >"$encoded_image_file"
    next_content_file="$(make_temp_file)"
    jq -n \
      --rawfile content_raw "$content_file" \
      --arg mime_type "$mime_type" \
      --rawfile encoded_image "$encoded_image_file" \
      '($content_raw | fromjson) + [{type:"image", source:{type:"base64", media_type:$mime_type, data:$encoded_image}}]' >"$next_content_file"
    content_file="$next_content_file"
  done

  printf '%s\n' "$content_file"
}

build_payload() {
  local prompt_text="$1"
  local content_file
  local payload_file
  local next_payload_file

  case "$FORMAT" in
    openai)
      content_file="$(build_openai_content "$prompt_text")"
      payload_file="$(make_temp_file)"
      jq -n \
        --arg model "$MODEL" \
        --rawfile content_raw "$content_file" \
        '{model:$model, messages:[{role:"user", content:($content_raw | fromjson)}]}' >"$payload_file"
      ;;
    claude)
      content_file="$(build_claude_content "$prompt_text")"
      payload_file="$(make_temp_file)"
      jq -n \
        --arg model "$MODEL" \
        --rawfile content_raw "$content_file" \
        '{model:$model, messages:[{role:"user", content:($content_raw | fromjson)}]}' >"$payload_file"
      ;;
    *)
      die "unsupported format: $FORMAT"
      ;;
  esac

  if [[ -n "$MAX_TOKENS" ]]; then
    next_payload_file="$(make_temp_file)"
    jq -n --rawfile payload_raw "$payload_file" --argjson max_tokens "$MAX_TOKENS" '($payload_raw | fromjson) + {max_tokens:$max_tokens}' >"$next_payload_file"
    payload_file="$next_payload_file"
  elif [[ "$FORMAT" == "claude" ]]; then
    next_payload_file="$(make_temp_file)"
    jq -n --rawfile payload_raw "$payload_file" '($payload_raw | fromjson) + {max_tokens:1024}' >"$next_payload_file"
    payload_file="$next_payload_file"
  fi

  if [[ -n "$TEMPERATURE" ]]; then
    next_payload_file="$(make_temp_file)"
    jq -n --rawfile payload_raw "$payload_file" --argjson temperature "$TEMPERATURE" '($payload_raw | fromjson) + {temperature:$temperature}' >"$next_payload_file"
    payload_file="$next_payload_file"
  fi

  printf '%s\n' "$payload_file"
}

build_endpoint() {
  local resolved_base_url="$1"

  if [[ "$LIST_MODELS" == "1" ]]; then
    printf '%s/v1/models\n' "$resolved_base_url"
    return
  fi

  case "$FORMAT" in
    openai)
      printf '%s/v1/chat/completions\n' "$resolved_base_url"
      ;;
    claude)
      printf '%s/v1/messages\n' "$resolved_base_url"
      ;;
    *)
      die "unsupported format: $FORMAT"
      ;;
  esac
}

write_output() {
  local output_value="$1"

  if [[ -n "$DECLARE_RESPONSE_PATH" ]]; then
    ensure_parent_dir "$DECLARE_RESPONSE_PATH"
    printf '%s' "$output_value" >"$DECLARE_RESPONSE_PATH"
    info "response written to $DECLARE_RESPONSE_PATH"
    return
  fi

  printf '%s\n' "$output_value"
}

extract_response_text() {
  local response_body="$1"

  case "$FORMAT" in
    openai)
      jq -er 'if (.choices[0].message.content | type) == "string" then .choices[0].message.content else .choices[0].message.content[]? | select(.type == "text") | .text end' <<<"$response_body"
      ;;
    claude)
      jq -er '[.content[]? | select(.type == "text") | .text] | join("\n")' <<<"$response_body"
      ;;
    *)
      die "unsupported format: $FORMAT"
      ;;
  esac
}

extract_models_list() {
  local response_body="$1"

  jq -er '
    if type == "array" then
      [.[]? | .id // .name]
    elif type == "object" and (has("data")) and (.data | type) == "array" then
      [.data[]? | .id // .name]
    else
      []
    end
    | if length == 0 then error("no models found in response") else .[] end
  ' <<<"$response_body"
}

send_request() {
  local endpoint="$1"
  local resolved_api_key="$2"
  local payload_file="$3"
  local -a curl_args=()
  local request_method="POST"
  local response_body
  local response_text
  local output_value

  case "$FORMAT" in
    openai)
      mapfile -t curl_args < <(printf '%s\n' \
        -H "Authorization: Bearer $resolved_api_key" \
        -H "Content-Type: application/json")
      ;;
    claude)
      mapfile -t curl_args < <(printf '%s\n' \
        -H "x-api-key: $resolved_api_key" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json")
      ;;
    *)
      die "unsupported format: $FORMAT"
      ;;
  esac

  if [[ "$LIST_MODELS" == "1" ]]; then
    request_method="GET"
  fi

  debug "sending request to $endpoint"
  if [[ "$LIST_MODELS" == "1" ]]; then
    response_body="$(curl --silent --show-error --fail-with-body -X "$request_method" "$endpoint" "${curl_args[@]}")"
  else
    response_body="$(curl --silent --show-error --fail-with-body -X "$request_method" "$endpoint" "${curl_args[@]}" --data-binary "@$payload_file")"
  fi

  if [[ "$RAW_RESPONSE" == "1" ]]; then
    output_value="$response_body"
  elif [[ "$LIST_MODELS" == "1" ]]; then
    response_text="$(extract_models_list "$response_body")"
    output_value="$response_text"
  else
    response_text="$(extract_response_text "$response_body")"
    output_value="$response_text"
  fi

  write_output "$output_value"
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      message)
        SUBCOMMAND="message"
        shift
        ;;
      models)
        SUBCOMMAND="models"
        LIST_MODELS=1
        shift
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)
        [[ $# -ge 2 ]] || die "--format requires a value"
        FORMAT="$2"
        FORMAT_EXPLICIT=1
        shift 2
        ;;
      --model)
        [[ $# -ge 2 ]] || die "--model requires a value"
        MODEL="$2"
        shift 2
        ;;
      --image)
        [[ $# -ge 2 ]] || die "--image requires a value"
        IMAGE_PATHS+=("$(resolve_from_cwd "$2")")
        shift 2
        ;;
      --base-url)
        [[ $# -ge 2 ]] || die "--base-url requires a value"
        BASE_URL="$2"
        shift 2
        ;;
      --api-key)
        [[ $# -ge 2 ]] || die "--api-key requires a value"
        API_KEY="$2"
        shift 2
        ;;
      --max-tokens)
        [[ $# -ge 2 ]] || die "--max-tokens requires a value"
        MAX_TOKENS="$2"
        shift 2
        ;;
      --temperature)
        [[ $# -ge 2 ]] || die "--temperature requires a value"
        TEMPERATURE="$2"
        shift 2
        ;;
      --raw-response)
        RAW_RESPONSE=1
        shift
        ;;
      --list-models)
        LIST_MODELS=1
        shift
        ;;
      --output)
        [[ $# -ge 2 ]] || die "--output requires a value"
        DECLARE_RESPONSE_PATH="$(resolve_from_cwd "$2")"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
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
      *)
        if [[ "$SUBCOMMAND" == "message" && -z "$PROMPT" ]]; then
          PROMPT="$1"
          shift
          continue
        fi
        die "unknown argument: $1"
        ;;
    esac
  done

  FORMAT="$(infer_format)"
  [[ "$FORMAT" == "openai" || "$FORMAT" == "claude" ]] || die "--format must be openai or claude"

  if [[ -z "$SUBCOMMAND" ]]; then
    if [[ "$LIST_MODELS" == "1" ]]; then
      SUBCOMMAND="models"
    else
      SUBCOMMAND="message"
    fi
  fi

  if [[ "$SUBCOMMAND" == "message" && "$LIST_MODELS" == "1" ]]; then
    die "message cannot be used with --list-models"
  fi

  if [[ "$LIST_MODELS" == "1" ]]; then
    [[ -z "$MODEL" ]] || die "--model cannot be used with --list-models"
    [[ -z "$PROMPT" ]] || die "PROMPT cannot be used with --list-models"
    [[ ${#IMAGE_PATHS[@]} -eq 0 ]] || die "--image cannot be used with --list-models"
    [[ -z "$MAX_TOKENS" ]] || die "--max-tokens cannot be used with --list-models"
    [[ -z "$TEMPERATURE" ]] || die "--temperature cannot be used with --list-models"
    return
  fi

  [[ -n "$MODEL" ]] || die "missing required argument: --model"

  if [[ -n "$MAX_TOKENS" && ! "$MAX_TOKENS" =~ ^[0-9]+$ ]]; then
    die "--max-tokens must be an integer"
  fi

  if [[ -n "$TEMPERATURE" && ! "$TEMPERATURE" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    die "--temperature must be numeric"
  fi

}

main() {
  local prompt_text=""
  local resolved_api_key=""
  local resolved_base_url
  local endpoint
  local payload_file=""

  trap cleanup_temp_files EXIT

  parse_args "$@"

  require_cmd curl
  require_cmd jq
  if [[ "$LIST_MODELS" != "1" && ${#IMAGE_PATHS[@]} -gt 0 ]]; then
    require_cmd base64
  fi

  resolved_base_url="$(resolve_base_url)"
  endpoint="$(build_endpoint "$resolved_base_url")"

  if [[ "$LIST_MODELS" != "1" ]]; then
    prompt_text="$(read_prompt)"
    payload_file="$(build_payload "$prompt_text")"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'format=%s\n' "$FORMAT"
    printf 'mode=%s\n' "$SUBCOMMAND"
    printf 'endpoint=%s\n' "$endpoint"
    if [[ "$LIST_MODELS" != "1" ]]; then
      jq . "$payload_file"
    fi
    return 0
  fi

  resolved_api_key="$(resolve_api_key)"
  [[ -n "$resolved_api_key" ]] || die "missing API key: use --api-key or set environment variables"
  send_request "$endpoint" "$resolved_api_key" "$payload_file"
}

main "$@"
