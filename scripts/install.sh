#!/usr/bin/env bash
# Thin bootstrap for the single-command installer. All real logic lives in
# scripts/install.py, run through `uv` — see that file for the actual
# first-run/upgrade/--check flows. This script only does the things a Python
# process can't do for itself: reclaim a real terminal when piped through
# `curl | bash`, get install.py and its supporting files onto disk, and make
# sure `uv` exists.
#
# Piping this script through `bash` (`curl -fsSL .../install.sh | bash`)
# consumes stdin for the script body, so a bare `read` won't see the
# terminal. Reattach stdin to the controlling tty up front, before anything
# downstream (including install.py's interactive bootstrap prompts) needs it.
# If there is no controlling terminal at all (headless CI/cron), leave stdin
# alone — install.py requires --yes for anything that would otherwise prompt,
# and errors clearly instead of hanging.
set -euo pipefail

if [ ! -t 0 ]; then
  exec < /dev/tty 2>/dev/null || true
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "install.sh: docker is required but not found on PATH." >&2
  echo "Install Docker (https://docs.docker.com/get-docker/) and re-run." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  # Compose v2 is the plugin subcommand `docker compose` (two words). The
  # distro `docker.io` package ships the engine plus *legacy* standalone
  # `docker-compose` v1 (one word, e.g. 1.25) but not the v2 plugin, so
  # detecting v1 lets us point at the exact fix instead of a dead-end.
  if command -v docker-compose >/dev/null 2>&1; then
    cat >&2 <<'EOF'
install.sh: found 'docker-compose' (standalone; often legacy v1) but not 'docker compose' (v2).
Compose v2 is required. The standalone 'docker-compose' command is not sufficient
and will not be used.

On Ubuntu, install the v2 plugin from Docker's official apt repo
('apt-get install docker-compose-plugin' fails until the repo is added):

  sudo apt-get update && sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update && sudo apt-get install -y docker-compose-plugin

Or install the standalone Compose v2 binary. Full instructions:
  https://docs.docker.com/compose/install/

Then re-run this script.
EOF
    exit 1
  fi
  echo "install.sh: 'docker compose' (v2) is required but not available." >&2
  echo "Install Docker Compose v2 (https://docs.docker.com/compose/install/) and re-run." >&2
  exit 1
fi

# No `${BASH_SOURCE[0]}`-relative repo-root lookup here on purpose: when this
# script is piped via `curl | bash`, there is no on-disk script file to
# resolve a path from at all. Instead, operate wherever the operator already
# is (or MCP_INSTALL_DIR, for scripted use). There is no from-source install
# path - the published image is the only supported source.
INSTALL_DIR="${MCP_INSTALL_DIR:-$(pwd)}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || { echo "install.sh: failed to enter install directory: ${INSTALL_DIR}" >&2; exit 1; }

# Default the image source to ACR; a pre-existing .env value always wins.
if [ ! -f .env ] || ! grep -q "^[[:space:]]*MCP_IMAGE_BASE[[:space:]]*=" .env; then
  printf 'MCP_IMAGE_BASE=%s\n' "crcustconstgappeaus001.azurecr.io/forescout/forescout-mcp-eyesight" >> .env
fi

# Do not extract into, or create project directories within, an arbitrary
# existing directory. A pre-created .env is allowed for unattended installs
# that need to override the image reference before the bundle is extracted.
if [ -f docker-compose.yml ] && ! grep -q "container_name: eyesight_mcp$" docker-compose.yml; then
  echo "install.sh: $(pwd)/docker-compose.yml exists but doesn't look like the forescout-eyesight-mcp bundle." >&2
  echo "install.sh: run this in an empty directory (or set MCP_INSTALL_DIR to one) and re-run." >&2
  exit 1
fi
if [ ! -f docker-compose.yml ] && find . -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name secrets ! -name state ! -name nginx -print -quit | grep -q .; then
  echo "install.sh: $(pwd) is not empty. Run this in an empty directory (or set MCP_INSTALL_DIR to one) and re-run." >&2
  exit 1
fi

# Pre-create the bind-mount sources docker-compose.yml expects (secrets/,
# state/, nginx/certs/, nginx/client-ca/) as the invoking user, before any
# `docker compose`/`docker cp` touches this directory. Docker auto-creates a
# missing bind-mount source on first use, but it does so as root, and the mcp
# container runs as MCP_RUNTIME_UID/GID (the invoking user on Linux, set below)
# - so a root-created secrets/ or state/ directory then fails every write
# (e.g. bootstrap add-agent's agents.json.tmp) with a permission error.
mkdir -p secrets state nginx/certs nginx/client-ca

# A pre-created .env (see the comment above) may set MCP_IMAGE_BASE/TAG for
# mirror/air-gapped installs. Parse just these two keys - never source the
# file, since it isn't trusted code - so the override takes effect for this
# initial pull/extraction too, not just for `docker compose` later on.
env_file_value() {
  local key="$1" line value
  [ -f .env ] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" .env | tail -n1)" || return 0
  value="${line#*=}"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
  printf '%s' "$value"
}

MCP_IMAGE_BASE="${MCP_IMAGE_BASE:-$(env_file_value MCP_IMAGE_BASE)}"
MCP_IMAGE_BASE="${MCP_IMAGE_BASE:-crcustconstgappeaus001.azurecr.io/forescout/forescout-mcp-eyesight}"
MCP_IMAGE_TAG="${MCP_IMAGE_TAG:-$(env_file_value MCP_IMAGE_TAG)}"
MCP_IMAGE_TAG="${MCP_IMAGE_TAG:-latest}"
MCP_IMAGE="${MCP_IMAGE_BASE}:${MCP_IMAGE_TAG}"

BUNDLE_FILES=(
  docker-compose.yml
  .env.example
  scripts/install.sh
  scripts/install.py
  config/eyesight.sample.json
  config/tools.sample.json
  config/approvals.sample.json
  artifacts/Policies.sample.xml
  artifacts/Groups.sample.xml
  artifacts/Segments.sample.xml
)

bundle_complete=1
for bundle_file in "${BUNDLE_FILES[@]}"; do
  if [ ! -f "$bundle_file" ]; then
    bundle_complete=0
    break
  fi
done

if [ -f docker-compose.yml ] && [ "$bundle_complete" != "1" ]; then
  echo "install.sh: $(pwd) contains an incomplete forescout-eyesight-mcp bundle." >&2
  echo "install.sh: use an empty directory (or restore the missing bundle files) and re-run." >&2
  exit 1
fi

# Pull the published image and lift its self-extracting install bundle
# (docker-compose.yml, .env.example, this same install.py, and the sample
# config/artifact files bootstrap init-config copies from - see the
# Dockerfile's "Self-extracting install bundle" comment for the exact list).
if [ "$bundle_complete" != "1" ]; then
  echo "install.sh: no docker-compose.yml in $(pwd); pulling install files from ${MCP_IMAGE}"
  if ! docker pull "$MCP_IMAGE"; then
    echo "install.sh: could not pull ${MCP_IMAGE}. Check network access to ${MCP_IMAGE_BASE%%/*} and the image/tag name, then re-run." >&2
    exit 1
  fi
  cid="$(docker create "$MCP_IMAGE")"
  extract_ok=1
  docker cp "${cid}:/app/dist/." . || extract_ok=0
  docker rm "$cid" >/dev/null 2>&1 || true
  if [ "$extract_ok" != "1" ] || [ ! -f docker-compose.yml ]; then
    echo "install.sh: failed to extract install files from ${MCP_IMAGE}." >&2
    # The "not empty" guard above already established that, other than
    # .env/secrets/state/nginx, this directory held none of the bundle's
    # top-level entries before this attempt - so anything docker cp landed
    # under them belongs to this failed extraction, not to the operator.
    # Remove it so a re-run's guard sees an empty directory again instead of
    # permanently requiring manual cleanup after a transient failure
    # (permissions, disk full, interrupted docker cp).
    rm -rf docker-compose.yml .env.example scripts config artifacts
    exit 1
  fi
  echo "install.sh: install files extracted into $(pwd)"
fi

assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --yes | -y) assume_yes=1 ;;
  esac
done

if ! command -v uv >/dev/null 2>&1; then
  echo "install.sh: uv is not on PATH." >&2
  if [ "$assume_yes" != "1" ]; then
    read -r -p "Install uv now (curl -LsSf https://astral.sh/uv/install.sh | sh)? [y/N] " reply
    case "$reply" in
      [Yy]*) ;;
      *)
        echo "install.sh: uv is required. Install it yourself (https://docs.astral.sh/uv/) and re-run." >&2
        exit 1
        ;;
    esac
  fi
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # The installer places uv under ~/.local/bin (or ~/.cargo/bin on older
  # releases) without necessarily updating this shell's PATH.
  export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
  if ! command -v uv >/dev/null 2>&1; then
    echo "install.sh: uv installed but is still not on PATH. Open a new shell and re-run." >&2
    exit 1
  fi
fi

exec uv run scripts/install.py "$@"
