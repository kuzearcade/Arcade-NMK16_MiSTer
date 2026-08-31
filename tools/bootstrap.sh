#!/usr/bin/env bash
# Fetches every vendored dependency pinned in deps.lock into its gitignored
# destination. Re-run any time deps.lock changes; existing destinations are
# left alone (rm -rf the destination to force a re-fetch of just that dep).
#
# Special case: the `template_mister` entry provides both the MiSTer sys/
# framework (goes to sys/) AND the top-level Quartus skeleton
# (Template.sv/.sdc/.qpf/.qsf/files.qip), which get copied to the project
# root ONLY if not already present there, since those files are meant to be
# customized per hardware family afterwards, not silently overwritten.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/deps.lock"

log() { echo "[bootstrap] $*" >&2; }

strip_git_dirs() {
	find "$1" -name ".git" -maxdepth 6 -exec rm -rf {} + 2>/dev/null || true
}

fetch_repo() {
	local name="$1" url="$2" ref="$3" dest="$4" staging="$5"
	local full_dest="$ROOT/$dest"

	if [ -n "$staging" ]; then
		full_dest="$ROOT/.bootstrap-staging/$name"
	fi

	if [ -z "$staging" ] && [ -d "$full_dest" ] && [ -n "$(ls -A "$full_dest" 2>/dev/null)" ]; then
		log "skip $name: $dest already populated (rm -rf it to re-fetch)"
		return
	fi

	log "fetching $name -> ${staging:+staging/}$dest @ $ref"
	rm -rf "$full_dest" "$full_dest.tmp"
	git clone --quiet "$url" "$full_dest.tmp"
	git -C "$full_dest.tmp" checkout --quiet "$ref"
	git -C "$full_dest.tmp" submodule update --init --recursive --quiet 2>/dev/null || true
	strip_git_dirs "$full_dest.tmp"
	mkdir -p "$(dirname "$full_dest")"
	mv "$full_dest.tmp" "$full_dest"
	log "done $name"
}

fetch_file() {
	local name="$1" url="$2" ref="$3" dest="$4"
	local rev="${ref%%:*}" path_in_repo="${ref#*:}"
	local full_dest="$ROOT/$dest"

	if [ -f "$full_dest" ]; then
		log "skip $name: $dest already exists (rm it to re-fetch)"
		return
	fi

	log "fetching $name file $path_in_repo -> $dest"
	local tmp
	tmp="$(mktemp -d)"
	git clone --quiet --depth 50 "$url" "$tmp/repo"
	[ "$rev" != "HEAD" ] && git -C "$tmp/repo" checkout --quiet "$rev"
	mkdir -p "$(dirname "$full_dest")"
	cp "$tmp/repo/$path_in_repo" "$full_dest"
	rm -rf "$tmp"
	log "done $name"
}

seed_template_skeleton() {
	local staged="$ROOT/.bootstrap-staging/template_mister"
	[ -d "$staged" ] || return 0

	mkdir -p "$ROOT/sys"
	if [ -z "$(ls -A "$ROOT/sys" 2>/dev/null)" ]; then
		log "seeding sys/ from vendored Template_MiSTer"
		cp -r "$staged/sys/." "$ROOT/sys/"
	else
		log "sys/ already populated, leaving as-is"
	fi

	for f in Template.sv Template.sdc Template.qpf Template.qsf files.qip; do
		if [ -f "$ROOT/$f" ]; then
			log "$f already exists at project root, leaving as-is"
		elif [ -f "$staged/$f" ]; then
			cp "$staged/$f" "$ROOT/$f"
			log "seeded $f at project root (customize per hardware family before building)"
		fi
	done
}

main() {
	while IFS='|' read -r name kind url ref dest license notes; do
		[[ -z "$name" || "$name" == \#* ]] && continue
		case "$kind" in
		repo)
			if [ "$name" = "template_mister" ]; then
				fetch_repo "$name" "$url" "$ref" "$dest" "staging"
			else
				fetch_repo "$name" "$url" "$ref" "$dest" ""
			fi
			;;
		file) fetch_file "$name" "$url" "$ref" "$dest" ;;
		*) log "unknown kind '$kind' for $name, skipping" ;;
		esac
	done <"$LOCK"

	seed_template_skeleton
	rm -rf "$ROOT/.bootstrap-staging"

	log "all dependencies fetched."
	log "vendored trees are gitignored (see .gitignore); only deps.lock is tracked."
}

main "$@"
