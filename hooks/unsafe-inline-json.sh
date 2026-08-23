#!/usr/bin/env bash
# PreToolUse hook on Bash. Blocks brittle inline JSON parsing through
# node -e / python -c quoting and machine-readable JSON streams polluted by
# merged stderr, where fleet transcripts repeatedly show failures.
#
# The merged-stream check is STATEMENT-SCOPED (2026-08-23). It used to grep the
# whole tool input for three independent signals and AND them, with nothing
# tying the redirect to the command that produced the JSON and nothing telling
# shell syntax from prose. A safe script that silenced one command and, further
# down, wrote JSON to a file with stderr correctly separated was denied anyway:
# 97 distinct denials across ~30 sessions in one 24h fleet window, the highest
# single class measured. Documenting the guard also tripped it, so its own
# defects could not be filed.
#
# Now: heredoc bodies, comments and quoted strings are removed first, the input
# is split into statements, and a statement is only a hit when the merged stream
# IS the machine-readable stream and a parser actually consumes it -- in the
# same pipeline, or through a file a later parser reads.
#
# Card: hook-unsafe-inline-json-merged-stderr-false-positive-whole-command-scan
# Brain: papercut-agent-tooling-json-stderr-guard-matches-a-redirect-on-a-different-command
#        papercut-claude-unsafe-inline-json-hook-matches-prose-not-shell-syntax
set -u

input="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
[ -n "$cmd" ] || exit 0

emit_deny() {
  # Deny the tool call and surface the reason, but never halt the session:
  # "continue": false here killed entire agent turns on every violation
  # (Tom, 2026-07-18). Deny alone lets the agent retry compliantly.
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }' 2>/dev/null && exit 0
  printf '%s\n' "$reason" >&2
  exit 2
}

# Remove heredoc bodies and comments so document text is never read as shell
# syntax. mode=strip also blanks quoted-string contents, for matchers that only
# need command position; mode=keep preserves them, for matchers whose true
# positive lives inside the quotes (node -e "...JSON.parse...").
sanitize() {
  awk -v mode="$1" -v SQ="'" -v DQ='"' '
  function isword(ch) { return ch ~ /[A-Za-z0-9_]/ }
  {
    line = $0
    if (hd) {
      t = line
      sub(/^[ \t]+/, "", t)
      sub(/[ \t]+$/, "", t)
      if (t == hdword) { hd = 0; hdword = "" }
      print ""
      next
    }
    out = ""
    n = length(line)
    i = 1
    pending = ""
    while (i <= n) {
      c = substr(line, i, 1)
      if (q == 1) {
        if (c == SQ) q = 0
        out = out (mode == "strip" ? " " : c)
        i++
        continue
      }
      if (q == 2) {
        if (c == "\\") {
          out = out (mode == "strip" ? "  " : c substr(line, i + 1, 1))
          i += 2
          continue
        }
        if (c == DQ) q = 0
        out = out (mode == "strip" ? " " : c)
        i++
        continue
      }
      if (c == "\\") {
        out = out c substr(line, i + 1, 1)
        i += 2
        continue
      }
      if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(]/)) break
      if (c == SQ) { q = 1; out = out (mode == "strip" ? " " : c); i++; continue }
      if (c == DQ) { q = 2; out = out (mode == "strip" ? " " : c); i++; continue }
      if (c == "<" && substr(line, i + 1, 1) == "<") {
        if (substr(line, i + 2, 1) == "<") { out = out "   "; i += 3; continue }
        j = i + 2
        if (substr(line, j, 1) == "-") j++
        while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
        qc = ""
        ch = substr(line, j, 1)
        if (ch == SQ || ch == DQ) { qc = ch; j++ }
        w = ""
        while (j <= n) {
          ch = substr(line, j, 1)
          if (isword(ch)) { w = w ch; j++ } else break
        }
        if (qc != "" && substr(line, j, 1) == qc) j++
        if (w != "") { pending = w; out = out " "; i = j; continue }
        out = out "  "
        i += 2
        continue
      }
      out = out c
      i++
    }
    print out
    if (pending != "") { hd = 1; hdword = pending }
  }
  '
}

# Report a genuinely merged machine-readable stream. Prints
# "<kind>\001<statement>" for the first hit, nothing when the input is clean.
analyze_merged() {
  awk '
  function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
  function is_parser(seg) {
    return seg ~ /^[ \t]*(jq|last-stack-json-get|last-stack-forge-json-jq)([ \t]|$)/
  }
  function has_parser(seg) {
    return seg ~ /(^|[ \t;&|\/])(jq|last-stack-json-get|last-stack-forge-json-jq)([ \t]|$)/
  }
  { all = all $0 "\n" }
  END {
    gsub(/&>>/, " __MERGE_OUT__ ", all)
    gsub(/&>/, " __MERGE_OUT__ ", all)
    gsub(/2>&1/, " __MERGE_ERR__ ", all)
    gsub(/>&/, " __REDIR_FD__ ", all)
    gsub(/&&/, "\001", all)
    gsub(/\|\|/, "\001", all)
    gsub(/;/, "\001", all)
    gsub(/\n/, "\001", all)
    gsub(/&/, "\001", all)
    ns = split(all, stmts, "\001")
    pcount = 0
    for (s = 1; s <= ns; s++) {
      st = stmts[s]
      if (st !~ /__MERGE_ERR__/ && st !~ /__MERGE_OUT__/) continue
      if (st !~ /--json/) continue
      # The merged stream feeds a parser directly, in this pipeline.
      np = split(st, segs, "|")
      for (p = 2; p <= np; p++) {
        if (is_parser(segs[p])) {
          printf "pipe\001%s\n", trim(st)
          exit
        }
      }
      # Otherwise remember where the merged JSON lands. /dev/null has no
      # consumer, so silencing a command is never a hit.
      t2 = st
      gsub(/>>/, " __GTGT__ ", t2)
      gsub(/>/, " __GT__ ", t2)
      nt = split(t2, toks, /[ \t]+/)
      for (k = 1; k <= nt; k++) {
        if (toks[k] == "__GT__" || toks[k] == "__GTGT__" || toks[k] == "__MERGE_OUT__") {
          f = toks[k + 1]
          if (f != "" && f != "/dev/null") { pcount++; poison[pcount] = f }
        }
      }
    }
    if (pcount == 0) exit
    # A later parser reading one of those files gets the warnings too.
    for (s = 1; s <= ns; s++) {
      st = stmts[s]
      if (!has_parser(st)) continue
      t2 = st
      gsub(/>>/, " __GTGT__ ", t2)
      gsub(/>/, " __GT__ ", t2)
      nt = split(t2, toks, /[ \t]+/)
      for (k = 1; k <= nt; k++) {
        for (p = 1; p <= pcount; p++) {
          if (toks[k] == poison[p]) {
            printf "file\001%s\n", trim(st)
            exit
          }
        }
      }
    }
  }
  '
}

syntax_only="$(printf '%s' "$cmd" | sanitize strip)"
command_pos="$(printf '%s' "$cmd" | sanitize keep)"

matches_node_json=0
matches_python_json=0
matches_python_fstring_index=0

if printf '%s' "$command_pos" | grep -qE '(^|[[:space:];&|])node[[:space:]]+(-[[:alnum:]]*[e][[:alnum:]]*|-e)[[:space:]]' \
  && printf '%s' "$command_pos" | grep -q 'JSON\.parse'; then
  matches_node_json=1
fi

if printf '%s' "$command_pos" | grep -qE '(^|[[:space:];&|])python3?[[:space:]]+(-[[:alnum:]]*[c][[:alnum:]]*|-c)[[:space:]]' \
  && printf '%s' "$command_pos" | grep -qE 'json\.loads?\('; then
  matches_python_json=1
fi

if printf '%s' "$command_pos" | grep -qE '(^|[[:space:];&|])python3?[[:space:]]+(-[[:alnum:]]*[c][[:alnum:]]*|-c)[[:space:]]' \
  && printf '%s' "$command_pos" | grep -qE 'f["'\''][^"'\'']*\[\\?["'\''][^"'\'']+\\?["'\'']\]'; then
  matches_python_fstring_index=1
fi

# Audited escape hatch, same shape as the census guard: a reason is required.
#   <command> --json 2>&1 | jq .   # json-guard-ok: <why the merge is correct>
merged_hit=""
if ! printf '%s' "$cmd" | grep -qE 'json-guard-ok:[[:space:]]*[^[:space:]]'; then
  merged_hit="$(printf '%s' "$syntax_only" | analyze_merged)"
fi

if [ -n "$merged_hit" ]; then
  merged_kind="${merged_hit%%$'\001'*}"
  merged_stmt="${merged_hit#*$'\001'}"
  if [ "$merged_kind" = "pipe" ]; then
    merged_how="that merged stream is piped straight into a JSON parser"
  else
    merged_how="that merged stream is written to a file a later JSON parser reads"
  fi
  emit_deny "BLOCKED: stderr is being merged into machine-readable JSON before parsing.

Matched statement: $merged_stmt

It carries --json and merges stderr into stdout, and $merged_how. Warnings or progress text then become byte 1 of the parser input; fleet sessions repeatedly failed with jq 'Invalid numeric literal' this way.

Keep the streams separate: write stdout to the JSON pipe/file and stderr to its own file (or leave stderr visible). Example: command --json >data.json 2>command.err; jq . data.json.

Only this statement was matched — a merged redirect on some other command in the same script is not a hit. If the merge really is correct here, append a reason: # json-guard-ok: <why>"
fi

if [ "$matches_node_json" -eq 0 ] && [ "$matches_python_json" -eq 0 ] && [ "$matches_python_fstring_index" -eq 0 ]; then
  exit 0
fi

emit_deny "BLOCKED: unsafe inline JSON parsing in Bash.

This command uses node -e / python -c with JSON.parse, json.load/json.loads, or a fragile f-string [\"...\"] index. That quoting pattern is a recurring fleet failure.

Hint: for socket/API JSON, pipe to last-stack-json-get .field after sourcing last-stack-shell-prelude. For richer parsing, use jq when available or write a small .py file in scratchpad and run the file. Avoid -c/-e JSON quoting."
