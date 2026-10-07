# mz-watch

Zig 0.17.0, libvaxis `zig-0.17`, libpq. Keep database I/O off the UI thread.
Canaries are read-only. A winner is the first completely received successful
result, not the first response or error. Preserve visibility of losing endpoints.

Run `zig fmt --check build.zig src` and `zig build test` before committing.
Use `zig build -fincremental --watch` for iteration, launching the executable
separately. Also verify ordinary builds, since incremental compilation is experimental.

Do not commit connection credentials. No persisted configuration is required.
