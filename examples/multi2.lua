package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"
local client = redis.createClient()

-- start a separate command queue for multi
local multi = client:multi()
multi:incr("incr thing", redis.print)
multi:incr("incr other thing", redis.print)

-- runs immediately
client:mset("incr thing", 100, "incr other thing", 1, redis.print)

-- drains multi queue and runs atomically
multi:exec(function (_, err, replies)
	console.log(replies) -- 101, 2
end)

-- you can re-run the same transaction if you like
multi:exec(function (_, err, replies)
	console.log(replies) -- 102, 3
	client:quit()
end)

client:multi({
	{"mget", "multifoo", "multibar", redis.print},
	{"incr", "multifoo"},
	{"incr", "multibar"}
}):exec(function (_, err, replies)
	console.log(replies)
end)

process:loop()
