package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"
local client = redis.createClient()

-- Sending commands in response to other commands.
-- This example runs "type" against every key in the database
--

client:keys("*", function (_, err, keys)
	for i, key in ipairs(keys) do
		client:type(key, function(_, err, keytype)
			console.log("%s is %s", key, keytype)
			if i == #keys then
				client:quit()
			end
		end)
	end
end)

process:loop()
