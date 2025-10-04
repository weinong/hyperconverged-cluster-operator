#!/usr/bin/env bash

set -ex

if docker ps >/dev/null; then
    _cri_bin=docker
    >&2 echo "selecting docker as container runtime"
else
    >&2 echo "no working container runtime found. Neither docker nor podman seems to work."
    exit 1
fi

CRI_BIN=${_cri_bin}
CRI_INSECURE=${_cri_insecure}
