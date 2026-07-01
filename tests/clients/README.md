Wayland protocol/client tests belong here.

The first integration layer uses `tests/harness/compositor.lua` to start a
headless compositor. Small LuaJIT clients should be added here as protocol
coverage grows, then driven from `tests/integration`.
