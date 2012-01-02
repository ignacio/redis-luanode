package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"
local client = redis.createClient()

local set_size = 20

client:sadd("bigset", "a member")
client:sadd("bigset", "another member")

while set_size > 0 do
	client:sadd("bigset", "member " .. set_size)
	set_size = set_size - 1
end

-- multi chain with an individual callback
client:multi()
	:scard("bigset")
	:smembers("bigset")
	:keys("*", function (_, err, replies)
		client:mget(replies, redis.print)
	end)
	:dbsize()
	:exec(function (_, err, replies)
		console.log("MULTI got %d replies", #replies)
		for k,v in ipairs(replies) do
			console.log("Reply %d: %s", k, luanode.utils.inspect(v))
		end
	end)

client:mset("incr thing", 100, "incr other thing", 1, redis.print)

-- start a separate multi command queue
local multi = client:multi()
multi:incr("incr thing", redis.print)
multi:incr("incr other thing", redis.print)

-- runs immediately
client:get("incr thing", redis.print) -- 100

-- drains multi queue and runs atomically
multi:exec(function (emitter, err, replies)
	console.log(replies)	-- 101, 2
end)

-- you can re-run the same transaction if you like
multi:exec(function (emitter, err, replies)
	console.log(replies)	-- 102, 3
	client:quit()
end)

process:loop()
