#!/usr/bin/env bash

set -eo pipefail

apt-get update -y
apt-get install -y firefox-esr


# check to see if `nbc` command is available
if ! command -v nbc &> /dev/null
then
    echo "nbc could not be found, please install nbc to proceed."
    exit 1
fi

# download the installation image for offline use
nbc download --image ghcr.io/frostyard/snow:latest --for-install