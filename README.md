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

For fast iteration on x86_64 Linux, keep `zig build -fincremental --watch` running
in one terminal and launch `./zig-out/bin/mz-watch` in another. Rebuilding does not
hot-reload a running dashboard. Use `-Dllvm=true` when an LLVM build is needed.
