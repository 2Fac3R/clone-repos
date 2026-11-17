#!/usr/bin/env bash
#
# clone-repos.sh - Clone all repos of a GitHub user/org, organized as:
#
#   <dest>/<Language>/<Framework>/<repo>     (framework detected)
#   <dest>/<Language>/<repo>                 (no framework detected)
#
# Language comes from the GitHub API (primary language of the repo).
# Framework is detected from manifest files inside the cloned repo
# (package.json, requirements.txt, composer.json, Gemfile, pom.xml, ...).
#
# Requires: bash >= 4.3, curl, jq, git

set -uo pipefail

# ----------------------------- defaults ------------------------------------
CNTX="users"          # users | orgs
NAME=""
DEST="."
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
ENV_FILE=""
USE_SSH=0
INCLUDE_FORKS=0
INCLUDE_ARCHIVED=0
DETECT_FRAMEWORK=1
DRY_RUN=0
JOBS=4
SHALLOW=0
PER_PAGE=100
API="https://api.github.com"

# ------------------------------- helpers -----------------------------------
usage() {
  cat <<EOF
Usage: ${0##*/} -n NAME [options]

Required:
  -n, --name NAME        GitHub user or organization name

Options:
  -c, --context TYPE     'users' (default) or 'orgs'
  -d, --dest DIR         Destination directory (default: current dir)
  -e, --env-file FILE    Read GITHUB_TOKEN from this .env file. If omitted,
                         ./.env and the script's own folder are checked.
                         Precedence: -t > environment variable > .env file
  -t, --token TOKEN      GitHub token (or set GITHUB_TOKEN). Raises rate
                         limits and enables private repos:
                           users: token must belong to NAME itself
                           orgs:  token needs access to the org's repos
                         Classic PAT scope: 'repo'. Fine-grained: Contents
                         and Metadata (read) on the repos you want.
  -j, --jobs N           Parallel clones (default: $JOBS)
  -s, --ssh              Clone via SSH instead of HTTPS
  -f, --forks            Include forked repos (skipped by default)
  -a, --archived         Include archived repos (skipped by default)
  -F, --no-framework     Only organize by language, skip framework detection
      --shallow          Use 'git clone --depth 1'
  -N, --dry-run          Show what would be done, clone nothing
  -h, --help             Show this help

Examples:
  ${0##*/} -n 2Fac3R
  ${0##*/} -n anthropics -c orgs -d ~/code -j 8 --shallow
  GITHUB_TOKEN=ghp_xxx ${0##*/} -n myuser -s -f -a
EOF
}

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Make a string safe to use as a directory name.
sanitize() { printf '%s' "$1" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._+#-'; }

# Read GITHUB_TOKEN (or GH_TOKEN) from a .env-style file WITHOUT sourcing it,
# so nothing in the file is ever executed. Returns 0 if a token was found.
load_env_token() {
  local file="$1" line val
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(GITHUB_TOKEN|GH_TOKEN)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    val="${BASH_REMATCH[3]}"
    val="${val%"${val##*[![:space:]]}"}"          # trim trailing spaces
    val="${val%\"}"; val="${val#\"}"              # strip double quotes
    val="${val%\'}"; val="${val#\'}"              # strip single quotes
    if [[ -n "$val" ]]; then TOKEN="$val"; return 0; fi
  done < "$file"
  return 1
}

# ---------------------------- arg parsing ----------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)       NAME="${2:-}"; shift 2 ;;
    -c|--context)    CNTX="${2:-}"; shift 2 ;;
    -d|--dest)       DEST="${2:-}"; shift 2 ;;
    -t|--token)      TOKEN="${2:-}"; shift 2 ;;
    -e|--env-file)   ENV_FILE="${2:-}"; shift 2 ;;
    -j|--jobs)       JOBS="${2:-}"; shift 2 ;;
    -s|--ssh)        USE_SSH=1; shift ;;
    -f|--forks)      INCLUDE_FORKS=1; shift ;;
    -a|--archived)   INCLUDE_ARCHIVED=1; shift ;;
    -F|--no-framework) DETECT_FRAMEWORK=0; shift ;;
    --shallow)       SHALLOW=1; shift ;;
    -N|--dry-run)    DRY_RUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

[[ -n "$NAME" ]] || { usage >&2; die "--name is required"; }

# Token precedence: -t flag > GITHUB_TOKEN/GH_TOKEN env var > .env file
if [[ -z "$TOKEN" ]]; then
  for envf in "$ENV_FILE" "./.env" "$(dirname "${BASH_SOURCE[0]}")/.env"; do
    [[ -n "$envf" ]] || continue
    if load_env_token "$envf"; then log "Token loaded from $envf"; break; fi
  done
  if [[ -z "$TOKEN" && -n "$ENV_FILE" ]]; then
    warn "No GITHUB_TOKEN/GH_TOKEN found in $ENV_FILE"
  fi
fi
[[ "$CNTX" == "users" || "$CNTX" == "orgs" ]] || die "--context must be 'users' or 'orgs'"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
for bin in curl jq git; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but not installed"
done

mkdir -p "$DEST" || die "Cannot create destination: $DEST"
DEST="$(cd "$DEST" && pwd)"
TMP_ROOT="$(mktemp -d "$DEST/.clone-tmp.XXXXXX")" || die "Cannot create temp dir"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ------------------------- framework detection -----------------------------
# has_dep FILE REGEX -> true if FILE exists and matches REGEX (case-insens.)
has_dep() { [[ -f "$1" ]] && grep -qiE "$2" "$1" 2>/dev/null; }

# First manifest found at root or up to 2 levels deep (monorepos / subfolders).
find_manifest() {
  local dir="$1" name="$2"
  find "$dir" -maxdepth 3 -name "$name" \
    -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.git/*' \
    2>/dev/null | head -n 1
}

detect_framework() {
  local dir="$1" lang="$2" f

  # --- JavaScript / TypeScript -------------------------------------------
  f="$(find_manifest "$dir" package.json)"
  if [[ -n "$f" ]]; then
    local pairs=(
      '"next"|Next.js'            '"nuxt"|Nuxt'            '"gatsby"|Gatsby'
      '"@remix-run/[a-z-]+"|Remix' '"astro"|Astro'         '"@sveltejs/kit"|SvelteKit'
      '"@angular/core"|Angular'   '"react-native"|React-Native' '"expo"|Expo'
      '"@nestjs/core"|NestJS'     '"electron"|Electron'    '"react"|React'
      '"vue"|Vue'                 '"svelte"|Svelte'        '"solid-js"|SolidJS'
      '"express"|Express'         '"fastify"|Fastify'      '"koa"|Koa'
      '"@hapi/hapi"|Hapi'
    )
    local p
    for p in "${pairs[@]}"; do
      if has_dep "$f" "\"?${p%%|*}\"?[[:space:]]*:" || has_dep "$f" "${p%%|*}"; then
        printf '%s' "${p##*|}"; return
      fi
    done
  fi

  # --- Python -------------------------------------------------------------
  local pyfiles=() m
  for m in requirements.txt pyproject.toml Pipfile setup.py setup.cfg; do
    f="$(find_manifest "$dir" "$m")"; [[ -n "$f" ]] && pyfiles+=("$f")
  done
  for f in "${pyfiles[@]:-}"; do
    [[ -n "$f" ]] || continue
    has_dep "$f" '(^|[^a-z])django([^a-z]|$)'    && { printf 'Django'; return; }
    has_dep "$f" '(^|[^a-z])fastapi([^a-z]|$)'   && { printf 'FastAPI'; return; }
    has_dep "$f" '(^|[^a-z])flask([^a-z]|$)'     && { printf 'Flask'; return; }
    has_dep "$f" '(^|[^a-z])pyramid([^a-z]|$)'   && { printf 'Pyramid'; return; }
    has_dep "$f" '(^|[^a-z])tornado([^a-z]|$)'   && { printf 'Tornado'; return; }
    has_dep "$f" '(^|[^a-z])streamlit([^a-z]|$)' && { printf 'Streamlit'; return; }
    has_dep "$f" '(^|[^a-z])scrapy([^a-z]|$)'    && { printf 'Scrapy'; return; }
  done

  # --- PHP ----------------------------------------------------------------
  f="$(find_manifest "$dir" composer.json)"
  if [[ -n "$f" ]]; then
    has_dep "$f" 'laravel/framework' && { printf 'Laravel'; return; }
    has_dep "$f" 'symfony/'          && { printf 'Symfony'; return; }
    has_dep "$f" 'cakephp/'          && { printf 'CakePHP'; return; }
    has_dep "$f" 'codeigniter'       && { printf 'CodeIgniter'; return; }
    has_dep "$f" 'slim/slim'         && { printf 'Slim'; return; }
  fi

  # --- Ruby ---------------------------------------------------------------
  f="$(find_manifest "$dir" Gemfile)"
  if [[ -n "$f" ]]; then
    has_dep "$f" "gem ['\"]rails['\"]"   && { printf 'Rails'; return; }
    has_dep "$f" "gem ['\"]sinatra['\"]" && { printf 'Sinatra'; return; }
    has_dep "$f" "gem ['\"]hanami"       && { printf 'Hanami'; return; }
  fi

  # --- Java / Kotlin ------------------------------------------------------
  for m in pom.xml build.gradle build.gradle.kts; do
    f="$(find_manifest "$dir" "$m")"
    [[ -n "$f" ]] || continue
    has_dep "$f" 'spring-boot|org\.springframework' && { printf 'Spring'; return; }
    has_dep "$f" 'io\.quarkus'                      && { printf 'Quarkus'; return; }
    has_dep "$f" 'io\.micronaut'                    && { printf 'Micronaut'; return; }
    has_dep "$f" 'com\.android\.'                   && { printf 'Android'; return; }
  done

  # --- Go -----------------------------------------------------------------
  f="$(find_manifest "$dir" go.mod)"
  if [[ -n "$f" ]]; then
    has_dep "$f" 'gin-gonic/gin'        && { printf 'Gin'; return; }
    has_dep "$f" 'labstack/echo'        && { printf 'Echo'; return; }
    has_dep "$f" 'gofiber/fiber'        && { printf 'Fiber'; return; }
    has_dep "$f" 'go-chi/chi'           && { printf 'Chi'; return; }
    has_dep "$f" 'gorilla/mux'          && { printf 'Gorilla'; return; }
  fi

  # --- Rust ---------------------------------------------------------------
  f="$(find_manifest "$dir" Cargo.toml)"
  if [[ -n "$f" ]]; then
    has_dep "$f" '^\s*actix-web'  && { printf 'Actix'; return; }
    has_dep "$f" '^\s*axum'       && { printf 'Axum'; return; }
    has_dep "$f" '^\s*rocket'     && { printf 'Rocket'; return; }
    has_dep "$f" '^\s*tauri'      && { printf 'Tauri'; return; }
    has_dep "$f" '^\s*bevy'       && { printf 'Bevy'; return; }
  fi

  # --- Dart / Flutter -----------------------------------------------------
  f="$(find_manifest "$dir" pubspec.yaml)"
  has_dep "$f" 'flutter:' 2>/dev/null && { printf 'Flutter'; return; }

  # --- C# / .NET ----------------------------------------------------------
  f="$(find "$dir" -maxdepth 3 -name '*.csproj' -not -path '*/.git/*' 2>/dev/null | head -n 1)"
  if [[ -n "$f" ]]; then
    has_dep "$f" 'Microsoft\.NET\.Sdk\.Web|Microsoft\.AspNetCore' && { printf 'ASP.NET'; return; }
    has_dep "$f" 'Blazor'                                         && { printf 'Blazor'; return; }
  fi

  # --- Elixir -------------------------------------------------------------
  f="$(find_manifest "$dir" mix.exs)"
  has_dep "$f" ':phoenix' 2>/dev/null && { printf 'Phoenix'; return; }

  # --- Swift --------------------------------------------------------------
  f="$(find_manifest "$dir" Package.swift)"
  has_dep "$f" 'vapor' 2>/dev/null && { printf 'Vapor'; return; }

  # nothing found
  return 0
}

# --------------------------- fetch repo list -------------------------------
curl_api() {
  local url="$1"
  local args=(-sS -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  [[ -n "$TOKEN" ]] && args+=(-H "Authorization: Bearer $TOKEN")
  curl "${args[@]}" "$url"
}

fetch_repos() {
  # Emits TSV: language \t name \t clone_url \t fork \t archived
  local page=1 resp count
  local endpoint="$API/$CNTX/$NAME/repos?sort=full_name"

  # /users/NAME/repos only lists PUBLIC repos, even with a token. To get your
  # own private repos, use /user/repos, which needs the token to belong to NAME.
  if [[ "$CNTX" == "users" && -n "$TOKEN" ]]; then
    local me
    me="$(curl_api "$API/user" | jq -r '.login // empty' 2>/dev/null)"
    if [[ -n "$me" && "${me,,}" == "${NAME,,}" ]]; then
      endpoint="$API/user/repos?affiliation=owner&visibility=all"
      log "Authenticated as $me: including private repos"
    else
      warn "Token does not belong to '$NAME' (or is invalid): only public repos will be listed"
    fi
  fi

  while :; do
    resp="$(curl_api "$endpoint&page=$page&per_page=$PER_PAGE")" \
      || die "Request to GitHub failed"

    if jq -e 'type == "object" and has("message")' >/dev/null 2>&1 <<<"$resp"; then
      die "GitHub API: $(jq -r '.message' <<<"$resp")"
    fi

    count="$(jq 'length' <<<"$resp")"
    [[ "$count" -eq 0 ]] && break

    if [[ "$USE_SSH" -eq 1 ]]; then
      jq -r '.[] | [(.language // "Other"), .name, .ssh_url, .fork, .archived] | @tsv' <<<"$resp"
    else
      jq -r '.[] | [(.language // "Other"), .name, .clone_url, .fork, .archived] | @tsv' <<<"$resp"
    fi

    [[ "$count" -lt "$PER_PAGE" ]] && break
    page=$((page + 1))
  done
}

# ------------------------------ clone one ----------------------------------
clone_one() {
  local lang="$1" repo="$2" url="$3"
  local lang_dir; lang_dir="$(sanitize "$lang")"; [[ -n "$lang_dir" ]] || lang_dir="Other"
  local repo_dir; repo_dir="$(sanitize "$repo")"

  # Already cloned somewhere under this language? Skip.
  if compgen -G "$DEST/$lang_dir/$repo_dir" >/dev/null || \
     compgen -G "$DEST/$lang_dir/*/$repo_dir" >/dev/null; then
    log "SKIP   $lang_dir/$repo_dir (already exists)"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRYRUN $repo  ->  $lang_dir/[framework]/$repo_dir"
    return 0
  fi

  local tmp="$TMP_ROOT/$repo_dir"
  local git_args=(clone --quiet)
  [[ "$SHALLOW" -eq 1 ]] && git_args+=(--depth 1)

  local git_cmd=(git)
  if [[ -n "$TOKEN" && "$USE_SSH" -eq 0 ]]; then
    local b64; b64="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
    git_cmd+=(-c "http.extraHeader=Authorization: Basic $b64")
  fi

  if ! "${git_cmd[@]}" "${git_args[@]}" "$url" "$tmp" 2>/dev/null; then
    warn "FAILED to clone $repo"
    rm -rf "$tmp"
    return 1
  fi

  local fw=""
  [[ "$DETECT_FRAMEWORK" -eq 1 ]] && fw="$(sanitize "$(detect_framework "$tmp" "$lang")")"

  local target="$DEST/$lang_dir"
  [[ -n "$fw" ]] && target="$target/$fw"
  mkdir -p "$target"
  mv "$tmp" "$target/$repo_dir"
  log "OK     $repo  ->  ${target#"$DEST"/}/$repo_dir"
}

# --------------------------------- main ------------------------------------
log "Fetching repo list for $CNTX/$NAME ..."
mapfile -t ROWS < <(fetch_repos)
TOTAL=${#ROWS[@]}
[[ "$TOTAL" -gt 0 ]] || { log "No repositories found."; exit 0; }
log "Found $TOTAL repositories. Destination: $DEST (jobs: $JOBS)"

running=0; selected=0
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r lang repo url is_fork is_archived <<<"$row"

  [[ "$is_fork" == "true"     && "$INCLUDE_FORKS"    -eq 0 ]] && { log "SKIP   $repo (fork)"; continue; }
  [[ "$is_archived" == "true" && "$INCLUDE_ARCHIVED" -eq 0 ]] && { log "SKIP   $repo (archived)"; continue; }

  selected=$((selected + 1))
  clone_one "$lang" "$repo" "$url" &
  running=$((running + 1))
  if [[ "$running" -ge "$JOBS" ]]; then
    wait -n || true
    running=$((running - 1))
  fi
done
wait

log "Done. Processed $selected of $TOTAL repositories."
