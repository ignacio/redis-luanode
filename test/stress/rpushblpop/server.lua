package.path = "../../../src/?.lua;../../../src/?/init.lua;".. package.path
require "luanode.utils"

package.path = [[C:\LuaRocks\1.0\lua\?.lua;C:\LuaRocks\1.0\lua\?\init.lua;]] .. 
				[[C:\LuaRocks\2.0\lua\?.lua;C:\LuaRocks\2.0\lua\?\init.lua;]] .. package.path
require "luarocks.require"

require "json"

local id = math.random()
local recv = 0

local cmd = require('redis-luanode').createClient()
local sub = require('redis-luanode').createClient()
sub:on('ready', function()
	sub:emit('timeline')
end)
sub:on('timeline', function()
	sub:blpop('timeline', 0, function(self, err, result)
		local message = result[2]
		if message then
			message = json.decode(message)
			recv = recv + 1
		end
		sub:emit('timeline')
	end)
end)

setInterval(function()
	cmd:llen('timeline', function(self, err, result)
		console.error('id', id, 'received', recv, 'llen', result)
	end)
end, 2000)

process:loop()
