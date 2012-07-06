package.path = "../src/?.lua;../src/?/init.lua;".. package.path
require "luanode.utils"

local client = require("redis-luanode").createClient()
local client2 = require("redis-luanode").createClient()

client:subscribe("something")
client:on("subscribe", function (self, channel, count)
    console.log("Got sub: " .. channel)
    client:unsubscribe("something")
end)

client:on("unsubscribe", function (self, channel, count)
    console.log("Got unsub: " .. channel .. ", quitting")
    client:quit()
end)

-- exercise unsub before sub
client2:unsubscribe("something")
client2:subscribe("another thing")
client2:quit()

process:loop()
