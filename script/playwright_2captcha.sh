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
image_selector=""
input_selector=""
audio_selector=""
text_selector=""
instruction=""
rows=""
cols=""
angle=40
piece_selectors=()

usage() {
  cat <<'EOF'
Usage: playwright_2captcha.sh --type TYPE [options]

Required inputs:
  --type TYPE             automatic provider or generic media type; see below

Optional inputs:
  --session NAME          existing playwright-cli session name, defaults to default
  --api-key KEY           2captcha API key
  --image SELECTOR        captcha image/background selector for media types
  --input SELECTOR        answer input or rotate control selector
  --audio SELECTOR        audio element selector for audio recognition
  --text SELECTOR         question text selector for text captcha
  --instruction TEXT      worker instruction for visual captcha types
  --rows NUMBER           grid row count, auto-detected when omitted
  --cols NUMBER           grid column count, auto-detected when omitted
  --angle DEGREES         rotate step angle, defaults to 40
  --piece SELECTOR        draggable piece selector; repeat for drag-drop
  --help                  show this message

Automatic provider types:
  auto, turnstile, cloudflare-challenge, recaptcha-v2,
  recaptcha-v2-invisible, recaptcha-v2-enterprise, recaptcha-v3,
  recaptcha-v3-enterprise, hcaptcha, funcaptcha, geetest-v3, geetest-v4,
  keycaptcha, capy, lemin, amazon-waf, mtcaptcha, friendly-captcha, prosopo,
  yandex-smartcaptcha, altcha

Generic media types:
  image             requires --image and --input
  audio             requires --audio and --input
  text              requires --text and --input
  coordinates       requires --image; --instruction is optional
  grid              requires --image; --instruction/--rows/--cols are optional
  rotate            requires --image and --input; --angle defaults to 40
  bounding-box      requires --image and --instruction
  drag-drop         requires --image and one or more --piece

API key lookup order:
  1. --api-key
  2. TWOCAPTCHA_API_KEY environment variable
  3. TWOCAPTCHA_API_KEY or 2CAPTCHA_API_KEY in repository-root/env.ini

Default behavior:
  The script connects to an existing playwright-cli named browser session using
  playwright-cli -s=NAME. It reads captcha parameters from the session's current
  page, submits a task to 2captcha, polls for the solution, writes the token to
  the matching response fields and invokes data-callback when one is available.
  Page submission remains controlled by the caller. Provider handlers extract
  known parameters automatically. Generic media handlers use the selectors
  supplied for the selected type.

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

playwright_run_value() {
  local code="$1"
  local output
  if ! output="$(playwright-cli -s="$session" --raw run-code "$code")"; then
    die "unable to run code in playwright-cli session: $session"
  fi
  printf '%s' "$output" | decode_playwright_value
}

selector_screenshot_base64() {
  local selector_json
  selector_json="$(printf '%s' "$1" | json_quote)"
  playwright_run_value "async page => (await page.locator($selector_json).first().screenshot()).toString('base64')"
}

selector_audio_base64() {
  local selector_json
  selector_json="$(printf '%s' "$1" | json_quote)"
  playwright_run_value "async page => {
    const element = page.locator($selector_json).first();
    const source = await element.getAttribute('src') || await element.locator('source').first().getAttribute('src');
    if (!source) throw new Error('audio source not found');
    const response = await page.request.get(new URL(source, page.url()).href);
    if (!response.ok()) throw new Error('unable to download audio');
    return (await response.body()).toString('base64');
  }"
}

selector_text_value() {
  local selector_json
  selector_json="$(printf '%s' "$1" | json_quote)"
  playwright_run_value "async page => (await page.locator($selector_json).first().innerText()).trim()"
}

fill_selector() {
  local selector_json
  local value_json
  local result
  selector_json="$(printf '%s' "$1" | json_quote)"
  value_json="$(printf '%s' "$2" | json_quote)"
  result="$(playwright_run_value "async page => {
    const selector = $selector_json;
    const value = $value_json;
    const field = page.locator(selector).first();
    await field.fill(value);
    await field.dispatchEvent('input');
    await field.dispatchEvent('change');
    return { selector, valueLength: value.length };
  }")"
  printf 'apply_result: %s\n' "$result"
}

click_coordinates() {
  local selector_json
  local answer_json
  local result
  selector_json="$(printf '%s' "$1" | json_quote)"
  answer_json="$(printf '%s' "$2" | json_quote)"
  result="$(playwright_run_value "async page => {
    const selector = $selector_json;
    const answer = $answer_json;
    const box = await page.locator(selector).first().boundingBox();
    if (!box) throw new Error('captcha target is not visible');
    let points = [];
    try {
      const parsed = JSON.parse(answer);
      if (Array.isArray(parsed)) points = parsed.map(point => ({ x: Number(point.x), y: Number(point.y) }));
    } catch {}
    if (!points.length) {
      points = [...answer.matchAll(/x=(-?\\d+),y=(-?\\d+)/g)].map(match => ({ x: Number(match[1]), y: Number(match[2]) }));
    }
    if (!points.length) throw new Error('coordinate result is invalid: ' + answer);
    for (const point of points) await page.mouse.click(box.x + point.x, box.y + point.y);
    return { selector, clicks: points.length };
  }")"
  printf 'apply_result: %s\n' "$result"
}

click_grid_cells() {
  local selector_json
  local answer_json
  local rows_value="$3"
  local cols_value="$4"
  local result
  selector_json="$(printf '%s' "$1" | json_quote)"
  answer_json="$(printf '%s' "$2" | json_quote)"
  result="$(playwright_run_value "async page => {
    const selector = $selector_json;
    const answer = $answer_json;
    const box = await page.locator(selector).first().boundingBox();
    if (!box) throw new Error('captcha grid is not visible');
    const rows = Number('$rows_value') || (Math.round(box.width) === 300 && Math.round(box.height) === 300 ? 3 : 4);
    const cols = Number('$cols_value') || rows;
    const cells = (answer.match(/\\d+/g) || []).map(Number);
    if (!cells.length) throw new Error('grid result is invalid: ' + answer);
    for (const cell of cells) {
      const index = cell - 1;
      const row = Math.floor(index / cols);
      const col = index % cols;
      await page.mouse.click(box.x + (col + 0.5) * box.width / cols, box.y + (row + 0.5) * box.height / rows);
    }
    return { selector, rows, cols, clicks: cells.length };
  }")"
  printf 'apply_result: %s\n' "$result"
}

click_bounding_boxes() {
  local selector_json
  local answer_json
  local result
  selector_json="$(printf '%s' "$1" | json_quote)"
  answer_json="$(printf '%s' "$2" | json_quote)"
  result="$(playwright_run_value "async page => {
    const selector = $selector_json;
    const answer = $answer_json;
    const box = await page.locator(selector).first().boundingBox();
    if (!box) throw new Error('captcha target is not visible');
    const areas = JSON.parse(answer);
    for (const area of areas) {
      await page.mouse.click(box.x + (area.xMin + area.xMax) / 2, box.y + (area.yMin + area.yMax) / 2);
    }
    return { selector, clicks: areas.length };
  }")"
  printf 'apply_result: %s\n' "$result"
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
      --image)
        [[ $# -ge 2 && -n "$2" ]] || die "--image requires a value"
        image_selector="$2"
        shift 2
        ;;
      --input)
        [[ $# -ge 2 && -n "$2" ]] || die "--input requires a value"
        input_selector="$2"
        shift 2
        ;;
      --audio)
        [[ $# -ge 2 && -n "$2" ]] || die "--audio requires a value"
        audio_selector="$2"
        shift 2
        ;;
      --text)
        [[ $# -ge 2 && -n "$2" ]] || die "--text requires a value"
        text_selector="$2"
        shift 2
        ;;
      --instruction)
        [[ $# -ge 2 && -n "$2" ]] || die "--instruction requires a value"
        instruction="$2"
        shift 2
        ;;
      --rows)
        [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--rows requires a positive integer"
        rows="$2"
        shift 2
        ;;
      --cols)
        [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--cols requires a positive integer"
        cols="$2"
        shift 2
        ;;
      --angle)
        [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--angle requires a positive integer"
        angle="$2"
        shift 2
        ;;
      --piece)
        [[ $# -ge 2 && -n "$2" ]] || die "--piece requires a value"
        piece_selectors+=("$2")
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
solved_user_agent=""

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

  solved_token=""
  solved_user_agent=""

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
      solved_user_agent="$(printf '%s' "$result_response" | json_field useragent)" || true
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

solve_image() {
  local body
  [[ -n "$image_selector" ]] || die "--image is required for type image"
  [[ -n "$input_selector" ]] || die "--input is required for type image"
  body="$(selector_screenshot_base64 "$image_selector")"
  submit_and_poll "method=base64" "body=$body"
  fill_selector "$input_selector" "$solved_token"
}

solve_audio() {
  local body
  [[ -n "$audio_selector" ]] || die "--audio is required for type audio"
  [[ -n "$input_selector" ]] || die "--input is required for type audio"
  body="$(selector_audio_base64 "$audio_selector")"
  submit_and_poll "method=audio" "body=$body" "lang=en"
  fill_selector "$input_selector" "$solved_token"
}

solve_text() {
  local question
  [[ -n "$text_selector" ]] || die "--text is required for type text"
  [[ -n "$input_selector" ]] || die "--input is required for type text"
  question="$(selector_text_value "$text_selector")"
  [[ -n "$question" ]] || die "text captcha question is empty"
  submit_and_poll "textcaptcha=$question"
  fill_selector "$input_selector" "$solved_token"
}

solve_coordinates() {
  local body
  local -a parameters
  [[ -n "$image_selector" ]] || die "--image is required for type coordinates"
  body="$(selector_screenshot_base64 "$image_selector")"
  parameters=("method=base64" "body=$body" "coordinatescaptcha=1")
  [[ -n "$instruction" ]] && parameters+=("textinstructions=$instruction")
  submit_and_poll "${parameters[@]}"
  click_coordinates "$image_selector" "$solved_token"
}

solve_grid() {
  local body
  local -a parameters
  [[ -n "$image_selector" ]] || die "--image is required for type grid"
  body="$(selector_screenshot_base64 "$image_selector")"
  parameters=("method=base64" "body=$body" "recaptcha=1")
  [[ -n "$instruction" ]] && parameters+=("textinstructions=$instruction")
  [[ -n "$rows" ]] && parameters+=("recaptcharows=$rows")
  [[ -n "$cols" ]] && parameters+=("recaptchacols=$cols")
  submit_and_poll "${parameters[@]}"
  click_grid_cells "$image_selector" "$solved_token" "$rows" "$cols"
}

solve_rotate() {
  local body
  local answer
  local input_json
  local result
  [[ -n "$image_selector" ]] || die "--image is required for type rotate"
  [[ -n "$input_selector" ]] || die "--input is required for type rotate"
  body="$(selector_screenshot_base64 "$image_selector")"
  submit_and_poll "method=rotatecaptcha" "body=$body" "angle=$angle"
  answer="${solved_token%%|*}"
  [[ "$answer" =~ ^-?[0-9]+$ ]] || die "rotate result is invalid: $solved_token"
  input_json="$(printf '%s' "$input_selector" | json_quote)"
  result="$(playwright_run_value "async page => {
    const selector = $input_json;
    const degrees = Number('$answer');
    const step = Number('$angle');
    const key = degrees < 0 ? 'ArrowLeft' : 'ArrowRight';
    const count = Math.round(Math.abs(degrees) / step);
    const control = page.locator(selector).first();
    await control.focus();
    for (let index = 0; index < count; index++) await control.press(key);
    return { selector, degrees, keyPresses: count };
  }")"
  printf 'apply_result: %s\n' "$result"
}

solve_bounding_box() {
  local body
  [[ -n "$image_selector" ]] || die "--image is required for type bounding-box"
  [[ -n "$instruction" ]] || die "--instruction is required for type bounding-box"
  body="$(selector_screenshot_base64 "$image_selector")"
  submit_and_poll "method=bounding_box" "image=$body" "textinstructions=$instruction"
  click_bounding_boxes "$image_selector" "$solved_token"
}

solve_drag_drop() {
  local body
  local piece
  local piece_body
  local pieces_json="["
  local selectors_json
  local answer_json
  local result
  local background_json
  local first=1
  [[ -n "$image_selector" ]] || die "--image is required for type drag-drop"
  [[ "${#piece_selectors[@]}" -gt 0 ]] || die "at least one --piece is required for type drag-drop"
  body="$(selector_screenshot_base64 "$image_selector")"
  for piece in "${piece_selectors[@]}"; do
    piece_body="$(selector_screenshot_base64 "$piece")"
    [[ "$first" == "1" ]] || pieces_json+=","
    pieces_json+="$(printf '%s' "$piece_body" | json_quote)"
    first=0
  done
  pieces_json+="]"
  submit_and_poll "method=drag_drop" "body=$body" "images=$pieces_json" "textinstructions=${instruction:-Drag the images to proper position}"
  selectors_json="$(printf '%s\n' "${piece_selectors[@]}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().splitlines()))')"
  answer_json="$(printf '%s' "$solved_token" | json_quote)"
  background_json="$(printf '%s' "$image_selector" | json_quote)"
  result="$(playwright_run_value "async page => {
    const backgroundSelector = $background_json;
    const pieceSelectors = $selectors_json;
    const answer = $answer_json;
    const background = await page.locator(backgroundSelector).first().boundingBox();
    if (!background) throw new Error('drag-drop background is not visible');
    const targets = answer.split('|');
    let moved = 0;
    for (let index = 0; index < pieceSelectors.length; index++) {
      if (!targets[index] || targets[index] === 'null') continue;
      const match = targets[index].match(/^(-?\\d+),(-?\\d+)$/);
      if (!match) throw new Error('drag-drop result is invalid: ' + targets[index]);
      const piece = await page.locator(pieceSelectors[index]).first().boundingBox();
      if (!piece) throw new Error('drag-drop piece is not visible: ' + pieceSelectors[index]);
      await page.mouse.move(piece.x + piece.width / 2, piece.y + piece.height / 2);
      await page.mouse.down();
      await page.mouse.move(background.x + Number(match[1]), background.y + Number(match[2]), { steps: 15 });
      await page.mouse.up();
      moved++;
    }
    return { background: backgroundSelector, moved };
  }")"
  printf 'apply_result: %s\n' "$result"
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

solve_cloudflare_challenge() {
  local capture
  local pageurl
  local sitekey
  local challenge_action
  local challenge_data
  local challenge_pagedata
  local user_agent
  local token_json
  local user_agent_json
  local result
  local attempt

  playwright_run_value "async page => {
    await page.context().addInitScript(() => {
      window.__twoCaptchaChallenge = null;
      const timer = setInterval(() => {
        if (!window.turnstile?.render || window.turnstile.render.__twoCaptchaIntercepted) return;
        clearInterval(timer);
        const intercepted = (container, options = {}) => {
          window.__twoCaptchaChallenge = {
            sitekey: options.sitekey || '',
            action: options.action || '',
            data: options.cData || '',
            pagedata: options.chlPageData || '',
            userAgent: navigator.userAgent,
            pageurl: location.href
          };
          window.__twoCaptchaChallengeCallback = options.callback;
          return '2captcha-intercepted';
        };
        intercepted.__twoCaptchaIntercepted = true;
        window.turnstile.render = intercepted;
      }, 10);
    });
    return true;
  }" >/dev/null

  for attempt in 1 2 3; do
    capture="$(playwright_run_value "async page => {
      await page.reload({ waitUntil: 'domcontentloaded' });
      await page.waitForFunction(() => window.__twoCaptchaChallenge?.sitekey, null, { timeout: 30000 });
      return await page.evaluate(() => window.__twoCaptchaChallenge);
    }")"
    pageurl="$(printf '%s' "$capture" | json_field pageurl)"
    sitekey="$(printf '%s' "$capture" | json_field sitekey)"
    challenge_action="$(printf '%s' "$capture" | json_field action)"
    challenge_data="$(printf '%s' "$capture" | json_field data)"
    challenge_pagedata="$(printf '%s' "$capture" | json_field pagedata)"
    user_agent="$(printf '%s' "$capture" | json_field userAgent)"
    [[ -n "$sitekey" && -n "$challenge_data" && -n "$challenge_pagedata" ]] || die "unable to capture Cloudflare Challenge parameters"
    submit_and_poll "method=turnstile" "sitekey=$sitekey" "pageurl=$pageurl" "action=$challenge_action" "data=$challenge_data" "pagedata=$challenge_pagedata" "userAgent=$user_agent"
    if [[ -z "$solved_user_agent" || "$solved_user_agent" == "$user_agent" ]]; then
      break
    fi
    user_agent_json="$(printf '%s' "$solved_user_agent" | json_quote)"
    playwright_run_value "async page => {
      const cdp = await page.context().newCDPSession(page);
      await cdp.send('Network.setUserAgentOverride', { userAgent: $user_agent_json });
      return true;
    }" >/dev/null
  done
  token_json="$(printf '%s' "$solved_token" | json_quote)"
  user_agent_json="$(printf '%s' "${solved_user_agent:-$user_agent}" | json_quote)"
  result="$(playwright_run_value "async page => {
    const token = $token_json;
    const userAgent = $user_agent_json;
    if (userAgent) {
      const cdp = await page.context().newCDPSession(page);
      await cdp.send('Network.setUserAgentOverride', { userAgent });
    }
    const applied = await page.evaluate(token => {
      if (typeof window.__twoCaptchaChallengeCallback !== 'function') return false;
      window.__twoCaptchaChallengeCallback(token);
      return true;
    }, token);
    await page.waitForTimeout(8000);
    return { applied, url: page.url(), title: await page.title() };
  }")"
  printf 'apply_result: %s\n' "$result"
}

apply_structured_solution() {
  local mapping_json="$1"
  local callback_name="${2:-}"
  local answer_json
  local callback_json
  local result
  answer_json="$(printf '%s' "$solved_token" | json_quote)"
  callback_json="$(printf '%s' "$callback_name" | json_quote)"
  result="$(playwright_run_value "async page => {
    const answer = $answer_json;
    const mapping = $mapping_json;
    const callbackName = $callback_json;
    return await page.evaluate(({ answer, mapping, callbackName }) => {
      let solution;
      try { solution = JSON.parse(answer); } catch { solution = answer; }
      const fields = [];
      for (const [selector, key] of Object.entries(mapping)) {
        const value = key ? solution?.[key] : solution;
        if (value === undefined || value === null) continue;
        for (const field of document.querySelectorAll(selector)) {
          field.value = typeof value === 'string' ? value : JSON.stringify(value);
          field.dispatchEvent(new Event('input', { bubbles: true }));
          field.dispatchEvent(new Event('change', { bubbles: true }));
          fields.push(selector);
        }
      }
      let callback = 'not-found';
      const callbackFn = callbackName
        ? callbackName.split('.').reduce((value, part) => value?.[part], window)
        : null;
      if (typeof callbackFn === 'function') {
        callbackFn(solution);
        callback = callbackName;
      }
      return { fields, callback };
    }, { answer, mapping, callbackName });
  }")"
  printf 'apply_result: %s\n' "$result"
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
  local -a parameters

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

solve_funcaptcha() {
  local capture
  local pageurl
  local publickey
  local surl
  local user_agent
  local callback_name
  capture="$(playwright_value "(() => {
    const widget = document.querySelector('[data-pkey]');
    const input = document.querySelector('input[name=fc-token], #fc-token');
    const raw = input?.value || '';
    const params = new URLSearchParams(raw.replaceAll('|', '&'));
    return {
      pageurl: location.href,
      publickey: widget?.getAttribute('data-pkey') || params.get('pk') || '',
      surl: params.get('surl') || '',
      userAgent: navigator.userAgent,
      callback: widget?.getAttribute('data-callback') || ''
    };
  })()")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  publickey="$(printf '%s' "$capture" | json_field publickey)"
  surl="$(printf '%s' "$capture" | json_field surl)"
  user_agent="$(printf '%s' "$capture" | json_field userAgent)"
  callback_name="$(printf '%s' "$capture" | json_field callback)"
  [[ -n "$publickey" ]] || die "unable to detect the FunCaptcha public key"
  local -a parameters=("method=funcaptcha" "publickey=$publickey" "pageurl=$pageurl" "userAgent=$user_agent")
  [[ -n "$surl" ]] && parameters+=("surl=$surl")
  submit_and_poll "${parameters[@]}"
  apply_structured_solution '{"input[name=\"fc-token\"],#fc-token":""}' "$callback_name"
}

solve_geetest_v3() {
  local capture
  local pageurl
  local gt
  local challenge
  local api_server
  local user_agent
  capture="$(playwright_value "(() => {
    const widget = document.querySelector('[data-gt], .geetest_holder');
    const config = window.geetestConfig || window.gtConfig || window.GeeTestConfig || {};
    return {
      pageurl: location.href,
      gt: widget?.getAttribute('data-gt') || config.gt || window.gt || '',
      challenge: widget?.getAttribute('data-challenge') || config.challenge || window.challenge || document.querySelector('input[name=geetest_challenge]')?.value || '',
      apiServer: widget?.getAttribute('data-api-server') || config.api_server || config.apiServer || '',
      userAgent: navigator.userAgent
    };
  })()")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  gt="$(printf '%s' "$capture" | json_field gt)"
  challenge="$(printf '%s' "$capture" | json_field challenge)"
  api_server="$(printf '%s' "$capture" | json_field apiServer)"
  user_agent="$(printf '%s' "$capture" | json_field userAgent)"
  [[ -n "$gt" && -n "$challenge" ]] || die "unable to detect GeeTest v3 gt/challenge parameters"
  local -a parameters=("method=geetest" "gt=$gt" "challenge=$challenge" "pageurl=$pageurl" "userAgent=$user_agent")
  [[ -n "$api_server" ]] && parameters+=("api_server=$api_server")
  submit_and_poll "${parameters[@]}"
  apply_structured_solution '{"input[name=\"geetest_challenge\"]":"challenge","input[name=\"geetest_validate\"]":"validate","input[name=\"geetest_seccode\"]":"seccode"}'
}

solve_geetest_v4() {
  local capture
  local pageurl
  local captcha_id
  local risk_type
  capture="$(playwright_value "(() => {
    let captchaId = document.querySelector('[data-captcha-id]')?.getAttribute('data-captcha-id') || document.querySelector('input[name=captcha_id]')?.value || '';
    let riskType = document.querySelector('[data-risk-type]')?.getAttribute('data-risk-type') || '';
    for (const script of document.scripts) {
      if (!script.src.includes('geetest')) continue;
      try {
        const url = new URL(script.src);
        captchaId ||= url.searchParams.get('captcha_id') || '';
        riskType ||= url.searchParams.get('risk_type') || '';
      } catch {}
    }
    return { pageurl: location.href, captchaId, riskType };
  })()")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  captcha_id="$(printf '%s' "$capture" | json_field captchaId)"
  risk_type="$(printf '%s' "$capture" | json_field riskType)"
  [[ -n "$captcha_id" ]] || die "unable to detect the GeeTest v4 captcha_id"
  local -a parameters=("method=geetest_v4" "captcha_id=$captcha_id" "pageurl=$pageurl")
  [[ -n "$risk_type" ]] && parameters+=("risk_type=$risk_type")
  submit_and_poll "${parameters[@]}"
  apply_structured_solution '{"input[name=\"captcha_id\"]":"captcha_id","input[name=\"lot_number\"]":"lot_number","input[name=\"pass_token\"]":"pass_token","input[name=\"gen_time\"]":"gen_time","input[name=\"captcha_output\"]":"captcha_output"}'
}

solve_keycaptcha() {
  local capture
  local pageurl
  local user_id
  local session_id
  local sign
  local sign2
  capture="$(playwright_value "({
    pageurl: location.href,
    userId: window.s_s_c_user_id || '',
    sessionId: window.s_s_c_session_id || '',
    sign: window.s_s_c_web_server_sign || '',
    sign2: window.s_s_c_web_server_sign2 || ''
  })")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  user_id="$(printf '%s' "$capture" | json_field userId)"
  session_id="$(printf '%s' "$capture" | json_field sessionId)"
  sign="$(printf '%s' "$capture" | json_field sign)"
  sign2="$(printf '%s' "$capture" | json_field sign2)"
  [[ -n "$user_id" && -n "$session_id" && -n "$sign" && -n "$sign2" ]] || die "unable to detect KeyCaptcha parameters"
  submit_and_poll "method=keycaptcha" "s_s_c_user_id=$user_id" "s_s_c_session_id=$session_id" "s_s_c_web_server_sign=$sign" "s_s_c_web_server_sign2=$sign2" "pageurl=$pageurl"
  apply_structured_solution '{"#capcode,input[name=\"capcode\"]":""}'
}

solve_capy() {
  local capture
  local pageurl
  local captchakey
  local api_server
  capture="$(playwright_value "(() => {
    for (const script of document.scripts) {
      if (!script.src.includes('capy')) continue;
      try {
        const url = new URL(script.src);
        const key = url.searchParams.get('k');
        if (key) return { pageurl: location.href, captchakey: key, apiServer: url.origin + '/' };
      } catch {}
    }
    return { pageurl: location.href, captchakey: window.capy_captchakey || '', apiServer: '' };
  })()")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  captchakey="$(printf '%s' "$capture" | json_field captchakey)"
  api_server="$(printf '%s' "$capture" | json_field apiServer)"
  [[ -n "$captchakey" ]] || die "unable to detect the Capy captcha key"
  local -a parameters=("method=capy" "captchakey=$captchakey" "pageurl=$pageurl")
  [[ -n "$api_server" ]] && parameters+=("api_server=$api_server")
  submit_and_poll "${parameters[@]}"
  apply_structured_solution '{"input[name=\"capy_captchakey\"]":"captchakey","input[name=\"capy_challengekey\"]":"challengekey","input[name=\"capy_answer\"]":"answer"}'
}

solve_lemin() {
  local capture
  local pageurl
  local captcha_id
  local div_id
  local api_server
  capture="$(playwright_value "(() => {
    for (const script of document.scripts) {
      const match = script.src.match(/^(https?:\\/\\/[^/]+\\/).*captcha\\/v1\\/cropped\\/(CROPPED_[^/]+)/);
      if (!match) continue;
      const parent = script.parentElement;
      if (parent && !parent.id) parent.id = 'lemin-captcha-' + Date.now();
      return { pageurl: location.href, captchaId: match[2], divId: parent?.id || '', apiServer: match[1] };
    }
    return { pageurl: location.href, captchaId: '', divId: '', apiServer: '' };
  })()")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  captcha_id="$(printf '%s' "$capture" | json_field captchaId)"
  div_id="$(printf '%s' "$capture" | json_field divId)"
  api_server="$(printf '%s' "$capture" | json_field apiServer)"
  [[ -n "$captcha_id" ]] || die "unable to detect the Lemin captcha_id"
  local -a parameters=("method=lemin" "captcha_id=$captcha_id" "pageurl=$pageurl")
  [[ -n "$div_id" ]] && parameters+=("div_id=$div_id")
  [[ -n "$api_server" ]] && parameters+=("api_server=$api_server")
  submit_and_poll "${parameters[@]}"
  apply_structured_solution '{"input[name=\"lemin_answer\"]":"answer","input[name=\"lemin_challenge_id\"]":"challenge_id"}'
}

solve_amazon_waf() {
  local capture
  local pageurl
  local sitekey
  local iv
  local context
  local challenge_script
  local captcha_script
  local jsapi_script
  capture="$(playwright_value "(() => {
    const props = window.gokuProps || window.awsWafConfig || {};
    const scripts = [...document.scripts].map(script => script.src).filter(Boolean);
    return {
      pageurl: location.href,
      sitekey: props.key || props.sitekey || '',
      iv: props.iv || '',
      context: props.context || '',
      challengeScript: scripts.find(src => src.includes('/challenge.js')) || '',
      captchaScript: scripts.find(src => src.includes('/captcha.js')) || '',
      jsapiScript: scripts.find(src => src.includes('jsapi')) || ''
    };
  })()")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  sitekey="$(printf '%s' "$capture" | json_field sitekey)"
  iv="$(printf '%s' "$capture" | json_field iv)"
  context="$(printf '%s' "$capture" | json_field context)"
  challenge_script="$(printf '%s' "$capture" | json_field challengeScript)"
  captcha_script="$(printf '%s' "$capture" | json_field captchaScript)"
  jsapi_script="$(printf '%s' "$capture" | json_field jsapiScript)"
  [[ -n "$sitekey" ]] || die "unable to detect the Amazon WAF sitekey"
  local -a parameters=("method=amazon_waf" "sitekey=$sitekey" "pageurl=$pageurl")
  if [[ -n "$jsapi_script" ]]; then
    parameters+=("jsapiScript=$jsapi_script")
  else
    [[ -n "$iv" && -n "$context" ]] || die "unable to detect Amazon WAF iv/context parameters"
    parameters+=("iv=$iv" "context=$context")
    [[ -n "$challenge_script" ]] && parameters+=("challenge_script=$challenge_script")
    [[ -n "$captcha_script" ]] && parameters+=("captcha_script=$captcha_script")
  fi
  submit_and_poll "${parameters[@]}"
  apply_structured_solution '{"input[name=\"amazon_waf_captcha_voucher\"],challenge.input":"captcha_voucher","input[name=\"amazon_waf_existing_token\"]":"existing_token"}'
}

solve_mtcaptcha() {
  local capture
  local pageurl
  local sitekey
  capture="$(playwright_value "({
    pageurl: location.href,
    sitekey: window.mtcaptchaConfig?.sitekey || document.querySelector('[data-mt-sitekey],[data-sitekey]')?.getAttribute('data-mt-sitekey') || document.querySelector('[data-mt-sitekey],[data-sitekey]')?.getAttribute('data-sitekey') || ''
  })")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  sitekey="$(printf '%s' "$capture" | json_field sitekey)"
  [[ -n "$sitekey" ]] || die "unable to detect the MTCaptcha sitekey"
  submit_and_poll "method=mt_captcha" "sitekey=$sitekey" "pageurl=$pageurl"
  apply_structured_solution '{"input[name=\"mtcaptcha-verifiedtoken\"]":""}'
}

solve_friendly_captcha() {
  local capture
  local pageurl
  local sitekey
  local version
  local module_script
  local nomodule_script
  capture="$(playwright_value "(() => {
    const widget = document.querySelector('.frc-captcha[data-sitekey],[data-sitekey]');
    const scripts = [...document.scripts];
    return {
      pageurl: location.href,
      sitekey: widget?.getAttribute('data-sitekey') || '',
      version: widget?.getAttribute('data-version') || 'v1',
      moduleScript: scripts.find(script => script.type === 'module' && script.src.includes('friendly'))?.src || '',
      nomoduleScript: scripts.find(script => script.noModule && script.src.includes('friendly'))?.src || ''
    };
  })()")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  sitekey="$(printf '%s' "$capture" | json_field sitekey)"
  version="$(printf '%s' "$capture" | json_field version)"
  module_script="$(printf '%s' "$capture" | json_field moduleScript)"
  nomodule_script="$(printf '%s' "$capture" | json_field nomoduleScript)"
  [[ -n "$sitekey" ]] || die "unable to detect the Friendly Captcha sitekey"
  local -a parameters=("method=friendly_captcha" "sitekey=$sitekey" "pageurl=$pageurl" "version=$version")
  [[ -n "$module_script" ]] && parameters+=("module_script=$module_script")
  [[ -n "$nomodule_script" ]] && parameters+=("nomodule_script=$nomodule_script")
  submit_and_poll "${parameters[@]}"
  apply_solution "frc-captcha-solution" ".frc-captcha[data-callback],[data-sitekey][data-callback]"
}

solve_simple_sitekey_token() {
  local method="$1"
  local label="$2"
  local field_names="$3"
  local selector="$4"
  local pageurl
  local user_agent
  local sitekey
  current_page_parameters
  sitekey="$(playwright_value "$selector")"
  [[ -n "$sitekey" ]] || die "unable to detect the $label sitekey"
  submit_and_poll "method=$method" "sitekey=$sitekey" "pageurl=$pageurl" "userAgent=$user_agent"
  apply_solution "$field_names" "[data-callback]"
}

solve_altcha() {
  local capture
  local pageurl
  local challenge_url
  capture="$(playwright_value "(() => {
    const widget = document.querySelector('altcha-widget,[challengeurl],[challenge-url]');
    return { pageurl: location.href, challengeUrl: widget?.getAttribute('challengeurl') || widget?.getAttribute('challenge-url') || '' };
  })()")"
  pageurl="$(printf '%s' "$capture" | json_field pageurl)"
  challenge_url="$(printf '%s' "$capture" | json_field challengeUrl)"
  [[ -n "$challenge_url" ]] || die "unable to detect the Altcha challenge URL"
  submit_and_poll "method=altcha" "challenge_url=$challenge_url" "pageurl=$pageurl"
  apply_solution "altcha" "altcha-widget[data-callback],[data-callback]"
}

detect_automatic_type() {
  playwright_value "(() => {
    const scripts = [...document.scripts].map(script => script.src).filter(Boolean);
    if (window._cf_chl_opt || document.title === 'Just a moment...' || scripts.some(src => src.includes('/turnstile/') && document.body?.innerText.includes('security verification'))) return 'cloudflare-challenge';
    if (document.querySelector('.cf-turnstile,[name=cf-turnstile-response]') || scripts.some(src => src.includes('/turnstile/'))) return 'turnstile';
    if (document.querySelector('.h-captcha,[name=h-captcha-response]') || scripts.some(src => src.includes('hcaptcha.com/1/api.js'))) return 'hcaptcha';
    if (document.querySelector('[data-pkey],#fc-token,input[name=fc-token]') || scripts.some(src => src.includes('arkoselabs'))) return 'funcaptcha';
    if (scripts.some(src => src.includes('gt4.js') || src.includes('gcaptcha4.geetest.com'))) return 'geetest-v4';
    if (typeof window.initGeetest === 'function' || document.querySelector('.geetest_holder,[data-gt]')) return 'geetest-v3';
    if (window.s_s_c_user_id || document.querySelector('#div_for_keycaptcha,#capcode')) return 'keycaptcha';
    if (scripts.some(src => src.includes('capy.me'))) return 'capy';
    if (scripts.some(src => src.includes('/captcha/v1/cropped/CROPPED_'))) return 'lemin';
    if (window.gokuProps || scripts.some(src => src.includes('captcha-sdk.awswaf.com') || src.includes('/challenge.js'))) return 'amazon-waf';
    if (window.mtcaptchaConfig || document.querySelector('[name=mtcaptcha-verifiedtoken]')) return 'mtcaptcha';
    if (document.querySelector('.frc-captcha,[name=frc-captcha-solution]')) return 'friendly-captcha';
    if (document.querySelector('altcha-widget,[challengeurl],[challenge-url]')) return 'altcha';
    if (document.querySelector('.smart-captcha,[name=smart-token]') || scripts.some(src => src.includes('smartcaptcha.yandexcloud.net'))) return 'yandex-smartcaptcha';
    if (scripts.some(src => src.includes('recaptcha/enterprise.js'))) {
      return scripts.some(src => src.includes('render=')) ? 'recaptcha-v3-enterprise' : 'recaptcha-v2-enterprise';
    }
    if (document.querySelector('.g-recaptcha,[name=g-recaptcha-response]') || scripts.some(src => src.includes('/recaptcha/'))) {
      if (scripts.some(src => { try { const render = new URL(src).searchParams.get('render'); return render && render !== 'explicit'; } catch { return false; } })) return 'recaptcha-v3';
      return 'recaptcha-v2';
    }
    return '';
  })()"
}

main() {
  parse_args "$@"
  [[ -n "$type_name" ]] || die "--type is required"
  require_cmd curl
  require_cmd python3
  require_cmd playwright-cli
  load_api_key

  if [[ "$type_name" == "auto" ]]; then
    type_name="$(detect_automatic_type)"
    [[ -n "$type_name" ]] || die "unable to detect a supported captcha on the current page"
    printf 'detected_type: %s\n' "$type_name"
  fi

  case "$type_name" in
    image) solve_image ;;
    audio) solve_audio ;;
    text) solve_text ;;
    coordinates) solve_coordinates ;;
    grid) solve_grid ;;
    rotate) solve_rotate ;;
    bounding-box) solve_bounding_box ;;
    drag-drop) solve_drag_drop ;;
    turnstile) solve_turnstile ;;
    cloudflare-challenge) solve_cloudflare_challenge ;;
    recaptcha-v2|recaptcha) solve_recaptcha v2 0 0 ;;
    recaptcha-v2-invisible) solve_recaptcha v2 1 0 ;;
    recaptcha-v2-enterprise) solve_recaptcha v2 0 1 ;;
    recaptcha-v3) solve_recaptcha v3 0 0 ;;
    recaptcha-v3-enterprise) solve_recaptcha v3 0 1 ;;
    hcaptcha) solve_hcaptcha ;;
    funcaptcha) solve_funcaptcha ;;
    geetest-v3) solve_geetest_v3 ;;
    geetest-v4) solve_geetest_v4 ;;
    keycaptcha) solve_keycaptcha ;;
    capy) solve_capy ;;
    lemin) solve_lemin ;;
    amazon-waf) solve_amazon_waf ;;
    mtcaptcha) solve_mtcaptcha ;;
    friendly-captcha) solve_friendly_captcha ;;
    prosopo) solve_simple_sitekey_token prosopo Prosopo "procaptcha-response,prosopo-procaptcha-response" "document.querySelector('[data-sitekey]')?.getAttribute('data-sitekey') || ''" ;;
    yandex-smartcaptcha) solve_simple_sitekey_token yandex "Yandex SmartCaptcha" "smart-token" "document.querySelector('.smart-captcha[data-sitekey],[data-sitekey]')?.getAttribute('data-sitekey') || ''" ;;
    altcha) solve_altcha ;;
    *) die "unsupported captcha type: $type_name" ;;
  esac
}

main "$@"
