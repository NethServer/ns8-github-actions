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

podman run -i \
    --volume=.:/srv/source:z \
    --volume=rftest-cache:${venvroot}:z \
    --replace --name=rftest \
    --env=ssh_key \
    --env=venvroot \
    --env=LEADER_NODE \
    --env=IMAGE_URL \
    --env=RUN_UI_TESTS \
    docker.io/python:3.11-alpine \
    ash -l -s -- "${@}" <<'EOF'
set -e
echo "$ssh_key" > /tmp/idssh
if [ ! -x ${venvroot}/bin/robot ] ; then
    python3 -mvenv ${venvroot} --upgrade
    ${venvroot}/bin/pip3 install -q -r /srv/source/tests/pythonreq.txt
fi
cd /srv/source
mkdir -vp tests/outputs/
exec ${venvroot}/bin/robot \
    -v NODE_ADDR:${LEADER_NODE} \
    -v IMAGE_URL:${IMAGE_URL} \
    -v SSH_KEYFILE:/tmp/idssh \
    -v RUN_UI_TESTS:${RUN_UI_TESTS} \
    --name test-ns8-module \
    --skiponfailure unstable \
    -d tests/outputs "${@}" tests/
EOF
