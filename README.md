# mz-watch

A responsive terminal dashboard for Materialize availability demonstrations.
Built with Zig 0.17, libvaxis and libpq.

## Build

Install Zig 0.17.0 and libpq development files (`apt install libpq-dev` on Debian/Ubuntu).
Controller monitoring also requires `curl` on PATH. HTTP polling uses bounded,
cancelable curl processes, including for DNS resolution and HTTPS verification.

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
are saved verbatim in the private configuration file. Endpoint details show
normalized explicit connection options with password fields redacted.
Embedded passwords are stored in plaintext on disk.

The Canaries tab shows queries and winner-latency charts. The Endpoints tab
compares destinations for one canary. `1` and `2` select those
tabs, `j`/`k` or the arrow keys select an item, `p` pauses the selected canary,
and `x` opens removal confirmation. Tab moves focus between controls, Enter
activates them, and Escape cancels a form. Quit with `q` or Ctrl-C.
Forms and removal confirmations are centered overlays over a dimmed dashboard.
Removal defaults to Confirm, so Enter removes the item. Escape or Cancel closes
the dialog without changing it. The background cannot be clicked while a dialog
is open.
In the Endpoints tab, use `h`/`l` or the previous/next canary buttons to
choose the canary in the fixed header. All endpoint cards show results for that
same query, and scroll together below it. Current activity and the last completed
result are shown separately, so a retry does not erase the last diagnostic.
Left/right arrows remain aliases for `h`/`l`.

Each tab shows a selectable list, with full-width result cards for endpoints.
`j`/`k` select items and keep the selection in
view. Mouse-wheel scrolling browses the list without changing the selected
item. Labels are left-aligned, with status summaries and faint separators.
Click a row or endpoint card to select it, or click and drag the scrollbar to
browse. Removal targets the selected item, not the first visible item.
The tabs retain their own scroll positions within the session.

Light mode is the default, with pale backgrounds, bordered panels and teal
accents. A terminal color-scheme report switches the palette automatically.
The active tab is white in light mode, with a teal inactive tab. Keyboard focus
is underlined rather than changing which tab looks active. At 80x24 both charts
fit below the canary list. Wider terminals put the canary list beside its charts.
The Endpoints tab shows multiple cards at both 80x24 and wider sizes.
Smaller terminals keep controls and measurements accessible, hiding charts when
there is not enough room.

## Controllers, services and collections

Add a controller with `c` or **+ Controller**. Give it a name, HTTP(S) base URL
(for example `http://127.0.0.1:6882`) and shared libpq options for its adapters
(default `user=materialize dbname=materialize`). Add both old and new controllers
during an upgrade. Each controller polls independently, approximately once per
second. Slow or unavailable controllers do not block the UI or other controllers.
Controller HTTP is read-only and has no built-in authentication. Protect remote
access outside controllerd, such as through a trusted tunnel.

**Services** (`3`) groups adapters, replicas and pubsub under each controller.
It shows deployment generation, observed process status, restart counts,
provisioning errors and labeled addresses. Adapter SQL readiness is distinct
from process status. `online` is not a SQL-readiness guarantee. Select any row
in a controller group and press `x` to remove that controller from monitoring.
This never stops processes or changes controllerd state.

**Collections** (`4`) shows ID, qualified name and committed catalog since for
one controller at a time. `h`/`l` and the header buttons select the controller.
Press `/` or **Filter** to apply name and/or ID patterns. These are case-sensitive
SQL LIKE patterns: `%` matches any sequence, `_` one character and backslash
escapes literals. Both filters must match. Empty fields disable that filter.
A name filter excludes unnamed entries. Applied filters and controller selection
are saved. New filters clear the previous result until a matching response arrives.
`unknown` means the frontier is unavailable, while `[]` means an empty frontier.
Since is the committed combined catalog frontier, not physical Persist since.
Inspection works without a serving SQL adapter and acquires no read holds.

Adapters advertising **sql-external** automatically join the Endpoints tab and
canary races, labeled with their controller, generation and adapter identity.
Host and port come from inventory, overriding those in the shared libpq options.
Other listener names remain visible in Services but are not guessed as SQL targets.
Readiness does not gate canary attempts. Identical destinations with identical
explicit libpq options are queried once even when multiple controllers advertise
them. Discovery does not resolve DNS aliases or expand service files to identify
equivalent destinations.

Failed polls retain the last good inventory and SQL endpoints, marked stale.
Successful inventory removal, or removing its last advertising controller, removes
a discovered destination. Shared destinations retain their measurements while
at least one controller advertises them. Discovered addresses are not saved to
configuration and cannot be removed individually. Manually added endpoints remain
independent. There is no automated failover policy or process control.

## Configuration

Controllers, manual endpoints and canaries load on startup. Adding, removing, pausing or resuming
items automatically saves `~/.config/mz-watch/config.zon`, or
`$XDG_CONFIG_HOME/mz-watch/config.zon` when that variable is an absolute path.
Measurements reset each session. Files are atomically replaced with permissions
`0600`. Missing directories are created with permissions `0700`.

The format is ZON, supported by Zig's standard library. For example:

```zig
.{
    .controllers = .{
        .{ .name = "blue", .url = "http://127.0.0.1:6882", .conninfo = "user=materialize dbname=materialize" },
        .{ .name = "green", .url = "http://127.0.0.1:7882", .conninfo = "user=materialize dbname=materialize" },
    },
    .collections_controller = "http://127.0.0.1:6882",
    .collection_id_filter = "u%",
    .collection_name_filter = "",
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

Dispatch and socket servicing rotate endpoint priority. Wins need not be evenly
distributed, even for two connections to the same server. When multiple sockets
are ready together, polling cannot establish their response arrival order.
Wins reflect the first complete success observed by the client.

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

The controller-only terminal harness needs no running Materialize instance:

```sh
python scripts/controller-smoke.py
```

It uses isolated local HTTP fixtures to exercise multi-controller discovery,
collection filtering and persistence, stale inventory, deduplication and removal.
