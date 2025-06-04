#!/usr/bin/env bash

BASE=$(dirname "$(readlink -f "${0}")")
install=$BASE/install

set -eu

function parse_parameters() {
    while ((${#})); do
        case ${1} in
            all | binutils | deps | llvm | release) ACTION=${1} ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_binutils
    do_release
}

function do_binutils() {
    "${BASE}"/build-binutils.py -t arm aarch64 x86_64
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0
    sudo apt-get install -y --no-install-recommends \
        bc \
        bison \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        flex \
        gcc \
        g++ \
        git \
        libelf-dev \
        libssl-dev \
        lld \
        make \
        ninja-build \
        python3 \
        texinfo \
        xz-utils \
        zlib1g-dev
}

function do_llvm() {
    EXTRA_ARGS=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && EXTRA_ARGS+=(--no-ccache)
    "${BASE}"/build-llvm.py \
        --assertions \
        --branch "release/16.x" \
        --build-stage1-only \
        --check-targets clang lld llvm \
        --install-stage1-only \
        --projects "clang;lld" \
        --shallow-clone \
        --targets AArch64 ARM X86 \
        "${EXTRA_ARGS[@]}"
}

# --- Function to Create GitHub Release ---
function do_release() {
    echo "--- Preparing GitHub Release ---"

    # Ensure GH_TOKEN is available (from GitHub Actions secrets or local environment)
    if [[ -z ${GH_TOKEN:-} ]]; then
        echo "Error: GH_TOKEN environment variable not set. Cannot create GitHub release."
        echo "Make sure to set GH_TOKEN (e.g., secrets.GITHUB_TOKEN in GitHub Actions)."
        exit 1 # Exit if token is missing
    fi

    # Determine repository details (owner/name)
    # GITHUB_REPOSITORY is available in GitHub Actions (e.g., "owner/repo-name")
    local REPO_OWNER
    local REPO_NAME
    if [[ -n ${GITHUB_REPOSITORY:-} ]]; then
        REPO_OWNER=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f1)
        REPO_NAME=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f2)
    else
        echo "Error: GITHUB_REPOSITORY environment variable not set. This script expects to run in a GitHub Actions context."
        echo "If running locally, you must manually set GITHUB_REPOSITORY (e.g., 'your-org/your-repo')."
        exit 1
    fi

    # Define toolchain archive name and path
    # Based on your do_llvm function, the toolchain installs to "$install"
    local TOOLCHAIN_ARCHIVE_NAME
    TOOLCHAIN_ARCHIVE_NAME="llvm-toolchain-$(date +%Y.%m.%d).tar.xz"
    local TOOLCHAIN_ARCHIVE_PATH="${BASE}/${TOOLCHAIN_ARCHIVE_NAME}"

    echo "Compressing toolchain from '$install' to '$TOOLCHAIN_ARCHIVE_PATH'"
    # Navigate into the install directory to tar its contents directly
    (cd "$install" && tar -cJvf "$TOOLCHAIN_ARCHIVE_PATH" ./*)

    if [ ! -f "$TOOLCHAIN_ARCHIVE_PATH" ]; then
        echo "Error: Toolchain archive '$TOOLCHAIN_ARCHIVE_PATH' was not created."
        exit 1
    fi

    # Determine release tag name
    local RELEASE_TAG
    RELEASE_TAG="llvm-toolchain-$(date +%Y.%m.%d)-${GITHUB_RUN_NUMBER:-$(date +%s)}" # Uses run number or timestamp for unique tag
    local RELEASE_NAME="LLVM Toolchain ${RELEASE_TAG}"
    local RELEASE_BODY
    RELEASE_BODY="Automated release of LLVM Toolchain.\nBuilt on: $(date)\nTag: ${RELEASE_TAG}\n\nThis release contains the complete LLVM, Clang, and LLD toolchain as built by your script."

    echo "Creating GitHub release with tag: ${RELEASE_TAG}"

    # Create the release via GitHub API (HTTP POST)
    local API_RESPONSE
    API_RESPONSE=$(
        curl -sS -X POST \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Authorization: token ${GH_TOKEN}" \
            "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases" \
            -d "{
            \"tag_name\": \"${RELEASE_TAG}\",
            \"name\": \"${RELEASE_NAME}\",
            \"body\": \"${RELEASE_BODY}\",
            \"draft\": false,
            \"prerelease\": false
        }"
    )

    local UPLOAD_URL
    UPLOAD_URL=$(echo "${API_RESPONSE}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('upload_url', '').replace('{?name,label}', ''))")
    local RELEASE_ID
    RELEASE_ID=$(echo "${API_RESPONSE}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', ''))")

    if [[ -z "$UPLOAD_URL" || -z "$RELEASE_ID" ]]; then
        echo "Error: Failed to create GitHub release."
        echo "API Response: ${API_RESPONSE}"
        exit 1
    fi

    echo "Release created successfully. Uploading asset..."

    # Upload the compressed toolchain as a release asset
    local UPLOAD_RESPONSE
    UPLOAD_RESPONSE=$(
        curl -sS -X POST \
            -H "Content-Type: application/octet-stream" \
            -H "Authorization: token ${GH_TOKEN}" \
            --data-binary "@${TOOLCHAIN_ARCHIVE_PATH}" \
            "${UPLOAD_URL}?name=${TOOLCHAIN_ARCHIVE_NAME}"
    )

    local ASSET_ID
    ASSET_ID=$(echo "${UPLOAD_RESPONSE}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', ''))")

    if [[ -z "$ASSET_ID" ]]; then
        echo "Error: Failed to upload asset."
        echo "Upload Response: ${UPLOAD_RESPONSE}"
        exit 1
    fi

    echo "Toolchain uploaded successfully to release: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/${RELEASE_TAG}"
    echo "--- GitHub Release Process Complete ---"
}
# --- End of do_release function ---

parse_parameters "${@}"
do_"${ACTION:=all}"
