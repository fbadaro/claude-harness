#!/usr/bin/env bash
# claude-harness guard: Claude Code PreToolUse hook (Bash|PowerShell|Monitor).
#
# Blocks destructive git/gh commands an agent might run by accident. It does
# NOT parse shell: it strips quotes, splits the text on command separators
# and inspects the arguments of every git/gh call it finds, including inside
# nested shells (bash -c "...", pwsh -Command "..."). False positives are
# accepted; the git pre-push hook is the authoritative push guard.
#
# Exit 0 = allow, exit 2 = block (reason on stderr, shown to the agent).
set -euo pipefail

case ${BASH_SOURCE[0]} in */*) here=${BASH_SOURCE[0]%/*} ;; *) here=. ;; esac
# shellcheck source=lib.sh
. "$here/lib.sh"

block() {
	printf 'claude-harness guard: %s\n' "$*" >&2
	exit 2
}

require_jq || exit 2
# One jq call: first line = cwd, the rest = command. Everything below uses
# bash builtins only, because each extra process costs ~20-50 ms on Windows.
# (git and bash both accept Windows paths, so cwd needs no conversion.)
if ! parsed=$(jq -r '(.cwd // "" | gsub("\n"; " ")), (.tool_input.command // "")' 2>/dev/null); then
	block "invalid hook input (not JSON); refusing to run an uninspected command"
fi
parsed=${parsed//$'\r'/} # jq.exe on Windows writes CRLF
cwd=${parsed%%$'\n'*}
cmd=${parsed#*$'\n'}
[ "$cmd" != "$parsed" ] || cmd=""
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd=.

load_conf
protected=$PROTECTED_BRANCH

# --- normalization --------------------------------------------------------
bash_cont=$'\\\n'
ps_cont=$'`\n'
cmd=${cmd//"$bash_cont"/ } # bash line continuation
cmd=${cmd//"$ps_cont"/ }   # PowerShell line continuation
# Quotes and grouping characters vanish, newlines become separators.
flat=${cmd//[\"\']/}
flat=${flat//[$'\t\r(){}`']/ }
flat=${flat//$'\n'/;}
lower=${flat,,}

# --- whole-text rules: anything that could disable the pre-push hook -------
if [[ $lower == *core.hookspath* ]]; then
	block "changing core.hooksPath would disable the git pre-push hook"
fi
if [[ $lower =~ (^|[^a-z0-9_])git_(config[a-z0-9_]*|dir|exec_path)[[:space:]]*= ]]; then
	block "setting GIT_CONFIG*/GIT_DIR/GIT_EXEC_PATH can disable the git pre-push hook"
fi
if [[ $lower == *git* && $lower =~ (^|[^a-z0-9_.-])(home|xdg_config_home)[[:space:]]*= ]]; then
	block "redefining HOME/XDG_CONFIG_HOME for git can load a config that disables the pre-push hook"
fi
if [[ $lower == *--config-env* ]]; then
	block "git --config-env is not allowed (it can inject configuration that disables hooks)"
fi
if [[ $lower =~ (^|[[:space:]])-c[[:space:]]*(alias|include|includeif)\. ]]; then
	block "git -c alias.*/include.* is not allowed (it can redefine commands or load other configs)"
fi
if [[ $lower =~ (pwsh|powershell) && $lower =~ (^|[[:space:]])-(e|ec|en|enc|enco|encod|encode|encoded|encodedc|encodedco|encodedcom|encodedcomm|encodedcomma|encodedcomman|encodedcommand)([[:space:]]|$) ]]; then
	block "PowerShell -EncodedCommand cannot be inspected"
fi

# --- per-call rules ---------------------------------------------------------
dir_changed=0 # a cd/pushd/git -C earlier in the command: cwd is no longer known

current_branch() {
	git -C "$cwd" branch --show-current 2>/dev/null || true
}

# push_dst_branch <dst>: resolve HEAD/@ and strip refs/heads/.
push_dst_branch() {
	local dst=$1
	if [ "$dst" = HEAD ] || [ "$dst" = @ ]; then
		[ "$dir_changed" = 0 ] || block "git push $dst after changing directory: use an explicit refspec (e.g. git push origin my-branch)"
		dst=$(current_branch)
		[ -n "$dst" ] || block "cannot determine the current branch; use an explicit refspec"
	fi
	printf '%s\n' "${dst#refs/heads/}"
}

check_push() {
	local remote="" w skip=0 del=0 r src dst cur
	local -a refspecs=()
	for w in "$@"; do
		if [ "$skip" = 1 ]; then skip=0; continue; fi
		case $w in
		--force | --force=* | --force-with-lease | --force-with-lease=* | --force-if-includes)
			block "force-push rewrites history; push a new commit instead" ;;
		--mirror | --all | --branches | --prune)
			block "git push $w touches every branch, including $protected" ;;
		--no-verify)
			block "git push --no-verify skips the pre-push hook" ;;
		--delete) del=1 ;;
		--repo | --push-option | --receive-pack | --exec) skip=1 ;;
		--*) ;;
		-*)
			[[ $w == *f* ]] && block "force-push rewrites history; push a new commit instead"
			[[ $w == *d* ]] && del=1
			[[ $w == *o* ]] && skip=1 ;;
		*)
			if [ -z "$remote" ]; then remote=$w; else refspecs+=("$w"); fi ;;
		esac
	done
	if [ "${#refspecs[@]}" = 0 ]; then
		[ "$del" = 0 ] || return 0
		[ "$dir_changed" = 0 ] || block "git push without a refspec after changing directory: use an explicit refspec (e.g. git push origin my-branch)"
		cur=$(current_branch)
		[ -n "$cur" ] || block "cannot determine the current branch; use an explicit refspec"
		[ "$cur" != "$protected" ] || block "pushing to $protected is not allowed; open a PR from a ticket branch"
		return 0
	fi
	for r in "${refspecs[@]}"; do
		[[ $r == +* ]] && block "force-push ($r) rewrites history; push a new commit instead"
		[ "$r" != : ] || block "git push origin : pushes every matching branch, including $protected"
		src=${r%%:*}
		if [[ $r == *:* ]]; then dst=${r#*:}; else dst=$src; fi
		dst=$(push_dst_branch "$dst")
		[ "$dst" != "$protected" ] || block "pushing to (or deleting) $protected is not allowed; open a PR from a ticket branch"
	done
}

check_git() {
	# Skip git's global options; -C changes the directory.
	while [ $# -gt 0 ]; do
		case $1 in
		-C) dir_changed=1; shift 2 || return 0 ;;
		-c) shift 2 || return 0 ;;
		-*) shift ;;
		*) break ;;
		esac
	done
	[ $# -gt 0 ] || return 0
	local sub=$1 w
	shift
	case $sub in
	push | reset | branch | config)
		for w in "$@"; do
			[[ $w != *\$* ]] || block "unresolved shell expansion ($w) in git $sub: use literal arguments"
		done ;;
	esac
	case $sub in
	push) check_push "$@" ;;
	reset)
		for w in "$@"; do
			[ "$w" != --hard ] || block "git reset --hard discards work; use git stash or git restore on specific files"
		done ;;
	branch)
		local del=0 names=()
		for w in "$@"; do
			case $w in
			--delete) del=1 ;;
			--*) ;;
			-*) [[ $w == *[dD]* ]] && del=1 ;;
			*) names+=("$w") ;;
			esac
		done
		if [ "$del" = 1 ]; then
			for w in "${names[@]}"; do
				[ "$w" != "$protected" ] || block "deleting $protected is not allowed"
			done
		fi ;;
	config)
		for w in "$@"; do
			w=${w,,}
			case $w in
			alias.* | include.* | includeif.*) block "git config $w is not allowed (it can redefine commands or load other configs)" ;;
			esac
		done ;;
	esac
}

check_merge() {
	[ "$REQUIRE_GREEN_CHECKS" = 1 ] || return 0
	local w skip=0 sel="" errf out
	local -a repo=()
	while [ $# -gt 0 ]; do
		w=$1
		shift
		if [ "$skip" = 1 ]; then skip=0; continue; fi
		case $w in
		-R | --repo) repo=(--repo "${1:-}"); shift || true ;;
		--repo=*) repo=("$w") ;;
		-t | --subject | -b | --body | -F | --body-file | --match-head-commit | -A | --author-email) skip=1 ;;
		-*) ;;
		*[\<\>]*) ;; # leftover of a redirection such as 2>&1
		*) [ -n "$sel" ] || sel=$w ;;
		esac
	done
	if [ "$dir_changed" = 1 ] && [ "${#repo[@]}" = 0 ]; then
		block "gh pr merge after changing directory: pass --repo owner/name so the checks are read from the right repository"
	fi
	local -a args=(pr checks)
	[ -z "$sel" ] || args+=("$sel")
	args+=("${repo[@]}" --json "name,bucket")
	errf=$(mktemp)
	out=$(cd "$cwd" && gh "${args[@]}" 2>"$errf") || true
	if ! printf '%s' "$out" | jq -e 'type == "array" and length > 0 and all(.[]; .bucket == "pass" or .bucket == "skipping")' >/dev/null 2>&1; then
		local err
		err=$(cat "$errf")
		rm -f "$errf"
		block "gh pr merge needs every check green (gh ${args[*]}): ${out:-no output} ${err}"
	fi
	rm -f "$errf"
}

check_gh() {
	case "${1:-} ${2:-}" in
	"pr merge") shift 2; check_merge "$@" ;;
	api\ *)
		local w
		for w in "$@"; do
			[[ $w != */merge* ]] || block "merging through gh api bypasses the checks rule; use gh pr merge"
		done ;;
	esac
}

while IFS= read -r seg; do
	read -ra raw <<<"$seg" || true
	# Drop redirections and their targets (> f, 2>err, >>"$LOG"): they are
	# not arguments of the command.
	words=()
	skip=0
	for w in "${raw[@]}"; do
		if [ "$skip" = 1 ]; then skip=0; continue; fi
		if [[ $w =~ ^[0-9]*(\>\>?|\<\<?)$ ]]; then skip=1; continue; fi
		[[ $w =~ ^[0-9]*[\<\>] ]] && continue
		words+=("$w")
	done
	[ "${#words[@]}" -gt 0 ] || continue
	case ${words[0],,} in
	cd | pushd | popd | chdir | set-location | sl | push-location) dir_changed=1; continue ;;
	esac
	# Every git/gh word starts a check, so nested calls such as
	# "git submodule foreach git push --force" are inspected too.
	for i in "${!words[@]}"; do
		name=${words[$i]##*[/\\]}
		case ${name,,} in
		git | git.exe) check_git "${words[@]:$((i + 1))}" ;;
		gh | gh.exe) check_gh "${words[@]:$((i + 1))}" ;;
		esac
	done
done <<<"${flat//[;|&]/$'\n'}"

exit 0
