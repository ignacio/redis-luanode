package.path = ---[[d:\trunk_git\sources\LuaNode\lib\?.lua;d:\trunk_git\sources\LuaNode\lib\?\init.lua;]] ..
	[[d:\trunk_git\sources\LuaNode\lib\?\init.lua;]] .. 
	[[C:\LuaRocks\2.0\lua\?.lua;C:\LuaRocks\2.0\lua\?\init.lua;]] ..
	[[C:\LuaRocks\1.0\lua\?.lua;C:\LuaRocks\1.0\lua\?\init.lua;]] .. package.path

if process.platform == "windows" then
	require "luarocks.require"
end

package.path = "../src/?.lua;../src/?/init.lua;".. package.path

local Barrier = require "siteswap.barrier"

redis = require "redis-luanode"

local Runner = require "siteswap.runner"
local Test = require "siteswap.test"

local runner = Runner()

AddTest = function(name, ...) 
	if 
		true or
	name == "socket_nodelay" then
		return runner:AddTest(name, ...)
	end
end


client1 = redis.createClient()
client2 = redis.createClient()
client3 = redis.createClient()

client = client1 -- the main client instance

require "test"


-- Wait until three redis clients are connected
local barrier = Barrier(3)

client:once("ready", barrier.join)
client2:once("ready", barrier.join)
client3:once("ready", barrier.join)

runner:on("done", function()
	client1:quit()
	client2:quit()
	client3:quit()
end)

local env = {
	test_db_num = 15, -- this DB will be flushed and used for testing
}

barrier:on("ready", function()
	client:select(test_db_num)
	client2:select(test_db_num)
    client3:select(test_db_num)
	runner:Run(env)
end)

process:loop()
