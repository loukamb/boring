return function(t)
    for _, name in ipairs({ "@boring/library/ui", "@boring/library/desktop", "@boring/library/animate" }) do
        package.preload[name] = function() return {} end
    end
    local fuzzy = require("plugins.launcher")._private.fuzzy
    local desktop = require("plugins.library.desktop")

    t.test("launcher: fuzzy ranks prefix > word start > substring > letters", function()
        local prefix = fuzzy("fi", "Firefox")
        local word = fuzzy("fox", "Fire fox")
        local sub = fuzzy("efo", "Firefox")
        local letters = fuzzy("ffx", "Firefox")
        t.ok(prefix > word and word > sub and sub > letters, table.concat({ prefix, word, sub, letters }, " "))
        t.eq(fuzzy("zz", "Firefox"), nil)
        t.ok(fuzzy("FIRE", "firefox") ~= nil) -- case-insensitive
    end)

    t.test("desktop: entries parse, filter and become commands", function()
        local dir = t.tmpdir("boring-desktop")
        local function write(name, body)
            local f = assert(io.open(dir .. "/" .. name, "w"))
            f:write(body)
            f:close()
            return dir .. "/" .. name
        end
        local path = write("app.desktop", [[
[Desktop Entry]
Type=Application
Name=Editor
Name[fr]=Éditeur
Comment=Edit text
Keywords=text;notes;
Exec=editor --new %U
Icon=accessories-text-editor
Terminal=true

[Desktop Action new]
Name=Ignored
]])
        local app = desktop.parse(path, "app.desktop")
        t.eq(app.exec, "editor --new %U")
        t.eq(app.keywords[2], "notes")
        t.eq(desktop.command(app, { terminal = "foot" }), "foot -e editor --new")
        if not (os.getenv("LC_ALL") or os.getenv("LANG") or ""):match("^fr") then t.eq(app.name, "Editor") end

        t.eq(desktop.parse(write("hidden.desktop", "[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true\n")), nil)
        t.eq(desktop.parse(write("link.desktop", "[Desktop Entry]\nType=Link\nName=X\nURL=x\n")), nil)
        t.eq(desktop.parse(write("try.desktop",
            "[Desktop Entry]\nType=Application\nName=X\nExec=x\nTryExec=surely-not-installed-anywhere\n")), nil)
        t.eq(desktop.parse(write("only.desktop",
            "[Desktop Entry]\nType=Application\nName=X\nExec=x\nOnlyShowIn=SomeOtherDesktop;\n")), nil)
        local pct = desktop.parse(write("pct.desktop", "[Desktop Entry]\nType=Application\nName=Pct\nExec=echo 100%% %c\n"))
        t.eq(desktop.command(pct), "echo 100% 'Pct'")
    end)
end
