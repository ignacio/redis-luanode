package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"
local redis  = require "redis-luanode"
local client = redis.createClient()

-- This currently doesn't work, due to what I beleive to be a bug in redis 2.0.1.
-- INFO and QUIT are pipelined together, and the socket closes before the INFO
-- command gets a reply.

--redis.debug_mode = true
--client:info(redis.print)
--client:quit()

--// A workaround is:
client:info(function (self, err, res)
	console.log(res)
	client:quit()
	console.log("everything ok")
end)

process:loop()
