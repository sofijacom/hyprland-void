#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

MAINTAINER_LINE='maintainer="Rich <rich@bandaholics.cash>"'
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
PKG_DIR="${PKG_DIR:-srcpkgs}"

github_api() {
	local url="$1"
	if [[ -n "$TOKEN" ]]; then
		curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $TOKEN" "$url"
	else
		curl -fsSL -H "Accept: application/vnd.github+json" "$url"
	fi
}

template_var() {
	local template="$1"
	local var_name="$2"
	local arch="${3:-}"

	bash -c '
set -eo pipefail
template="$1"
var_name="$2"
arch="${3:-}"
if [[ -n "$arch" ]]; then
	export XBPS_TARGET_MACHINE="$arch"
fi
source "$template"
printf "%s" "${!var_name:-}"
' _ "$template" "$var_name" "$arch"
}

repo_from_distfiles() {
	local distfiles="$1"
	local first_url="${distfiles%% *}"
	if [[ "$first_url" =~ github\.com/([^/]+/[^/]+)/ ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

latest_tag_for_repo() {
	local repo="$1"
	local releases_json
	local tags_json
	local latest_tag

	if ! releases_json="$(github_api "https://api.github.com/repos/${repo}/releases?per_page=100")"; then
		return 1
	fi
	latest_tag="$(
		jq -r '[.[] | select((.prerelease | not) and (.draft | not))] | sort_by(.published_at) | reverse | .[0].tag_name // empty' <<<"$releases_json"
	)"

	if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
		if ! tags_json="$(github_api "https://api.github.com/repos/${repo}/tags?per_page=100")"; then
			return 1
		fi
		latest_tag="$(jq -r '.[0].name // empty' <<<"$tags_json")"
	fi

	printf '%s' "$latest_tag"
}

checksums_for_urls() {
	local -a urls=("$@")
	local tmpdir
	local -a sums=()
	local idx=0

	tmpdir="$(mktemp -d)"
	for url in "${urls[@]}"; do
		[[ -n "$url" ]] || continue
		local artifact="${tmpdir}/artifact_${idx}"
		curl -fsSL -L "$url" -o "$artifact"
		sums+=("$(sha256sum "$artifact" | awk '{print $1}')")
		idx=$((idx + 1))
	done
	rm -rf "$tmpdir"

	printf '%s\n' "${sums[@]}"
}

checksum_literal() {
	local existing_line="$1"
	shift
	local -a sums=("$@")

	if [[ "${#sums[@]}" -eq 0 ]]; then
		return 1
	fi

	local joined
	joined="$(printf '%s ' "${sums[@]}")"
	joined="${joined% }"

	if [[ "${#sums[@]}" -gt 1 || "$existing_line" == *\"* ]]; then
		printf '"%s"' "$joined"
	else
		printf '%s' "$joined"
	fi
}

replace_first_match() {
	local file="$1"
	local pattern="$2"
	local replacement="$3"

	awk -v pattern="$pattern" -v replacement="$replacement" '
BEGIN { done = 0 }
!done && $0 ~ pattern {
	print replacement
	done = 1
	next
}
{ print }
' "$file" >"${file}.tmp"
	mv "${file}.tmp" "$file"
}

replace_first_checksum() {
	local file="$1"
	local literal="$2"

	awk -v literal="$literal" '
BEGIN { done = 0 }
!done && $0 ~ /^[[:space:]]*checksum=/ {
	match($0, /^[[:space:]]*/)
	indent = substr($0, RSTART, RLENGTH)
	print indent "checksum=" literal
	done = 1
	next
}
{ print }
' "$file" >"${file}.tmp"
	mv "${file}.tmp" "$file"
}

list_machine_arches() {
	local file="$1"
	awk '
/^[[:space:]]*case "\$XBPS_TARGET_MACHINE" in[[:space:]]*$/ { in_case = 1; next }
in_case && /^[[:space:]]*esac[[:space:]]*$/ { in_case = 0; next }
in_case {
	if (match($0, /^[[:space:]]*([A-Za-z0-9_+.-]+)\)[[:space:]]*$/, m) && m[1] != "*")
		print m[1]
}
' "$file" | sort -u
}

arch_checksum_line() {
	local file="$1"
	local arch="$2"

	awk -v arch="$arch" '
BEGIN { in_case = 0; in_arch = 0 }
/^[[:space:]]*case "\$XBPS_TARGET_MACHINE" in[[:space:]]*$/ { in_case = 1; next }
in_case && /^[[:space:]]*esac[[:space:]]*$/ { in_case = 0; in_arch = 0; next }
in_case && $0 ~ ("^[[:space:]]*" arch "\\)[[:space:]]*$") { in_arch = 1; next }
in_case && in_arch && /^[[:space:]]*;;[[:space:]]*$/ { in_arch = 0; next }
in_case && in_arch && /^[[:space:]]*checksum=/ { print; exit }
' "$file"
}

replace_arch_checksum() {
	local file="$1"
	local arch="$2"
	local literal="$3"

	awk -v arch="$arch" -v literal="$literal" '
BEGIN { in_case = 0; in_arch = 0 }
/^[[:space:]]*case "\$XBPS_TARGET_MACHINE" in[[:space:]]*$/ { in_case = 1 }
in_case && $0 ~ ("^[[:space:]]*" arch "\\)[[:space:]]*$") { in_arch = 1 }
in_case && in_arch && /^[[:space:]]*checksum=/ {
	match($0, /^[[:space:]]*/)
	indent = substr($0, RSTART, RLENGTH)
	print indent "checksum=" literal
	next
}
in_case && in_arch && /^[[:space:]]*;;[[:space:]]*$/ { in_arch = 0 }
in_case && /^[[:space:]]*esac[[:space:]]*$/ { in_case = 0 }
{ print }
' "$file" >"${file}.tmp"
	mv "${file}.tmp" "$file"
}

process_template() {
	local template="$1"
	local pkgname
	local current_version
	local distfiles
	local repo
	local latest_tag
	local latest_version

	pkgname="$(sed -n 's/^pkgname=//p' "$template" | head -n1)"
	current_version="$(sed -n 's/^version=//p' "$template" | head -n1)"
	if [[ -z "$pkgname" || -z "$current_version" ]]; then
		echo "Skipping ${template}: missing pkgname/version"
		return 0
	fi

	replace_first_match "$template" '^maintainer=' "$MAINTAINER_LINE"

	distfiles="$(template_var "$template" distfiles)"
	repo="$(repo_from_distfiles "$distfiles" || true)"
	if [[ -z "$repo" ]]; then
		echo "Skipping ${pkgname}: distfiles is not a GitHub source"
		return 0
	fi

	if ! latest_tag="$(latest_tag_for_repo "$repo")"; then
		echo "Failed to query GitHub for ${pkgname} (${repo})" >&2
		return 1
	fi
	if [[ -z "$latest_tag" ]]; then
		echo "No release or tag found for ${pkgname} (${repo})" >&2
		return 1
	fi
	latest_version="${latest_tag#v}"

	if [[ "$current_version" == "$latest_version" ]]; then
		echo "${pkgname}: already at ${current_version}"
		return 0
	fi

	echo "${pkgname}: ${current_version} -> ${latest_version}"
	replace_first_match "$template" '^version=' "version=${latest_version}"

	if grep -qE '^[[:space:]]*case "\$XBPS_TARGET_MACHINE" in' "$template"; then
		local arch
		mapfile -t arches < <(list_machine_arches "$template")
		for arch in "${arches[@]}"; do
			local arch_distfiles
			local existing_line
			local literal
			local -a urls
			local -a sums

			arch_distfiles="$(template_var "$template" distfiles "$arch")"
			[[ -n "$arch_distfiles" ]] || continue
			read -r -a urls <<<"$arch_distfiles"
			mapfile -t sums < <(checksums_for_urls "${urls[@]}")
			existing_line="$(arch_checksum_line "$template" "$arch")"
			literal="$(checksum_literal "$existing_line" "${sums[@]}")"
			replace_arch_checksum "$template" "$arch" "$literal"
		done
	else
		local existing_line
		local literal
		local -a urls
		local -a sums

		distfiles="$(template_var "$template" distfiles)"
		read -r -a urls <<<"$distfiles"
		mapfile -t sums < <(checksums_for_urls "${urls[@]}")
		existing_line="$(grep -m1 -E '^[[:space:]]*checksum=' "$template" || true)"
		literal="$(checksum_literal "$existing_line" "${sums[@]}")"
		replace_first_checksum "$template" "$literal"
	fi
}

mapfile -t templates < <(find "$PKG_DIR" -mindepth 2 -maxdepth 2 -type f -name template | sort)
if [[ "${#templates[@]}" -eq 0 ]]; then
	echo "No templates found under ${PKG_DIR}" >&2
	exit 1
fi

failures=0
for template in "${templates[@]}"; do
	if ! process_template "$template"; then
		failures=$((failures + 1))
	fi
done

if [[ "$failures" -gt 0 ]]; then
	echo "Updater failed for ${failures} template(s)" >&2
	exit 1
fi
