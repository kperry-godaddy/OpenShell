#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Fetches the ANS identity extension at a pinned release and runs its OpenShell
# smoke test, which downloads the pinned OpenShell release, starts a gateway on
# the Docker driver with the extension registered, creates sandboxes, and
# asserts the identity guarantees described in README.md.

ANS_OPENSHELL_REPO="${ANS_OPENSHELL_REPO:-https://github.com/agentnameservice/ans-openshell.git}"
ANS_OPENSHELL_REF="${ANS_OPENSHELL_REF:-v0.1.1}"

usage() {
  cat <<USAGE
usage: $0 [--keep-running|--print-config]

Clones the ANS identity extension at $ANS_OPENSHELL_REF into a temporary
directory and runs its OpenShell smoke test. Arguments are passed through.

Options:
  --keep-running   Leave the gateway, middleware, callee and sandbox running
                   after the checks pass, until Ctrl-C.
  --print-config   Print the rendered gateway and middleware configuration
                   and exit.
  -h, --help       Show this help.

Environment:
  ANS_SMOKE_HOST      Non-loopback IPv4 address of this machine that sandbox
                      containers can reach. Detected when unset.
  ANS_SMOKE_CACHE     Where OpenShell release assets are cached.
  ANS_OPENSHELL_REF   Extension tag or branch to run (default: $ANS_OPENSHELL_REF).
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --keep-running | --print-config) ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for cmd in git make go docker curl jq tar; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 1
  }
done

WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "INFO fetching the ANS identity extension at $ANS_OPENSHELL_REF"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ANS_OPENSHELL_REF" "$ANS_OPENSHELL_REPO" "$WORK/ans-openshell"
echo "INFO extension commit $(git -C "$WORK/ans-openshell" rev-parse HEAD)"

if [[ "$#" -eq 0 ]]; then
  make -C "$WORK/ans-openshell" openshell-smoke
else
  "$WORK/ans-openshell/examples/openshell-smoke/smoke.sh" "$@"
fi
