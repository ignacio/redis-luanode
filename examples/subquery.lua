package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"
local client = redis.createClient()

-- build a map of all keys and their types
client:keys("*", function (_, err, all_keys)
	local key_types = {}
	
	for i,key in ipairs(all_keys) do
		client:type(key, function(_, err, type)
			key_types[key] = type
			if i == #all_keys then
				console.log(luanode.utils.inspect(key_types))
				client:finish()
			end
		end)
	end
end)

process:loop()
