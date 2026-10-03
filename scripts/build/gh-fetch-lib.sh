# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Shared helper for build-time header downloads from GitHub.
#
# Source this, then call gh_fetch:
#   gh_fetch <owner/repo> <ref> <path-in-repo> <dest> [anchor] [optional]
#
# Several build targets pull headers from GitHub, and every CI job that
# builds does so at the same moment from the same runner egress IP.
# raw.githubusercontent.com rate-limits that burst with HTTP 429, which is
# how a green build turns red with no diff to point at. Two things keep
# that from happening:
#
#   - When a token is available the api.github.com contents endpoint is
#     used instead. It serves byte-identical content under a 5000/hr
#     per-token budget rather than a shared per-IP one. CI workflows pass
#     github.token; locally there is usually no token, and no burst either.
#   - Whatever the endpoint, a download is written to a temporary file and
#     only published once it contains an anchor the consumer needs. A 429
#     body, a 404 page or a truncated response never reaches the build.

# shellcheck shell=bash

GH_FETCH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

gh_fetch() {
    local repo="$1" ref="$2" path="$3" dest="$4"
    local anchor="${5:-}" optional="${6:-}"
    local tmp="${dest}.tmp"
    local -a curl_args=(
        --silent --show-error --fail --location
        # No --retry-delay: curl then backs off exponentially, which is what
        # a 429 wants. A fixed short delay just spends the retries inside the
        # same rate-limit window and fails anyway.
        --retry 5 --retry-all-errors --retry-max-time 120
    )
    local url

    if [ -n "${GH_FETCH_TOKEN}" ]; then
        url="https://api.github.com/repos/${repo}/contents/${path}?ref=${ref}"
        curl_args+=(
            -H "Authorization: Bearer ${GH_FETCH_TOKEN}"
            -H "Accept: application/vnd.github.raw"
        )
    else
        url="https://raw.githubusercontent.com/${repo}/${ref}/${path}"
    fi

    mkdir -p "$(dirname "${dest}")"

    if ! curl "${curl_args[@]}" "${url}" -o "${tmp}"; then
        rm -f "${tmp}"
        if [ -n "${optional}" ]; then
            echo "    Warning: ${path} not found in ${repo}@${ref}" >&2
            return 0
        fi
        echo "ERROR: failed to download ${path} from ${repo}@${ref}" >&2
        if [ -z "${GH_FETCH_TOKEN}" ]; then
            echo "       Unauthenticated; raw.githubusercontent.com rate-limits" >&2
            echo "       by IP. Set GITHUB_TOKEN to use the API budget instead." >&2
        fi
        return 1
    fi

    if [ -n "${anchor}" ] && ! grep -q "${anchor}" "${tmp}"; then
        rm -f "${tmp}"
        if [ -n "${optional}" ]; then
            echo "    Warning: ${path} lacks '${anchor}'; skipping" >&2
            return 0
        fi
        echo "ERROR: ${path} from ${repo}@${ref} does not contain '${anchor}'." >&2
        echo "       Either the download is corrupt or upstream renamed it." >&2
        return 1
    fi

    mv "${tmp}" "${dest}"
}
