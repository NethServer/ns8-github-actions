#!/bin/bash

#
# Copyright (C) 2026 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

set -e -a

SSH_KEYFILE=${SSH_KEYFILE:-$HOME/.ssh/id_rsa}

LEADER_NODE="${1:?missing LEADER_NODE argument}"
IMAGE_URL="${2:?missing IMAGE_URL argument}"
shift 2

ssh_key="$(< $SSH_KEYFILE)"
venvroot=/usr/local/venv

echo "Test! RUN_UI_TESTS=${RUN_UI_TESTS} ////"

if [ "${RUN_UI_TESTS}" = "true" ]; then
    container_image="mcr.microsoft.com/playwright/python:v1.51.0-noble"
    container_shell="bash"
    pythonreq="/srv/source/tests/pythonreq-ui.txt"
else
    container_image="docker.io/python:3.11-alpine"
    container_shell="ash"
    pythonreq="/srv/source/tests/pythonreq.txt"
fi

podman run -i \
    --volume=.:/srv/source:z \
    --volume=rftest-cache:${venvroot}:z \
    --replace --name=rftest \
    --env=ssh_key \
    --env=venvroot \
    --env=LEADER_NODE \
    --env=IMAGE_URL \
    --env=RUN_UI_TESTS \
    --env=pythonreq \
    "${container_image}" \
    ${container_shell} -l -s -- "${@}" <<'EOF'
set -e
echo "$ssh_key" > /tmp/idssh
if [ ! -x ${venvroot}/bin/robot ] ; then
    if command -v apt-get > /dev/null 2>&1; then
        apt install -y -q python3.12-venv
    fi
    python3 -mvenv ${venvroot} --upgrade
    ${venvroot}/bin/pip3 install -q -r ${pythonreq}
fi
if [ "${RUN_UI_TESTS}" = "true" ] && [ ! -f ${venvroot}/.rfbrowser_initialized ] ; then
    ${venvroot}/bin/rfbrowser init
    touch ${venvroot}/.rfbrowser_initialized
fi
cd /srv/source
mkdir -vp tests/outputs/

# Exclude UI tests if RUN_UI_TESTS is not set to "true"
if [ "${RUN_UI_TESTS}" = "true" ]; then
    ui_tag_filter=""
else
    ui_tag_filter="--exclude ui"
fi

exec ${venvroot}/bin/robot \
    -v NODE_ADDR:${LEADER_NODE} \
    -v IMAGE_URL:${IMAGE_URL} \
    -v SSH_KEYFILE:/tmp/idssh \
    -v RUN_UI_TESTS:${RUN_UI_TESTS} \
    --name test-ns8-module \
    --skiponfailure unstable \
    ${ui_tag_filter} \
    -d tests/outputs "${@}" tests/
EOF
