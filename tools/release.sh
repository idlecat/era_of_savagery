#!/usr/bin/env bash
# Build the Windows and macOS downloads and publish them as a GitHub release.
#   tools/release.sh v0.2.0          # new release (or re-upload the files of an existing one)
#   tools/release.sh v0.2.0 --draft  # create it as a draft to check before publishing
# Steps: check gh can write to the repo and the tree is committed and pushed,
# stamp the version into export_presets.cfg (committed and pushed if it changed),
# run tools/build.sh, then create the release (tag on the pushed commit) with
# tools/release_notes.md, or replace the zips if the release already exists.
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:-}"
[[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "usage: tools/release.sh vX.Y.Z [--draft]" >&2; exit 2; }
ver="${tag#v}"
draft=()
[[ "${2:-}" == "--draft" ]] && draft=(--draft)
files=(export/EraOfSavagery-windows.zip export/EraOfSavagery-macos.zip)

# 1. GitHub access: the logged-in gh account must be able to push to this repo.
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
if [[ "$(gh api "repos/$repo" --jq .permissions.push)" != "true" ]]; then
	echo "gh is logged in as '$(gh api user --jq .login)', which can't write to $repo." >&2
	echo "Run 'gh auth switch' or 'gh auth login' with an account that can." >&2
	exit 1
fi

# 2. The release must match committed, pushed code.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
	echo "There are uncommitted changes; commit or stash them first." >&2
	exit 1
fi
branch="$(git rev-parse --abbrev-ref HEAD)"

# 3. Stamp the version into both export presets.
sed -i '' -E \
	-e "s/^(application\/(file|product)_version=)\".*\"/\1\"$ver.0\"/" \
	-e "s/^(application\/(short_version|version)=)\".*\"/\1\"$ver\"/" \
	export_presets.cfg
if ! git diff --quiet export_presets.cfg; then
	git commit -q -m "Release $tag" export_presets.cfg
	echo "Committed version $ver in export_presets.cfg"
fi
git push -q origin "$branch"
sha="$(git rev-parse HEAD)"

# 4. Build.
tools/build.sh

# 5. Publish.
if gh release view "$tag" >/dev/null 2>&1; then
	echo "Release $tag exists; replacing its files"
	gh release upload "$tag" "${files[@]}" --clobber
else
	gh release create "$tag" "${files[@]}" --target "$sha" ${draft[@]+"${draft[@]}"} \
		--title "Era of Savagery $tag" --notes-file tools/release_notes.md
fi
gh release view "$tag" --json url --jq .url
