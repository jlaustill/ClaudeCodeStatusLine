#!/bin/bash
# Behavior checks for statusline.sh. Builds fixture transcripts and a fixture
# model catalog in a temporary CLAUDE_CONFIG_DIR, so it makes no network calls
# and never touches the real usage cache.
# Usage: tests/statusline_test.sh [path/to/statusline.sh]
# Exit status = number of failed checks.

script="${1:-$(cd "$(dirname "$0")/.." && pwd)/statusline.sh}"
[ -x "$script" ] || { echo "not executable: $script" >&2; exit 99; }

work=$(mktemp -d)
config_dir="$work/config"
usage_cache="/tmp/claude/statusline-usage-cache-$(printf '%s' "$config_dir" | sha256sum | cut -c1-8).json"
trap 'rm -rf "$work"; rm -f "$usage_cache"' EXIT

mkdir -p "$config_dir/cache/model-catalog"
cat > "$config_dir/cache/model-catalog/fixture-cc.json" <<'EOF'
{"catalog":{"config":{"models":[
  {"id":"claude-opus-5-5","name":"Opus 5.5"},
  {"id":"claude-fable-5-2","name":"Fable 5.2"},
  {"id":"claude-sonnet-5-5","name":"Sonnet 5.5"}]}}}
EOF

# ===== Fixture transcript entries, in the key order Claude Code writes =====
# shape <hash> [advisor model id]: the tools a request sent; no model = no advisor tool
shape() {
    local tools='{"name":"Agent"}'
    [ -n "$2" ] && tools+=",{\"name\":\"advisor\",\"model\":\"$2\",\"defer_loading\":true}"
    printf '{"type":"api-request-shape","sessionId":"s1","shapeHash":"%s","timestamp":"2026-11-22T00:00:00.000Z","version":"2.1.330","shape":{"system":[],"tools":[%s]}}\n' \
        "$1" "$tools"
}
# request <hash> [querySource]: one API request that used that shape
request() {
    printf '{"type":"api-request","sessionId":"s1","id":"r1","timestamp":"2026-11-22T00:00:01.000Z","version":"2.1.330","querySource":"%s","shapeHash":"%s","params":{"model":"claude-opus-5-5"}}\n' \
        "${2:-repl_main_thread}" "$1"
}
chat() { printf '{"type":"user","message":{"role":"user","content":"hello"}}\n'; }

{ chat; shape aa11 claude-fable-5-2; request aa11; } > "$work/advisor-on.jsonl"
{ chat; shape bb22; request bb22; } > "$work/advisor-off.jsonl"
# Shapes are written once per hash, so switching back reuses an earlier shape
{ shape aa11 claude-fable-5-2; request aa11; shape cc33 claude-sonnet-5-5; request cc33; request aa11; } > "$work/switch-back.jsonl"
{ shape aa11 claude-fable-5-2; request aa11; shape bb22; request bb22 agent:builtin:general-purpose; } > "$work/subagent-last.jsonl"
{ shape cc33 claude-sonnet-5-5; request cc33 repl_main_thread:outputStyle:Concise; } > "$work/style-suffix.jsonl"
{ shape aa11 claude-fable-5-2; request dd44; } > "$work/unresolved.jsonl"
{ chat; } > "$work/fresh.jsonl"
{ shape ee55 claude-fable-9-9; request ee55; } > "$work/unknown-id.jsonl"

# ===== Rendering =====
base='"model":{"display_name":"Opus 5.5"},"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000}},"effort":{"level":"max"}'
base_1m=${base/'"Opus 5.5"'/'"Opus 5.5 (1M context)"'}
render_raw() {
    printf '{%s}' "$1" | CLAUDE_CONFIG_DIR="$config_dir" STATUSLINE_CHECK_UPDATES=false "$script"
}
render() { render_raw "$1" | sed -E 's/\x1b\[[0-9;]*m//g'; }
with_transcript() { render "\"transcript_path\":\"$work/$1\",$base"; }

failures=0
expect_prefix() { # description, expected prefix, actual output
    if [[ "$3" == "$2"* ]]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1"
        echo "      want prefix: $2"
        echo "      got:         $3"
        failures=$((failures + 1))
    fi
}
expect_contains() { # description, expected substring, actual output
    if [[ "$3" == *"$2"* ]]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1"
        echo "      want: ...$2..."
        echo "      got:  $3"
        failures=$((failures + 1))
    fi
}

# ===== Advisor model =====
expect_prefix "advisor shown in parentheses after the model" \
    "Opus 5.5(Fable 5.2) (max) | tmp | " "$(with_transcript advisor-on.jsonl)"
expect_prefix "no advisor tool in the request: nothing shown" \
    "Opus 5.5 (max) | tmp | " "$(with_transcript advisor-off.jsonl)"
expect_prefix "switching back to an earlier advisor reuses its recorded shape" \
    "Opus 5.5(Fable 5.2) (max) | " "$(with_transcript switch-back.jsonl)"
expect_prefix "subagent requests are ignored" \
    "Opus 5.5(Fable 5.2) (max) | " "$(with_transcript subagent-last.jsonl)"
expect_prefix "main-thread request with an output style suffix counts" \
    "Opus 5.5(Sonnet 5.5) (max) | " "$(with_transcript style-suffix.jsonl)"
expect_prefix "request whose shape is not in the transcript: nothing shown" \
    "Opus 5.5 (max) | " "$(with_transcript unresolved.jsonl)"
expect_prefix "session with no request yet: nothing shown" \
    "Opus 5.5 (max) | " "$(with_transcript fresh.jsonl)"
expect_prefix "model missing from the catalog: show its ID" \
    "Opus 5.5(claude-fable-9-9) (max) | " "$(with_transcript unknown-id.jsonl)"
expect_prefix "missing transcript file: nothing shown" \
    "Opus 5.5 (max) | " "$(with_transcript no-such-file.jsonl)"
expect_prefix "named 1M-context session keeps its layout" \
    "demo | Opus 5.5 1M(Fable 5.2) (max) | " \
    "$(render "\"session_name\":\"demo\",\"transcript_path\":\"$work/advisor-on.jsonl\",$base_1m")"
no_path=$(render_raw "$base")
empty_path=$(render_raw "\"transcript_path\":\"\",$base")
if [ "$no_path" = "$empty_path" ]; then echo "PASS  empty transcript_path renders like none"; else
    echo "FAIL  empty transcript_path renders like none"; failures=$((failures + 1)); fi
expect_prefix "no transcript_path: line unchanged" \
    "Opus 5.5 (max) | tmp | 33k/200k (16%)" "$(printf '%s' "$no_path" | sed -E 's/\x1b\[[0-9;]*m//g')"

# ===== Session name =====
expect_prefix "named session shows its name first" "demo | Opus 5.5 (max) | " "$(render "\"session_name\":\"demo\",$base")"
expect_prefix "unnamed session starts at the model" "Opus 5.5 (max) | " "$(render "$base")"

# ===== Usage pace (rate limits on stdin, each window exactly half elapsed) =====
now=$(date +%s)
limits=$(printf '"rate_limits":{"five_hour":{"used_percentage":75,"resets_at":%d},"seven_day":{"used_percentage":25,"resets_at":%d}}' \
    $((now + 9000)) $((now + 302400)))
paced=$(render "$base,$limits")
expect_contains "5h pace: 75% used at half window -> (50%)" "5h 75%(50%) @" "$paced"
expect_contains "7d pace: 25% used at half window -> (-50%)" "7d 25%(-50%) @" "$paced"

exit "$failures"
