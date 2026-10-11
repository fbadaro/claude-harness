#!/usr/bin/env bash
# claude-harness format: Claude Code PostToolUse hook (Edit|Write|MultiEdit).
#
# Formats the edited file with the command configured for its extension in
# .claude/harness.conf (FORMAT_<ext>). Never blocks: exit 0 = done or
# nothing to do, exit 1 = non-blocking warning shown to the user.
set -euo pipefail

case ${BASH_SOURCE[0]} in */*) here=${BASH_SOURCE[0]%/*} ;; *) here=. ;; esac
# shellcheck source=lib.sh
. "$here/lib.sh"

warn() {
	printf 'claude-harness format: %s\n' "$*" >&2
	exit 1
}

require_jq || exit 1
if ! file=$(jq -r '.tool_input.file_path // ""' 2>/dev/null); then
	warn "invalid hook input (not JSON)"
fi
file=${file%$'\r'} # jq.exe on Windows writes CRLF
[ -n "$file" ] || exit 0

load_conf
root=$(to_posix "$(project_dir)")
file=$(to_posix "$file")
rel=${file#"$root"/}
[ "$rel" != "$file" ] || exit 0 # outside the project

for prefix in $FORMAT_SKIP; do
	case $rel in "$prefix"*) exit 0 ;; esac
done

ext=${rel##*.}
[ "$ext" != "$rel" ] || exit 0 # no extension
[[ $ext =~ ^[A-Za-z0-9_]+$ ]] || exit 0
template_var="FORMAT_$ext"
template=${!template_var:-}
[ -n "$template" ] || exit 0

# FORMAT_DIR_<ext>: run inside this subdirectory; files outside it are skipped.
dir_var="FORMAT_DIR_$ext"
subdir=${!dir_var:-}
workdir=$root
if [ -n "$subdir" ]; then
	subdir=${subdir%/}
	case $rel in "$subdir"/*) rel=${rel#"$subdir"/} ;; *) exit 0 ;; esac
	workdir="$root/$subdir"
fi

# The template is split into words (no eval, no shell expansion); the word {}
# becomes ./<path>, so a file named "-v.go" cannot turn into an option.
read -ra words <<<"$template"
for i in "${!words[@]}"; do
	[ "${words[$i]}" != "{}" ] || words[i]="./$rel"
done
command -v "${words[0]}" >/dev/null 2>&1 || warn "${words[0]} not found on PATH; $rel was not formatted"
if ! out=$(cd "$workdir" && "${words[@]}" 2>&1); then
	warn "${words[*]} failed: $out"
fi
exit 0
