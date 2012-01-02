package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"
local client = redis.createClient()

client:mget({"sessions started", "sessions started", "foo"}, function (self, err, res)
	console.log(luanode.utils.inspect(res))
	client:quit()
end)

process:loop()
