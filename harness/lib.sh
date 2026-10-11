# shellcheck shell=bash
# Shared helpers for the claude-harness hooks. Sourced, never executed.
# The guard runs on every terminal command, so these helpers avoid spawning
# processes: each one costs ~20-50 ms on Windows.

# project_dir prints the project root as given: $CLAUDE_PROJECT_DIR when
# Claude Code sets it, else the git top level, else the current directory.
# Git Bash opens Windows paths (C:\x, C:/x) as they are.
project_dir() {
	if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
		printf '%s\n' "$CLAUDE_PROJECT_DIR"
	else
		git rev-parse --show-toplevel 2>/dev/null || pwd
	fi
}

# to_posix converts a Windows path to the POSIX form used by Git Bash, so it
# can be compared with other paths. No-op where cygpath does not exist.
to_posix() {
	if command -v cygpath >/dev/null 2>&1; then
		cygpath -u "$1"
	else
		printf '%s\n' "$1"
	fi
}

# load_conf sets the defaults and then reads <project>/.claude/harness.conf.
# The file is PARSED, never sourced: an agent can edit it, so it must not be
# able to run code or switch the protections off with a malformed value.
# Only known keys are read (KEY=value, KEY="value" or KEY='value', optional
# trailing # comment); CRLF line endings are accepted.
# shellcheck disable=SC2034 # the variables are read by the scripts that source this file
load_conf() {
	PROTECTED_BRANCH=main
	REQUIRE_GREEN_CHECKS=1
	FORMAT_SKIP=""
	local conf line key val
	conf="$(project_dir)/.claude/harness.conf"
	[ -f "$conf" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%$'\r'}
		[[ $line =~ ^[[:space:]]*(PROTECTED_BRANCH|REQUIRE_GREEN_CHECKS|FORMAT_SKIP|FORMAT_[A-Za-z0-9_]+)=(.*)$ ]] || continue
		key=${BASH_REMATCH[1]}
		val=${BASH_REMATCH[2]}
		if [[ $val =~ ^\"([^\"]*)\" || $val =~ ^\'([^\']*)\' ]]; then
			val=${BASH_REMATCH[1]}
		else
			val=${val%%[[:space:]]#*}
			while [[ $val == *[[:space:]] ]]; do val=${val%[[:space:]]}; done
		fi
		case $key in
		PROTECTED_BRANCH)
			# An invalid name keeps the default rather than disabling the rule.
			[[ $val =~ ^[A-Za-z0-9._/-]+$ ]] && PROTECTED_BRANCH=$val ;;
		REQUIRE_GREEN_CHECKS)
			# Only an explicit 0 turns the merge rule off.
			if [ "$val" = 0 ]; then REQUIRE_GREEN_CHECKS=0; else REQUIRE_GREEN_CHECKS=1; fi ;;
		*) printf -v "$key" '%s' "$val" ;;
		esac
	done <"$conf"
}

# require_jq fails with install instructions when jq is not on PATH.
# printf only: no external command may run before jq is known to exist.
require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' \
			'claude-harness: jq not found on PATH. Install it and restart Claude Code:' \
			'  Windows: winget install jqlang.jq' \
			'  macOS:   brew install jq' \
			'  Debian/Ubuntu: sudo apt install jq' >&2
		return 1
	fi
}
