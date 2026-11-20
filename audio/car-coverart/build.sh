#!/bin/sh
# Cross-build the arm64 cover-art binaries on this desk.
# Needs docker or podman. Does not touch the phone.
#
# Artifacts land in ~/.local/share/fp5-coverart-staging/ (not in git).
# The flat set there is what install.sh expects to sit beside itself.
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)
STAGE=${FP5_COVERART_STAGE:-"$HOME/.local/share/fp5-coverart-staging"}
IMAGE=${FP5_COVERART_IMAGE:-debian:forky@sha256:15f483ba923e165dde04ac535be6f479a62008ae5fefb42fed21896288ce447a}

if command -v docker >/dev/null 2>&1; then
	RUNNER=docker
elif command -v podman >/dev/null 2>&1; then
	RUNNER=podman
else
	echo "ABORT: need docker or podman"
	exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "runner: $RUNNER"
echo "image:  $IMAGE"
echo "stage:  $STAGE"

# Keep downloaded debs across retries. The container itself is ephemeral.
"$RUNNER" volume create fp5-coverart-aptcache >/dev/null

# linux/amd64: this desk has no qemu-user binfmt, so the container is
# native amd64 and cross-compiles with gcc-aarch64-linux-gnu.
exec "$RUNNER" run --rm --platform linux/amd64 \
	-v "$ROOT:/src:ro" \
	-v "$STAGE:/out" \
	-v fp5-coverart-aptcache:/var/cache/apt/archives \
	"$IMAGE" \
	bash /src/build-inner.sh
