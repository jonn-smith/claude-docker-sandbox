#!/usr/bin/env bash
# Merge per-instance DinD volumes (claude-dind-lib*) into one target volume,
# deduplicating image layers. Run only when no sandbox containers are using
# the volumes.
#
# Usage:
#   ./consolidate_dind_volumes.sh [target-volume]
#
# Default target is claude-dind-lib-shared. Source volumes are NOT deleted —
# inspect the result, then `docker volume rm <name>...` to reclaim space.

# Matches the launcher's floor (which uses [[ -v VAR ]], a 4.2+ feature).
# macOS ships bash 3.2; install a newer one via Homebrew if you hit this.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; then
    echo "Error: this script requires bash 4.2+ (running ${BASH_VERSION:-unknown})." >&2
    echo "On macOS the system bash is 3.2 — install a newer one (e.g. 'brew install bash')" >&2
    echo "and re-invoke with that interpreter, e.g.: /opt/homebrew/bin/bash $0" >&2
    exit 1
fi

set -euo pipefail

TARGET="${1:-claude-dind-lib-shared}"
IMAGE="claude-sandbox:latest"
PATTERN='^claude-dind-lib(-.+)?$'

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Error: $IMAGE not found. Build it first (cd claude-sandbox_docker && make)." >&2
    exit 1
fi

VOLUMES=()
while IFS= read -r v; do
    [ -n "$v" ] && VOLUMES+=("$v")
done < <(docker volume ls --format '{{.Name}}' | grep -E "$PATTERN" | sort)

if [ "${#VOLUMES[@]}" -eq 0 ]; then
    echo "No claude-dind-lib* volumes found; nothing to do."
    exit 0
fi

# Refuse to run if any are mounted in a running container — concurrent dockerd
# writes to /var/lib/docker corrupt the store.
for v in "${VOLUMES[@]}"; do
    if docker ps -q --filter "volume=$v" | grep -q .; then
        echo "Error: volume $v is in use by a running container." >&2
        echo "Stop all sandbox instances before consolidating." >&2
        exit 1
    fi
done

docker volume create "$TARGET" >/dev/null

SOURCES=()
for v in "${VOLUMES[@]}"; do
    [ "$v" != "$TARGET" ] && SOURCES+=("$v")
done

if [ "${#SOURCES[@]}" -eq 0 ]; then
    echo "Only target $TARGET present; nothing to consolidate."
    exit 0
fi

echo "Consolidating ${#SOURCES[@]} volume(s) into $TARGET:"
for v in "${SOURCES[@]}"; do echo "  $v"; done
echo

DST_CID=""
SRC_CID=""
cleanup() {
    if [ -n "$SRC_CID" ]; then
        docker rm -f "$SRC_CID" >/dev/null 2>&1 || true
    fi
    if [ -n "$DST_CID" ]; then
        docker rm -f "$DST_CID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# Spawn a temporary dind container against a volume. Uses the same image and
# runtime as the production launcher so storage layout is guaranteed to match.
# (No --rm — we want logs to survive a startup failure for diagnosis.)
spawn_dind() {
    local vol=$1
    local cid
    cid=$(docker run -d --runtime=sysbox-runc \
        -v "$vol:/var/lib/docker" \
        --entrypoint /bin/bash \
        "$IMAGE" \
        -c "/home/claude/start_dockerd.sh && exec sleep infinity")

    local i
    for i in $(seq 1 60); do
        if docker exec "$cid" docker info >/dev/null 2>&1; then
            echo "$cid"
            return 0
        fi
        # If the container already died, bail fast.
        if [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != "true" ]; then
            echo "Error: dind container exited before dockerd became ready. Logs:" >&2
            docker logs "$cid" >&2 || true
            docker rm -f "$cid" >/dev/null 2>&1 || true
            return 1
        fi
        sleep 1
    done

    echo "Error: dockerd in container $cid did not become ready within 60s. Logs:" >&2
    docker logs "$cid" >&2 || true
    docker rm -f "$cid" >/dev/null 2>&1 || true
    return 1
}

echo "==> Starting target daemon for $TARGET"
DST_CID=$(spawn_dind "$TARGET")

for src in "${SOURCES[@]}"; do
    echo
    echo "==> Reading from $src"
    SRC_CID=$(spawn_dind "$src")

    IMAGES=()
    while IFS= read -r line; do
        [ -n "$line" ] && IMAGES+=("$line")
    done < <(docker exec "$SRC_CID" docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -v '^<none>' || true)

    echo "    ${#IMAGES[@]} tagged image(s) to migrate"
    for img in "${IMAGES[@]:-}"; do
        [ -z "$img" ] && continue
        printf "    -> %-60s " "$img"
        # Stream save->load directly between the two inner daemons; no host disk used.
        if docker exec "$SRC_CID" docker save "$img" | docker exec -i "$DST_CID" docker load >/dev/null; then
            echo "ok"
        else
            echo "FAILED"
        fi
    done

    docker rm -f "$SRC_CID" >/dev/null
    SRC_CID=""
done

docker rm -f "$DST_CID" >/dev/null
DST_CID=""
trap - EXIT

echo
echo "Consolidation complete. Source volumes are still present:"
for v in "${SOURCES[@]}"; do echo "  $v"; done
echo
echo "Inspect $TARGET, then reclaim space with:"
echo "  docker volume rm ${SOURCES[*]}"
