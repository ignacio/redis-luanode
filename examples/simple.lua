package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"
local client = redis.createClient()

client:on("error", function (self, err)
    console.log("Redis connection error to %s:%d - %s", client.host, client.port, err)
end)

client:set("string key", "string val", redis.print)
client:hset("hash key", "hashtest 1", "some value", redis.print)
client:hset({"hash key", "hashtest 2", "some other value"}, redis.print)
client:hkeys("hash key", function (self, err, replies)
    console.log(#replies .. " replies:")
	for i,reply in ipairs(replies) do
        console.log("    " .. i .. ": " .. reply)
    end
    client:quit()
end)

process:loop()