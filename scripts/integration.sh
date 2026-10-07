#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
zig="${ZIG:-zig}"
image="${MZ_WATCH_POSTGRES_IMAGE:-postgres:17-alpine}"
container=""
cleanup() {
    if [[ -n "$container" ]]; then
        docker rm -f "$container" >/dev/null
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Docker allocates a free host port. No reusable name or fixed port is shared
# between parallel invocations. Trust auth is confined to this disposable server.
container="$(docker run -d --rm -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_DB=mz_watch_test -p 127.0.0.1::5432 "$image")"
ready=false
for ((attempt = 0; attempt < 120; attempt++)); do
    if docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -d mz_watch_test >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.5
done
if [[ "$ready" != true ]]; then
    echo 'Disposable PostgreSQL did not become ready within 60 seconds.' >&2
    exit 1
fi
port="$(docker port "$container" 5432/tcp)"
port="${port##*:}"
[[ "$port" =~ ^[0-9]+$ ]]
docker exec "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d mz_watch_test \
    -c 'CREATE TABLE mz_watch_integration_writes (value integer NOT NULL)' >/dev/null
export MZ_WATCH_TEST_CONNINFO="host=127.0.0.1 port=$port dbname=mz_watch_test user=postgres connect_timeout=5"
# Also bound a stuck libpq call or worker join, including on assertion failures.
timeout "${MZ_WATCH_INTEGRATION_TIMEOUT:-300s}" "$zig" build integration -- "$@"
