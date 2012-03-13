package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"
local redis  = require "redis-luanode"
local client = redis.createClient()
local client2 = redis.createClient()

client:on("ready", function()
	client:once("subscribe", function (redis, channel, count)
		client:unsubscribe("x")
		client:subscribe("x", function ()
			client:quit()
			client2:quit()
		end)
		client2:publish("x", "hi")
		client2:publish("x", "hi")
		client2:publish("x", "hi")
	end)

	client:subscribe("x")
end)

process:loop()
