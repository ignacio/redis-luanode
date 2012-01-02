package.path = "../src/?.lua;../src/?/init.lua;".. package.path

require "luanode.utils"

local redis = require "redis-luanode"
local redis_client = redis.createClient()

-- A simple web server that generates dyanmic content based on responses from Redis
local http = require "luanode.http"

local server = http.createServer(function (_, request, response)
	response:writeHead(200, {
		["Content-Type"] = "text/plain"
	})
	
	local redis_info, total_requests
	
	redis_client:info(function (_, err, reply)
		redis_info = reply	-- stash response in outer scope
	end)
	redis_client:incr("requests", function (_, err, reply)
		total_requests = reply	-- stash response in outer scope
	end)
	redis_client:hincrby("ip", request.connection:remoteAddress(), 1)
	redis_client:hgetall("ip", function (_, err, reply)
		-- This is the last reply, so all of the previous replies must have completed already
		response:write("This page was generated after talking to redis.\n\n" ..
			"Redis info:\n" .. redis_info .. "\n" ..
			"Total requests: " .. total_requests .. "\n\n" ..
			"IP count: \n")
		for ip, value in pairs(reply) do
			response:write("    " .. ip .. ": " .. value .. "\n")
		end
		response:finish()
	end)
end):listen(80)

process:loop()
