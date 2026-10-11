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

# load_conf sets the defaults and then sources <project>/.claude/harness.conf.
# shellcheck disable=SC2034 # the variables are read by the scripts that source this file
load_conf() {
	PROTECTED_BRANCH=main
	REQUIRE_GREEN_CHECKS=1
	FORMAT_SKIP=""
	local conf
	conf="$(project_dir)/.claude/harness.conf"
	if [ -f "$conf" ]; then
		# shellcheck source=/dev/null
		. "$conf"
	fi
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
