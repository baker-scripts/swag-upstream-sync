#!/bin/bash
set -euo pipefail

# upstream-diff.sh — Smart diff of local nginx configs against upstream samples
# Filters known customizations, flags genuine upstream changes.
#
# Usage: upstream-diff.sh <upstream-dir> [--config-dir <dir>] [--map <file>] [--stock-dir <dir>]... [--output-json]
# Exit codes: 0 = no actionable changes, 1 = has changes, 2 = error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# --- Configuration ---
OUTPUT_JSON=false
UPSTREAM_DIR=""
CONFIG_DIR="."
MAP_FILE="${SCRIPT_DIR}/upstream-map.conf"

# Counters
declare -i TOTAL_CHECKED=0
declare -i TOTAL_NO_UPSTREAM=0
declare -i TOTAL_REDIRECT=0
declare -i TOTAL_CLEAN=0
declare -i TOTAL_FORKED=0
declare -i TOTAL_ACTIONABLE=0
declare -i TOTAL_ALLOWLISTED=0
declare -i TOTAL_STOCK_CHECKED=0
declare -i TOTAL_STOCK_STALE=0

# Stock-conf clones (docker-swag, docker-baseimage-alpine-nginx) and report body
declare -a STOCK_DIRS=()
STOCK_BODY=""
# Local file being compared; lets is_known_customization check absence locally
CURRENT_LOCAL_NORM=""

# Accumulate markdown output
MARKDOWN_BODY=""
# Accumulate JSON entries
JSON_ENTRIES=""

# --- Argument parsing ---
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-json)
        OUTPUT_JSON=true
        ;;
      --config-dir)
        [[ $# -ge 2 ]] || { printf "--config-dir needs a directory\n" >&2; exit 2; }
        CONFIG_DIR="$2"
        shift
        ;;
      --map)
        [[ $# -ge 2 ]] || { printf "--map needs a file\n" >&2; exit 2; }
        MAP_FILE="$2"
        shift
        ;;
      --stock-dir)
        [[ $# -ge 2 ]] || {
          printf "--stock-dir needs a directory\n" >&2
          exit 2
        }
        STOCK_DIRS+=("$2")
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      -*)
        printf "Unknown option: %s\n" "$1" >&2
        usage >&2
        exit 2
        ;;
      *)
        if [[ -z "$UPSTREAM_DIR" ]]; then
          UPSTREAM_DIR="$1"
        else
          printf "Unexpected argument: %s\n" "$1" >&2
          usage >&2
          exit 2
        fi
        ;;
    esac
    shift
  done

  if [[ -z "$UPSTREAM_DIR" ]]; then
    printf "Error: upstream directory required\n" >&2
    usage >&2
    exit 2
  fi

  if [[ ! -d "$UPSTREAM_DIR" ]]; then
    printf "Error: upstream directory does not exist: %s\n" "$UPSTREAM_DIR" >&2
    exit 2
  fi
}

usage() {
  cat <<'USAGE'
Usage: upstream-diff.sh <upstream-dir> [--config-dir <dir>] [--map <file>] [--stock-dir <dir>]... [--output-json]

Compare local nginx proxy configs against upstream linuxserver samples.
Filters known customizations and reports only genuine upstream changes.
With --stock-dir (a docker-swag or docker-baseimage-alpine-nginx clone),
also compares the forked stock confs listed as stock: lines in
upstream-map.conf by "## Version" date.

Options:
  --stock-dir DIR Clone holding root/defaults/nginx/*.sample (repeatable)
  --output-json   Output results as JSON instead of markdown
  --help, -h      Show this help

Exit codes:
  0  No actionable changes found
  1  Actionable changes found (needs review)
  2  Error
USAGE
}

# --- Upstream name mapping ---
# Load alias map: local_name=upstream_name
declare -A UPSTREAM_MAP
declare -A IGNORE_MAP
declare -a STOCK_LIST=()
load_upstream_map() {
  local mapfile="$MAP_FILE"
  if [[ -f "$mapfile" ]]; then
    while IFS='=' read -r local_name upstream_name; do
      # Skip comments and blank lines
      [[ -z "$local_name" || "$local_name" =~ ^# ]] && continue
      # ignore:<key>=<reason> suppresses an intentional rewrite
      if [[ "$local_name" == ignore:* ]]; then
        IGNORE_MAP["${local_name#ignore:}"]="$upstream_name"
        continue
      fi
      # stock:<path under config/>=<sample path under root/defaults/nginx>
      if [[ "$local_name" == stock:* ]]; then
        STOCK_LIST+=("${local_name#stock:}=${upstream_name}")
        continue
      fi
      local_name="${local_name%%[[:space:]]*}"
      upstream_name="${upstream_name%%[[:space:]]*}"
      upstream_name="${upstream_name##[[:space:]]}"
      UPSTREAM_MAP["$local_name"]="$upstream_name"
    done <"$mapfile"
  fi
}

# Resolve upstream sample path: check exact match first, then alias map
resolve_upstream_sample() {
  local basename="$1"
  local exact="${UPSTREAM_DIR}/${basename}.sample"
  if [[ -f "$exact" ]]; then
    printf '%s' "$exact"
    return 0
  fi

  # Check alias map
  local mapped="${UPSTREAM_MAP[$basename]:-}"
  if [[ -n "$mapped" ]]; then
    local alias_path="${UPSTREAM_DIR}/${mapped}.sample"
    if [[ -f "$alias_path" ]]; then
      printf '%s' "$alias_path"
      return 0
    fi
  fi

  # Strip our per-domain infix (<app>.subdomain.app.conf ->
  # <app>.subdomain.conf) so per-subdomain vhosts still match the
  # domain-agnostic upstream sample. Without this, every .app/.xyz
  # vhost was silently uncompared ("without upstream sample").
  local norm=""
  # <app>.subdomain.<label>.conf -> <app>.subdomain.conf
  norm="$(printf '%s' "$basename" | sed -E 's/\.(subdomain|subfolder)\.[^.]+\.conf$/.\1.conf/')"
  [[ "$norm" == "$basename" ]] && norm=""

  if [[ -n "$norm" && -f "${UPSTREAM_DIR}/${norm}.sample" ]]; then
    printf '%s' "${UPSTREAM_DIR}/${norm}.sample"
    return 0
  fi

  return 1
}

# --- Fuzzy match for unmatched configs ---
# Accumulate unmatched configs for fuzzy reporting
declare -a UNMATCHED_CONFIGS=()

fuzzy_match_report() {
  if [[ ${#UNMATCHED_CONFIGS[@]} -eq 0 ]]; then
    return
  fi

  local fuzzy_body=""
  local fuzzy_count=0

  for conf_path in "${UNMATCHED_CONFIGS[@]}"; do
    local bn
    bn="$(basename "$conf_path")"
    # Extract service name (strip .subdomain/.subfolder.conf)
    local svc
    svc="$(printf '%s' "$bn" | sed 's/\.\(subdomain\|subfolder\)\.conf$//')"

    # Skip very short names (risk of false positives)
    [[ ${#svc} -lt 3 ]] && continue

    # Search upstream samples for partial match
    local matches
    matches="$(find "${UPSTREAM_DIR}" -maxdepth 1 -name '*.sample' -print0 2>/dev/null \
      | xargs -0 -I {} basename {} .sample \
      | grep -i "$svc" \
      | head -5 \
      | tr '\n' ', ' \
      | sed 's/,$//')"

    if [[ -n "$matches" ]]; then
      fuzzy_body+="| \`${bn}\` | ${matches} |"$'\n'
      fuzzy_count=$((fuzzy_count + 1))
    fi
  done

  if [[ $fuzzy_count -gt 0 && "$OUTPUT_JSON" == "false" ]]; then
    printf '\n## Potential Upstream Matches (Fuzzy)\n\n'
    printf 'These configs have no exact upstream match but their service name partially matches upstream samples.\n'
    printf $'Add confirmed mappings to the map file to enable diff tracking.\n\n'
    printf '| Our Config | Possible Upstream |\n'
    printf '|---|---|\n'
    printf '%s' "$fuzzy_body"
    printf '\n'
  fi
}

# --- Known customization patterns ---
# Returns 0 if the diff line is a known customization that should be filtered.
# Called with a direction parameter: "removed" for - lines, "added" for + lines.
is_known_customization() {
  local line="$1"
  local direction="$2" # "removed" or "added"

  # Strip leading diff marker (+/-) and whitespace for matching
  local content
  content="${line#[+-]}"
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"

  # Empty or comment-only lines — always skip
  [[ -z "$content" ]] && return 0
  [[ "$content" =~ ^# ]] && return 0

  # --- Patterns for ADDED lines (+ lines = our customizations, always skip) ---
  if [[ "$direction" == "added" ]]; then
    return 0
  fi

  # --- Patterns for REMOVED lines (- lines = upstream content we might be missing) ---
  # Filter upstream template boilerplate and directive types we always customize.
  # Genuinely novel directive types (not matching any pattern) will still be caught.

  # server_name (upstream uses wildcards like app.*, we use specific domains)
  [[ "$content" =~ ^server_name[[:space:]] ]] && return 0

  # Upstream auth boilerplate (commented-out options we strip when enabling specific auth)
  [[ "$content" =~ ^#include.*/config/nginx/(ldap|authelia|authentik|tinyauth) ]] && return 0
  [[ "$content" =~ ^#auth_basic ]] && return 0
  [[ "$content" =~ ^auth_basic[[:space:]] ]] && return 0
  [[ "$content" =~ ^auth_basic_user_file ]] && return 0

  # Structural tokens
  [[ "$content" == "}" ]] && return 0
  [[ "$content" == "{" ]] && return 0

  # Upstream location blocks and these directives are actionable when absent
  # locally; a differing local value or an identical local line is a customization.
  if [[ "$content" =~ ^location[[:space:]] ]]; then
    local norm_loc
    norm_loc="$(printf '%s' "$content" | tr -s '[:space:]' ' ')"
    grep -qxF -- "$norm_loc" <<<"$CURRENT_LOCAL_NORM" && return 0
    return 1
  fi
  if [[ "$content" =~ ^(client_max_body_size|proxy_buffering)[[:space:]] ]]; then
    grep -qE "^${BASH_REMATCH[1]}[[:space:]]" <<<"$CURRENT_LOCAL_NORM" && return 0
    return 1
  fi

  # listen directives (QUIC variants)
  [[ "$content" =~ ^listen[[:space:]] ]] && return 0

  # Standard includes
  [[ "$content" =~ include.*/config/nginx/ssl\.conf ]] && return 0
  [[ "$content" =~ include.*/config/nginx/proxy\.conf ]] && return 0
  [[ "$content" =~ include.*/config/nginx/resolver\.conf ]] && return 0

  # set $upstream_* (app, port, proto — we always customize these)
  [[ "$content" =~ ^set[[:space:]]+\$upstream_ ]] && return 0

  # proxy_pass (standard form always follows set directives)
  [[ "$content" =~ ^proxy_pass[[:space:]] ]] && return 0

  # Proxy tuning directives
  [[ "$content" =~ ^proxy_redirect[[:space:]] ]] && return 0
  [[ "$content" =~ ^proxy_buffer ]] && return 0
  [[ "$content" =~ ^proxy_busy_buffers_size ]] && return 0

  # proxy_set_header (we add/remove various headers)
  [[ "$content" =~ ^proxy_set_header[[:space:]] ]] && return 0

  # return / rewrite (routing customizations)
  [[ "$content" =~ ^return[[:space:]] ]] && return 0
  [[ "$content" =~ ^rewrite[[:space:]] ]] && return 0

  # Not a known customization — flag it
  return 1
}

# --- Version comparison ---
# Extracts version string from config file (## Version YYYY/MM/DD)
get_version() {
  local file="$1"
  grep -oP '^## Version \K\d{4}/\d{2}/\d{2}' "$file" 2>/dev/null || printf "unknown"
}

# Compare version strings (YYYY/MM/DD format).
# Prints: "equal", "newer" (v1 > v2), "older" (v1 < v2), or "unknown"
compare_versions() {
  local v1="$1" v2="$2"
  if [[ "$v1" == "unknown" || "$v2" == "unknown" ]]; then
    printf "unknown"
    return
  fi
  if [[ "$v1" == "$v2" ]]; then
    printf "equal"
  elif [[ "$v1" > "$v2" ]]; then
    printf "newer"
  else
    printf "older"
  fi
}

# --- Detect redirect-only configs (no proxy_pass; only return 30x) ---
is_redirect_only() {
  local conf="$1"
  # Has return 301 or 302 directive
  grep -qE '^\s*return\s+30[12]\b' "$conf" || return 1
  # And does NOT have proxy_pass or set $upstream_*
  # shellcheck disable=SC2016  # regex pattern; $ is literal in grep, not shell expansion
  if grep -qE '^\s*proxy_pass\b|^\s*set\s+\$upstream_' "$conf"; then
    return 1
  fi
  return 0
}

# --- Process a single config ---
process_config() {
  local conf="$1"
  local basename
  basename="$(basename "$conf")"
  local server_dir
  server_dir="$(basename "$(dirname "$(dirname "$conf")")")"
  local conf_dir_name
  conf_dir_name="$(basename "$(dirname "$conf")")"

  TOTAL_CHECKED=$((TOTAL_CHECKED + 1))

  # Allowlisted intentional rewrite (reason lives in upstream-map.conf)
  if [[ -n "${IGNORE_MAP[$basename]:-}" ]]; then
    TOTAL_ALLOWLISTED=$((TOTAL_ALLOWLISTED + 1))
    return 0
  fi

  # Skip redirect-only configs (no upstream to compare; intentional legacy 301s)
  if is_redirect_only "$conf"; then
    TOTAL_REDIRECT=$((TOTAL_REDIRECT + 1))
    return 0
  fi

  # Resolve upstream sample (exact match or alias map)
  local sample
  if ! sample="$(resolve_upstream_sample "$basename")"; then
    TOTAL_NO_UPSTREAM=$((TOTAL_NO_UPSTREAM + 1))
    UNMATCHED_CONFIGS+=("$conf")
    return 0
  fi

  # Get versions
  local local_version upstream_version version_cmp
  local_version="$(get_version "$conf")"
  upstream_version="$(get_version "$sample")"
  version_cmp="$(compare_versions "$local_version" "$upstream_version")"

  CURRENT_LOCAL_NORM="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]\+/ /g' -e 's/ $//' "$conf")"

  # Run diff (upstream is "old", local is "new")
  local raw_diff
  raw_diff="$(diff -u "$sample" "$conf" 2>/dev/null || true)"

  # No diff at all — identical
  if [[ -z "$raw_diff" ]]; then
    TOTAL_CLEAN=$((TOTAL_CLEAN + 1))
    return 0
  fi

  # Classify changed lines — only - lines (upstream content we might be missing) are actionable
  local has_actionable=false

  while IFS= read -r line; do
    # Skip diff headers
    [[ "$line" =~ ^--- ]] && continue
    [[ "$line" =~ ^\+\+\+ ]] && continue
    [[ "$line" =~ ^@@ ]] && continue

    # Determine direction
    if [[ "$line" =~ ^\- ]]; then
      if ! is_known_customization "$line" "removed"; then
        has_actionable=true
        break
      fi
    elif [[ "$line" =~ ^\+ ]]; then
      # + lines are our additions — always skip for actionable detection
      continue
    fi
  done <<<"$raw_diff"

  if [[ "$has_actionable" == "false" ]]; then
    if [[ "$version_cmp" == "newer" ]]; then
      TOTAL_FORKED=$((TOTAL_FORKED + 1))
    else
      TOTAL_CLEAN=$((TOTAL_CLEAN + 1))
    fi
    return 0
  fi

  # We have actionable changes
  TOTAL_ACTIONABLE=$((TOTAL_ACTIONABLE + 1))

  local version_note=""
  case "$version_cmp" in
    older)
      version_note=" — upstream updated (local: ${local_version}, upstream: ${upstream_version})"
      ;;
    newer)
      version_note=" — forked (local: ${local_version}, upstream: ${upstream_version})"
      ;;
    unknown)
      version_note=" — version unknown"
      ;;
  esac

  # Build filtered diff — show only hunks with actionable - lines
  local filtered_diff
  filtered_diff="$(build_filtered_diff "$raw_diff")"

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    local json_entry
    json_entry="$(
      cat <<JSONEOF
{
  "config": "${basename}",
  "server": "${server_dir}",
  "dir": "${conf_dir_name}",
  "local_version": "${local_version}",
  "upstream_version": "${upstream_version}",
  "version_status": "${version_cmp}",
  "has_actionable": true,
  "diff": $(printf '%s' "$filtered_diff" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '""')
}
JSONEOF
    )"
    if [[ -n "$JSON_ENTRIES" ]]; then
      JSON_ENTRIES+=","$'\n'
    fi
    JSON_ENTRIES+="$json_entry"
  else
    MARKDOWN_BODY+="### ${basename} (${server_dir}/${conf_dir_name})${version_note}"$'\n\n'
    MARKDOWN_BODY+='```diff'$'\n'
    MARKDOWN_BODY+="${filtered_diff}"$'\n'
    MARKDOWN_BODY+='```'$'\n\n'
  fi
}

# Build a filtered diff showing only hunks that contain actionable removed lines
build_filtered_diff() {
  local raw_diff="$1"

  local current_hunk=""
  local hunk_header=""
  local hunk_has_actionable=false
  local output=""

  while IFS= read -r line; do
    # Skip file headers
    [[ "$line" =~ ^--- ]] && continue
    [[ "$line" =~ ^\+\+\+ ]] && continue

    # New hunk starts
    if [[ "$line" =~ ^@@ ]]; then
      # Flush previous hunk if actionable
      if [[ "$hunk_has_actionable" == "true" && -n "$current_hunk" ]]; then
        output+="${hunk_header}"$'\n'
        output+="${current_hunk}"
      fi
      hunk_header="$line"
      current_hunk=""
      hunk_has_actionable=false
      continue
    fi

    # Accumulate hunk lines
    current_hunk+="${line}"$'\n'

    # Only - lines can be actionable (upstream content we're missing)
    if [[ "$line" =~ ^\- ]]; then
      if ! is_known_customization "$line" "removed"; then
        hunk_has_actionable=true
      fi
    fi
  done <<<"$raw_diff"

  # Flush last hunk
  if [[ "$hunk_has_actionable" == "true" && -n "$current_hunk" ]]; then
    output+="${hunk_header}"$'\n'
    output+="${current_hunk}"
  fi

  printf '%s' "$output"
}

# --- Stock confs (forked from docker-swag / docker-baseimage-alpine-nginx) ---
# Compares "## Version" dates only; a missing local header counts as stale.
process_stock() {
  local entry local_rel sample_rel local_file sample="" dir
  for entry in "${STOCK_LIST[@]}"; do
    local_rel="${entry%%=*}"
    sample_rel="${entry#*=}"
    TOTAL_STOCK_CHECKED=$((TOTAL_STOCK_CHECKED + 1))

    if [[ -n "${IGNORE_MAP[$local_rel]:-}" ]]; then
      TOTAL_ALLOWLISTED=$((TOTAL_ALLOWLISTED + 1))
      continue
    fi

    local_file="${CONFIG_DIR}/${local_rel}"
    [[ -f "$local_file" ]] || continue

    sample=""
    for dir in "${STOCK_DIRS[@]}"; do
      if [[ -f "${dir}/root/defaults/nginx/${sample_rel}" ]]; then
        sample="${dir}/root/defaults/nginx/${sample_rel}"
        break
      fi
    done
    if [[ -z "$sample" ]]; then
      printf 'Warning: no upstream sample for stock conf %s (%s)\n' "$local_rel" "$sample_rel" >&2
      continue
    fi

    local lv uv
    lv="$(get_version "$local_file")"
    uv="$(get_version "$sample")"
    if [[ "$lv" != "unknown" && "$(compare_versions "$lv" "$uv")" != "older" ]]; then
      continue
    fi

    TOTAL_STOCK_STALE=$((TOTAL_STOCK_STALE + 1))
    TOTAL_ACTIONABLE=$((TOTAL_ACTIONABLE + 1))
    local note="local header ${lv}, upstream ${uv}"
    [[ "$lv" == "unknown" ]] && note="no local ## Version header, upstream ${uv}"
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      if [[ -n "$JSON_ENTRIES" ]]; then
        JSON_ENTRIES+=","$'\n'
      fi
      JSON_ENTRIES+="{\"config\": \"${local_rel}\", \"kind\": \"stock\", \"local_version\": \"${lv}\", \"upstream_version\": \"${uv}\", \"has_actionable\": true}"
    else
      STOCK_BODY+="- \`config/${local_rel}\`: ${note} (upstream \`${sample_rel}\`)"$'\n'
    fi
  done
}

# --- Main ---
main() {
  parse_args "$@"
  load_upstream_map

  # Find all local configs to check. Production hosts expose a runtime
  # `servers -> config/servers` symlink, but a clean GitHub checkout only has
  # the tracked `config/servers` tree.
  local servers_root="$CONFIG_DIR"
  [[ -d "$servers_root" ]] || { printf 'Error: config dir not found: %s\n' "$servers_root" >&2; exit 2; }

  local configs=()
  while IFS= read -r -d '' conf; do
    configs+=("$conf")
  done < <(find "$servers_root" -type f \( -name '*.subdomain*.conf' -o -name '*.subfolder*.conf' \) -print0 2>/dev/null | sort -z)

  if [[ ${#configs[@]} -eq 0 ]]; then
    printf "No configs found to check.\n" >&2
    exit 2
  fi

  # Process each config
  for conf in "${configs[@]}"; do
    process_config "$conf"
  done

  if [[ ${#STOCK_DIRS[@]} -gt 0 ]]; then
    process_stock
  fi

  # Output results
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    cat <<JSONEOF
{
  "summary": {
    "total_checked": ${TOTAL_CHECKED},
    "no_upstream": ${TOTAL_NO_UPSTREAM},
    "forked": ${TOTAL_FORKED},
    "clean": ${TOTAL_CLEAN},
    "allowlisted": ${TOTAL_ALLOWLISTED},
    "stock_checked": ${TOTAL_STOCK_CHECKED},
    "stock_stale": ${TOTAL_STOCK_STALE},
    "actionable": ${TOTAL_ACTIONABLE}
  },
  "configs": [
${JSON_ENTRIES}
  ]
}
JSONEOF
  else
    # Markdown output
    if [[ $TOTAL_ACTIONABLE -gt 0 ]]; then
      printf '# SWAG Upstream Config Changes\n\n'
      printf '| Metric | Count |\n'
      printf '|--------|-------|\n'
      printf '| Configs checked | %d |\n' "$TOTAL_CHECKED"
      printf '| No upstream sample | %d |\n' "$TOTAL_NO_UPSTREAM"
      printf '| Forked (local version newer) | %d |\n' "$TOTAL_FORKED"
      printf '| Clean (customizations only) | %d |\n' "$TOTAL_CLEAN"
      printf '| Allowlisted (intentional rewrite) | %d |\n' "$TOTAL_ALLOWLISTED"
      printf '| Stock confs checked / stale | %d / %d |\n' "$TOTAL_STOCK_CHECKED" "$TOTAL_STOCK_STALE"
      printf '| **Actionable changes** | **%d** |\n\n' "$TOTAL_ACTIONABLE"
      if [[ -n "$STOCK_BODY" ]]; then
        printf '## Stock confs behind upstream\n\n%s\n' "$STOCK_BODY"
      fi
      printf '%s' "$MARKDOWN_BODY"
    else
      printf 'All %d configs are in sync (customizations filtered).\n' "$TOTAL_CHECKED"
      if [[ $TOTAL_FORKED -gt 0 ]]; then
        printf '  (%d forked, %d clean, %d without upstream sample)\n' \
          "$TOTAL_FORKED" "$TOTAL_CLEAN" "$TOTAL_NO_UPSTREAM"
      fi
    fi

    # Append fuzzy match suggestions for unmatched configs
    fuzzy_match_report
  fi

  # Exit code
  if [[ $TOTAL_ACTIONABLE -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
