# mz-watch

A responsive terminal dashboard for Materialize availability demonstrations.
Built with Zig 0.17, libvaxis and libpq.

## Build

Install Zig 0.17.0 and libpq development files (`apt install libpq-dev` on Debian/Ubuntu).

```sh
zig build
zig build run
zig build test
```

The `test` target always executes all unit tests. Compilation remains cached.

For fast iteration on x86_64 Linux, keep `zig build -fincremental --watch` running
in one terminal and launch `./zig-out/bin/mz-watch` in another. Rebuilding does not
hot-reload a running dashboard. Use `-Dllvm=true` when an LLVM build is needed.

Zig 0.17's native watcher requires Linux 6.5 or newer. On older kernels such as
Linux 6.1, it can panic after a successful build. Use
ordinary `zig build` invocations there. No host or compiler changes are needed
to run the dashboard. See [the upstream watcher issue](https://codeberg.org/ziglang/zig/issues/31394).

## Dashboard

Add endpoints with `e` and canaries with `a`, or click the corresponding buttons.
Endpoints accept standard libpq URIs, connection strings, or `service=name`.
For a local Materialize instance, for example:

```text
hostaddr=127.0.0.1 port=6875 user=materialize dbname=materialize
```

Use `sslmode=verify-full` with the appropriate CA for remote TLS endpoints.
Prefer `.pgpass` or libpq service files to embedding passwords. Connection strings
are saved verbatim in the private configuration file, but not displayed after
creation. Embedded passwords are stored in plaintext.

The Canaries and Endpoints tabs select the detail panel. `1` and `2` select those
tabs, `j`/`k` or the arrow keys select an item, `p` pauses the selected canary,
and `x` opens removal confirmation. Tab moves focus between controls, Enter
activates them, and Escape cancels a form. Quit with `q` or Ctrl-C.
In the Endpoints tab, use the previous/next canary buttons or left/right keys to
inspect each endpoint/canary pair. Current activity and the last completed
result are shown separately, so a retry does not erase the last diagnostic.

Light mode is the default, with pale backgrounds, bordered panels and teal
accents. A terminal color-scheme report switches the palette automatically.
At 80x24 both charts fit. Wider terminals also show both item lists.
Smaller terminals keep controls and measurements accessible, hiding charts when
there is not enough room.

There is no automatic endpoint discovery, failover policy, or process control.

## Configuration

Endpoints and canaries load on startup. Adding, removing, pausing or resuming
items automatically saves `~/.config/mz-watch/config.zon`, or
`$XDG_CONFIG_HOME/mz-watch/config.zon` when that variable is an absolute path.
Measurements reset each session. Files are atomically replaced with permissions
`0600`. Missing directories are created with permissions `0700`.

The format is ZON, supported by Zig's standard library. For example:

```zig
.{
    .endpoints = .{
        .{ .name = "local", .conninfo = "service=demo" },
    },
    .canaries = .{
        .{
            .name = "availability",
            .sql = "SELECT 1",
            .interval_ms = 1000,
            .timeout_ms = 5000,
            .paused = false,
        },
    },
}
```

Edit the file while the dashboard is stopped. Use one dashboard per configuration
file. Autosave rewrites the file, including comments. Invalid configuration stops
startup without modifying the file or printing its contents. If saving fails,
the dashboard shows an error and keeps your changes in memory. The previous
saved file stays intact. A subsequent configuration change retries saving.

## Measurements

Each scheduled run races one SQL statement across all available endpoints.
Every canary/endpoint pair has its own persistent connection and at most one
outstanding request. Busy or disconnected endpoints are reported as skipped.
Missed ticks are not queued or replayed as catch-up bursts.

The first **complete successful result** wins. Latency uses a monotonic clock,
from the run's start through receipt of all query results. It includes a
`BEGIN READ ONLY` round trip, query planning, execution and result transfer, but
not the cleanup `ROLLBACK`. Errors never win. A run without any success is
counted as failed, including runs where every endpoint was busy or unavailable.
With no endpoints configured, no runs are sampled.

The histogram and mean use the current second and preceding 59 seconds.
The time plot shows per-second means. Seconds without successful samples are
gaps, not zero latency. Success/failure counters are lifetime totals for that
canary. Endpoint detail shows outcomes, skipped attempts, wins and SQLSTATEs
without exposing credential-bearing server error text.

Use read-only queries and preferably a read-only database user. One-statement
extended protocol and read-only transactions reject ordinary writes, but are
not a sandbox for privileged functions. Independent reads may select different
timestamps. Racing queries demonstrates availability, not result equality.
It multiplies database load by the number of participating endpoints.

Timeouts and removal close the affected connections. This bounds client work,
but does not guarantee immediate server-side cancellation. Configure a server
statement timeout if that guarantee matters. DNS lookup inside libpq can block
the database runner, though not the UI. Numeric addresses or `hostaddr` avoid
that limitation in a demo.

## Verification

```sh
zig fmt --check build.zig src
zig build test
scripts/integration.sh
```

The integration script starts an isolated PostgreSQL container on a randomly
allocated localhost port and removes it afterward. It checks early winners,
losing outcomes, failures, read-only enforcement, deadlines, skipped schedules,
in-flight connection loss and recovery, configuration changes and shutdown.
Requires Docker. `ZIG` can override the
compiler executable.

For the actual terminal UI, install the test-only dependency `pyte==0.8.2` in a
Python environment, build the dashboard, and run:

```sh
MZ_WATCH_SMOKE_CONNINFO='hostaddr=127.0.0.1 port=6875 user=materialize dbname=materialize' \
  python scripts/terminal-smoke.py
```

Use a disposable Materialize or PostgreSQL endpoint. The test exercises mouse
buttons, forms, real SQL samples, both charts, every endpoint/canary pair, light
and dark palettes, resize, pause, removal, persistence across restarts and save
failure recovery. Its configuration is isolated in a temporary directory.
