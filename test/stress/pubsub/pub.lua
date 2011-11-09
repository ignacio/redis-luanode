package.path = "../../../src/?.lua;../../../src/?/init.lua;".. package.path
require "luanode.utils"

package.path = [[C:\LuaRocks\1.0\lua\?.lua;C:\LuaRocks\1.0\lua\?\init.lua;]] .. 
				[[C:\LuaRocks\2.0\lua\?.lua;C:\LuaRocks\2.0\lua\?\init.lua;]] .. package.path
require "luarocks.require"

require "json"

local sent = 0

local pub = require('redis-luanode').createClient(nil, nil, {
	--command_queue_high_water = 5,
	--command_queue_low_water = 1
})
pub:on('ready', function(self)
	self:emit('drain');
end)
pub:on('drain', function()
	process.nextTick(exec)
end)

local payload = '1'
for i = 0, 12 do
	payload = payload .. payload
end
console.log('Message payload length', #payload)

function exec()
	pub:publish('timeline', json.encode({ foo = payload }))
	sent = sent + 1
	if not pub.should_buffer then
		process.nextTick(exec)
	end
end

exec()

setInterval(function()
	console.error('sent', sent, 'cmdqlen', #pub.command_queue, 'offqlen', #pub.offline_queue)
end, 2000)

process:loop()
