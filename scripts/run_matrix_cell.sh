#!/usr/bin/env bash
# Run one compatibility-matrix cell for one architecture.
#
#   ./scripts/run_matrix_cell.sh PY_MIN PY_MAX DJ_MAJOR DJ_NEXT RDK_MAJOR RDK_NEXT ARCH OUT_DIR
#
# ARCH is "amd64" or "arm64"; the script must run on a runner of that arch
# (we build natively per arch — no QEMU emulation). Two gates:
#   1. uv lock         — does the dep graph resolve?
#   2. docker build    — does the image build all the way through?
#
# On success, the image is tagged with an arch suffix
# (matrix-py311-dj42-rdk202409-amd64). If env GH_OWNER is set the image is
# also pushed to ghcr.io/${GH_OWNER}/protwis_django_docker:<tag>; otherwise
# it stays local. This lets the same script run on CI (push) and on a
# laptop (no push). Manifest-list creation that joins amd64+arm64 happens
# in a separate merge step (scripts/merge_matrix_cells.py).
#
# Each invocation writes a JSON result file to OUT_DIR/<tag>.json. The
# merge step picks these up from both arch jobs and renders the
# compatibility-matrix.md.
#
# This script never aborts on a single-cell failure: red cells are data,
# not exceptions. Use `set -e` only around its callsites if you need that.

set -uo pipefail

if [ "$#" -ne 8 ]; then
    echo "usage: $0 PY_MIN PY_MAX DJ_MAJOR DJ_NEXT RDK_MAJOR RDK_NEXT ARCH OUT_DIR" >&2
    exit 2
fi

PY_MIN=$1; PY_MAX=$2
DJANGO_MAJOR=$3; DJANGO_NEXT=$4
RDKIT_MAJOR=$5; RDKIT_NEXT=$6
ARCH=$7
OUT=$8

case "$ARCH" in
    amd64|arm64) ;;
    *) echo "ARCH must be amd64 or arm64, got: $ARCH" >&2; exit 2 ;;
esac

mkdir -p "$OUT"

# ghcr requires repository names to be lowercase. github.repository_owner
# can have uppercase letters (e.g. protwis), so normalise once here.
GH_OWNER_LC=$(printf '%s' "${GH_OWNER:-}" | tr '[:upper:]' '[:lower:]')

# Tag suffix: drop dots so it's a valid OCI tag.
# Per-arch tag (matrix-py311-dj42-rdk202409-amd64) is what we push from
# this run; the un-suffixed BASE_TAG is reserved for the manifest list
# created by the merge step when both arches succeed.
strip_dots() { echo "$1" | tr -d '.'; }
BASE_TAG="matrix-py$(strip_dots "$PY_MIN")-dj$(strip_dots "$DJANGO_MAJOR")-rdk$(strip_dots "$RDKIT_MAJOR")"
TAG="$BASE_TAG-$ARCH"
RESULT="$OUT/$TAG.json"

echo "::group::Cell $TAG  (Python $PY_MIN, Django $DJANGO_MAJOR, RDKit $RDKIT_MAJOR, $ARCH)"

LOCK=fail
BUILD=skip
TAG_PUSHED=

# 1. Render pyproject.toml from the template, fresh per cell.
#    Wipe any uv.lock left over from a previous cell so each cell resolves
#    independently (matches what a developer would observe locally).
rm -f uv.lock
export PY_MIN PY_MAX DJANGO_MAJOR DJANGO_NEXT RDKIT_MAJOR RDKIT_NEXT
envsubst < pyproject.matrix.toml.tmpl > pyproject.toml

# 2. Gate 1: uv lock.
if timeout 120 uv lock; then
    LOCK=pass

    # 3. Gate 2: docker build.
    #    `docker buildx build --push` pushes EVERY tag attached, so we must
    #    not give it a tag that isn't pushable (e.g. an unprefixed
    #    "matrix-probe-local:..." resolves to docker.io/library/... which we
    #    cannot push to). Branch tag selection on whether GH_OWNER is set.
    BUILD_ARGS=(
        --platform   "linux/$ARCH"
        --build-arg  "PYTHON_VERSION=$PY_MIN"
        --cache-to   "type=gha,scope=$TAG,mode=max"
        --cache-from "type=gha,scope=$TAG"
    )

    if [ -n "$GH_OWNER_LC" ]; then
        REMOTE_TAG="ghcr.io/${GH_OWNER_LC}/protwis_django_docker:$TAG"
        BUILD_ARGS+=(--tag "$REMOTE_TAG" --push)
        TAG_PUSHED="$REMOTE_TAG"
    else
        BUILD_ARGS+=(--tag "matrix-probe-local:$TAG" --load)
    fi

    if timeout 600 docker buildx build "${BUILD_ARGS[@]}" .; then
        BUILD=pass
    else
        BUILD=fail
        TAG_PUSHED=
    fi
fi

# 4. Emit JSON result. This is the per-arch wire format consumed by
#    scripts/merge_matrix_cells.py, which joins the two arch jobs' output
#    and produces the final per-cell record for render_matrix_md.py.
cat > "$RESULT" <<EOF
{
  "python":   "$PY_MIN",
  "django":   "$DJANGO_MAJOR",
  "rdkit":    "$RDKIT_MAJOR",
  "arch":     "$ARCH",
  "lock":     "$LOCK",
  "build":    "$BUILD",
  "base_tag": "$BASE_TAG",
  "tag":      "$TAG",
  "pushed":   "${TAG_PUSHED:-}"
}
EOF

echo "Cell $TAG ($ARCH): lock=$LOCK build=$BUILD"
echo "::endgroup::"

# Always exit 0 — the result is in the JSON, not the exit code.
exit 0
