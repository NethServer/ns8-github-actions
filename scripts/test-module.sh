#!/bin/bash

#
# Copyright (C) 2026 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

set -e -a

# Path to the SSH private key used to connect to the NS8 leader node
SSH_KEYFILE=${SSH_KEYFILE:-$HOME/.ssh/id_ecdsa}

# Mandatory first argument: the leader node hostname
LEADER_NODE="${1:?missing LEADER_NODE argument}"
# Optional second argument: the module image URL.
# If omitted, the script runs in "core" mode (testing ns8-core itself).
# If provided, the script runs in "module" mode (testing a module).
# Robot options start with a dash and an image URL never does, so core mode
# still works when robot options follow the leader node.
if [ -n "${2:-}" ] && [[ $2 != -* ]]; then
    IMAGE_URL="$2"
    mode="module"
    shift 2
else
    IMAGE_URL=""
    mode="core"
    shift 1
fi

# Read SSH key contents so they can be injected into the container via an env var
ssh_key="$(<$SSH_KEYFILE)"

# The venv is stored in a named volume (rftest-cache) to cache pip/rfbrowser installs across runs
venvroot=/usr/local/venv

# Select the container image and Python packages based on whether UI tests are enabled.
# UI tests require the Playwright image (Debian-based, includes browser binaries).
# Non-UI tests use a lightweight Debian slim Python image.
if [ "${RUN_UI_TESTS}" = "true" ]; then
    # NOTE: the Playwright container image version and the robotframework-browser package
    # version must be compatible with each other. If one is upgraded, the other must be
    # upgraded accordingly. Each release notes the Playwright version it was tested with:
    # https://github.com/MarketSquare/robotframework-browser/releases
    container_image="mcr.microsoft.com/playwright:v1.59.0-noble"
    packages="robotframework robotframework-sshlibrary robotframework-browser==19.14.2"
    cache_volume="rftest-cache-ui"
else
    container_image="docker.io/python:3.11-slim"
    packages="robotframework robotframework-sshlibrary"
    cache_volume="rftest-cache"
fi

# Run the test suite inside a container.
# Mounts:
#   .            → /srv/source  (source tree, including the tests/ directory)
#   rftest-cache → ${venvroot}  (named volume to persist the Python venv across runs)
# Any extra arguments are forwarded to the robot command inside the container.
# The caller must cd to the appropriate source tree before running this script.
podman_extra_args=()
if [ "${mode}" = "core" ]; then
    podman_extra_args+=(--network=host)
fi
podman run -i \
    "${podman_extra_args[@]}" \
    --volume=.:/srv/source:z \
    --volume=${cache_volume}:${venvroot} \
    --replace --name=rftest \
    --env=ssh_key \
    --env=venvroot \
    --env=LEADER_NODE \
    --env=IMAGE_URL \
    --env=COREMODULES \
    --env=RUN_UI_TESTS \
    --env=mode \
    --env=packages \
    "${container_image}" \
    bash -l -s -- "${@}" <<'EOF'
set -e

# Write the SSH private key to a temp file for use by Robot Framework tests
echo "$ssh_key" > /tmp/idssh

# PyPI is sometimes slow from a runner, and pip does not retry a download it already started.
# The variable also reaches the pip subprocess that installs build dependencies, which
# ignores the --timeout option.
export PIP_TIMEOUT=60
# A package that must be built from source fails the same way every time, because the
# container has no C compiler: return 2 at once instead of retrying. pip reports any build
# step failure as subprocess-exited-with-error, and so a failed download of the build or
# backend dependencies too: retry that one, unless a dependency itself failed to compile.
pip_install() {
    local attempt
    for attempt in 1 2 3; do
        "${venvroot}/bin/pip3" install -q "$@" 2>&1 | tee /tmp/pip-install.log
        [ "${PIPESTATUS[0]}" -eq 0 ] && return 0
        grep -q 'Failed building wheel' /tmp/pip-install.log && return 2
        if grep -q 'subprocess-exited-with-error' /tmp/pip-install.log &&
            ! grep -q -i -E 'install(ing)? (build|backend) dependencies' /tmp/pip-install.log; then
            return 2
        fi
        echo "pip install failed, attempt ${attempt} of 3" >&2
        [ "${attempt}" -lt 3 ] && sleep 10
    done
    return 1
}

# Install the Python venv and Robot Framework dependencies if not already cached.
# Cache is invalidated when the package list changes, ensuring that dependency
# updates are always picked up even on reused (self-hosted) runners.
module_pythonreq="/srv/source/tests/pythonreq.txt"
pythonreq_checksum_file="${venvroot}/.pythonreq.md5"
pythonreq_current_checksum=$(echo "${packages}" | cat - "${module_pythonreq}" 2>/dev/null | md5sum | cut -d' ' -f1)
pythonreq_cached_checksum=$(cat "${pythonreq_checksum_file}" 2>/dev/null || true)

if [ ! -x "${venvroot}/bin/robot" ] || [ "${pythonreq_current_checksum}" != "${pythonreq_cached_checksum}" ] ; then
    if ! python3 -c "import ensurepip" > /dev/null 2>&1; then
        # Playwright image has Python without venv support; install the missing package
        apt-get update -q
        apt-get install -y -q python3 python3-venv
    fi
    python3 -mvenv "${venvroot}"
    # Install the Robot Framework packages
    pip_install ${packages} || {
        echo "::error::Cannot install the test runner packages: see the pip output above"
        exit 1
    }
    # Install any module-specific Python requirements if present
    if [ -f "${module_pythonreq}" ]; then
        # The runner installs these packages itself: a version pin or a URL can replace its version
        if grep -q -i -E '^[[:space:]]*robotframework([-_.](sshlibrary|browser))?[[:space:]]*(\[[^]]*\])?[[:space:]]*([=<>!~][^;#]*)?(==|~=|<|@)' "${module_pythonreq}"; then
            echo "::warning::tests/pythonreq.txt pins robotframework, robotframework-sshlibrary or robotframework-browser, which the test runner installs itself. Remove those lines: https://github.com/NethServer/ns8-github-actions/blob/v1/docs/test-module-qemu.md#python-requirements"
        fi
        status=0
        pip_install -r "${module_pythonreq}" || status=$?
        if [ "${status}" -eq 2 ]; then
            failed=$(grep -o -E "Failed (building wheel for [^ ]+|to build '[^']+')" /tmp/pip-install.log | sed -E "s/.* //; s/'//g" | sort -u | paste -sd' ')
            pyver=$("${venvroot}/bin/python3" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
            echo "::error::Cannot build ${failed:-a package} from source while installing tests/pythonreq.txt (Python ${pyver}, no C compiler in the test container). Remove the lines the test runner already covers, and update the other pins: https://github.com/NethServer/ns8-github-actions/blob/v1/docs/test-module-qemu.md#python-requirements"
        elif [ "${status}" -ne 0 ]; then
            echo "::error::Cannot install tests/pythonreq.txt: see the pip output above"
        fi
        [ "${status}" -eq 0 ] || exit 1
    fi
    # Save the checksum so future runs can detect requirement changes
    echo "${pythonreq_current_checksum}" > "${pythonreq_checksum_file}"
    # Invalidate the rfbrowser sentinel so it is re-initialized with the new packages
    rm -f "${venvroot}/.rfbrowser_initialized"
fi

# Initialize the Playwright browser binaries for rfbrowser (UI tests only).
# A sentinel file prevents re-running this expensive step on cache hits.
if [ "${RUN_UI_TESTS}" = "true" ] && [ ! -f "${venvroot}/.rfbrowser_initialized" ] ; then
    ${venvroot}/bin/rfbrowser init
    touch "${venvroot}/.rfbrowser_initialized"
fi

cd /srv/source
mkdir -vp tests/outputs/

# Exclude UI tests if RUN_UI_TESTS is not set to "true"
if [ "${RUN_UI_TESTS}" = "true" ]; then
    ui_tag_filter=""
else
    ui_tag_filter="--exclude ui"
fi

robot_vargs=()
if [ "${mode}" = "module" ]; then
    robot_vargs+=(-v "IMAGE_URL:${IMAGE_URL}")
fi
if [ "${mode}" = "core" ] && [ -n "${COREMODULES}" ]; then
    robot_vargs+=(-v "COREMODULES:${COREMODULES}")
fi

exec ${venvroot}/bin/robot \
    -v NODE_ADDR:${LEADER_NODE} \
    "${robot_vargs[@]}" \
    -v SSH_KEYFILE:/tmp/idssh \
    -v RUN_UI_TESTS:${RUN_UI_TESTS} \
    --name test-${mode} \
    --skiponfailure unstable \
    ${ui_tag_filter} \
    -d tests/outputs "${@}" tests/
EOF
