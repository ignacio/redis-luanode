package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"

local client1 = redis.createClient()
local client2 = redis.createClient()
local client3 = redis.createClient()
local client4 = redis.createClient()
local msg_count = 0

redis.debug_mode = false

client1:on("psubscribe", function (self, pattern, count)
	console.log("client1 psubscribed to %s, %d total subscriptions", pattern, count)
	client2:publish("channeltwo", "Me!")
	client3:publish("channelthree", "Me too!")
	client4:publish("channelfour", "And me too!")
end)

client1:on("punsubscribe", function (self, pattern, count)
	console.log("client1 punsubscribed to %s, %d total subscriptions", pattern, count)
	client4:finish()
	client3:finish()
	client2:finish()
	client1:finish()
end)

client1:on("pmessage", function (self, pattern, channel, message)
	console.log("(%s) client1 received message on %s: %s", pattern, channel, message)
	msg_count = msg_count + 1
	if msg_count == 3 then
		client1:punsubscribe()
	end
end)

client1:psubscribe("channel*")

process:loop()
