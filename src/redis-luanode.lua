--[[
Based upon node-redis, by Matt Ranney and various contributors.
Also based on redis-lua, by Daniele Alessandri

This is mostly a translation of node-redis from JavaScript to Lua.

As both source projects, this one is MIT Licensed.
--]]

local net = require "luanode.net"
local EventEmitter = require "luanode.event_emitter"
local Class = require "luanode.class"

module(..., package.seeall)

-- can set this to true to enable for all connections
debug_mode = false

local defaults = {
	host        = '127.0.0.1',
	port        = 6379,
	tcp_nodelay = true,
	path        = nil
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
	if not options.socket_nodelay then
        c.options.socket_nodelay = true
    end
	c.should_buffer = false
	c.command_queue_high_water = c.options.command_queue_high_water or 1000
	c.command_queue_low_water = c.options.command_queue_low_water or 0
	c.max_attempts = nil
	if type(options.max_attempts) == "number" and options.max_attempts > 0 then
        c.max_attempts = options.max_attempts
    end
	c.command_queue = {}--new Queue(); // holds sent commands to de-pipeline them
	c.offline_queue = {}--new Queue(); // holds commands issued but not able to be sent
	c.commands_sent = 0
	
	-- -->
	--c.retry_delay = 250 -- inital reconnection delay
	--c.current_retry_delay = c.retry_delay
	--c.retry_backoff = 1.7 -- each retry waits current delay * retry_backoff
	c.connect_timeout = false
	if type(options.connect_timeout) == "number" and options.connect_timeout > 0 then
		c.connect_timeout = options.connect_timeout
	end
	c.retry_totaltime = 0
	c.retry_delay = 250
	c.retry_backoff = 1.7
	-- <--
	
	c.subscriptions = false
	c.monitoring = false
	c.closing = false
	c.server_info = {}
	c.auth_pass = nil
	c.parser_module = nil

	c.stream:on("connect", function(self)
		c:on_connect()
	end)

	c.stream:on("data", function(self, data)
		c:on_data(data)
	end)

	c.stream:on("error", function(self, msg)
		if c.closing then return end

		local message = ("Redis connection to %s:%d failed - %s"):format(c.host, c.port, msg)
		if debug_mode then
			console.warn(message)
		end
		for _,v in ipairs(c.offline_queue) do
			-- TODO: chequear esto
			if type(v[2]) == "function" then
				v[2](message)
			end
		end
		c.offline_queue = {}

		for _,v in ipairs(c.command_queue) do
			-- TODO: chequear esto
			if type(v[2]) == "function" then
				v[2](message)
			end
		end
		c.command_queue = {}

		c.connected = false
		c.ready = false

		c:emit("error", message)

		c:connection_gone("error")
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

---
--
function RedisClient:do_auth ()
	
	if debug_mode then
		console.log("Sending auth to %s:%d socket %s", self.host, self.port, tostring(self.stream._raw_socket))
	end
	self.send_anyway = true
	self:send_command("auth", {self.auth_pass}, function (err, res)
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
			console.log("Auth succeeded %s:%d socket %s", self.host, self.port, tostring(self.stream._raw_socket))
		end
		if self.auth_callback then
			self:auth_callback(err, res)
			self.auth_callback = nil
		end

		-- now we are really connected
		self:emit("connect")
		if self.options.no_ready_check then
			self.ready = true
			self:send_offline_queue()
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
		console.log("Stream connected %s:%d socket %s", self.host, self.port, tostring(self.stream._raw_socket))
	end

	self.connected = true
	self.ready = false
	self.attempts = 0
	self.connections = self.connections + 1
	self.command_queue = {}--new Queue();
	self.emitted_end = false
	-- -->
	--self:initialize_retry_vars()
    if self.options.socket_nodelay then
	  	self.stream:setNoDelay()
    end
	
	self.retry_timer = nil
	self.current_retry_delay = self.retry_delay
	self.stream:setNoDelay()
	self.stream:setTimeout(0)

	self:init_parser()

	if self.auth_pass then
		self:do_auth()
	else
		self:emit("connect")

		if self.options.no_ready_check then
			self.ready = true
			self:send_offline_queue()
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

---
--
function RedisClient:ready_check ()

	local function send_info_cmd()
		if debug_mode then console.log("checking server ready state...") end

		self.send_anyway = true     -- secret flag to send_command to send something even if not "ready"
		self:info(function (self, err, res)
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
			--obj.redis_version

			-- expose info key/vals to users
			self.server_info = info

			if (not info.loading or (info.loading and info.loading == "0")) then
				if debug_mode then console.log("Redis server ready.") end
				self.ready = true

				self:send_offline_queue()
				self:emit("ready")
			else
				retry_time = info.loading_eta_seconds * 1000
				if retry_time > 1000 then
					retry_time = 1000
				end
				if debug_mode then console.log("Redis server still loading, trying again in " .. retry_time) end
				setTimeout(send_info_cmd, retry_time)
			end
		end)
		self.send_anyway = false
	end

	send_info_cmd()
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

	-- Note that this may trigger another "close" or "end" event
	self.stream:destroy()

	if debug_mode then
		console.warn("Redis connection is gone from %s event.", why)
	end
	self.connected = false
	self.ready = false
	self.subscriptions = false
	self.monitoring = false

	-- since we are collapsing end and close, users don't expect to be called twice
	if not self.emitted_end then
		self:emit("end")
		self.emitted_end = true
	end

	for _, v in ipairs(self.command_queue) do
		if type(v[2]) == "function" then
			v[2]("Server connection closed")
		end
	end
	self.command_queue = {}

	-- If this is a requested shutdown, then don't retry
	if self.closing then
		self.retry_timer = nil
		self.stream._events = {}
		return
	end

	self.current_retry_delay = self.current_retry_delay + self.retry_delay * self.retry_backoff

	if debug_mode then
		console.log("Retry connection in %d ms", self.current_retry_delay)
	end
	self.attempts = self.attempts + 1
	self:emit("reconnecting", {
		delay = self.current_retry_delay,
		attempt = self.attempts
	})
	self.retry_timer = setTimeout(function ()
		if debug_mode then
			console.log("Retrying connection...")
		end
		self.stream:connect(self.port, self.host)
		self.retry_timer = nil
	end, self.current_retry_delay)
end

---
--
function RedisClient:on_data (data)
	if debug_mode then
		console.log("net read %s:%d socket %s: %s", self.host, self.port, tostring(self.stream._raw_socket), data)
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

	if self.subscriptions == false and queue_len == 0 then
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
		console.log("node_redis: no callback to send error: %s", err.message)
		-- this will probably not make it anywhere useful, but we might as well throw
		process.nextTick(function ()
			error(err)
		end)
	end
end

---
--
function RedisClient:return_reply (reply)
	local command_obj = table.remove(self.command_queue, 1)
	local queue_len = #self.command_queue

	if self.subscriptions == false and queue_len == 0 then
		self:emit("idle")
		self.command_queue = {}
	end
	if self.should_buffer and queue_len <= self.command_queue_low_water then
		self:emit("drain")
		self.should_buffer = false
	end

	if command_obj and not command_obj.sub_command then
		if type(command_obj.callback) == "function" then
			-- TODO - confusing and error-prone that hgetall is special cased in two places
			if reply and 'hgetall' == command_obj.command:lower() then
				if type(reply) == "table" then
					--console.warn("--> HGETALL", luanode.utils.inspect(reply), #reply)
					reply = reply_to_object(reply)
				end
			end

			local ok, err = pcall(command_obj.callback, self, nil, reply)
			if not ok then
				-- if a callback throws an exception, re-throw it on a new stack so the parser can keep going
				process.nextTick(function ()
					error(err)
				end)
			end
		elseif debug_mode then
			console.log("no callback for reply: " .. tostring(reply))-- && reply.toString && reply.toString()));
		end
	elseif self.subscriptions or (command_obj and command_obj.sub_command) then
		if type(reply) == "table" then -- is array?
			local kind = reply[1]

			if kind == "message" then
				self:emit("message", reply[2], reply[3]) -- channel, message
			elseif kind == "pmessage" then
				self:emit("pmessage", reply[2], reply[3], reply[4]) -- pattern, channel, message
			elseif kind == "subscribe" or kind == "unsubscribe" or kind == "psubscribe" or kind == "punsubscribe" then
				--console.error("ACA", luanode.utils.inspect(reply))
				if reply[3] == "0" then
					self.subscriptions = false
					if self.debug_mode then
						console.log("All subscriptions removed, exiting pub/sub mode")
					end
				end
				self:emit(kind, reply[2], tonumber(reply[3])) -- channel, count
			else
				error("subscriptions are active but got unknown reply type " .. kind)
			end
		elseif not self.closing then
			error("subscriptions are active but got an invalid reply: " .. reply)
		end
	elseif self.monitoring then
		--local len = reply.indexOf(" ");
		--timestamp = reply.slice(0, len);
		---- TODO - this de-quoting doesn't work correctly if you put JSON strings in your values.
		--args = reply.slice(len + 1).match(/"[^"]+"/g).map(function (elem) {
			--return elem.replace(/"/g, "");
		--});
		--self:emit("monitor", timestamp, args)
	else
		error("node_redis command queue state error. If you can reproduce this, please report it.")
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
                callback = args[#args]
                args[#args] = nil
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
    --if (Array.isArray(args[args.length - 1])) {
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
        if self.subscriptions == false and debug_mode then
            console.log("Entering pub/sub mode from %q", command)
        end
        command_obj.sub_command = true
        self.subscriptions = true
    elseif command == "monitor" then
        self.monitoring = true
    elseif command == "quit" then
        self.closing = true
    elseif self.subscriptions == true then
        error("Connection in pub/sub mode, only pub/sub commands may be used")
    end
    table.insert(self.command_queue, command_obj)
    self.commands_sent = self.commands_sent + 1

    local elem_count = 1
    local buffer_args = false;

    --elem_count = elem_count + args_len
    elem_count = elem_count + #args

    -- Always use "Multi bulk commands", but if passed any Buffer args, then do multiple writes, one for each arg
    -- This means that using Buffers in commands is going to be slower, so use Strings if you don't already have a Buffer.
    -- Also, why am I putting user documentation in the library source code?

    command_str = "*" .. elem_count .. "\r\n$" .. #command .. "\r\n" .. command .. "\r\n"

    if not buffer_args then  -- Build up a string and send entire command in one write
        --for i = 1, args_len do
        for i = 1, #args do
            local arg = args[i]
            if type(arg) ~= "string" then
                arg = tostring(arg)
            end
            command_str = command_str .. "$" .. #arg .. "\r\n" .. arg .. "\r\n"
        end
        if debug_mode then
            console.log("send %s:%d socket %s: %s", self.host, self.port, tostring(self.stream._raw_socket), command_str)
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
	--if (Array.isArray(args)) {
	  --  this.queue = this.queue.concat(args);
	--}
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

---
-- Stash auth for connect and reconnect.  Send immediately if already connected.
function RedisClient:auth (...)
	--var args = to_array(arguments)
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
		--var command = args[0], obj;
		--console.warn("queue", luanode.utils.inspect(args))
		local args_copy = {}
		local command = args[1]
		--console.warn(command)
		if type(args[#args]) == "function" then
			for i=2, #args - 1 do
				args_copy[i - 1] = args[i]
			end
			--console.warn("cortado", luanode.utils.inspect(args))
		else
			--console.warn("por aca")
			if type(args[2]) == "table" then
				args_copy = args[2]
			else
				for i=2, #args do
					args_copy[i - 1] = args[i]
				end
			end
		end
		--if #args == 2 then
		--	args_copy = args[2]
		--end
		--console.warn("args_copy", command, luanode.utils.inspect(args_copy))
		
		if cmd == "hmset" and type(args[1]) == "table" then
			error("NOT IMPLEMENTED")
			local obj = table.remove(args, -1)
			for key, value in pairs(obj) do
				args[#args + 1] = key
				args[#args + 1] = value
			end
		end
		
		self.client:send_command(command, args_copy, function (emitter, err, reply)
			--console.warn("callback", command, emitter, err, reply, index)
			--console.warn(self, emitter)
			if err then
				--console.error("callback err", emitter, err, reply)
				local cur = self.queue[index]
				if type(cur[#cur]) == "function" then
					--console.error("callback err", emitter, err, reply, cur)
					cur[#cur](self, err)
				else
					error(err)
				end
				--self.queue.splice(index, 1)
				--console.warn("queue", luanode.utils.inspect(self.queue))
				--self.queue = splice(self.queue, index + 2)
				table.remove(self.queue, index)
				--console.warn("queue", luanode.utils.inspect(self.queue))
			end
		end)
	end

	-- TODO - make this callback part of Multi.prototype instead of creating it each time
	return self.client:send_command("EXEC", {}, function (emitter, err, replies)
		--console.warn("EXEC callback", emitter, err, replies)
		if err then
			--console.error("EXEC callback", emitter, err, replies)
			if callback then
				callback(self, err)
				return
			else
				error(err)
			end
		end


		if replies then
			--console.warn("replies", luanode.utils.inspect(replies))
			for index = 2, #self.queue do-- index, args in ipairs(self.queue) do
				--console.warn("#replies", #replies)
				local reply = replies[index - 1]
				local args = self.queue[index]
				-- Convert HGETALL reply to object
				-- TODO - confusing and error-prone that hgetall is special cased in two places
				if reply and args[1]:lower() == "hgetall" then
					--console.warn("queue", index, luanode.utils.inspect(args), reply)
					reply = reply_to_object(reply)
					replies[index - 1] = reply
				end

				if type(args[#args]) == "function" then
					--console.log("calling")
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
function print (redis_client, err, reply)
	if err then
		console.log("Error: %s", err)
	else
		console.log("Reply: %s", reply)
	end
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
