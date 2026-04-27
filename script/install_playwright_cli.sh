#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=_lib/common.sh
source "$SCRIPT_DIR/_lib/common.sh"

usage() {
  cat <<'EOF'
Usage: install_playwright_cli.sh [install|uninstall|install-deps|init|clean] [--scope SCOPE] [--target TARGET] [--version VERSION] [--project-dir PATH] [--verbose]

Required inputs:
  install|uninstall|install-deps|init|clean

Optional inputs:
  --scope            global | project, used by init|clean, defaults to global
  --target           all | opencode | claude, used by init|clean, auto-detect when omitted
  --version          npm package version, used by install, defaults to latest
  --project-dir      target project directory for init|clean when --scope project
  --verbose          print debug logs
  --help             show this message

Default behavior:
  install installs @playwright/cli globally with npm, then installs default
  Playwright artifacts for that installation using Playwright's default
  browser-install behavior.

  uninstall removes Playwright artifacts for the current @playwright/cli
  installation when the bundled Playwright uninstall command is available, then
  uninstalls @playwright/cli globally with npm.

  install-deps installs Playwright system dependencies using Playwright's
  bundled dependency installer. This may require elevated privileges depending
  on the host system.

  init writes skills to ~/.config/opencode/skills and/or ~/.claude/skills for
  global scope, or to --project-dir/.opencode/skills and/or
  --project-dir/.claude/skills for project scope. It also preserves Playwright
  CLI workspace files at ~/.playwright/ for global scope or
  --project-dir/.playwright/ for project scope. When --target is omitted, init
  only targets tools found in PATH for global scope, or tool directories that
  already exist in the project for project scope.

  clean removes skills and the .playwright/ directory for the selected scope.
  When --target is omitted, clean removes targets with an existing manifest,
  command, or project tool directory.

Interactive mode:
  Not supported.

Side effects:
  install/uninstall modify the global npm package @playwright/cli and may add
  or remove Playwright artifacts under the current user's Playwright cache.
  install-deps installs host system packages required by Playwright browsers.
  init/clean create or remove skill directories, manifest files, and the
  .playwright/ directory for the selected scope.
EOF
}

validate_command_name() {
  case "$1" in
    install|uninstall|install-deps|init|clean) ;;
    *) die "unsupported command: $1" ;;
  esac
}

validate_scope() {
  case "$1" in
    global|project) ;;
    *) die "unsupported scope: $1" ;;
  esac
}

validate_target() {
  case "$1" in
    all|opencode|claude) ;;
    *) die "unsupported target: $1" ;;
  esac
}

global_bin_dir() {
  local prefix
  prefix="$(npm config get prefix)"
  printf '%s/bin\n' "$prefix"
}

resolve_project_dir() {
  [[ -n "$project_dir" ]] || die "--project-dir is required when --scope project"
  project_dir="$(resolve_from_cwd "$project_dir")"
  [[ -d "$project_dir" ]] || die "project directory does not exist: $project_dir"
}

has_global_target() {
  local tool_name="$1"

  case "$tool_name" in
    opencode) command -v opencode >/dev/null 2>&1 ;;
    claude) command -v claude >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

has_project_target() {
  local tool_name="$1"

  case "$tool_name" in
    opencode) [[ -d "$project_dir/.opencode" ]] ;;
    claude) [[ -d "$project_dir/.claude" ]] ;;
    *) return 1 ;;
  esac
}

manifest_path_for_target() {
  local tool_name="$1"

  case "$scope:$tool_name" in
    global:opencode) printf '%s\n' "$HOME/.config/opencode/playwright-cli-skills-manifest.txt" ;;
    global:claude) printf '%s\n' "$HOME/.claude/playwright-cli-skills-manifest.txt" ;;
    project:opencode) printf '%s\n' "$project_dir/.opencode/playwright-cli-skills-manifest.txt" ;;
    project:claude) printf '%s\n' "$project_dir/.claude/playwright-cli-skills-manifest.txt" ;;
    *) die "unsupported target for manifest: $tool_name" ;;
  esac
}

skill_dir_for_target() {
  local tool_name="$1"

  case "$scope:$tool_name" in
    global:opencode) printf '%s\n' "$HOME/.config/opencode/skills" ;;
    global:claude) printf '%s\n' "$HOME/.claude/skills" ;;
    project:opencode) printf '%s\n' "$project_dir/.opencode/skills" ;;
    project:claude) printf '%s\n' "$project_dir/.claude/skills" ;;
    *) die "unsupported target for skill dir: $tool_name" ;;
  esac
}

manifest_exists_for_target() {
  local tool_name="$1"
  [[ -f "$(manifest_path_for_target "$tool_name")" ]]
}

playwright_workspace_dir() {
  case "$scope" in
    global) printf '%s\n' "$HOME/.playwright" ;;
    project) printf '%s\n' "$project_dir/.playwright" ;;
    *) die "unsupported scope for Playwright workspace path: $scope" ;;
  esac
}

add_selected_target() {
  local tool_name="$1"
  local existing

  for existing in "${selected_targets[@]}"; do
    [[ "$existing" == "$tool_name" ]] && return
  done

  selected_targets+=("$tool_name")
}

should_auto_select_target() {
  local tool_name="$1"

  if [[ "$scope" == "global" ]]; then
    if [[ "$command_name" == "init" ]]; then
      has_global_target "$tool_name"
    else
      has_global_target "$tool_name" || manifest_exists_for_target "$tool_name"
    fi
  else
    if [[ "$command_name" == "init" ]]; then
      has_project_target "$tool_name"
    else
      has_project_target "$tool_name" || manifest_exists_for_target "$tool_name"
    fi
  fi
}

resolve_selected_targets() {
  if [[ "$scope" == "project" ]]; then
    resolve_project_dir
  fi

  if [[ -n "$target" ]]; then
    case "$target" in
      all)
        add_selected_target opencode
        add_selected_target claude
        ;;
      opencode|claude)
        add_selected_target "$target"
        ;;
    esac
    return
  fi

  should_auto_select_target opencode && add_selected_target opencode
  should_auto_select_target claude && add_selected_target claude

  if (( ${#selected_targets[@]} == 0 )); then
    if [[ "$command_name" == "clean" ]]; then
      warn "no skill targets detected, only .playwright directory will be cleaned"
      return
    fi
    die "no init targets detected; use --target to specify opencode and/or claude"
  fi
}

install_cli() {
  local package_spec="$1"

  require_cmd npm
  info "installing $package_spec globally"
  npm install -g "$package_spec"
  playwright_cli_cmd="$(global_bin_dir)/playwright-cli"
  [[ -x "$playwright_cli_cmd" ]] || die "playwright-cli executable not found: $playwright_cli_cmd"
}

resolve_playwright_cli_cmd() {
  if command -v playwright-cli >/dev/null 2>&1; then
    playwright_cli_cmd="$(command -v playwright-cli)"
    return 0
  fi

  if [[ -x "$(global_bin_dir)/playwright-cli" ]]; then
    playwright_cli_cmd="$(global_bin_dir)/playwright-cli"
    return 0
  fi

  return 1
}

uninstall_cli() {
  require_cmd npm

  if npm ls -g @playwright/cli --depth=0 >/dev/null 2>&1; then
    info "uninstalling @playwright/cli globally"
    npm uninstall -g @playwright/cli
  else
    warn "@playwright/cli is not installed globally"
  fi
}

ensure_parent_of_file() {
  local file_path="$1"
  mkdir -p "$(dirname "$file_path")"
}

install_playwright_workspace() {
  local source_dir="$1"
  local target_dir

  [[ -d "$source_dir" ]] || die "playwright-cli did not create workspace directory: $source_dir"
  target_dir="$(playwright_workspace_dir)"
  mkdir -p "$(dirname "$target_dir")"
  rm -rf "$target_dir"
  cp -a "$source_dir" "$target_dir"
  info "installed Playwright workspace to $target_dir"
}

uninstall_playwright_workspace() {
  local target_dir

  target_dir="$(playwright_workspace_dir)"
  rm -rf "$target_dir"
  cleanup_dir_if_empty "$(dirname "$target_dir")"
}

collect_skill_items() {
  local source_dir="$1"
  local item_path

  skill_items=()
  shopt -s dotglob nullglob
  for item_path in "$source_dir"/*; do
    skill_items+=("$(basename "$item_path")")
  done
  shopt -u dotglob nullglob

  (( ${#skill_items[@]} > 0 )) || die "no skill entries found in $source_dir"
}

write_manifest() {
  local manifest_path="$1"
  shift

  ensure_parent_of_file "$manifest_path"
  printf '%s\n' "$@" > "$manifest_path"
}

read_manifest_items() {
  local manifest_path="$1"
  local line

  skill_items=()
  [[ -f "$manifest_path" ]] || return 0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    skill_items+=("$line")
  done < "$manifest_path"
}

install_skills_to_dir() {
  local source_dir="$1"
  local target_dir="$2"
  local manifest_path="$3"
  local item_name

  collect_skill_items "$source_dir"
  mkdir -p "$target_dir"
  for item_name in "${skill_items[@]}"; do
    cp -a "$source_dir/$item_name" "$target_dir/"
  done
  write_manifest "$manifest_path" "${skill_items[@]}"
  info "installed skills to $target_dir"
}

install_named_target_skills() {
  local source_dir="$1"
  local tool_name="$2"

  if [[ "$scope" == "global" && ! -x "$(command -v "$tool_name" 2>/dev/null || true)" ]]; then
    warn "$tool_name not found in PATH, continuing with directory install"
  fi

  install_skills_to_dir "$source_dir" "$(skill_dir_for_target "$tool_name")" "$(manifest_path_for_target "$tool_name")"
}

install_target_skills() {
  local source_dir="$1"
  local tool_name

  for tool_name in "${selected_targets[@]}"; do
    install_named_target_skills "$source_dir" "$tool_name"
  done
}

run_skill_installer() {
  local tmp_dir
  local workspace_dir
  local skill_dir

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf '"'"$tmp_dir"'"'' EXIT

  info "installing skills into temporary directory $tmp_dir"
  bash -lc 'cd "$1" && "$2" install --skills' -- "$tmp_dir" "$playwright_cli_cmd"

  skill_dir="$tmp_dir/.claude/skills"
  [[ -d "$skill_dir" ]] || die "playwright-cli did not create skills directory: $skill_dir"
  workspace_dir="$tmp_dir/.playwright"

  install_target_skills "$skill_dir"
  install_playwright_workspace "$workspace_dir"
  rm -rf "$tmp_dir"
  trap - EXIT
}

generate_manifest_from_cli() {
  local tool_name="$1"
  local tmp_dir
  local skill_dir

  resolve_playwright_cli_cmd || return 1

  tmp_dir="$(mktemp -d)"
  if ! bash -lc 'cd "$1" && "$2" install --skills' -- "$tmp_dir" "$playwright_cli_cmd"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  skill_dir="$tmp_dir/.claude/skills"
  if [[ ! -d "$skill_dir" ]]; then
    rm -rf "$tmp_dir"
    return 1
  fi

  collect_skill_items "$skill_dir"
  write_manifest "$(manifest_path_for_target "$tool_name")" "${skill_items[@]}"
  rm -rf "$tmp_dir"
}

cleanup_dir_if_empty() {
  local dir_path="$1"
  [[ -d "$dir_path" ]] || return 0
  rmdir "$dir_path" 2>/dev/null || true
}

resolve_playwright_bundled_cli() {
  local npm_root
  local cli_js

  require_cmd npm
  require_cmd node
  npm_root="$(npm root -g)"
  cli_js="$npm_root/@playwright/cli/node_modules/playwright/cli.js"
  [[ -f "$cli_js" ]] || return 1
  printf '%s\n' "$cli_js"
}

ensure_sudo_session() {
  require_cmd sudo
  info "requesting sudo credentials for Playwright dependency installation"

  if [[ -t 0 ]]; then
    sudo -v
  else
    sudo -S -v
  fi
}

install_playwright_artifacts() {
  local bundled_cli

  if ! bundled_cli="$(resolve_playwright_bundled_cli)"; then
    die "Playwright bundled CLI not found after installing @playwright/cli"
  fi

  info "installing Playwright artifacts for current @playwright/cli installation"
  node "$bundled_cli" install
}

install_playwright_deps() {
  local bundled_cli
  local current_node_cmd

  if ! bundled_cli="$(resolve_playwright_bundled_cli)"; then
    die "Playwright bundled CLI not found; run install first"
  fi
  current_node_cmd="$(command -v node)"
  [[ -n "$current_node_cmd" ]] || die "missing command: node"

  info "installing Playwright system dependencies"
  ensure_sudo_session
  sudo "$current_node_cmd" "$bundled_cli" install-deps
}

uninstall_playwright_artifacts() {
  local bundled_cli

  if ! bundled_cli="$(resolve_playwright_bundled_cli)"; then
    warn "Playwright uninstall CLI not found, skip Playwright artifact cleanup"
    return
  fi

  info "removing Playwright artifacts for current @playwright/cli installation"
  node "$bundled_cli" uninstall
}

uninstall_named_target_skills() {
  local tool_name="$1"
  local target_dir
  local manifest_path
  local item_name

  target_dir="$(skill_dir_for_target "$tool_name")"
  manifest_path="$(manifest_path_for_target "$tool_name")"

  read_manifest_items "$manifest_path"
  if (( ${#skill_items[@]} == 0 )); then
    if ! generate_manifest_from_cli "$tool_name"; then
      warn "no manifest available for $tool_name, skip removing skills from $target_dir"
      return
    fi
    read_manifest_items "$manifest_path"
  fi

  for item_name in "${skill_items[@]}"; do
    rm -rf "$target_dir/$item_name"
  done

  rm -f "$manifest_path"
  cleanup_dir_if_empty "$target_dir"
  info "removed skills from $target_dir"
}

uninstall_target_skills() {
  local tool_name

  for tool_name in "${selected_targets[@]}"; do
    uninstall_named_target_skills "$tool_name"
  done
}

command_name=""
scope="global"
target=""
version="latest"
project_dir=""
playwright_cli_cmd=""
selected_targets=()
skill_items=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|uninstall|install-deps|init|clean)
      command_name="$1"
      shift
      ;;
    --scope)
      [[ $# -ge 2 ]] || die "missing value for --scope"
      scope="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || die "missing value for --target"
      target="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || die "missing value for --version"
      version="$2"
      shift 2
      ;;
    --project-dir)
      [[ $# -ge 2 ]] || die "missing value for --project-dir"
      project_dir="$2"
      shift 2
      ;;
    --verbose)
      SCRIPT_VERBOSE=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$command_name" ]] || die "missing command: install, uninstall, install-deps, init, or clean"
validate_command_name "$command_name"
validate_scope "$scope"
[[ -z "$target" ]] || validate_target "$target"

if [[ "$command_name" == "install" ]]; then
  install_cli "@playwright/cli@$version"
  install_playwright_artifacts
elif [[ "$command_name" == "uninstall" ]]; then
  uninstall_playwright_artifacts
  uninstall_cli
elif [[ "$command_name" == "install-deps" ]]; then
  install_playwright_deps
elif [[ "$command_name" == "init" ]]; then
  resolve_selected_targets
  resolve_playwright_cli_cmd || die "playwright-cli is not installed; run install first"
  run_skill_installer
else
  resolve_selected_targets
  uninstall_target_skills
  uninstall_playwright_workspace
fi
