#!/bin/sh
# Installs claude-harness into a git project.
#
#   git clone --depth 1 --branch <tag> https://github.com/fbadaro/claude-harness /tmp/claude-harness
#   sh /tmp/claude-harness/install.sh [project-dir]     # default: current directory
#
# Copies harness/ to <project>/.claude/harness/ (replacing a previous copy),
# records the version in .claude/harness/VERSION, creates
# .claude/harness.conf from the example only if it does not exist, and points
# core.hooksPath at .claude/harness when it is not set yet.
set -eu

src=$(cd "$(dirname "$0")" && pwd)
target=$(cd "${1:-.}" && git rev-parse --show-toplevel) || {
	echo "install.sh: ${1:-.} is not inside a git repository" >&2
	exit 1
}
version=$(git -C "$src" describe --tags --always --dirty 2>/dev/null || echo unknown)
dest="$target/.claude/harness"

rm -rf "$dest" # owned by claude-harness: local edits are not supported
mkdir -p "$dest"
for f in guard.sh format.sh lib.sh pre-push; do
	cp "$src/harness/$f" "$dest/$f"
	chmod +x "$dest/$f"
done
printf '%s\n' "$version" >"$dest/VERSION"
echo "installed claude-harness $version in $dest"

conf="$target/.claude/harness.conf"
if [ -f "$conf" ]; then
	echo "kept existing $conf"
else
	cp "$src/harness.conf.example" "$conf"
	echo "created $conf: review the formatters for your project"
fi

hooks_path=$(git -C "$target" config --get core.hooksPath || true)
case $hooks_path in
"")
	git -C "$target" config core.hooksPath .claude/harness
	echo "enabled the pre-push hook (core.hooksPath = .claude/harness)" ;;
.claude/harness) ;;
*)
	echo "WARNING: core.hooksPath is already '$hooks_path'; the pre-push hook is NOT active." >&2
	echo "  Move your hooks to .claude/harness/ and run: git config core.hooksPath .claude/harness" >&2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
	echo "WARNING: jq not found. Without it the guard blocks every terminal command." >&2
	echo "  Windows: winget install jqlang.jq | macOS: brew install jq | Debian/Ubuntu: sudo apt install jq" >&2
fi

cat <<EOF

Next steps:
  1. Merge the "hooks" block of $src/settings.example.json into $target/.claude/settings.json.
  2. Commit .claude/harness/ and .claude/harness.conf. On Windows, keep the exec bit for Linux/macOS clones:
       git add --chmod=+x .claude/harness/pre-push .claude/harness/guard.sh .claude/harness/format.sh
  3. Every other clone runs once: git config core.hooksPath .claude/harness
  4. Restart Claude Code (or open /hooks) so it loads the new hooks.
EOF
