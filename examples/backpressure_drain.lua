package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"

local client = redis.createClient(nil, nil, {
	command_queue_high_water = 5,
	command_queue_low_water = 1
})

local remaining_ops = 100000
local paused = false

local function op()
	if remaining_ops <= 0 then
		console.log("Finished.")
		client:quit()
		return
	end

	remaining_ops = remaining_ops - 1
	if client:hset("test hash", "val " .. remaining_ops, remaining_ops) == false then
		console.log("Pausing at " .. remaining_ops)
		paused = true
	else
		process.nextTick(op)
	end
end

client:on("drain", function ()
	if paused then
		console.log("Resuming at " .. remaining_ops)
		paused = false
		process.nextTick(op)
	else
		console.log("Got drain while not paused at " .. remaining_ops)
	end
end)

op()

process:loop()
