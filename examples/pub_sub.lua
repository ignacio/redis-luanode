package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"

local client1 = redis.createClient()
local msg_count = 0
local client2 = redis.createClient()

redis.debug_mode = false

-- Most clients probably don't do much on "subscribe".  This example uses it to coordinate things within one program.
client1:on("subscribe", function (self, channel, count)
	console.log("client1 subscribed to " .. channel .. ", " .. count .. " total subscriptions")
	if count == 2 then
		client2:publish("a nice channel", "I am sending a message.")
		client2:publish("another one", "I am sending a second message.")
		client2:publish("a nice channel", "I am sending my last message.")
	end
end)

client1:on("unsubscribe", function (self, channel, count)
	console.log("client1 unsubscribed from " .. channel .. ", " .. count .. " total subscriptions")
	if count == 0 then
		client2:finish()
		client1:finish()
	end
end)

client1:on("message", function (self, channel, message)
	console.log("client1 channel " .. channel .. ": " .. message)
	msg_count = msg_count + 1
	if msg_count == 3 then
		client1:unsubscribe()
	end
end)

client1:on("ready", function ()
	-- if you need auth, do it here
	client1:incr("did a thing")
	client1:subscribe("a nice channel", "another one")
end)

client2:on("ready", function ()
	-- if you need auth, do it here
end)

process:loop()
