#!/usr/bin/env bash
# shellcheck disable=SC2016 # commands under test are literal text: no expansion wanted
# Table tests for the claude-harness hooks. Usage: bash test/run.sh
# Needs bash, jq and git. gh and the formatters are replaced by stubs.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
H="$repo_root/harness"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
ko() {
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$*" >&2
}

# --- fixtures ----------------------------------------------------------------
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset CLAUDE_PROJECT_DIR || true

proj="$tmp/proj"
git init -q -b main "$proj"
git -C "$proj" commit -q --allow-empty -m init
nogit="$tmp/nogit"
mkdir -p "$nogit"

# gh stub: prints checks built from $FAKE_GH_BUCKETS ("pass,fail"; "none" = []),
# exits $FAKE_GH_EXIT and logs its arguments to $FAKE_GH_LOG.
stubs="$tmp/stubs"
mkdir -p "$stubs"
cat >"$stubs/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
if [ "${FAKE_GH_BUCKETS:-}" = garbage ]; then echo "not json"; echo "boom" >&2; exit 1; fi
if [ "${FAKE_GH_BUCKETS:-none}" = none ]; then echo '[]'; exit "${FAKE_GH_EXIT:-0}"; fi
IFS=, read -ra b <<<"$FAKE_GH_BUCKETS"
printf '%s\n' "${b[@]}" | jq -Rn '[inputs | {name: "ci", bucket: .}]'
exit "${FAKE_GH_EXIT:-0}"
EOF
# formatter stub: logs "<pwd> <args>"
cat >"$stubs/fake-fmt" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(pwd)" "$*" >>"$FAKE_FMT_LOG"
EOF
chmod +x "$stubs/gh" "$stubs/fake-fmt"
export PATH="$stubs:$PATH"
export FAKE_GH_LOG="$tmp/gh.log" FAKE_FMT_LOG="$tmp/fmt.log"

# --- guard ---------------------------------------------------------------------
# guard <name> <expected exit> <branch|-> <command> [cwd]
guard() {
	local name=$1 want=$2 branch=$3 command=$4 dir=${5:-$proj} got
	if [ "$branch" != - ]; then git -C "$proj" switch -q -C "$branch"; fi
	got=0
	jq -n --arg c "$command" --arg d "$dir" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' |
		bash "$H/guard.sh" >/dev/null 2>"$tmp/err" || got=$?
	if [ "$got" = "$want" ]; then ok; else ko "guard: $name: exit $got, want $want: $command ($(cat "$tmp/err"))"; fi
}
B=2 # blocked
A=0 # allowed

# push to the protected branch
guard "push main explicit" $B issue-1-x "git push origin main"
guard "push HEAD:main" $B issue-1-x "git push origin HEAD:main"
guard "push refs/heads/main" $B issue-1-x "git push origin feature:refs/heads/main"
guard "push delete main" $B issue-1-x "git push origin --delete main"
guard "push -d main" $B issue-1-x "git push -d origin main"
guard "push colon main" $B issue-1-x "git push origin :main"
guard "push matching" $B issue-1-x "git push origin :"
guard "push on main no refspec" $B main "git push"
guard "push on main remote only" $B main "git push origin"
guard "push HEAD on main" $B main "git push -u origin HEAD"
guard "push @ on main" $B main "git push origin @"
guard "push all" $B issue-1-x "git push --all origin"
guard "push mirror" $B issue-1-x "git push --mirror"
guard "push prune" $B issue-1-x "git push --prune origin"
guard "push in compound" $B issue-1-x "cd repo && git push origin main"
guard "push with git -C" $B issue-1-x "git -C ../repo push origin main"
guard "push with env prefix" $B issue-1-x "GIT_TRACE=1 git push origin main"
guard "push quoted main" $B issue-1-x 'git push origin "main"'
guard "push git.exe" $B issue-1-x "git.exe push origin main"
guard "push full path git" $B issue-1-x "/usr/bin/git push origin main"
guard "push line continuation" $B issue-1-x $'git push origin \\\n main'
guard "push second line" $B issue-1-x $'echo hi\ngit push origin main'
guard "push unknown branch" $B - "git push" "$nogit"
guard "push no refspec after cd" $B issue-1-x "cd /c/x && git push"
guard "push HEAD after cd" $B issue-1-x "cd /tmp && git push origin HEAD"
guard "push no refspec with -C" $B issue-1-x "git -C ../other push"
guard "push variable" $B issue-1-x 'git push origin $B'
guard "push subshell" $B issue-1-x 'git push origin "$(echo main)"'
# force
guard "force" $B issue-1-x "git push --force origin issue-1-x"
guard "force short" $B issue-1-x "git push -f origin issue-1-x"
guard "force clustered" $B issue-1-x "git push -fu origin issue-1-x"
guard "force with lease" $B issue-1-x "git push --force-with-lease origin issue-1-x"
guard "force with lease value" $B issue-1-x "git push --force-with-lease=issue-1-x origin issue-1-x"
guard "force plus refspec" $B issue-1-x "git push origin +issue-1-x"
guard "no-verify" $B issue-1-x "git push --no-verify origin issue-1-x"
# nested shells
guard "bash -c push main" $B issue-1-x 'bash -c "git push origin main"'
guard "bash -c force" $B issue-1-x 'bash -c "git push --force"'
guard "sh -c force" $B issue-1-x "sh -c 'git push -f origin x'"
guard "pwsh -Command push main" $B issue-1-x 'pwsh -NoProfile -Command "git push origin main"'
guard "powershell -c reset" $B issue-1-x 'powershell -c "git reset --hard"'
guard "cmd /c push main" $B issue-1-x "cmd /c git push origin main"
guard "eval push main" $B issue-1-x "eval git push origin main"
guard "nested twice" $B issue-1-x "bash -c \"sh -c 'git push origin main'\""
guard "subshell parens" $B issue-1-x "(git push origin main)"
guard "command substitution" $B issue-1-x 'x=$(git push -f origin x)'
guard "encoded command" $B issue-1-x "pwsh -EncodedCommand ZQBjAGgAbwA="
guard "encoded command short" $B issue-1-x "powershell -enc ZQBjAGgAbwA="
# allowed pushes
guard "push feature branch" $A issue-12-x "git push origin issue-12-x"
guard "push -u feature" $A issue-12-x "git push -u origin issue-12-x"
guard "push current feature" $A issue-12-x "git push"
guard "push HEAD on feature" $A issue-12-x "git push -u origin HEAD"
guard "push feature while on main" $A main "git push origin issue-12-x"
guard "push branch named like main" $A maintenance "git push origin maintenance"
guard "push with push option" $A issue-12-x "git push -o ci.skip origin issue-12-x"
guard "push tag" $A issue-12-x "git push origin v0.1.0"
guard "push delete feature" $A main "git push origin --delete issue-3-old"
guard "push with redirection" $A issue-12-x "git push origin issue-12-x 2>&1 | tail -3"
guard "push explicit after cd" $A issue-12-x "cd /c/x && git push origin issue-12-x"
guard "bash -c harmless" $A main 'bash -c "go test ./..."'
guard "bash script file" $A main "bash scripts/build.sh"
# reset, branch
guard "reset hard" $B issue-1-x "git reset --hard HEAD~1"
guard "reset hard origin" $B issue-1-x "git reset --hard origin/main"
guard "reset backtick" $B issue-1-x 'git reset `echo --hard`'
guard "reset soft" $A issue-1-x "git reset --soft HEAD~1"
guard "delete main -D" $B issue-1-x "git branch -D main"
guard "delete main -d" $B issue-1-x "git branch -d main"
guard "delete main --delete" $B issue-1-x "git branch --delete --force main"
guard "delete feature" $A main "git branch -D issue-3-old"
guard "list branches" $A main "git branch -a"
# configuration that could disable the pre-push hook
guard "set hooksPath" $B main "git config core.hooksPath /tmp/none"
guard "unset hooksPath" $B main "git config --unset core.hooksPath"
guard "hookspath lowercase" $B main "git config --local core.hookspath x"
guard "-c hooksPath" $B issue-1-x "git -c core.hooksPath=/dev/null push origin issue-1-x"
guard "config alias" $B main "git config alias.p 'push origin main'"
guard "config include" $B main "git config include.path /tmp/evil"
guard "-c alias" $B main "git -c alias.x='push origin main' x"
guard "-c include.path" $B issue-1-x "git -c include.path=/tmp/evil push origin issue-1-x"
guard "-c includeIf" $B issue-1-x 'git -c "includeIf.gitdir:/.path=/tmp/evil" push origin issue-1-x'
guard "config-env joined" $B issue-1-x "git --config-env=core.x=X push origin issue-1-x"
guard "config-env separate" $B issue-1-x "git --config-env core.x=X push origin issue-1-x"
guard "GIT_CONFIG_COUNT" $B issue-1-x "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.x GIT_CONFIG_VALUE_0=y git push origin issue-1-x"
guard "env GIT_CONFIG_PARAMETERS" $B issue-1-x "env GIT_CONFIG_PARAMETERS=x git push origin issue-1-x"
guard "export GIT_CONFIG_GLOBAL" $B issue-1-x "export GIT_CONFIG_GLOBAL=/tmp/c; git push origin issue-1-x"
guard "powershell GIT_CONFIG" $B issue-1-x '$env:GIT_CONFIG_GLOBAL = "C:\x"; git push origin issue-1-x'
guard "GIT_DIR" $B issue-1-x "GIT_DIR=/tmp/other/.git git push origin issue-1-x"
guard "GIT_EXEC_PATH" $B issue-1-x "GIT_EXEC_PATH=/tmp git status"
guard "HOME override" $B main "HOME=/tmp/fake git push origin x"
guard "XDG override" $B main "XDG_CONFIG_HOME=/tmp/x git status"
guard "read other config" $A main "git config --get user.name"
guard "harmless -c" $A main "git -c color.ui=always log"
guard "GIT_TRACE" $A main "GIT_TRACE=1 git status"
guard "GIT_PAGER" $A main "GIT_PAGER=cat git log"
# gh pr merge needs green checks
export FAKE_GH_BUCKETS=pass,skipping FAKE_GH_EXIT=0
guard "merge green" $A issue-12-x "gh pr merge 12 --squash"
guard "merge green with redirection" $A issue-12-x "gh pr merge 3 --squash 2>&1 | tail -3"
guard "merge current branch green" $A issue-12-x "gh pr merge --squash --delete-branch"
guard "merge after cd without repo" $B issue-12-x "cd /c/x && gh pr merge 3 --squash"
guard "merge after cd with repo" $A issue-12-x "cd /c/x && gh pr merge 3 --squash -R o/r"
FAKE_GH_BUCKETS=pass,fail FAKE_GH_EXIT=1 guard "merge failing" $B issue-12-x "gh pr merge 12 --squash"
FAKE_GH_BUCKETS=pending FAKE_GH_EXIT=8 guard "merge pending" $B issue-12-x "gh pr merge 12"
FAKE_GH_BUCKETS=cancel FAKE_GH_EXIT=1 guard "merge canceled" $B issue-12-x "gh pr merge 12"
FAKE_GH_BUCKETS=none guard "merge no checks" $B issue-12-x "gh pr merge 12"
FAKE_GH_BUCKETS=garbage guard "merge gh error" $B issue-12-x "gh pr merge 12"
: >"$FAKE_GH_LOG"
guard "merge selector and repo" $A issue-12-x "gh pr merge https://github.com/o/r/pull/7 --repo o/r --squash --subject 'x y'"
if grep -q -- "pr checks https://github.com/o/r/pull/7 --repo o/r --json name,bucket" "$FAKE_GH_LOG"; then ok; else ko "merge selector and repo: gh called with: $(cat "$FAKE_GH_LOG")"; fi
guard "merge via api" $B main "gh api -X PUT repos/o/r/pulls/1/merge"
guard "read via api" $A main "gh api repos/o/r/pulls/1"
guard "gh pr view" $A main "gh pr view 12"
# everything else
guard "go test" $A main "go test ./..."
guard "git status" $A main "git status"
guard "commit" $A main "git commit -m 'add parser'"
guard "empty command" $A main ""
# redirections are not arguments (issue #3)
guard "redirect target with variable" $A issue-12-x 'git push origin issue-12-x > "$LOG/out.txt"'
guard "glued redirect with variable" $A issue-12-x 'git push origin issue-12-x 2>$ERR'
guard "append redirect" $A issue-12-x 'git push origin issue-12-x >> $LOG'
guard "redirect does not hide main" $B issue-12-x "git push origin main > out.txt"
guard "printf to file mentioning push" $A issue-12-x 'printf x > "$D/f"; git push origin issue-12-x'
# accepted false positives (documented in the README)
guard "echo mentioning push main" $B main 'echo "git push origin main"'
guard "commit message with reset --hard" $B main "git commit -m 'avoid git reset --hard'"

# invalid input and missing jq fail closed
got=0
printf 'not json' | bash "$H/guard.sh" >/dev/null 2>&1 || got=$?
if [ "$got" = 2 ]; then ok; else ko "guard: invalid JSON: exit $got, want 2"; fi
got=0
printf '{}' | env PATH="$tmp/empty" "$BASH" "$H/guard.sh" >/dev/null 2>"$tmp/err" || got=$?
if [ "$got" = 2 ] && grep -q "winget install jqlang.jq" "$tmp/err"; then ok; else ko "guard: missing jq: exit $got, want 2 with install hint ($(cat "$tmp/err"))"; fi

# protected branch from harness.conf
mkdir -p "$proj/.claude"
echo "PROTECTED_BRANCH=trunk" >"$proj/.claude/harness.conf"
export CLAUDE_PROJECT_DIR="$proj"
guard "conf: push trunk" $B issue-1-x "git push origin trunk"
guard "conf: push main allowed" $A issue-1-x "git push origin main"
echo "REQUIRE_GREEN_CHECKS=0" >"$proj/.claude/harness.conf"
FAKE_GH_BUCKETS=fail guard "conf: merge without checks rule" $A issue-12-x "gh pr merge 12"
# the conf is parsed, never executed (agent-writable file)
printf 'PROTECTED_BRANCH=trunk\r\nREQUIRE_GREEN_CHECKS=1\r\n' >"$proj/.claude/harness.conf"
guard "conf: CRLF line endings" $B issue-1-x "git push origin trunk"
printf '%s\n' "touch \"$tmp/pwned\"" 'PROTECTED_BRANCH=$(touch pwned2)' 'REQUIRE_GREEN_CHECKS=no' >"$proj/.claude/harness.conf"
FAKE_GH_BUCKETS=fail guard "conf: invalid values keep the rules" $B issue-12-x "gh pr merge 12"
guard "conf: invalid branch keeps main" $B issue-1-x "git push origin main"
if [ ! -e "$tmp/pwned" ] && [ ! -e "$proj/pwned2" ]; then ok; else ko "conf: code in harness.conf must not run"; fi
printf '%s\n' 'PROTECTED_BRANCH="trunk"   # quoted, with comment' >"$proj/.claude/harness.conf"
guard "conf: quoted value with comment" $B issue-1-x "git push origin trunk"
rm "$proj/.claude/harness.conf"

# --- format --------------------------------------------------------------------
cat >"$proj/.claude/harness.conf" <<'EOF'
FORMAT_txt="fake-fmt --write {}"
FORMAT_py="fake-fmt {}"
FORMAT_DIR_py=ml
FORMAT_md="missing-formatter {}"
FORMAT_SKIP="gen/ vendor/"
EOF
mkdir -p "$proj/ml/src" "$proj/gen"

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi; }
proj_real=$(cd "$proj" && pwd)

# format <name> <expected exit> <file path> <expected log line or "">
format() {
	local name=$1 want=$2 file=$3 log=$4 got=0
	: >"$FAKE_FMT_LOG"
	jq -n --arg f "$file" '{tool_name: "Edit", tool_input: {file_path: $f}}' |
		bash "$H/format.sh" >/dev/null 2>"$tmp/err" || got=$?
	if [ "$got" != "$want" ]; then
		ko "format: $name: exit $got, want $want ($(cat "$tmp/err"))"
	elif [ "$(cat "$FAKE_FMT_LOG")" != "$log" ]; then
		ko "format: $name: formatter log '$(cat "$FAKE_FMT_LOG")', want '$log'"
	else ok; fi
}
format "txt at root" 0 "$proj/a.txt" "$proj_real --write ./a.txt"
format "native path" 0 "$(native "$proj/sub/b.txt")" "$proj_real --write ./sub/b.txt"
format "dash file name" 0 "$proj/-v.txt" "$proj_real --write ./-v.txt"
format "py under ml" 0 "$proj/ml/src/m.py" "$proj_real/ml ./src/m.py"
format "py outside ml" 0 "$proj/tools/x.py" ""
format "skipped prefix" 0 "$proj/gen/x.txt" ""
format "unconfigured ext" 0 "$proj/x.go" ""
format "no extension" 0 "$proj/Makefile" ""
format "outside project" 0 "$tmp/elsewhere/a.txt" ""
format "missing formatter" 1 "$proj/README.md" ""
got=0
printf 'not json' | bash "$H/format.sh" >/dev/null 2>&1 || got=$?
if [ "$got" = 1 ]; then ok; else ko "format: invalid JSON: exit $got, want 1"; fi
unset CLAUDE_PROJECT_DIR

# --- pre-push --------------------------------------------------------------------
pp="$tmp/pp"
git init -q -b main "$pp"
git -C "$pp" commit -q --allow-empty -m A
A_SHA=$(git -C "$pp" rev-parse HEAD)
git -C "$pp" commit -q --allow-empty -m B
B_SHA=$(git -C "$pp" rev-parse HEAD)
git -C "$pp" switch -q -c other "$A_SHA"
git -C "$pp" commit -q --allow-empty -m C
C_SHA=$(git -C "$pp" rev-parse HEAD)
Z=0000000000000000000000000000000000000000
MISSING=1234567890123456789012345678901234567890

# prepush <name> <expected exit> <stdin>
prepush() {
	local name=$1 want=$2 got=0
	(cd "$pp" && printf '%b' "$3" | sh "$H/pre-push" origin url) >/dev/null 2>"$tmp/err" || got=$?
	if [ "$got" = "$want" ]; then ok; else ko "pre-push: $name: exit $got, want $want ($(cat "$tmp/err"))"; fi
}
prepush "feature fast-forward" 0 "refs/heads/x $B_SHA refs/heads/x $A_SHA\n"
prepush "new feature branch" 0 "refs/heads/x $B_SHA refs/heads/x $Z\n"
prepush "delete feature branch" 0 "(delete) $Z refs/heads/x $A_SHA\n"
prepush "push to main" 1 "refs/heads/x $B_SHA refs/heads/main $A_SHA\n"
prepush "create main" 1 "refs/heads/main $B_SHA refs/heads/main $Z\n"
prepush "delete main" 1 "(delete) $Z refs/heads/main $A_SHA\n"
prepush "force push feature" 1 "refs/heads/x $C_SHA refs/heads/x $B_SHA\n"
prepush "unverifiable" 1 "refs/heads/x $B_SHA refs/heads/x $MISSING\n"
prepush "two refs, one bad" 1 "refs/heads/a $B_SHA refs/heads/a $Z\nrefs/heads/b $B_SHA refs/heads/main $A_SHA\n"
prepush "empty input" 0 ""
prepush "malformed input" 1 "garbage line\n"
mkdir -p "$pp/.claude"
echo "PROTECTED_BRANCH=trunk" >"$pp/.claude/harness.conf"
prepush "conf: push to trunk" 1 "refs/heads/x $B_SHA refs/heads/trunk $A_SHA\n"
prepush "conf: main is not protected" 0 "refs/heads/x $B_SHA refs/heads/main $A_SHA\n"
printf 'PROTECTED_BRANCH=trunk\r\n' >"$pp/.claude/harness.conf"
prepush "conf: CRLF" 1 "refs/heads/x $B_SHA refs/heads/trunk $A_SHA\n"
printf '%s\n' 'exit 0' 'PROTECTED_BRANCH=main' >"$pp/.claude/harness.conf"
prepush "conf: code is not executed" 1 "refs/heads/x $B_SHA refs/heads/main $A_SHA\n"
printf '%s\n' 'PROTECTED_BRANCH=$(echo x)' >"$pp/.claude/harness.conf"
prepush "conf: invalid branch rejects" 1 "refs/heads/x $B_SHA refs/heads/feature $A_SHA\n"

# --- install.sh ------------------------------------------------------------------
target="$tmp/target"
git init -q -b main "$target"
if sh "$repo_root/install.sh" "$target" >/dev/null 2>"$tmp/err" &&
	[ -x "$target/.claude/harness/guard.sh" ] && [ -x "$target/.claude/harness/pre-push" ] &&
	[ -f "$target/.claude/harness/lib.sh" ] && [ -f "$target/.claude/harness/format.sh" ] &&
	[ -s "$target/.claude/harness/VERSION" ] && [ -f "$target/.claude/harness.conf" ] &&
	[ "$(git -C "$target" config --get core.hooksPath)" = .claude/harness ]; then ok; else ko "install: fresh install ($(cat "$tmp/err"))"; fi
echo "PROTECTED_BRANCH=trunk" >"$target/.claude/harness.conf"
echo "local edit" >"$target/.claude/harness/stale-file"
sh "$repo_root/install.sh" "$target" >/dev/null 2>&1
if grep -q trunk "$target/.claude/harness.conf" && [ ! -e "$target/.claude/harness/stale-file" ]; then ok; else ko "install: reinstall must keep harness.conf and replace .claude/harness/"; fi
other="$tmp/other"
git init -q -b main "$other"
git -C "$other" config core.hooksPath .githooks
sh "$repo_root/install.sh" "$other" >/dev/null 2>"$tmp/err"
if [ "$(git -C "$other" config --get core.hooksPath)" = .githooks ] && grep -q "pre-push hook is NOT active" "$tmp/err"; then ok; else ko "install: must not override an existing core.hooksPath"; fi
# the installed copy works end to end
got=0
jq -n --arg d "$target" '{cwd: $d, tool_input: {command: "git push origin trunk"}}' |
	CLAUDE_PROJECT_DIR="$target" bash "$target/.claude/harness/guard.sh" >/dev/null 2>&1 || got=$?
if [ "$got" = 2 ]; then ok; else ko "install: installed guard must read harness.conf (exit $got)"; fi
if sh "$repo_root/install.sh" "$nogit" >/dev/null 2>&1; then ko "install: must fail outside a git repository"; else ok; fi

# --- summary ---------------------------------------------------------------------
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
