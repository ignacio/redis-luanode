package.path = "../../../src/?.lua;../../../src/?/init.lua;".. package.path
require "luanode.utils"

package.path = [[C:\LuaRocks\1.0\lua\?.lua;C:\LuaRocks\1.0\lua\?\init.lua;]] .. 
				[[C:\LuaRocks\2.0\lua\?.lua;C:\LuaRocks\2.0\lua\?\init.lua;]] .. package.path
require "luarocks.require"

require "json"

local id = math.random()
local recv = 0

local sub = require('redis-luanode').createClient()
sub:on('ready', function(self)
	self:subscribe('timeline')
end)
sub:on('message', function(self, channel, message)
	if message then
		message = json.decode(message)
		recv = recv + 1
	end
end)

setInterval(function()
	console.error('id', id, 'received', recv)
end, 2000)

process:loop()
