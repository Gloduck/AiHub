#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# shellcheck source=script/_lib/common.sh
source "$SCRIPT_DIR/_lib/common.sh"

SCRIPT_VERBOSE=0
FORMAT=""
MODEL=""
PROMPT=""
PROMPT_FILE=""
BASE_URL=""
API_KEY=""
MAX_TOKENS=""
TEMPERATURE=""
DECLARE_RESPONSE_PATH=""
RAW_RESPONSE=0
DRY_RUN=0
IMAGE_PATHS=()

usage() {
  cat <<EOF
Usage: script/${SCRIPT_NAME} --format openai|claude --model MODEL [options]

Purpose:
  Send a prompt to a third-party AI API using the official OpenAI or Claude request format.

Required inputs:
  --format         request format: openai or claude
  --model          model name passed to the upstream API

Prompt inputs:
  --prompt TEXT        prompt text
  --prompt-file PATH   read prompt text from file
  stdin                when --prompt and --prompt-file are both omitted, read prompt from stdin

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
  Generic: THIRDPARTY_AI_PLATFORM_API_KEY, THIRDPARTY_AI_PLATFORM_BASE_URL
  OpenAI:  OPENAI_API_KEY, OPENAI_BASE_URL
  Claude:  ANTHROPIC_API_KEY, CLAUDE_API_KEY, ANTHROPIC_BASE_URL, CLAUDE_BASE_URL

Default endpoints appended to --base-url:
  openai -> /v1/chat/completions
  claude -> /v1/messages

Notes:
  - Images are embedded as base64 in the official provider-specific payload shape.
  - If you store values in env.ini, load them first with: source script/load_env.sh
  - Side effect: sends an HTTP request unless --dry-run is used.
  - Normal output only prints the AI text response unless --raw-response is used.
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

read_prompt() {
  if [[ -n "$PROMPT" ]]; then
    printf '%s' "$PROMPT"
    return
  fi

  if [[ -n "$PROMPT_FILE" ]]; then
    [[ -f "$PROMPT_FILE" ]] || die "prompt file not found: $PROMPT_FILE"
    <"$PROMPT_FILE" tr -d '\r'
    return
  fi

  if [[ -t 0 ]]; then
    die "missing prompt: use --prompt, --prompt-file, or pipe stdin"
  fi

  tr -d '\r'
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
  local encoded_image
  local content_json

  content_json="$(jq -n --arg text "$prompt_text" '[{type:"text", text:$text}]')"

  for image_path in "${IMAGE_PATHS[@]}"; do
    [[ -f "$image_path" ]] || die "image file not found: $image_path"
    mime_type="$(infer_mime_type "$image_path")"
    encoded_image="$(encode_base64 "$image_path")"
    content_json="$(jq -n \
      --argjson content "$content_json" \
      --arg mime_type "$mime_type" \
      --arg encoded_image "$encoded_image" \
      '$content + [{type:"image_url", image_url:{url:("data:" + $mime_type + ";base64," + $encoded_image)}}]')"
  done

  printf '%s\n' "$content_json"
}

build_claude_content() {
  local prompt_text="$1"
  local image_path
  local mime_type
  local encoded_image
  local content_json

  content_json="$(jq -n --arg text "$prompt_text" '[{type:"text", text:$text}]')"

  for image_path in "${IMAGE_PATHS[@]}"; do
    [[ -f "$image_path" ]] || die "image file not found: $image_path"
    mime_type="$(infer_mime_type "$image_path")"
    encoded_image="$(encode_base64 "$image_path")"
    content_json="$(jq -n \
      --argjson content "$content_json" \
      --arg mime_type "$mime_type" \
      --arg encoded_image "$encoded_image" \
      '$content + [{type:"image", source:{type:"base64", media_type:$mime_type, data:$encoded_image}}]')"
  done

  printf '%s\n' "$content_json"
}

build_payload() {
  local prompt_text="$1"
  local content_json
  local payload

  case "$FORMAT" in
    openai)
      content_json="$(build_openai_content "$prompt_text")"
      payload="$(jq -n \
        --arg model "$MODEL" \
        --argjson content "$content_json" \
        '{model:$model, messages:[{role:"user", content:$content}]}')"
      ;;
    claude)
      content_json="$(build_claude_content "$prompt_text")"
      payload="$(jq -n \
        --arg model "$MODEL" \
        --argjson content "$content_json" \
        '{model:$model, messages:[{role:"user", content:$content}]}')"
      ;;
    *)
      die "unsupported format: $FORMAT"
      ;;
  esac

  if [[ -n "$MAX_TOKENS" ]]; then
    payload="$(jq -n --argjson payload "$payload" --argjson max_tokens "$MAX_TOKENS" '$payload + {max_tokens:$max_tokens}')"
  elif [[ "$FORMAT" == "claude" ]]; then
    payload="$(jq -n --argjson payload "$payload" '$payload + {max_tokens:1024}')"
  fi

  if [[ -n "$TEMPERATURE" ]]; then
    payload="$(jq -n --argjson payload "$payload" --argjson temperature "$TEMPERATURE" '$payload + {temperature:$temperature}')"
  fi

  printf '%s\n' "$payload"
}

build_endpoint() {
  local resolved_base_url="$1"

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

send_request() {
  local endpoint="$1"
  local resolved_api_key="$2"
  local payload="$3"
  local -a curl_args=()
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

  debug "sending request to $endpoint"
  response_body="$(curl --silent --show-error --fail-with-body -X POST "$endpoint" "${curl_args[@]}" --data "$payload")"

  if [[ "$RAW_RESPONSE" == "1" ]]; then
    output_value="$response_body"
  else
    response_text="$(extract_response_text "$response_body")"
    output_value="$response_text"
  fi

  write_output "$output_value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)
        [[ $# -ge 2 ]] || die "--format requires a value"
        FORMAT="$2"
        shift 2
        ;;
      --model)
        [[ $# -ge 2 ]] || die "--model requires a value"
        MODEL="$2"
        shift 2
        ;;
      --prompt)
        [[ $# -ge 2 ]] || die "--prompt requires a value"
        PROMPT="$2"
        shift 2
        ;;
      --prompt-file)
        [[ $# -ge 2 ]] || die "--prompt-file requires a value"
        PROMPT_FILE="$(resolve_from_cwd "$2")"
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
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$FORMAT" ]] || die "missing required argument: --format"
  [[ "$FORMAT" == "openai" || "$FORMAT" == "claude" ]] || die "--format must be openai or claude"
  [[ -n "$MODEL" ]] || die "missing required argument: --model"

  if [[ -n "$PROMPT" && -n "$PROMPT_FILE" ]]; then
    die "--prompt and --prompt-file cannot be used together"
  fi

  if [[ -n "$MAX_TOKENS" && ! "$MAX_TOKENS" =~ ^[0-9]+$ ]]; then
    die "--max-tokens must be an integer"
  fi

  if [[ -n "$TEMPERATURE" && ! "$TEMPERATURE" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    die "--temperature must be numeric"
  fi

}

main() {
  local prompt_text
  local resolved_api_key=""
  local resolved_base_url
  local endpoint
  local payload

  require_cmd curl
  require_cmd jq
  require_cmd base64

  parse_args "$@"

  prompt_text="$(read_prompt)"
  resolved_base_url="$(resolve_base_url)"
  endpoint="$(build_endpoint "$resolved_base_url")"
  payload="$(build_payload "$prompt_text")"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'format=%s\n' "$FORMAT"
    printf 'endpoint=%s\n' "$endpoint"
    jq . <<<"$payload"
    return 0
  fi

  resolved_api_key="$(resolve_api_key)"
  [[ -n "$resolved_api_key" ]] || die "missing API key: use --api-key or set environment variables"
  send_request "$endpoint" "$resolved_api_key" "$payload"
}

main "$@"
