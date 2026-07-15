#!/usr/bin/env bash
#
# Controller-image parity gate — Audit Run 37, issue #29 (criterion 3).
#
# THE FAILURE THIS EXISTS FOR (#29, "dead on arrival"):
#   `docker-compose.yml` was synced to the post-CD10 controller — its serving pool
#   connects as the least-privilege `fseven_app` role, which the controller only
#   provisions in builds at/after v0.3.0 — while the published `:latest` image was
#   still the pre-CD10 `v0.2.2` that never creates that role. So the published
#   compose and the published image were from different eras, and
#   `curl … install.sh | bash` produced a non-functional stack: migrations failed
#   as `fseven_app`, first-run bootstrap never ran, no admin user, no way to log in.
#
#   The existing env-contract gate (bootstrap-handoff-static.sh) asserts the compose
#   is INTERNALLY consistent and in parity with the controller source compose, but it
#   renders the compose in isolation — it never looks at the IMAGE the compose points
#   at, so it could not see that the image predated the capability the compose needs.
#
# WHAT THIS CHECKS:
#   The compose declares `x-fseven-controller-contract.min_controller_version` — the
#   earliest controller release whose image provides the capabilities this compose
#   depends on. This gate reads the *published* controller image's
#   `org.opencontainers.image.version` label and FAILS when it is older than that
#   floor. A stale `:latest` (the #29 condition) fails CI here, forcing a current
#   controller image to be published before the drift can reach a self-hoster.
#
# FAIL-CLOSED, everywhere (the BF14/PB6 lesson: a check that cannot observe its
#   subject, or silently skips, is not a check):
#     * missing/malformed `min_controller_version`   -> hard error (a resync likely
#                                                        dropped the key; restore it)
#     * image ref unresolvable / label unreadable     -> hard error, never "assume ok"
#     * published version not a clean vX.Y.Z release   -> hard error (a `:latest`
#                                                        that is an rc/dirty build is
#                                                        itself a release-hygiene bug)
#
# Usage:
#   tests/controller-image-parity.sh                 # check the compose's default image
#   tests/controller-image-parity.sh <image-ref>     # check a specific ref (tests/CI)
#   CONTROLLER_IMAGE_REF=<ref> tests/controller-image-parity.sh
#
# Requires docker buildx (imagetools). In CI, FSEVEN_REQUIRE_DOCKER=1 makes a missing
# buildx a hard failure rather than a skip.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT_DIR/docker-compose.yml"

die() { printf 'controller-image-parity: %s\n' "$1" >&2; exit "${2:-1}"; }

# ── 1. The version floor the compose declares ────────────────────────────────
# Only the real YAML key `  min_controller_version: vX.Y.Z` matches; the prose in
# the surrounding comment references the name without a `: <value>`.
min_line="$(grep -E '^[[:space:]]+min_controller_version:[[:space:]]*[^[:space:]#]' "$COMPOSE" || true)"
if [[ -z "$min_line" ]]; then
  die "x-fseven-controller-contract.min_controller_version is missing from docker-compose.yml.
       A compose resync likely dropped the top-level x- key. Restore it (see #29) —
       the parity gate refuses to pass without a declared floor." 1
fi
REQUIRED="$(printf '%s\n' "$min_line" | head -1 | sed -E 's/.*min_controller_version:[[:space:]]*//; s/[[:space:]]*(#.*)?$//')"
if [[ ! "$REQUIRED" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "declared min_controller_version '$REQUIRED' is not a vX.Y.Z release version" 1
fi

# ── 2. The image the compose actually ships ──────────────────────────────────
if [[ -n "${1:-}" ]]; then
  IMAGE_REF="$1"
elif [[ -n "${CONTROLLER_IMAGE_REF:-}" ]]; then
  IMAGE_REF="$CONTROLLER_IMAGE_REF"
else
  # The CONTROLLER_IMAGE default baked into the compose: `${CONTROLLER_IMAGE:-<ref>}`.
  IMAGE_REF="$(grep -E '^[[:space:]]*image:[[:space:]]*\$\{CONTROLLER_IMAGE:-' "$COMPOSE" \
    | head -1 | sed -E 's/.*:-//; s/\}.*//')"
  [[ -n "$IMAGE_REF" ]] || die "could not resolve the CONTROLLER_IMAGE default from docker-compose.yml" 1
fi

# ── 3. buildx availability (fail-closed in CI) ───────────────────────────────
if ! docker buildx version >/dev/null 2>&1; then
  if [[ "${FSEVEN_REQUIRE_DOCKER:-0}" == "1" ]]; then
    die "docker buildx is REQUIRED (FSEVEN_REQUIRE_DOCKER=1) but not available" 1
  fi
  printf 'controller-image-parity: docker buildx unavailable; SKIPPED (set FSEVEN_REQUIRE_DOCKER=1 to fail)\n'
  exit 0
fi

# ── 4. Read org.opencontainers.image.version off the published image ─────────
# Multi-arch index: the label lives on each per-platform config (.Image[<plat>]).
# Try the platforms a GitHub runner (amd64) and an Apple dev box (arm64) resolve.
read_image_version() {
  local ref="$1" plat v
  for plat in linux/amd64 linux/arm64; do
    v="$(docker buildx imagetools inspect "$ref" \
      --format "{{ index (index .Image \"$plat\").Config.Labels \"org.opencontainers.image.version\" }}" \
      2>/dev/null || true)"
    if [[ -n "$v" && "$v" != "<no value>" ]]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

PUBLISHED="$(read_image_version "$IMAGE_REF" || true)"
[[ -n "$PUBLISHED" ]] || die "could not read org.opencontainers.image.version from '$IMAGE_REF'
       (image unreachable, unauthenticated, or missing the label). Refusing to
       report parity for an image this gate cannot observe." 1
if [[ ! "$PUBLISHED" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "published image '$IMAGE_REF' reports version '$PUBLISHED', which is not a clean
       vX.Y.Z release. A community :latest must resolve to a stable release." 1
fi

# ── 5. Compare: published >= required ────────────────────────────────────────
# sort -V orders both `vX.Y.Z` tags; the smaller-or-equal of the pair must be the
# required floor for the published image to satisfy it.
smaller="$(printf '%s\n%s\n' "$PUBLISHED" "$REQUIRED" | sort -V | head -1)"
if [[ "$PUBLISHED" != "$REQUIRED" && "$smaller" != "$REQUIRED" ]]; then
  die "STALE PUBLISHED IMAGE (#29 recurrence):
       compose requires controller >= $REQUIRED, but $IMAGE_REF is $PUBLISHED.
       The published compose depends on a controller capability this image predates
       (e.g. the CD10 fseven_app serving-role provisioning). Publish a controller
       image at or after $REQUIRED so :latest is not dead-on-arrival, then re-run." 1
fi

printf 'controller-image-parity: OK — %s is %s (>= required %s)\n' "$IMAGE_REF" "$PUBLISHED" "$REQUIRED"
