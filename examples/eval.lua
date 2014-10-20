package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"
local client = redis.createClient()

math.randomseed(os.time())

client:eval("return 'hello world'", 0, redis.print)


local script = [[
local zset_key = assert(KEYS[1], "No zset provided")

redis.log(redis.LOG_WARNING, ("Got %d keys and %d arguments"):format(#KEYS, #ARGV) )

redis.call("del", zset_key)

for i=1, #ARGV, 2 do
	redis.call("zadd", zset_key, ARGV[i + 1], ARGV[i])
end
return redis.call("zrangebyscore", zset_key, "-inf", "+inf", "withscores")
]]
client:eval(script, 1, "test_zset", "foo", math.random(), "bar", math.random(), "baz", math.random(), function(_, err, res)
	console.log(luanode.utils.inspect(res))
end)


client:eval("return {1,2,3}", 0, function(_, err, res)
	console.log(luanode.utils.inspect(res))

	client:quit()
end)

process:loop()
