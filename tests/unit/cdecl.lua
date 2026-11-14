return function(t)
    package.path = "./?.lua;" .. package.path
    local cdecl = require("tools.cdecl")

    local function parse(src)
        return cdecl.parse('# 1 "/usr/include/wlr/test.h"\n' .. src)
    end

    local function find(decls, key)
        for _, d in ipairs(decls) do
            if d.defines[key] then return d end
        end
    end

    t.test("cdecl drops static inline function bodies", function()
        local decls = parse([[
            static inline int helper(int x) { if (x) { return 1; } return 0; }
            int kept(void);
        ]])
        t.eq(#decls, 1)
        t.ok(decls[1].defines["id:kept"])
    end)

    t.test("cdecl names declarators: functions, pointers, arrays, typedefs", function()
        local decls = parse([[
            struct wl_display *wl_display_create(void);
            typedef void (*wl_notify_func_t)(struct wl_listener *listener, void *data);
            extern const struct wl_interface wl_display_interface;
            typedef struct { int a; } anon_t;
            extern int table[4];
        ]])
        t.ok(find(decls, "id:wl_display_create"))
        t.eq(find(decls, "id:wl_notify_func_t").kind, "typedef")
        t.ok(find(decls, "id:wl_display_interface"))
        t.ok(find(decls, "id:anon_t"))
        t.ok(find(decls, "id:table"))
    end)

    t.test("cdecl records tags, enumerators and references", function()
        local decls = parse([[
            enum wlr_edges { WLR_EDGE_NONE = 0, WLR_EDGE_TOP = 1 << 0 };
            struct wlr_box { int x, y; enum wlr_edges edges; uint32_t pad; };
            struct wlr_output;
        ]])
        local enum = find(decls, "enum:wlr_edges")
        t.ok(enum.defines["id:WLR_EDGE_NONE"])
        t.ok(enum.defines["id:WLR_EDGE_TOP"])
        local box = find(decls, "struct:wlr_box")
        t.eq(box.defines["struct:wlr_box"], "full")
        t.ok(box.refs["enum:wlr_edges"])
        t.ok(not box.refs["id:uint32_t"], "builtin types need no declaration")
        t.eq(find(decls, "struct:wlr_output").kind, "forward")
    end)

    t.test("cdecl strips noise but keeps layout attributes and asm renames", function()
        local decls = parse([[
            __extension__ typedef long long __quad_t;
            struct __attribute__((packed, deprecated("x"))) p { char a; int b; };
            int fstat(int fd) __asm__ ("" "fstat64") __attribute__((__nothrow__));
            struct wlr_color_transform *wlr_m(const float matrix[static 9]);
        ]])
        local text = {}
        for _, d in ipairs(decls) do text[#text + 1] = cdecl.format(d) end
        text = table.concat(text, "\n")
        t.ok(not text:find("__extension__", 1, true))
        t.ok(not text:find("deprecated", 1, true))
        t.ok(not text:find("__nothrow__", 1, true))
        t.ok(text:find("packed", 1, true))
        t.ok(text:find("__asm__", 1, true))
        t.ok(not text:find("static", 1, true))
    end)

    t.test("cdecl strips integer suffixes and attributes tokens to their file", function()
        local decls = cdecl.parse([[
# 1 "/usr/include/stdint.h"
enum { BIG = 0xFFFFFFFFUL, SMALL = 10U };
# 5 "/usr/include/wlr/x.h"
int f(void);
]])
        t.eq(decls[1].file, "/usr/include/stdint.h")
        t.eq(decls[2].file, "/usr/include/wlr/x.h")
        local text = cdecl.format(decls[1])
        t.ok(text:find("0xFFFFFFFF", 1, true) and not text:find("UL", 1, true))
        t.ok(text:find("10", 1, true) and not text:find("10U", 1, true))
    end)

    t.test("formatted declarations load into LuaJIT", function()
        local ffi = require("ffi")
        local decls = parse([[
            struct cdecl_test_s { int x; struct { int y; } inner; void (*cb)(int); };
            enum cdecl_test_e { CDECL_TEST_A = 1 << 2, CDECL_TEST_B };
        ]])
        local text = {}
        for _, d in ipairs(decls) do text[#text + 1] = cdecl.format(d) end
        ffi.cdef(table.concat(text, "\n"))
        t.eq(ffi.C.CDECL_TEST_B, 5)
        t.eq(ffi.offsetof("struct cdecl_test_s", "inner"), ffi.sizeof("int"))
        t.eq(ffi.offsetof("struct cdecl_test_s", "cb") % ffi.alignof("void *"), 0)
    end)
end
