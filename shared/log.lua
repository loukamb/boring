local log = {
    color = {
        red = function(s)
            return "\027[31m" .. s .. "\027[0m"
        end,
        green = function(s)
            return "\027[32m" .. s .. "\027[0m"
        end,
        yellow = function(s)
            return "\027[33m" .. s .. "\027[0m"
        end,
        blue = function(s)
            return "\027[34m" .. s .. "\027[0m"
        end,
        magenta = function(s)
            return "\027[35m" .. s .. "\027[0m"
        end,
        cyan = function(s)
            return "\027[36m" .. s .. "\027[0m"
        end,
        white = function(s)
            return "\027[37m" .. s .. "\027[0m"
        end,
    },
}

function log.info(fmt, ...)
    print(string.format(log.color.blue("[info] ") .. fmt, ...))
end

function log.warn(fmt, ...)
    print(string.format(log.color.yellow("[warn] ") .. fmt, ...))
end

function log.error(fmt, ...)
    print(string.format(log.color.red("[err!] ") .. fmt, ...))
end

if os.getenv("BORING_DEBUG") then
    function log.debug(fmt, ...)
        print(string.format(log.color.cyan("[debug] ") .. fmt, ...))
    end
else
    log.debug = function() end
end

return log
