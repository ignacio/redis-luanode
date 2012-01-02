--[[
Based upon node-redis, by Matt Ranney and various contributors.
Also based on redis-lua, by Daniele Alessandri

This is mostly a translation of node-redis from JavaScript to Lua.

As both source projects, this one is also MIT Licensed.
--]]

local net = require "luanode.net"
local EventEmitter = require "luanode.event_emitter"
local Class = require "luanode.class"

module(..., package.seeall)

-- can set this to true to enable for all connections
debug_mode = false

local defaults = {
	host		= '127.0.0.1',
	port		= 6379,
	tcp_nodelay	= true,
	path		= nil
}

local connection_id = 0

-- helper function to clone tables
local function clone (t)
	assert(type(t) == "table")
	
	local n = {}
	
	for k,v in pairs(t) do
		if type(k) == "table" then
			k = clone(k)
		end
		if type(v) == "table" then
			v = clone(v)
		end
		n[k] = v
	end
	
	return n
end

-- hgetall converts its replies to a table.  If the reply is empty, nil is returned.
function reply_to_object (reply)
	if #reply == 0 then
		return nil
	end

	local obj = {}
	for i = 1, #reply, 2 do
		local key = reply[i]
		local val = reply[i + 1]
		obj[key] = val
	end
	return obj
end

local RedisClient = Class.InheritsFrom(EventEmitter)

local function initialize_retry_vars (client)
	client.retry_timer = nil	-- null
	client.retry_totaltime = 0
	client.retry_delay = 150
	client.retry_backoff = 1.7
	client.attempts = 1
end

---
--
function RedisClient:__init (stream, options)

	local c = Class.construct(RedisClient)
	
	options = options or {}
	
	c.stream = stream
	c.options = options
	
	connection_id = connection_id + 1
	
	c.connection_id = connection_id
	c.connected = false
	c.ready = false
	c.connections = 0
	if type(options.socket_nodelay) == "boolean" then
		c.options.socket_nodelay = options.socket_nodelay
	else
		c.options.socket_nodelay = true
	end
	c.should_buffer = false
	c.command_queue_high_water = c.options.command_queue_high_water or 1000
	c.command_queue_low_water = c.options.command_queue_low_water or 0
	c.max_attempts = nil
	if type(options.max_attempts) == "number" and options.max_attempts > 0 then
		c.max_attempts = options.max_attempts
	end
	c.command_queue = {}	-- holds sent commands to de-pipeline them
	c.offline_queue = {}	-- holds commands issued but not able to be sent
	c.commands_sent = 0
	c.connect_timeout = false
	if type(options.connect_timeout) == "number" and options.connect_timeout > 0 then
		c.connect_timeout = options.connect_timeout
	end
	initialize_retry_vars(c)
	c.pub_sub_mode = false
	c.subscription_set = { sub = {}, psub = {} }
	c.monitoring = false
	c.closing = false
	c.server_info = {}
	c.auth_pass = nil
	c.parser_module = nil
	c.selected_db = nil		-- save the selected db here, used when reconnecting

	c.stream:on("connect", function(self)
		c:on_connect()
	end)

	c.stream:on("data", function(self, data)
		c:on_data(data)
	end)

	c.stream:on("error", function(self, msg)
		c:on_error(msg)
	end)

	c.stream:on("close", function(stream)
		c:connection_gone("close")
	end)

	c.stream:on("end", function(stream)
		c:connection_gone("end")
	end)

	c.stream:on("drain", function(stream)
		c.should_buffer = false
		c:emit("drain")
	end)
	
	return c
end

-- flush offline_queue and command_queue, erroring any items with a callback first
function RedisClient:flush_and_error (message)
	for _, command_obj in ipairs(self.offline_queue) do
		if type(command_obj.callback) == "function" then
			command_obj.callback(self, message)
		end
	end
	self.offline_queue = {}
	
	for _, command_obj in ipairs(self.command_queue) do
		if type(command_obj.callback) == "function" then
			command_obj.callback(self, message)
		end
	end
	self.command_queue = {}
end

function RedisClient:on_error (msg)

	if self.closing then
		return
	end

	local message = ("Redis connection to %s:%d failed - %s"):format(self.host, self.port, msg)
	if debug_mode then
		console.warn(message)
	end

	self:flush_and_error(message)

	self.connected = false
	self.ready = false

	self:emit("error", message)
	-- "error" events get turned into exceptions if they aren't listened for.  If the user handled this error
	-- then we should try to reconnect.
	self:connection_gone("error")
end

---
--
function RedisClient:do_auth ()
	
	if debug_mode then
		console.log("Sending auth to %s:%d id %d", self.host, self.port, self.connection_id)
	end
	self.send_anyway = true
	self:send_command("auth", {self.auth_pass}, function (emitter, err, res)
		if err then
			if tostring(err):match("LOADING") then
				-- if redis is still loading the db, it will not authenticate and everything else will fail
				console.log("Redis still loading, trying to authenticate later")
				setTimeout(function()
					self:do_auth()
				end, 2000) -- TODO - magic number alert
				return
			else
				return self:emit("error", "Auth error: " .. err)
			end
		end
		if tostring(res) ~= "OK" then
			return self:emit("error", "Auth failed: " .. tostring(res))
		end
		if debug_mode then
			console.log("Auth succeeded %s:%d id %d", self.host, self.port, self.connection_id)
		end
		if self.auth_callback then
			self:auth_callback(err, res)
			self.auth_callback = nil
		end

		-- now we are really connected
		self:emit("connect")
		if self.options.no_ready_check then
			self:on_ready()
		else
			self:ready_check()
		end
	end)
	self.send_anyway = false
end

---
--
function RedisClient:on_connect ()
	if debug_mode then
		console.log("Stream connected %s:%d id %d", self.host, self.port, self.connection_id)
	end

	self.connected = true
	self.ready = false
	self.attempts = 0
	self.connections = self.connections + 1
	self.command_queue = {}
	self.emitted_end = false
	initialize_retry_vars(self)
	if self.options.socket_nodelay then
		self.stream:setNoDelay()
	end
	self.stream:setTimeout(0)

	self:init_parser()

	if self.auth_pass then
		self:do_auth()
	else
		self:emit("connect")

		if self.options.no_ready_check then
			self:on_ready()
		else
			self:ready_check()
		end
	end
end

---
--
function RedisClient:init_parser ()

	--[[
	if self.options.parser then
		if not parsers.some(function (parser)
			if parser.name == self.options.parser then
				self.parser_module = parser
				if debug_mode then console.log("Using parser module: " .. self.parser_module.name) end
				return true
			end
		end) then
			error("Couldn't find named parser " .. self.options.parser .. " on this system")
		end
	else
		if debug_mode then console.log("Using default parser module: " + parsers[0].name) end
		self.parser_module = parsers[0];
	end
	--]]
	self.parser_module = require "redis-luanode.parser"

	--self.parser_module.debug_mode = debug_mode

	--self.reply_parser = self.parser_module.Parser({
	self.reply_parser = self.parser_module({
		return_buffers = self.options.return_buffers or false
	})
	-- "reply error" is an error sent back by Redis
	self.reply_parser:on("reply error", function (parser, reply)
		self:return_error(reply)
	end)
	self.reply_parser:on("reply", function (parser, reply)
		self:return_reply(reply)
	end)
	-- "error" is bad.  Somehow the parser got confused.  It'll try to reset and continue.
	self.reply_parser:on("error", function (parser, err)
		-- TODO: chequear esto
		self:emit("error", "Redis reply parser error: " .. tostring(err.stack))
	end)
end

function RedisClient:on_ready ()
	
	self.ready = true
	
	-- magically restore any modal commands from a previous connection
	if self.selected_db then
		self:send_command('select', {self.selected_db})
	end
	if self.pub_sub_mode == true then
		for channel in pairs(self.subscription_set.sub) do
			if debug_mode then
				console.warn("sending pub/sub on_ready sub, " .. channel)
			end
			self:send_command("sub", {channel})
		end
		for channel in pairs(self.subscription_set.psub) do
			if debug_mode then
				console.warn("sending pub/sub on_ready psub, " .. channel)
			end
			self:send_command("psub", {channel})
		end
	elseif self.monitoring then
		self:send_command("monitor")
	else
		self:send_offline_queue()
	end
	self:emit("ready")
end

function RedisClient:on_info_cmd (err, res)	-- implicit first arg, self
	if err then
		return self:emit("error", "Ready check failed: " .. err)
	end

	local retry_time

	local info = {}
	res:gsub('([^\r\n]*)\r\n', function(kv)
		local k,v = kv:match(('([^:]*):([^:]*)'):rep(1))
		if (k:match('db%d+')) then
			info[k] = {}
			v:gsub(',', function(dbkv)
				local dbk,dbv = kv:match('([^:]*)=([^:]*)')
				info[k][dbk] = dbv
			end)
		else
			info[k] = v
		end
	end)
	
	info.versions = {}
	
	for num in info.redis_version:gmatch("([^%.])") do
		table.insert(info.versions, tonumber(num))
	end

	-- expose info key/vals to users
	self.server_info = info

	if (not info.loading or (info.loading and info.loading == "0")) then
		if debug_mode then console.log("Redis server ready.") end
		self:on_ready()
	else
		retry_time = info.loading_eta_seconds * 1000
		if retry_time > 1000 then
			retry_time = 1000
		end
		if debug_mode then console.log("Redis server still loading, trying again in " .. retry_time) end
		setTimeout(send_info_cmd, retry_time)
		setTimeout(function ()
			self:ready_check()
		end, retry_time)
	end
end

---
--
function RedisClient:ready_check ()

	if debug_mode then console.log("checking server ready state...") end

	self.send_anyway = true		-- secret flag to send_command to send something even if not "ready"
	self:info(function(_, err, res)
		self:on_info_cmd(err, res)
	end)
	self.send_anyway = false
end

---
--
function RedisClient:send_offline_queue ()
	local command_obj
	local buffered_writes = 0
	
	while #self.offline_queue > 0 do
		command_obj = table.remove(self.offline_queue, 1)   -- shift
		if debug_mode then
			console.log("Sending offline command: " .. command_obj.command)
		end
		if not self:send_command(command_obj.command, command_obj.args, command_obj.callback) then
			buffered_writes = buffered_writes + 1
		end
	end
	self.offline_queue = {}
	-- Even though items were shifted off, Queue backing store still uses memory until next add, so just get a new Queue

	if buffered_writes == 0 then
		self.should_buffer = false
		self:emit("drain")
	end
end

---
--
function RedisClient:connection_gone (why)

	-- If a retry is already in progress, just let that happen
	if self.retry_timer then return end

	if debug_mode then
		console.warn("Redis connection is gone from %s event.", why)
	end
	self.connected = false
	self.ready = false

	-- since we are collapsing end and close, users don't expect to be called twice
	if not self.emitted_end then
		self:emit("end")
		self.emitted_end = true
	end
	
	self:flush_and_error("Redis connection gone from " .. tostring(why) .. " event.")

	-- If this is a requested shutdown, then don't retry
	if self.closing then
		self.retry_timer = nil
		self.stream._events = {}	-- <-- this is a hack, don't let the stream emit more events
		if debug_mode then
			console.warn("connection ended from quit command, not retrying.")
		end
		return
	end

	self.retry_delay = math.floor(self.retry_delay * self.retry_backoff)

	if debug_mode then
		console.log("Retry connection in %d ms", self.retry_delay)
	end
	
	if self.max_attempts and self.attempts >= self.max_attempts then
		self.retry_timer = nil
		-- TODO - some people need a "Redis is Broken mode" for future commands that errors immediately, and others
		-- want the program to exit.  Right now, we just log, which doesn't really help in either case.
		console.error("redis-luanode: Couldn't get Redis connection after " .. self.max_attempts .. " attempts.")
		return
	end
	
	self.attempts = self.attempts + 1
	self:emit("reconnecting", {
		delay = self.retry_delay,
		attempt = self.attempts
	})
	self.retry_timer = setTimeout(function ()
		if debug_mode then
			console.log("Retrying connection...")
		end
		
		self.retry_totaltime = self.retry_totaltime + self.retry_delay
		
		if self.connect_timeout and self.retry_totaltime >= self.connect_timeout then
			self.retry_timer = nil
			-- TODO - engage Redis is Broken mode for future commands, or whatever
			console.error("redis-luanode: Couldn't get Redis connection after " .. self.retry_totaltime .. "ms.")
			return
		end
		
		self.stream:connect(self.port, self.host)
		self.retry_timer = nil
	end, self.retry_delay)
end

---
--
function RedisClient:on_data (data)
	if debug_mode then
		console.log("net read %s:%d id %d: %s", self.host, self.port, self.connection_id, data)
	end

	local ok, err = pcall(self.reply_parser.execute, self.reply_parser, data)
	if not ok then
		-- This is an unexpected parser problem, an exception that came from the parser code itself.
		-- Parser should emit "error" events if it notices things are out of whack.
		-- Callbacks that throw exceptions will land in return_reply(), below.
		-- TODO - it might be nice to have a different "error" event for different types of errors
		self:emit("error", err)
	end
end

---
--
function RedisClient:return_error (err)
	local command_obj = table.remove(self.command_queue, 1)
	local queue_len = #self.command_queue

	if self.pub_sub_mode == false and queue_len == 0 then
		self:emit("idle")
		self.command_queue = {}
	end
	if self.should_buffer and queue_len <= self.command_queue_low_water then
		self:emit("drain")
		self.should_buffer = false
	end

	if command_obj and type(command_obj.callback) == "function" then
		local ok, err = pcall(command_obj.callback, self, err)
		if not ok then
			-- if a callback throws an exception, re-throw it on a new stack so the parser can keep going
			process.nextTick(function ()
				error(err)
			end)
		end
	else
		console.log("redis-luanode: no callback to send error: %s", err)
		-- this will probably not make it anywhere useful, but we might as well throw
		process.nextTick(function ()
			error(err)
		end)
	end
end

-- if a callback throws an exception, re-throw it on a new stack so the parser can keep going
local function try_callback(self, callback, reply)
	local ok, err = pcall(callback, self, nil, reply)
	if not ok then
		process.nextTick(function ()
			error(err)
		end)
	end
end

---
--
function RedisClient:return_reply (reply)
	local queue_len = #self.command_queue

	if self.pub_sub_mode == false and queue_len == 0 then
		self:emit("idle")
		self.command_queue = {}
	end
	if self.should_buffer and queue_len <= self.command_queue_low_water then
		self:emit("drain")
		self.should_buffer = false
	end
	
	local command_obj = table.remove(self.command_queue, 1)

	if command_obj and not command_obj.sub_command then
		if type(command_obj.callback) == "function" then
			-- TODO - confusing and error-prone that hgetall is special cased in two places
			if reply and 'hgetall' == command_obj.command:lower() then
				if type(reply) == "table" then
					reply = reply_to_object(reply)
				end
			end
			
			try_callback(self, command_obj.callback, reply)
		elseif debug_mode then
			console.log("no callback for reply: " .. tostring(reply))-- && reply.toString && reply.toString()));
		end
	elseif self.pub_sub_mode or (command_obj and command_obj.sub_command) then
		if type(reply) == "table" then -- is array?
			local kind = reply[1]

			if kind == "message" then
				self:emit("message", reply[2], reply[3]) -- channel, message
			elseif kind == "pmessage" then
				self:emit("pmessage", reply[2], reply[3], reply[4]) -- pattern, channel, message
			elseif kind == "subscribe" or kind == "unsubscribe" or kind == "psubscribe" or kind == "punsubscribe" then
				if reply[3] == "0" then
					self.pub_sub_mode = false
					if debug_mode then
						console.log("All subscriptions removed, exiting pub/sub mode")
					end
				end
				-- subscribe commands take an optional callback and also emit an event, but only the first response is included in the callback
				-- TODO - document this or fix it so it works in a more obvious way
				if command_obj and type(command_obj.callback) == "function" then
					try_callback(self, command_obj.callback, reply[2])
				end
				self:emit(kind, reply[2], tonumber(reply[3])) -- channel, count
			else
				error("subscriptions are active but got unknown reply type " .. kind)
			end
		elseif not self.closing then
			error("subscriptions are active but got an invalid reply: " .. reply)
		end
	elseif self.monitoring then
		error("NOT IMPLEMENTED")
		local timestamp, rest = reply:match([[([^%s]+)%s[^"]-(".+)]])
		console.log("-->%s<--", rest)
		local args = {}
		rest = rest:gsub([[\"]], "\"")
		console.log("-->%s<--", rest)
		for coso in rest:gmatch("\"(.-)\"") do
			console.error(1, coso)
		end
		--table.insert(info.versions, tonumber(num))
		console.fatal(timestamp, rest)
		self:emit("monitor", timestamp, args)
	else
		error("redis-luanode command queue state error. If you can reproduce this, please report it.")
	end
end

-- This Command constructor is ever so slightly faster than using an object literal
local function Command(command, args, sub_command, callback)
	return {
		command = command,
		args = args,
		sub_command = sub_command,
		callback = callback
	}
end

---
--
function RedisClient:send_command (command, args, callback)
	local stream = self.stream
	local command_str = ""
	local buffered_writes = 0

	if type(command) ~= "string" then
		error("First argument to send_command must be the command name string, not " .. type(command))
	end

	if type(args) == "table" then
		if type(callback) == "function" then
			-- probably the fastest way:
			--     client.command([arg1, arg2], cb);  (straight passthrough)
			--         send_command(command, [arg1, arg2], cb);
		elseif not callback then
			--// most people find this variable argument length form more convenient, but it uses arguments, which is slower
			--//     client.command(arg1, arg2, cb);   (wraps up arguments into an array)
			--//       send_command(command, [arg1, arg2, cb]);
			--//     client.command(arg1, arg2);   (callback is optional)
			--//       send_command(command, [arg1, arg2]);
			if type(args[#args]) == "function" then
				callback = table.remove(args)
			end
		else
			error("send_command: last argument must be a callback or undefined")
		end
	else
		error("send_command: second argument must be an array")
	end

	-- if the last argument is an array, expand it out.  This allows commands like this:
	--     client.command(arg1, [arg2, arg3, arg4], cb);
	--  and converts to:
	--     client.command(arg1, arg2, arg3, arg4, cb);
	-- which is convenient for some things like sadd
	--if (args.length > 0 && Array.isArray(args[args.length - 1])) {
		--args = args.slice(0, -1).concat(args[args.length - 1]);
	--}

	command_obj = Command(command, args, false, callback)

	if (not self.ready and not self.send_anyway) or not stream.writable then
		if debug_mode then
			if not stream.writable then
				console.log("send command: stream is not writeable.")
			end
			
			console.log("Queueing %q for next server connection.", command)
		end
		table.insert(self.offline_queue, command_obj)
		self.should_buffer = true
		return false
	end

	if command == "subscribe" or command == "psubscribe" or command == "unsubscribe" or command == "punsubscribe" then
		self:pub_sub_command(command_obj)
	elseif command == "monitor" then
		self.monitoring = true
	elseif command == "quit" then
		self.closing = true
	elseif self.pub_sub_mode == true then
		error("Connection in pub/sub mode, only pub/sub commands may be used")
	end
	table.insert(self.command_queue, command_obj)
	self.commands_sent = self.commands_sent + 1

	local buffer_args = false

	--elem_count = elem_count + args_len
	local elem_count = #args + 1

	-- Always use "Multi bulk commands", but if passed any Buffer args, then do multiple writes, one for each arg
	-- This means that using Buffers in commands is going to be slower, so use Strings if you don't already have a Buffer.

	command_str = "*" .. elem_count .. "\r\n$" .. #command .. "\r\n" .. command .. "\r\n"

	if not buffer_args then  -- Build up a string and send entire command in one write
		for i = 1, #args do
			local arg = args[i]
			if type(arg) ~= "string" then
				arg = tostring(arg)
			end
			command_str = command_str .. "$" .. #arg .. "\r\n" .. arg .. "\r\n"
		end
		if debug_mode then
			console.log("send %s:%d id %d: %s", self.host, self.port, self.connection_id, command_str)
		end
		if not stream:write(command_str) then
			buffered_writes = buffered_writes + 1
		end
	else
		if debug_mode then
			console.log("send command (%s) has Buffer arguments", command_str)
		end
		if not stream:write(command_str) then
			buffered_writes = buffered_writes + 1
		end

		for i = 1, #args do
			local arg = tostring(args[i])

			if debug_mode then
				console.log("send_command: string send %d bytes: %s", #arg, arg)
			end
			if not stream:write("$" .. #arg .. "\r\n" .. arg .. "\r\n") then
				buffered_writes = buffered_writes + 1
			end
		end
	end
	if debug_mode then
		console.log("send_command buffered_writes: %d should_buffer: %s", buffered_writes, self.should_buffer)
	end
	if buffered_writes > 0 or #self.command_queue >= self.command_queue_high_water then
		self.should_buffer = true
	end
	return not self.should_buffer
end

function RedisClient:pub_sub_command (command_obj)
	
	if self.pub_sub_mode == false and debug_mode then
		console.log("Entering pub/sub mode from " .. command_obj.command)
	end
	self.pub_sub_mode = true
	command_obj.sub_command = true

	local command = command_obj.command
	local args = command_obj.args
	local key
	if command == "subscribe" or command == "psubscribe" then
		if command == "subscribe" then
			key = "sub"
		else
			key = "psub"
		end
		for i = 1, #args do
			self.subscription_set[key][args[i]] = true
		end
	else
		if command == "unsubscribe" then
			key = "sub"
		else
			key = "psub"
		end
		for i = 1, #args do
			self.subscription_set[key][args[i]] = nil
		end
	end
end

---
--
function RedisClient:finish ()
	self.closing = true
	-- if there's a pending retry, can't clear events (an error will fire and bring me down)
	-- do it later
	if not self.retry_timer then
		self.stream._events = {}	-- no deberia tocar a prepo este field de un EventEmitter
	end
	self.connected = false
	self.ready = false
	return self.stream:finish()
end

---
--
Multi = Class.InheritsFrom(EventEmitter)

function Multi:__init (client, args)
	local t = Class.construct(Multi)
	t.client = client
	t.queue = {{"MULTI"}}
	
	if type(args) == "table" then
		for k,v in ipairs(args) do
			table.insert(t.queue, v)
		end
	end
	
	return t
end

-- take 2 arrays and return the union of their elements
function set_union(seta, setb)
	local obj = {}
	
	for _, v in ipairs(seta) do
		obj[v] = true
	end
	for _, v in ipairs(setb) do
		obj[v] = true
	end
	-- returns an array
	local t = {}
	for k in pairs(obj) do
		t[#t + 1] = k
	end
	return t
end

-- This static list of commands is updated from time to time.  ./redis-luanode/commands.lua can be updated with generate_commands.lua
commands = set_union({"get", "set", "setnx", "setex", "append", "strlen", "del", "exists", "setbit", "getbit", "setrange", "getrange", "substr",
	"incr", "decr", "mget", "rpush", "lpush", "rpushx", "lpushx", "linsert", "rpop", "lpop", "brpop", "brpoplpush", "blpop", "llen", "lindex",
	"lset", "lrange", "ltrim", "lrem", "rpoplpush", "sadd", "srem", "smove", "sismember", "scard", "spop", "srandmember", "sinter", "sinterstore",
	"sunion", "sunionstore", "sdiff", "sdiffstore", "smembers", "zadd", "zincrby", "zrem", "zremrangebyscore", "zremrangebyrank", "zunionstore",
	"zinterstore", "zrange", "zrangebyscore", "zrevrangebyscore", "zcount", "zrevrange", "zcard", "zscore", "zrank", "zrevrank", "hset", "hsetnx",
	"hget", "hmset", "hmget", "hincrby", "hdel", "hlen", "hkeys", "hvals", "hgetall", "hexists", "incrby", "decrby", "getset", "mset", "msetnx",
	"randomkey", "select", "move", "rename", "renamenx", "expire", "expireat", "keys", "dbsize", "auth", "ping", "echo", "save", "bgsave",
	"bgrewriteaof", "shutdown", "lastsave", "type", "multi", "exec", "discard", "sync", "flushdb", "flushall", "sort", "info", "monitor", "ttl",
	"persist", "slaveof", "debug", "config", "subscribe", "unsubscribe", "psubscribe", "punsubscribe", "publish", "watch", "unwatch", "cluster",
	"restore", "migrate", "dump", "object", "client", "eval", "evalsha"}, require("redis-luanode.commands"))

for _, command in ipairs(commands) do
	RedisClient[command] = function (self, args, callback, ...)
		if type(args) == "table" then
			if type(callback) == "function" then
				return self:send_command(command, args, callback)
			else
				return self:send_command(command, args)
			end
		else
			return self:send_command(command, {args, callback, ...})
		end
	end

	RedisClient[command:upper()] = RedisClient[command]

	Multi[command] = function (self, ...)
		table.insert(self.queue, {command, ...})
		return self
	end
	Multi[command:upper()] = Multi[command]
end

-- store db in self.select_db to restore it on reconnect
function RedisClient:select (db, callback)
	self:send_command('select', {db}, function (emitter, err, res)
		if not err then
			self.selected_db = db
		end
		if type(callback) == 'function' then
			callback(emitter, err, res)
		end
	end)
end
RedisClient.SELECT = RedisClient.select

---
-- Stash auth for connect and reconnect.  Send immediately if already connected.
function RedisClient:auth (...)
	local args = {...}
	self.auth_pass = args[1]
	self.auth_callback = args[2]
	if debug_mode then
		console.log("Saving auth as " .. self.auth_pass)
	end

	if self.connected then
		self:send_command("auth", args)
	end
end
RedisClient.AUTH = RedisClient.auth

function RedisClient:hmget (arg1, arg2, arg3, ...)
	if type(arg2) == "table" and type(arg3) == "function" then
		local t = { arg1 }
		for _,v in ipairs(arg2) do t[#t + 1] = v end
		return self:send_command("hmget", t, arg3)
	
	elseif type(arg1) == "table" and type(arg2) == "function" then
		return self:send_command("hmget", arg1, arg2)
		
	else
		return self:send_command("hmget", {arg1, arg2, arg3, ...})
	end
end
RedisClient.HMGET = RedisClient.hmget

function RedisClient:hmset (args, callback, ...)
	if type(args) == "table" and type(callback) == "function" then
		return self:send_command("hmset", args, callback)
	end

	args = {args, callback, ...}
	if type(args[#args]) == "function" then
		callback = table.remove(args)	-- pop the last element
	else
		callback = nil
	end

	if #args == 2 and type(args[1]) == "string" and type(args[2]) == "table" then
		-- User does: client:hmset(key, {key1: val1, key2: val2})
		local tmp_args = { args[1] }
		for k,v in pairs(args[2]) do
			table.insert(tmp_args, k)
			table.insert(tmp_args, v)
		end
		args = tmp_args
	end

	return self:send_command("hmset", args, callback)
end
RedisClient.HMSET = RedisClient.hmset

function Multi:hmset (...)
	local args = {...}
	local tmp_args
	
	if select("#", ...) >= 2 and type(args[1]) == "string" and type(args[2]) == "table" then
		local tmp_args = { "hmset", args[1] }
		for k,v in pairs(args[2]) do
			table.insert(tmp_args, k)
			table.insert(tmp_args, v)
		end
		
		if args[3] then
			table.insert(tmp_args, args[3])
		end
		args = tmp_args
	else
		table.insert(args, 1, "hmset")
	end

	table.insert(self.queue, args)
	return self
end
Multi.HMSET = Multi.hmset

-- como lo de javascript
local function splice(array, from)
	local t = {} 
	for i = from, #array do
		t[#t + 1] = array[i]
	end 
	return t
end


function Multi:exec (callback)
	-- drain queue, callback will catch "QUEUED" or error
	-- TODO - get rid of all of these anonymous functions which are elegant but slow
	for index, args in ipairs(self.queue) do
		local args_copy = {}
		local command = args[1]
		
		if type(args[#args]) == "function" then
			for i=2, #args - 1 do
				args_copy[i - 1] = args[i]
			end
		else
			if type(args[2]) == "table" then
				args_copy = args[2]
			else
				for i=2, #args do
					args_copy[i - 1] = args[i]
				end
			end
		end
		
		if cmd == "hmset" and type(args[1]) == "table" then
			error("NOT IMPLEMENTED")
			local obj = table.remove(args, -1)
			for key, value in pairs(obj) do
				args[#args + 1] = key
				args[#args + 1] = value
			end
		end
		
		self.client:send_command(command, args_copy, function (emitter, err, reply)
			if err then
				local cur = self.queue[index]
				if type(cur[#cur]) == "function" then
					cur[#cur](self, err)
				else
					error(err)
				end
				table.remove(self.queue, index)
			end
		end)
	end

	-- TODO - make this callback part of Multi.prototype instead of creating it each time
	return self.client:send_command("EXEC", {}, function (emitter, err, replies)
		if err then
			if callback then
				callback(self, err)
				return
			else
				error(err)
			end
		end
		
		if replies then
			for index = 2, #self.queue do-- index, args in ipairs(self.queue) do
				local reply = replies[index - 1]
				local args = self.queue[index]
				-- Convert HGETALL reply to object
				-- TODO - confusing and error-prone that hgetall is special cased in two places
				if reply and args[1]:lower() == "hgetall" then
					reply = reply_to_object(reply)
					replies[index - 1] = reply
				end

				if type(args[#args]) == "function" then
					args[#args](self, nil, reply)
				end
			end
		end
		if callback then
			callback(self, nil, replies)
		end
	end)
end

function RedisClient:multi (args)
	return Multi(self, args)
end
function RedisClient:MULTI (args)
	return Multi(self, args)
end



---
--
function createClient (port, host, options)
	port = port or defaults.port
	host = host or defaults.host
	
	local net_client = net.createConnection(port, host)
	
	local redis_client = RedisClient(net_client, options)
	
	redis_client.port = port
	redis_client.host = host
	
	return redis_client
end

---
--
function print (redis_client, err, reply)
	if err then
		console.log("Error: %s", err)
	else
		console.log("Reply: %s", reply)
	end
end
