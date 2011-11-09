package.path = "../src/?.lua;../src/?/init.lua;".. package.path
require "luanode.utils"

local redis  = require("redis-luanode").createClient()
--require("redis-luanode").debug_mode = true

redis:on("error", function (self, err)
    console.log("Redis says: " .. err)
end)

redis:on("ready", function ()
    console.log("Redis ready.")
end)

redis:on("reconnecting", function (self, arg)
    console.log("Redis reconnecting: " .. luanode.utils.inspect(arg))
end)
redis:on("connect", function ()
    console.log("Redis connected.")
end)

setInterval(function ()
    local now = os.time()
    redis:set("now", now, function (self, err, res)
        if err then
            console.log(now .. " Redis reply error: " .. err)
        else
            console.log(now .. " Redis reply: " .. res)
        end
    end)
end, 200)

process:loop()
