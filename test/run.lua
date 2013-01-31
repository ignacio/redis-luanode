if not _LUANODE then
	io.stderr:write("You must run this script with luanode. Like this:\n\tluanode run.lua\n")
	return
end

package.path = ---[[d:\trunk_git\sources\LuaNode\lib\?.lua;d:\trunk_git\sources\LuaNode\lib\?\init.lua;]] ..
	[[d:\trunk_git\sources\LuaNode\lib\?\init.lua;]] .. 
	[[C:\LuaRocks\2.0\lua\?.lua;C:\LuaRocks\2.0\lua\?\init.lua;]] ..
	[[C:\LuaRocks\1.0\lua\?.lua;C:\LuaRocks\1.0\lua\?\init.lua;]] .. package.path

if process.platform == "windows" then
	require "luarocks.require"
end

package.path = "../src/?.lua;../src/?/init.lua;".. package.path

local helpers = require "test_helpers"
local Tasks = require "lua_ostasks"


local redis = require "redis-luanode"

local Barrier = require "siteswap.barrier"
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


--ejemplo de invocacion: lua5.1 run.lua --chatServer 192.168.22.210 --chatServerPort 1866
local args = helpers.CommandLine[[
redis-luanode testing parameters
	-r,--redisServer (string default ?)             The address of the redis server
	-s,--redisPort (number default ?)               The port number were redis will be listening
	-p,--pause                                      Pauses the test before stopping helper processes
	<tests...> (default ?)                          Tests to run (leave in blank to run all tests)
]]

local local_ip = helpers.GetHostAddress()

local config_env = {
	redis = {
		host = args.redisServer or local_ip,
		port = args.redisPort or 6379
	},
	test_db_num = 15, -- this DB will be flushed and used for testing
}

client1 = redis.createClient(config_env.redis.port, config_env.redis.host)
client2 = redis.createClient(config_env.redis.port, config_env.redis.host)
client3 = redis.createClient(config_env.redis.port, config_env.redis.host)

client = client1 -- the main client instance

require "test"


-- Wait until three redis clients are connected
local barrier = Barrier(3)

client:once("ready", barrier.join)
client2:once("ready", barrier.join)
client3:once("ready", barrier.join)

local with_errors = false

runner:on("done", function(runner, errs)
	with_errors = errs

	client1:quit()
	client2:quit()
	client3:quit()
end)

barrier:on("ready", function()
	client:select(test_db_num)
	client2:select(test_db_num)
    client3:select(test_db_num)
	runner:Run(config_env)
end)

process:loop()

if args.pause then
	os.execute("pause")
end
