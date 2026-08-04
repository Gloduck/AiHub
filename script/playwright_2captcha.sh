#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_DIR="$(cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

type_name=""
session="default"
api_key=""
env_file="$REPO_DIR/env.ini"
timeout_seconds=180
poll_interval=5

usage() {
  cat <<'EOF'
Usage: playwright_2captcha.sh --type TYPE [--session NAME] [--api-key KEY]

Required inputs:
  --type TYPE             turnstile | recaptcha-v2 | recaptcha-v2-invisible |
                          recaptcha-v2-enterprise | recaptcha-v3 |
                          recaptcha-v3-enterprise | hcaptcha

Optional inputs:
  --session NAME          existing playwright-cli session name, defaults to default
  --api-key KEY           2captcha API key
  --help                  show this message

API key lookup order:
  1. --api-key
  2. TWOCAPTCHA_API_KEY environment variable
  3. TWOCAPTCHA_API_KEY or 2CAPTCHA_API_KEY in repository-root/env.ini

Default behavior:
  The script connects to an existing playwright-cli named browser session using
  playwright-cli -s=NAME. It reads captcha parameters from the session's current
  page, submits a task to 2captcha, polls for the solution, writes the token to
  the matching response fields and invokes data-callback when one is available.
  Page submission remains controlled by the caller.

Interactive mode:
  Not supported.

Dependencies:
  bash, curl, python3 and playwright-cli. The named playwright-cli session must
  already be open.

Side effects:
  Spends 2captcha balance and changes the DOM of the selected browser page.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

read_env_value() {
  local file_path="$1"
  local wanted_key="$2"
  local line
  local key

  [[ -f "$file_path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"
    if [[ "$key" == "$wanted_key" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"$file_path"
  return 1
}

json_field() {
  local field="$1"
  python3 -c '
import json
import sys

try:
    value = json.load(sys.stdin).get(sys.argv[1], "")
except (json.JSONDecodeError, AttributeError) as exc:
    print(f"invalid JSON response: {exc}", file=sys.stderr)
    raise SystemExit(2)

if isinstance(value, bool):
    print("1" if value else "0")
elif value is None:
    print("")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
' "$field"
}

decode_playwright_value() {
  python3 -c '
import json
import sys

raw = sys.stdin.read().strip()
try:
    value = json.loads(raw)
except json.JSONDecodeError:
    print(raw)
else:
    if value is None:
        print("")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value, separators=(",", ":")))
    else:
        print(value)
'
}

json_quote() {
  python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

playwright_value() {
  local expression="$1"
  local output
  if ! output="$(playwright-cli -s="$session" --raw eval "$expression")"; then
    die "unable to evaluate the playwright-cli session: $session"
  fi
  printf '%s' "$output" | decode_playwright_value
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)
        [[ $# -ge 2 && -n "$2" ]] || die "--type requires a value"
        type_name="$2"
        shift 2
        ;;
      --session)
        [[ $# -ge 2 && -n "$2" ]] || die "--session requires a value"
        session="$2"
        shift 2
        ;;
      --api-key)
        [[ $# -ge 2 && -n "$2" ]] || die "--api-key requires a value"
        api_key="$2"
        shift 2
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
}

load_api_key() {
  local loaded=""

  if [[ -n "$api_key" ]]; then
    return
  fi
  if [[ -n "${TWOCAPTCHA_API_KEY:-}" ]]; then
    api_key="$TWOCAPTCHA_API_KEY"
    return
  fi
  if loaded="$(read_env_value "$env_file" TWOCAPTCHA_API_KEY)" && [[ -n "$loaded" ]]; then
    api_key="$loaded"
    return
  fi
  if loaded="$(read_env_value "$env_file" 2CAPTCHA_API_KEY)" && [[ -n "$loaded" ]]; then
    api_key="$loaded"
    return
  fi
  die "2captcha API key not found; use --api-key, TWOCAPTCHA_API_KEY, or $env_file"
}

solved_token=""

submit_and_poll() {
  local submit_response
  local submit_status
  local task_id
  local result_response
  local result_status
  local result_request
  local deadline
  local curl_args
  local parameter

  curl_args=(
    --silent --show-error --fail
    --request POST https://2captcha.com/in.php
    --data-urlencode "key=$api_key"
    --data-urlencode "json=1"
  )
  for parameter in "$@"; do
    curl_args+=(--data-urlencode "$parameter")
  done

  submit_response="$(curl "${curl_args[@]}")" || die "failed to submit the 2captcha task"
  submit_status="$(printf '%s' "$submit_response" | json_field status)" || die "invalid 2captcha submit response"
  task_id="$(printf '%s' "$submit_response" | json_field request)" || die "invalid 2captcha submit response"
  [[ "$submit_status" == "1" ]] || die "2captcha submit failed: $task_id"
  printf 'task_id: %s\n' "$task_id"

  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    sleep "$poll_interval"
    result_response="$(curl --silent --show-error --fail --get https://2captcha.com/res.php \
      --data-urlencode "key=$api_key" \
      --data-urlencode "action=get" \
      --data-urlencode "id=$task_id" \
      --data-urlencode "json=1")" || die "failed to poll the 2captcha task"
    result_status="$(printf '%s' "$result_response" | json_field status)" || die "invalid 2captcha result response"
    result_request="$(printf '%s' "$result_response" | json_field request)" || die "invalid 2captcha result response"

    if [[ "$result_status" == "1" ]]; then
      solved_token="$result_request"
      break
    fi
    [[ "$result_request" == "CAPCHA_NOT_READY" ]] || die "2captcha solve failed: $result_request"
  done
  [[ -n "$solved_token" ]] || die "2captcha solve timed out after ${timeout_seconds}s"
  printf 'token_length: %s\n' "${#solved_token}"
}

apply_solution() {
  local field_names="$1"
  local widget_selector="$2"
  local fallback_callback="${3:-}"
  local token_json
  local fields_json
  local selector_json
  local fallback_json
  local apply_code
  local apply_result

  token_json="$(printf '%s' "$solved_token" | json_quote)"
  fields_json="$(printf '%s' "$field_names" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read().split(",")))')"
  selector_json="$(printf '%s' "$widget_selector" | json_quote)"
  fallback_json="$(printf '%s' "$fallback_callback" | json_quote)"
  apply_code="async page => {
    const token = $token_json;
    const names = $fields_json;
    const widgetSelector = $selector_json;
    const fallbackCallback = $fallback_json;
    const result = await page.evaluate(({ token, names, widgetSelector, fallbackCallback }) => {
      const fields = [];
      for (const name of names) {
        for (const field of document.getElementsByName(name)) {
          const prototype = field instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype
            : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
          if (setter) setter.call(field, token);
          else field.value = token;
          field.dispatchEvent(new Event('input', { bubbles: true }));
          field.dispatchEvent(new Event('change', { bubbles: true }));
          fields.push(name);
        }
      }

      let callback = 'not-found';
      const widget = document.querySelector(widgetSelector);
      const callbackName = widget?.getAttribute('data-callback') || '';
      let callbackFn = callbackName
        ? callbackName.split('.').reduce((value, part) => value?.[part], window)
        : null;
      if (typeof callbackFn !== 'function' && fallbackCallback) {
        callbackFn = fallbackCallback.split('.').reduce((value, part) => value?.[part], window);
      }
      if (typeof callbackFn === 'function') {
        callbackFn(token);
        callback = callbackName || fallbackCallback;
      }
      return { fields, callback };
    }, { token, names, widgetSelector, fallbackCallback });

    return result;
  }"

  apply_result="$(playwright-cli -s="$session" --raw run-code "$apply_code")" || die "failed to apply the captcha token to session: $session"
  printf 'apply_result: %s\n' "$apply_result"
}

current_page_parameters() {
  pageurl="$(playwright_value 'location.href')"
  user_agent="$(playwright_value 'navigator.userAgent')"
  [[ -n "$pageurl" ]] || die "unable to detect the current page URL"
}

solve_turnstile() {
  local pageurl
  local user_agent
  local sitekey

  current_page_parameters
  sitekey="$(playwright_value "document.querySelector('.cf-turnstile[data-sitekey], [data-sitekey]')?.getAttribute('data-sitekey') || ''")"
  [[ -n "$sitekey" ]] || die "unable to detect the Turnstile sitekey"
  submit_and_poll "method=turnstile" "sitekey=$sitekey" "pageurl=$pageurl" "userAgent=$user_agent"
  apply_solution "cf-turnstile-response,g-recaptcha-response" ".cf-turnstile[data-callback], [data-sitekey][data-callback]" "tsCallback"
}

recaptcha_sitekey() {
  playwright_value "(() => {
    const widget = document.querySelector('.g-recaptcha[data-sitekey], [data-sitekey]');
    if (widget?.getAttribute('data-sitekey')) return widget.getAttribute('data-sitekey');
    for (const script of document.scripts) {
      if (!script.src.includes('/recaptcha/')) continue;
      try {
        const render = new URL(script.src).searchParams.get('render');
        if (render && render !== 'explicit') return render;
      } catch {}
    }
    return '';
  })()"
}

solve_recaptcha() {
  local version="$1"
  local invisible="$2"
  local enterprise="$3"
  local pageurl
  local user_agent
  local sitekey
  local action
  local parameters

  current_page_parameters
  sitekey="$(recaptcha_sitekey)"
  [[ -n "$sitekey" ]] || die "unable to detect the reCAPTCHA sitekey"
  parameters=("method=userrecaptcha" "googlekey=$sitekey" "pageurl=$pageurl" "userAgent=$user_agent")
  [[ "$invisible" == "1" ]] && parameters+=("invisible=1")
  [[ "$enterprise" == "1" ]] && parameters+=("enterprise=1")
  if [[ "$version" == "v3" ]]; then
    action="$(playwright_value "document.querySelector('.g-recaptcha[data-action], [data-sitekey][data-action]')?.getAttribute('data-action') || 'verify'")"
    parameters+=("version=v3" "action=$action" "min_score=0.3")
  fi
  submit_and_poll "${parameters[@]}"
  apply_solution "g-recaptcha-response,g-recaptcha-response-100000" ".g-recaptcha[data-callback], [data-sitekey][data-callback]"
}

solve_hcaptcha() {
  local pageurl
  local user_agent
  local sitekey

  current_page_parameters
  sitekey="$(playwright_value "document.querySelector('.h-captcha[data-sitekey], [data-sitekey]')?.getAttribute('data-sitekey') || ''")"
  [[ -n "$sitekey" ]] || die "unable to detect the hCaptcha sitekey"
  submit_and_poll "method=hcaptcha" "sitekey=$sitekey" "pageurl=$pageurl" "userAgent=$user_agent"
  apply_solution "h-captcha-response,g-recaptcha-response" ".h-captcha[data-callback], [data-sitekey][data-callback]"
}

main() {
  parse_args "$@"
  [[ -n "$type_name" ]] || die "--type is required"
  require_cmd curl
  require_cmd python3
  require_cmd playwright-cli
  load_api_key

  case "$type_name" in
    turnstile) solve_turnstile ;;
    recaptcha-v2|recaptcha) solve_recaptcha v2 0 0 ;;
    recaptcha-v2-invisible) solve_recaptcha v2 1 0 ;;
    recaptcha-v2-enterprise) solve_recaptcha v2 0 1 ;;
    recaptcha-v3) solve_recaptcha v3 0 0 ;;
    recaptcha-v3-enterprise) solve_recaptcha v3 0 1 ;;
    hcaptcha) solve_hcaptcha ;;
    *) die "unsupported captcha type: $type_name" ;;
  esac
}

main "$@"
