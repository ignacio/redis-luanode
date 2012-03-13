local redis = require "redis-luanode"

module(..., package.seeall)


-- Set this to truthy to see the wire protocol and other debugging info
--redis.debug_mode = process.argv[2]
--redis.debug_mode = true

local Test = require "siteswap.test"

function Test.require_number(test_case, expected)
	return function (emitter, err, results)
		--table.foreach(getmetatable(test_case), print)
		--console.warn(test_case, emitter, err, results)
		--console.log(test_case.assert_equal)
		test_case:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test_case:assert_equal(expected, results)
		test_case:assert_number(results)
		return true
	end
end

function Test.require_number_any(test_case)
	return function (emitter, err, results)
		test_case:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test_case:assert_number(results)
		return true
	end
end

function Test.require_number_pos(test_case)
	return function (emitter, err, results)
		test_case:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test_case:assert_number(results)
		test_case:assert_true(results > 0, "is not a positive number")
		return true
	end
end

function Test.require_string(test_case, str)
	return function (emitter, err, results)
		test_case:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test_case:assert_equal(str, results)
		return true
	end
end

function Test.require_null(test_case)
	return function (emitter, err, results)
		test_case:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test_case:assert_nil(results)
		return true
	end
end

function Test.require_error(test_case)
	return function (emitter, err, results)
		--console.error(emitter, err, results)
		test_case:assert_not_nil(err, " err is nil, but an error is expected here.")
		return true
	end
end


-- Tests are run in the order they are defined.  So FLUSHDB should be stay first.

t = AddTest("FLUSHDB", function(test, env)
	client:select(env.test_db_num, test:require_string("OK"))
	client2:select(env.test_db_num, test:require_string("OK"))
	client3:select(env.test_db_num, test:require_string("OK"))
	client:mset("flush keys 1", "flush val 1", "flush keys 2", "flush val 2", test:require_string("OK"))
	client:FLUSHDB(test:require_string("OK"))
	client:dbsize(test:Last(test:require_number(0)))
end)

--[[
t:on("done", function()
    console.warn("pronto!")
end)
--]]
    
    --t:on("done", function()
        --console.warn("pronto!")
    --end)
    
    --t:Run()
    
    --[[
    Sync(function(wait, yield)
        client:select(test_db_num, require_string("OK", name))
        --client2:select(test_db_num, require_string("OK", name))
        --client3:select(test_db_num, require_string("OK", name))
        client:mset("flush keys 1", "flush val 1", "flush keys 2", "flush val 2", require_string("OK", name))
        client:FLUSHDB(require_string("OK", name))
        --client:dbsize(last(name, test:require_number(0, name)))
        console.log("dbsize")
        --client:dbsize(wait)
        --client:dbsize(last(wait, test:require_number(0, name)))
        client:dbsize(last(name, wait, test:require_number(0, name)))
        --wait()
        --client:dbsize(function()
			--console.log("BLABLABLA")
        --end)
        local _, err, name = yield()
        --require_number(0, name)
        console.log("testsFLUSHDB fin")
        
        t:emit("done")
        --yield()
    end)
    --]]
	
	--process:loop()
--end


AddTest("MULTI_1", function (test)

	-- Provoke an error at queue time
	local multi1 = client:multi()
	multi1:mset("multifoo", "10", "multibar", "20", test:require_string("OK"))
	multi1:set("foo2", test:require_error())
	multi1:incr("multifoo", test:require_number(11))
	multi1:incr("multibar", test:require_number(21))
	multi1:exec()

	-- Confirm that the previous command, while containing an error, still worked.
	local multi2 = client:multi()
	multi2:incr("multibar", test:require_number(22))
	multi2:incr("multifoo", test:require_number(12))
	multi2:exec(test:Last(function (emitter, err, replies)
		test:assert_equal(22, replies[1])
		test:assert_equal(12, replies[2])
	end))
end)

AddTest("MULTI_2", function (test)

	-- test nested multi-bulk replies
	client:flushdb()
	client:mset({"multifoo", "10", "multibar", "20"}, test:require_string("OK"))
	
	client:multi({
		{"mget", "multifoo", "multibar", function (emitter, err, res)
			test:assert_equal(2, #res)
			test:assert_equal("10", res[1])
			test:assert_equal("20", res[2])
		end},
		{"set", "foo2", test:require_error()},
		{"incr", "multifoo", test:require_number(11)},
		{"incr", "multibar", test:require_number(21)}
	
	}):exec(test:Last(function (emitter, err, replies)
		test:assert_equal(2, #replies[1])
		test:assert_equal("10", replies[1][1])
		test:assert_equal("20", replies[1][2])
		
		test:assert_equal(11, replies[2])
		test:assert_equal(21, replies[3])
	end))
end)

AddTest("MULTI_3", function (test)

	client:sadd("some set", "mem 1")
	client:sadd("some set", "mem 2")
	client:sadd("some set", "mem 3")
	client:sadd("some set", "mem 4")

	-- make sure empty mb reply works
	client:del("some missing set")
	client:smembers("some missing set", function (_, err, reply)
		-- make sure empty mb reply works
		test:assert_deep_equal({}, reply)
	end)
 
	-- test nested multi-bulk replies with empty mb elements.
	client:multi({
		{"smembers", "some set"},
		{"del", "some set"},
		{"smembers", "some set"}
	})
	:scard("some set")
	:exec(test:Last(function (_, err, replies)
		test:assert_deep_equal({}, replies[3])
	end))
end)

AddTest("MULTI_4", function (test)
	
	client:multi()
		:mset('some', '10', 'keys', '20')
		:incr('some')
		:incr('keys')
		:mget('some', 'keys')
		:exec(test:Last(function (_, err, replies)
			test:assert_nil(err)
			test:assert_equal('OK', replies[1])
			test:assert_equal(11, replies[2])
			test:assert_equal(21, replies[3])
			test:assert_equal("11", replies[4][1])
			test:assert_equal("21", replies[4][2])
		end))
end)

AddTest("MULTI_5", function (test)

	-- test nested multi-bulk replies with nulls.
	client:mset("multifoo", "2", "some", "blah", "keys", "values")
	client:multi({
		{"mget", {"multifoo", "some", "random value", "keys"}},
		{"incr", "multifoo"}
	})
	:exec(test:Last(function (_, err, replies)
		test:assert_equal(2, #replies)
		test:assert_equal(4, #replies[1])
	end))
end)

AddTest("MULTI_6", function (test)
	
	client:multi()
		:hmset("multihash", "a", "foo", "b", 1)
		:hmset("multihash", {
			extra = "fancy",
			things = "here"
		})
		:hgetall("multihash")
		:exec(test:Last(function (_, err, replies)
			test:assert_nil(err)
			test:assert_equal("OK", replies[1])
			
			local count = 0
			for _ in pairs(replies[3]) do count = count + 1 end
			test:assert_equal(4, count)
			test:assert_equal("foo", replies[3].a)
			test:assert_equal("1", replies[3].b)
			test:assert_equal("fancy", replies[3].extra)
			test:assert_equal("here", replies[3].things)
		end))
end)

--[===[
AddTest("EVAL_1", function (test)

    if (client.server_info.versions[0] >= 2 && client.server_info.versions[1] >= 9) {
        // test {EVAL - Lua integer -> Redis protocol type conversion}
        client:eval("return 100.5", 0, test:require_number(100))
        // test {EVAL - Lua string -> Redis protocol type conversion}
        client:eval("return 'hello world'", 0, test:require_string("hello world"))
        // test {EVAL - Lua true boolean -> Redis protocol type conversion}
        client:eval("return true", 0, test:require_number(1))
        // test {EVAL - Lua false boolean -> Redis protocol type conversion}
        client:eval("return false", 0, require_null())
        // test {EVAL - Lua status code reply -> Redis protocol type conversion}
        client:eval("return {ok='fine'}", 0, test:require_string("fine"))
        // test {EVAL - Lua error reply -> Redis protocol type conversion}
        client:eval("return {err='this is an error'}", 0, require_error())
        // test {EVAL - Lua table -> Redis protocol type conversion}
        client:eval("return {1,2,3,'ciao',{1,2}}", 0, function (err, res) {
            assert.strictEqual(5, res.length)
            assert.strictEqual(1, res[0])
            assert.strictEqual(2, res[1])
            assert.strictEqual(3, res[2])
            assert.strictEqual("ciao", res[3])
            assert.strictEqual(2, res[4].length)
            assert.strictEqual(1, res[4][0])
            assert.strictEqual(2, res[4][1])
        })
        // test {EVAL - Are the KEYS and ARGS arrays populated correctly?}
        client:eval("return {KEYS[1],KEYS[2],ARGV[1],ARGV[2]}", 2, "a", "b", "c", "d", function (err, res) {
            assert.strictEqual(4, res.length)
            assert.strictEqual("a", res[0])
            assert.strictEqual("b", res[1])
            assert.strictEqual("c", res[2])
            assert.strictEqual("d", res[3])
        })
        // test {EVAL - is Lua able to call Redis API?}
        client:set("mykey", "myval")
        client:eval("return redis.call('get','mykey')", 0, test:require_string("myval"))
        // test {EVALSHA - Can we call a SHA1 if already defined?}
        client:evalsha("9bd632c7d33e571e9f24556ebed26c3479a87129", 0, test:require_string("myval"))
        // test {EVALSHA - Do we get an error on non defined SHA1?}
        client:evalsha("ffffffffffffffffffffffffffffffffffffffff", 0, require_error())
        // test {EVAL - Redis integer -> Lua type conversion}
        client:set("x", 0)
        client:eval("local foo = redis.call('incr','x')\n" + "return {type(foo),foo}", 0, function (err, res) {
            assert.strictEqual(2, res.length)
            assert.strictEqual("number", res[0])
            assert.strictEqual(1, res[1])
        })
        // test {EVAL - Redis bulk -> Lua type conversion}
        client:eval("local foo = redis.call('get','mykey') return {type(foo),foo}", 0, function (err, res) {
            assert.strictEqual(2, res.length)
            assert.strictEqual("string", res[0])
            assert.strictEqual("myval", res[1])
        })
        // test {EVAL - Redis multi bulk -> Lua type conversion}
        client:del("mylist")
        client:rpush("mylist", "a")
        client:rpush("mylist", "b")
        client:rpush("mylist", "c")
        client:eval("local foo = redis.call('lrange','mylist',0,-1)\n" + "return {type(foo),foo[1],foo[2],foo[3],# foo}", 0, function (err, res) {
            assert.strictEqual(5, res.length)
            assert.strictEqual("table", res[0])
            assert.strictEqual("a", res[1])
            assert.strictEqual("b", res[2])
            assert.strictEqual("c", res[3])
            assert.strictEqual(3, res[4])
        })
        // test {EVAL - Redis status reply -> Lua type conversion}
        client:eval("local foo = redis.call('set','mykey','myval') return {type(foo),foo['ok']}", 0, function (err, res) {
            assert.strictEqual(2, res.length)
            assert.strictEqual("table", res[0])
            assert.strictEqual("OK", res[1])
        })
        // test {EVAL - Redis error reply -> Lua type conversion}
        client:set("mykey", "myval")
        client:eval("local foo = redis.call('incr','mykey') return {type(foo),foo['err']}", 0, function (err, res) {
            assert.strictEqual(2, res.length)
            assert.strictEqual("table", res[0])
            assert.strictEqual("ERR value is not an integer or out of range", res[1])
        })
        // test {EVAL - Redis nil bulk reply -> Lua type conversion}
        client:del("mykey")
        client:eval("local foo = redis.call('get','mykey') return {type(foo),foo == false}", 0, function (err, res) {
            assert.strictEqual(2, res.length)
            assert.strictEqual("boolean", res[0])
            assert.strictEqual(1, res[1])
        })
        // test {EVAL - Script can't run more than configured time limit} {
        client:config("set", "lua-time-limit", 1)
        client:eval("local i = 0 while true do i=i+1 end", 0, test:Last("name", require_error()))
    } else {
        console.log("Skipping " + name + " because server version isn't new enough.")
        next(name)
    }
}
--]===]

AddTest("WATCH_MULTI", function (test)
	local name = 'WATCH_MULTI'

	if client.server_info.versions[1] >= 2 and client.server_info.versions[2] >= 1 then
		client:watch(name)
		client:incr(name)
		local multi = client:multi()
		multi:incr(name)
		multi:exec(test:Last(test:require_null()))
	else
		console.log("Skipping " .. name .. " because server version isn't new enough.")
		test:Skip()
	end
end)

AddTest("socket_nodelay", function(test, env)
	local ready_count = 0
	local quit_count = 0

	local c1 = redis.createClient(env.redis.port, env.redis.host, {socket_nodelay = true})
	local c2 = redis.createClient(env.redis.port, env.redis.host, {socket_nodelay = false})
	local c3 = redis.createClient(env.redis.port, env.redis.host)

	local function quit_check()
		quit_count = quit_count + 1

		if quit_count == 3 then
			test:Done()
		end
	end

	local function run()
		test:assert_equal(true, c1.options.socket_nodelay)
		test:assert_equal(false, c2.options.socket_nodelay)
		test:assert_equal(true, c3.options.socket_nodelay)

		c1:set({"set key 1", "set val"}, test:require_string("OK"))
		c1:set({"set key 2", "set val"}, test:require_string("OK"))
		c1:get({"set key 1"}, test:require_string("set val"))
		c1:get({"set key 2"}, test:require_string("set val"))

		c2:set({"set key 3", "set val"}, test:require_string("OK"))
		c2:set({"set key 4", "set val"}, test:require_string("OK"))
		c2:get({"set key 3"}, test:require_string("set val"))
		c2:get({"set key 4"}, test:require_string("set val"))

		c3:set({"set key 5", "set val"}, test:require_string("OK"))
		c3:set({"set key 6", "set val"}, test:require_string("OK"))
		c3:get({"set key 5"}, test:require_string("set val"))
		c3:get({"set key 6"}, test:require_string("set val"))

		c1:quit(quit_check)
		c2:quit(quit_check)
		c3:quit(quit_check)
	end

	local function ready_check()
		ready_count = ready_count + 1
		if ready_count == 3 then
			run()
		end
	end

	c1:on("ready", ready_check)
	c2:on("ready", ready_check)
	c3:on("ready", ready_check)
end)

AddTest("reconnect", function (test, env)

	client:set("recon 1", "one")
	client:set("recon 2", "two", function (emitter, err, res)
		-- Do not do this in normal programs. This is to simulate the server closing on us.
		-- For orderly shutdown in normal programs, do client:quit()
		client.stream:destroy()
	end)
	
	local on_recon, on_connect
	on_recon = function (_, params)
		client:on("connect", on_connect)
	end
	
	on_connect = function()
		client:removeListener("connect", on_connect)
		client:removeListener("reconnecting", on_recon)
		
		client:select(env.test_db_num, test:require_string("OK"))
		client:get("recon 1", test:require_string("one"))
		client:get("recon 1", test:require_string("one"))
		client:get("recon 2", test:require_string("two"))
		client:get("recon 2", test:Last(test:require_string("two")))
	end
	
	client:on("reconnecting", on_recon) 
end)


AddTest("HSET", function(test)
	local key = "test hash"
	local field1 = "0123456789"
	local value1 = "abcdefghij"
	local field2 = ""
	local value2 = ""


	client:HSET(key, field1, value1, test:require_number(1))
	client:HGET(key, field1, test:require_string(value1))

	-- Empty value
	client:HSET(key, field1, value2, test:require_number(0))
	client:HGET({key, field1}, test:require_string(""))

	-- Empty key, empty value
	client:HSET({key, field2, value1}, test:require_number(1))
	client:HSET(key, field2, value2, test:Last(test:require_number(0)))
end)


AddTest("HMSET_BUFFER_AND_ARRAY", function (test)
	-- Saving a buffer and an array to the same key should not error
	local key = "test hash"
	local field1 = "buffer"
	local value1 = "abcdefghij"
	local field2 = "array"
	local value2 = {"array contents"}

	client:HMSET(key, field1, value1, field2, value2, test:Last(test:require_string("OK")))
end)

-- TODO - add test for HMSET.  It is special.  Test for all forms as well as optional callbacks

AddTest("HMGET", function (test)
	local key1 = "test hash 1"
	local key2 = "test hash 2"

	-- redis-like hmset syntax
	client:HMSET(key1, "0123456789", "abcdefghij", "some manner of key", "a type of value", test:require_string("OK"))

	-- fancy hmset syntax
	client:HMSET(key2, {
		["0123456789"] = "abcdefghij",
		["some manner of key"] = "a type of value"
	}, test:require_string("OK"))

	client:HMGET(key1, "0123456789", "some manner of key", function (emitter, err, reply)
		test:assert_equal("abcdefghij", reply[1])
		test:assert_equal("a type of value", reply[2])
	end)

	client:HMGET(key2, "0123456789", "some manner of key", function (emitter, err, reply)
		test:assert_equal("abcdefghij", reply[1])
		test:assert_equal("a type of value", reply[2])
	end)

	client:HMGET(key1, {"0123456789"}, function (emitter, err, reply)
		test:assert_equal("abcdefghij", reply[1])
	end)

	client:HMGET(key1, {"0123456789", "some manner of key"}, function (emitter, err, reply)
		test:assert_equal("abcdefghij", reply[1])
		test:assert_equal("a type of value", reply[2])
	end)

	client:HMGET(key1, "missing thing", "another missing thing", test:Last(function (emitter, err, reply)
		test:assert_nil(reply[1])
		test:assert_nil(reply[2])
	end))
end)

AddTest("HINCRBY", function(test)
	client:hset("hash incr", "value", 10, test:require_number(1))
	client:HINCRBY("hash incr", "value", 1, test:require_number(11))
	client:HINCRBY("hash incr", "value 2", 1, test:Last(test:require_number(1)))
end)

AddTest("SUBSCRIBE", function (test)
	local client1 = client
	local msg_count = 0

	client1:on("subscribe", function (_, channel, count)
		if channel == "chan1" then
			client2:publish("chan1", "message 1", test:require_number(1))
			client2:publish("chan2", "message 2", test:require_number(1))
			client2:publish("chan1", "message 3", test:require_number(1))
		end
	end)

	client1:on("unsubscribe", function (_, channel, count)
		if count == 0 then
			-- make sure this connection can go into and out of pub/sub mode
			client1:incr("did a thing", test:Last(test:require_number(2)))
		end
	end)

	client1:on("message", function (_, channel, message)
		msg_count = msg_count + 1
		test:assert_equal("message " .. msg_count, message)
		if msg_count == 3 then
			client1:unsubscribe("chan1", "chan2")
		end
	end)

	client1:set("did a thing", 1, test:require_string("OK"))
	client1:subscribe("chan1", "chan2", function (emitter, err, results)
		test:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test:assert_equal("chan1", results)
	end)
end)

AddTest("SUBSCRIBE_QUIT", function (test)
	client3:on("end", test:Last())
	client3:on("subscribe", function (_, channel, count)
		client3:quit()
	end)
	client3:subscribe("chan3")
end)

AddTest("EXISTS", function(test)
	client:del("foo", "foo2", test:require_number_any())
	client:set("foo", "bar", test:require_string("OK"))
	client:EXISTS("foo", test:require_number(1))
	client:EXISTS("foo2", test:Last(test:require_number(0)))
end)


AddTest("DEL", function(test)
	client:DEL("delkey", test:require_number_any())
	client:set("delkey", "delvalue", test:require_string("OK"))
	client:DEL("delkey", test:require_number(1))
	client:exists("delkey", test:require_number(0))
	client:DEL("delkey", test:require_number(0))
	client:mset("delkey", "delvalue", "delkey2", "delvalue2", test:require_string("OK"))
	client:DEL("delkey", "delkey2", test:Last(test:require_number(2)))
end)


AddTest("TYPE", function(test)
	client:set({"string key", "should be a string"}, test:require_string("OK"))
	client:rpush({"list key", "should be a list"}, test:require_number_pos())
	client:sadd({"set key", "should be a set"}, test:require_number_any())
	client:zadd({"zset key", "10.0", "should be a zset"}, test:require_number_any())
	client:hset({"hash key", "hashtest", "should be a hash"}, test:require_number_any(0))
	
	client:TYPE({"string key"}, test:require_string("string"))
	client:TYPE({"list key"}, test:require_string("list"))
	client:TYPE({"set key"}, test:require_string("set"))
	client:TYPE({"zset key"}, test:require_string("zset"))
	client:TYPE("not here yet", test:require_string("none"))
	client:TYPE({"hash key"}, test:Last(test:require_string("hash")))
end)

AddTest("KEYS", function (test)
	client:mset({"test keys 1", "test val 1", "test keys 2", "test val 2"}, test:require_string("OK"))
	client:KEYS("test keys*", test:Last(function (redis, err, results)
		test:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test:assert_equal(2, #results)
		test:assert_equal("test keys 1", results[1])
		test:assert_equal("test keys 2", results[2])
	end))
end)

AddTest("MULTIBULK_ZERO_LENGTH", function (test)
	client:KEYS({'users:*'}, test:Last(function(redis, err, results)
		test:assert_nil(err, "error on empty multibulk reply")
		test:assert_nil(next(results), "not an empty array")
	end))
end)

AddTest("RANDOMKEY", function (test)
	client:mset({"test keys 1", "test val 1", "test keys 2", "test val 2"}, test:require_string("OK"))
	client:RANDOMKEY(test:Last(function (redis, err, results)
		test:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test:assert_match("%w+", results)
	end))
end)

AddTest("RENAME", function (test)
	client:set({'foo', 'bar'}, test:require_string("OK"))
	client:RENAME({"foo", "new foo"}, test:require_string("OK"))
	client:exists("foo", test:require_number(0))
	client:exists("new foo", test:Last(test:require_number(1)))
end)

AddTest("RENAMENX", function (test)
	client:set({'foo', 'bar'}, test:require_string("OK"))
	client:set({'foo2', 'bar2'}, test:require_string("OK"))
	client:RENAMENX({"foo", "foo2"}, test:require_number(0))
	client:exists("foo", test:require_number(1))
	client:exists("foo2", test:require_number(1))
	client:del("foo2", test:require_number(1))
	client:RENAMENX("foo", "foo2", test:require_number(1))
	client:exists("foo", test:require_number(0))
	client:exists("foo2", test:Last(test:require_number(1)))
end)

AddTest("DBSIZE", function (test)
	client:set('foo', 'bar', test:require_string("OK"))
	client:DBSIZE(test:Last(test:require_number_pos("DBSIZE")))
end)

AddTest("GET", function (test)
	client:set("get key", "get val", test:require_string("OK"))
	client:GET("get key", test:Last(test:require_string("get val")))
end)

AddTest("SET", function (test)
	client:SET("set key", "set val", test:require_string("OK"))
	client:get("set key", test:Last(test:require_string("set val")))
end)

AddTest("GETSET", function (test)
	client:set("getset key", "getset val", test:require_string("OK"))
	client:GETSET("getset key", "new getset val", test:require_string("getset val"))
	client:get("getset key", test:Last(test:require_string("new getset val")))
end)

AddTest("MGET", function (test)
	client:mset("mget keys 1", "mget val 1", "mget keys 2", "mget val 2", "mget keys 3", "mget val 3", test:require_string("OK"))
	client:MGET("mget keys 1", "mget keys 2", "mget keys 3", function (redis, err, results)
		test:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test:assert_equal(3, #results)
		test:assert_equal("mget val 1", results[1])
		test:assert_equal("mget val 2", results[2])
		test:assert_equal("mget val 3", results[3])
	end)
	client:MGET("mget keys 1", "mget keys 2", "mget keys 3", function (redis, err, results)
		test:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test:assert_equal(3, #results)
		test:assert_equal("mget val 1", results[1])
		test:assert_equal("mget val 2", results[2])
		test:assert_equal("mget val 3", results[3])
	end)
	client:MGET("mget keys 1", "some random shit", "mget keys 2", "mget keys 3", test:Last(function (redis, err, results)
		test:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		test:assert_equal(4, #results)
		test:assert_equal("mget val 1", results[1])
		test:assert_nil(results[2])
		test:assert_equal("mget val 2", results[3])
		test:assert_equal("mget val 3", results[4])
	end))
end)

AddTest("SETNX", function (test)
	client:set("setnx key", "setnx value", test:require_string("OK"))
	client:SETNX("setnx key", "new setnx value", test:require_number(0))
	client:del("setnx key", test:require_number(1))
	client:exists("setnx key", test:require_number(0))
	client:SETNX("setnx key", "new setnx value", test:require_number(1))
	client:exists("setnx key", test:Last(test:require_number(1)))
end)

AddTest("SETEX", function (test)
	client:SETEX("setex key", "100", "setex val", test:require_string("OK"))
	client:exists("setex key", test:require_number(1))
	client:ttl("setex key", test:Last(test:require_number_pos()))
end)

AddTest("MSETNX", function (test)
	client:mset("mset1", "val1", "mset2", "val2", "mset3", "val3", test:require_string("OK"))
	client:MSETNX("mset3", "val3", "mset4", "val4", test:require_number(0))
	client:del("mset3", test:require_number(1))
	client:MSETNX("mset3", "val3", "mset4", "val4", test:require_number(1))
	client:exists("mset3", test:require_number(1))
	client:exists("mset4", test:Last(test:require_number(1)))
end)

AddTest("HGETALL", function (test)
	client:hmset("hosts", "mjr", "1", "another", "23", "home", "1234", test:require_string("OK"))
	client:HGETALL("hosts", test:Last(function (redis, err, obj)
		test:assert_nil(err, "result sent back unexpected error: " .. tostring(err))
		
		local count = 0
		for _ in pairs(obj) do count = count + 1 end
		test:assert_equal(3, count)
		test:assert_equal("1", obj.mjr)
		test:assert_equal("23", obj.another)
		test:assert_equal("1234", obj.home)
	end))
end)

AddTest("HGETALL_NULL", function (test)
	
	client:hgetall('missing', test:Last(function (redis, err, obj)
		test:assert_nil(err)
		test:assert_nil(obj)
	end))
end)

AddTest("UTF8", function (test)
	local utf8_sample = "ಠ_ಠ"

	client:set("utf8test", utf8_sample, test:require_string("OK"))
	client:get("utf8test", test:Last(function (redis, err, obj)
		test:assert_nil(err)
		test:assert_equal(utf8_sample, obj)
	end))
end)

-- Set tests were adapted from Brian Hammond's redis-node-client.js, which has a comprehensive test suite

AddTest("SADD", function (test)
	client:del('set0')
	client:sadd('set0', 'member0', test:require_number(1))
	client:sadd('set0', 'member0', test:Last(test:require_number(0)))
end)

AddTest("SADD2", function (test)
	client:del("set0")
	client:sadd("set0", "member0", "member1", "member2", test:require_number(3))
	client:smembers("set0", test:Last(function (redis, err, res)
		test:assert_equal(#res, 3)
		test:assert_deep_equal({"member0", "member1", "member2"}, res)
	end))
end)

AddTest("SISMEMBER", function (test)
	client:del('set0')
	client:sadd('set0', 'member0', test:require_number(1))
	client:sismember('set0', 'member0', test:require_number(1))
	client:sismember('set0', 'member1', test:Last(test:require_number(0)))
end)

AddTest("SCARD", function (test)   
	client:del('set0')
	client:sadd('set0', 'member0', test:require_number(1))
	client:scard('set0', test:require_number(1))
	client:sadd('set0', 'member1', test:require_number(1))
	client:scard('set0', test:Last(test:require_number(2)))
end)

AddTest("SREM", function (test)
	client:del('set0')
	client:sadd('set0', 'member0', test:require_number(1))
	client:srem('set0', 'foobar', test:require_number(0))
	client:srem('set0', 'member0', test:require_number(1))
	client:scard('set0', test:Last(test:require_number(0)))
end)

AddTest("SPOP", function (test)
	client:del('zzz')
	client:sadd('zzz', 'member0', test:require_number(1))
	client:scard('zzz', test:require_number(1))

	client:spop('zzz', function (redis, err, value)
		if err then
			test:fail(err)
		end
		test:assert_equal('member0', value)
	end)

	client:scard('zzz', test:Last(test:require_number(0)))
end)

AddTest("SDIFF", function (test)  
	client:del('foo')
	client:sadd('foo', 'x', test:require_number(1))
	client:sadd('foo', 'a', test:require_number(1))
	client:sadd('foo', 'b', test:require_number(1))
	client:sadd('foo', 'c', test:require_number(1))

	client:sadd('bar', 'c', test:require_number(1))

	client:sadd('baz', 'a', test:require_number(1))
	client:sadd('baz', 'd', test:require_number(1))

	client:sdiff('foo', 'bar', 'baz', test:Last(function (redis, err, values)
		if err then
			test:fail(err)
		end
		table.sort(values)
		test:assert_equal(#values, 2)
		test:assert_equal('b', values[1])
		test:assert_equal('x', values[2])
	end))
end)

AddTest("SDIFFSTORE", function (test)
	client:del('foo')
	client:del('bar')
	client:del('baz')
	client:del('quux')

	client:sadd('foo', 'x', test:require_number(1))
	client:sadd('foo', 'a', test:require_number(1))
	client:sadd('foo', 'b', test:require_number(1))
	client:sadd('foo', 'c', test:require_number(1))

	client:sadd('bar', 'c', test:require_number(1))

	client:sadd('baz', 'a', test:require_number(1))
	client:sadd('baz', 'd', test:require_number(1))

	-- NB: SDIFFSTORE returns the number of elements in the dstkey 

	client:sdiffstore('quux', 'foo', 'bar', 'baz', test:require_number(2))

	client:smembers('quux', test:Last(function (redis, err, values)
		if err then
			test:fail(err)
		end
		table.sort(values)
		test:assert_deep_equal({"b", "x"}, values)
	end))
end)

AddTest("SMEMBERS", function (test)
	client:del('foo')
	client:sadd('foo', 'x', test:require_number(1))

	client:smembers('foo', function (redis, err, members)
		test:assert_nil(err)
		
		test:assert_equal('x', members[1])
	end)

	client:sadd('foo', 'y', test:require_number(1))

	client:smembers('foo', test:Last(function (redis, err, values)
		if err then
			test:fail(err)
		end
		test:assert_equal(2, #values)
		table.sort(values)
		test:assert_deep_equal({"x", "y"}, values)
	end))
end)

AddTest("SMOVE", function (test)
	client:del('foo')
	client:del('bar')

	client:sadd('foo', 'x', test:require_number(1))
	client:smove('foo', 'bar', 'x', test:require_number(1))
	client:sismember('foo', 'x', test:require_number(0))
	client:sismember('bar', 'x', test:require_number(1))
	client:smove('foo', 'bar', 'x', test:Last(test:require_number(0)))
end)

AddTest("SINTER", function (test)
	client:del('sa')
	client:del('sb')
	client:del('sc')
	
	client:sadd('sa', 'a', test:require_number(1))
	client:sadd('sa', 'b', test:require_number(1))
	client:sadd('sa', 'c', test:require_number(1))

	client:sadd('sb', 'b', test:require_number(1))
	client:sadd('sb', 'c', test:require_number(1))
	client:sadd('sb', 'd', test:require_number(1))

	client:sadd('sc', 'c', test:require_number(1))
	client:sadd('sc', 'd', test:require_number(1))
	client:sadd('sc', 'e', test:require_number(1))

	client:sinter('sa', 'sb', function (redis, err, intersection)
		test:assert_nil(err)
		test:assert_equal(2, #intersection)
		table.sort(intersection)
		test:assert_deep_equal({"b", "c"}, intersection)
	end)

	client:sinter('sb', 'sc', function (redis, err, intersection)
		test:assert_nil(err)
		test:assert_equal(2, #intersection)
		table.sort(intersection)
		test:assert_deep_equal({"c", "d"}, intersection)
	end)

	client:sinter('sa', 'sc', function (redis, err, intersection)
		test:assert_nil(err)
		test:assert_equal(1, #intersection)
		test:assert_deep_equal({"c"}, intersection)
	end)

	-- 3-way

	client:sinter('sa', 'sb', 'sc', test:Last(function (redis, err, intersection)
		test:assert_nil(err)
		test:assert_equal(1, #intersection)
		test:assert_equal("c", intersection[1])
	end))
end)

AddTest("SINTERSTORE", function (test)
	client:del('sa')
	client:del('sb')
	client:del('sc')
	client:del('foo')

	client:sadd('sa', 'a', test:require_number(1))
	client:sadd('sa', 'b', test:require_number(1))
	client:sadd('sa', 'c', test:require_number(1))

	client:sadd('sb', 'b', test:require_number(1))
	client:sadd('sb', 'c', test:require_number(1))
	client:sadd('sb', 'd', test:require_number(1))

	client:sadd('sc', 'c', test:require_number(1))
	client:sadd('sc', 'd', test:require_number(1))
	client:sadd('sc', 'e', test:require_number(1))

	client:sinterstore('foo', 'sa', 'sb', 'sc', test:require_number(1))

	client:smembers('foo', test:Last(function (redis, err, members)
		test:assert_nil(err)
		test:assert_equal("c", members[1])
	end))
end)

AddTest("SUNION", function (test)
	client:del('sa')
	client:del('sb')
	client:del('sc')
	
	client:sadd('sa', 'a', test:require_number(1))
	client:sadd('sa', 'b', test:require_number(1))
	client:sadd('sa', 'c', test:require_number(1))

	client:sadd('sb', 'b', test:require_number(1))
	client:sadd('sb', 'c', test:require_number(1))
	client:sadd('sb', 'd', test:require_number(1))

	client:sadd('sc', 'c', test:require_number(1))
	client:sadd('sc', 'd', test:require_number(1))
	client:sadd('sc', 'e', test:require_number(1))

	client:sunion('sa', 'sb', 'sc', test:Last(function (redis, err, union)
		test:assert_nil(err)
		table.sort(union)
		test:assert_deep_equal({'a', 'b', 'c', 'd', 'e'}, union)
	end))
end)

AddTest("SUNIONSTORE", function (test)
   
	client:del('sa')
	client:del('sb')
	client:del('sc')
	client:del('foo')
	
	client:sadd('sa', 'a', test:require_number(1))
	client:sadd('sa', 'b', test:require_number(1))
	client:sadd('sa', 'c', test:require_number(1))

	client:sadd('sb', 'b', test:require_number(1))
	client:sadd('sb', 'c', test:require_number(1))
	client:sadd('sb', 'd', test:require_number(1))

	client:sadd('sc', 'c', test:require_number(1))
	client:sadd('sc', 'd', test:require_number(1))
	client:sadd('sc', 'e', test:require_number(1))

	client:sunionstore('foo', 'sa', 'sb', 'sc', function (redis, err, cardinality)
		test:assert_nil(err)
		test:assert_equal(5, tonumber(cardinality))
	end)

	client:smembers('foo', test:Last(function (redis, err, members)
		test:assert_nil(err)
		test:assert_equal(5, #members)
		table.sort(members)
		test:assert_deep_equal({'a', 'b', 'c', 'd', 'e'}, members)
	end))
end)


-- Sorted set tests were adapted from Brian Hammond's redis-node-client.js, which has a comprehensive test suite

AddTest("ZADD", function (test)
	client:del("zset0")
	client:zadd("zset0", 100, "m0", test:require_number(1))

	-- Already added m0, just update the score to 50.
	-- Redis returns 0 in this case.
	client:zadd("zset0", 50, "m0", test:Last(test:require_number(0)))
end)

AddTest("ZREM", function (test)
	client:del("zset0")
	client:zadd("zset0", 100, "m0", test:require_number(1))
	client:zrem("zset0", "m0", test:require_number(1))
	client:zrem("zset0", "m0", test:Last(test:require_number(0)))
end)

AddTest("ZCARD", function (test)
	client:zcard("zzzzz", test:require_number(0)) -- Does not exist
	
	client:del("zset0")
	client:zadd("zset0", 100, "m0", test:require_number(1))
	client:zadd("zset0", 100, "m1", test:require_number(1))

	client:zcard("zset0", test:Last(test:require_number(2)))
end)

AddTest("ZSCORE", function (test)
	client:del("zset0")
	client:zadd("zset0", 100, "m0", test:require_number(1))
	client:zadd("zset0", 200, "m1", test:require_number(1))

	client:zscore("zset0", "m0", test:require_number(100))
	client:zscore("zset0", "m1", test:require_number(200))

	client:zscore("zset0", "zzzzz", test:Last(function (redis, err, res)
		test:assert_nil(res)
	end))
end)

AddTest("MULTI_ZSCORE", function (test)
	
	client:multi()
		:del("zset0")
		:zadd("zset0", 100, "m0", test:require_number(1))
		:zadd("zset0", 200, "m1", test:require_number(1))
		:zscore({"zset0", "m0"}, test:require_number(100))
		:zscore("zset0", "m0", test:require_number(100))
		:zscore({"zset0", "m1"}, test:require_number(200))
		:zscore("zset0", "m1", test:require_number(200))
		:zscore("zset0", "zzzzz", function (redis, err, res)
			test:assert_nil(res)
		end)
		:exec(test:Last(function(redis, err, res)
			test:assert_deep_equal({1, 1, 1, "100", "100", "200", "200"}, res)
		end))
end)

AddTest("ZRANGE", function (test)
	client:del("zset0")
	client:zadd("zset0", 100, "m0", test:require_number(1))
	client:zadd("zset0", 200, "m1", test:require_number(1))
	client:zadd("zset0", 300, "m2", test:require_number(1))

	client:zrange("zset0", 0, -1, function(redis, err, res)
		test:assert_equal("m0", res[1])
		test:assert_equal("m1", res[2])
		test:assert_equal("m2", res[3])
	end)

	client:zrange("zset0", -1, -1, function(redis, err, res)
		test:assert_equal("m2", res[1])
	end)

	client:zrange("zset0", -2, -1, function(redis, err, res)
		test:assert_equal("m1", res[1])
		test:assert_equal("m2", res[2])
		test:Done()
	end)
end)

AddTest("ZREVRANGE", function (test)
	client:del("zset0")
	client:zadd("zset0", 100, "m0", test:require_number(1))
	client:zadd("zset0", 200, "m1", test:require_number(1))
	client:zadd("zset0", 300, "m2", test:require_number(1))

	client:zrevrange("zset0", 0, 1000, test:Last(function(redis, err, res)
		test:assert_equal("m2", res[1])
		test:assert_equal("m1", res[2])
		test:assert_equal("m0", res[3])
	end))
end)

AddTest("ZRANGEBYSCORE", function (test)
	client:del("zset0")
	client:zadd("zset0", 100, "m0", test:require_number(1))
	client:zadd("zset0", 200, "m1", test:require_number(1))
	client:zadd("zset0", 300, "m2", test:require_number(1))

	client:zrangebyscore("zset0", 200, 300, function(redis, err, res)
		test:assert_equal("m1", res[1])
		test:assert_equal("m2", res[2])
	end)

	client:zrangebyscore("zset0", 100, 1000, function(redis, err, res)
		test:assert_equal("m0", res[1])
		test:assert_equal("m1", res[2])
		test:assert_equal("m2", res[3])
	end)

	client:zrangebyscore("zset0", 1000, 10000, test:Last(function(redis, err, res)
		test:assert_nil(next(res))
	end))
end)

AddTest("ZCOUNT", function (test)
	client:del("zset0")
	
	client:zcount("zset0", 0, 100, test:require_number(0))
	
	client:zadd("zset0", 1, "a", test:require_number(1))
	client:zcount("zset0", 0, 100, test:require_number(1))

	client:zadd("zset0", 2, "b", test:require_number(1))
	client:zcount("zset0", 0, 100, test:Last(test:require_number(2)))
end)

AddTest("ZINCRBY", function (test)
	client:del("zset0")

	client:zadd("zset0", 1, "a", test:require_number(1))
	client:zincrby("zset0", 1, "a", test:Last(test:require_number(2)))
end)

AddTest("ZINTERSTORE", function (test)
	client:del("z0", "z1", "z2")
	client:zadd("z0", 1, "a", test:require_number(1))
	client:zadd("z0", 2, "b", test:require_number(1))
	client:zadd("z1", 3, "a", test:require_number(1))
	client:zinterstore("z2", 2, "z0", "z1", "AGGREGATE", "SUM", test:require_number(1))
	client:zrange("z2", 0, -1, "WITHSCORES", test:Last(function (redis, err, res)
		test:assert_nil(err)
		test:assert_equal("a", res[1])
		test:assert_equal("4", res[2])	-- score=1+3
	end))
end)

AddTest("ZUNIONSTORE", function (test)
	client:del("z0", "z1", "z2")

	client:zadd("z0", 1, "a", test:require_number(1))
	client:zadd("z0", 2, "b", test:require_number(1))
	client:zadd("z1", 3, "a", test:require_number(1))
	client:zunionstore("z2", 2, "z0", "z1", "AGGREGATE", "SUM", test:require_number(2))
	client:zrange("z2", 0, -1, "WITHSCORES", test:Last(function (redis, err, res)
		test:assert_nil(err)
		test:assert_equal(0, #res % 2)
		local set = {}
		for i=1, #res, 2 do
			set[res[i]] = tonumber(res[i + 1])
		end
		test:assert_deep_equal({a = 4, b = 2}, set)
	end))
end)

AddTest("ZRANK", function (test)
	client:del("z0")

	client:zadd("z0", 1, "a", test:require_number(1))
	client:zadd("z0", 2, "b", test:require_number(1))
	client:zadd("z0", 3, "c", test:require_number(1))

	client:zrank("z0", "a", test:require_number(0))
	client:zrank("z0", "b", test:require_number(1))
	client:zrank("z0", "c", test:Last(test:require_number(2)))
end)

AddTest("ZREVRANK", function (test)
	client:del("z0")

	client:zadd("z0", 1, "a", test:require_number(1))
	client:zadd("z0", 2, "b", test:require_number(1))
	client:zadd("z0", 3, "c", test:require_number(1))

	client:zrevrank("z0", "a", test:require_number(2))
	client:zrevrank("z0", "b", test:require_number(1))
	client:zrevrank("z0", "c", test:Last(test:require_number(0)))
end)

AddTest("ZREMRANGEBYRANK", function (test)
	client:del("z0")

	client:zadd("z0", 1, "a", test:require_number(1))
	client:zadd("z0", 2, "b", test:require_number(1))
	client:zadd("z0", 3, "c", test:require_number(1))

	client:zremrangebyrank("z0", -1, -1, test:require_number(1))

	client:zrange("z0", 0, -1, "WITHSCORES", test:Last(function (redis, err, res)
		test:assert_nil(err)
		test:assert_equal(0, #res % 2)
		local set = {}
		for i=1, #res, 2 do
			set[res[i]] = tonumber(res[i + 1])
		end
		test:assert_deep_equal({a = 1, b = 2}, set)
	end))
end)

AddTest("ZREMRANGEBYSCORE", function (test)
	client:del("z0")

	client:zadd("z0", 1, "a", test:require_number(1))
	client:zadd("z0", 2, "b", test:require_number(1))
	client:zadd("z0", 3, "c", test:require_number(1))

	-- inclusive
	client:zremrangebyscore("z0", 2, 3, test:require_number(2))

	client:zrange("z0", 0, -1, "WITHSCORES", test:Last(function (redis, err, res)
		test:assert_nil(err)
		test:assert_equal(0, #res % 2)
		local set = {}
		for i=1, #res, 2 do
			set[res[i]] = tonumber(res[i + 1])
		end
		test:assert_deep_equal({a = 1}, set)
	end))
end)

-- SORT test adapted from Brian Hammond's redis-node-client.js, which has a comprehensive test suite

AddTest("SORT", function (test)

	client:del('y')
	client:del('x')
	
	client:rpush('y', 'd', test:require_number(1))
	client:rpush('y', 'b', test:require_number(2))
	client:rpush('y', 'a', test:require_number(3))
	client:rpush('y', 'c', test:require_number(4))

	client:rpush('x', '3', test:require_number(1))
	client:rpush('x', '9', test:require_number(2))
	client:rpush('x', '2', test:require_number(3))
	client:rpush('x', '4', test:require_number(4))

	client:set('w3', '4', test:require_string("OK"))
	client:set('w9', '5', test:require_string("OK"))
	client:set('w2', '12', test:require_string("OK"))
	client:set('w4', '6', test:require_string("OK"))

	client:set('o2', 'buz', test:require_string("OK"))
	client:set('o3', 'foo', test:require_string("OK"))
	client:set('o4', 'baz', test:require_string("OK"))
	client:set('o9', 'bar', test:require_string("OK"))

	client:set('p2', 'qux', test:require_string("OK"))
	client:set('p3', 'bux', test:require_string("OK"))
	client:set('p4', 'lux', test:require_string("OK"))
	client:set('p9', 'tux', test:require_string("OK"))

	-- Now the data has been setup, we can test.

	-- But first, test basic sorting.

	-- y = { d b a c }
	-- sort y ascending = { a b c d }
	-- sort y descending = { d c b a }

	client:sort('y', 'asc', 'alpha', function (redis, err, sorted)
		test:assert_nil(err)
		test:assert_deep_equal({'a', 'b', 'c', 'd'}, sorted)
	end)

	client:sort('y', 'desc', 'alpha', function (redis, err, sorted)
		test:assert_nil(err)
		test:assert_deep_equal({'d', 'c', 'b', 'a'}, sorted)
	end)

	-- Now try sorting numbers in a list.
	-- x = { 3, 9, 2, 4 }

	client:sort('x', 'asc', function (redis, err, sorted)
		test:assert_nil(err)
		test:assert_deep_equal({"2", "3", "4", "9"}, sorted)
	end)

	client:sort('x', 'desc', function (redis, err, sorted)
		test:assert_nil(err)
		test:assert_deep_equal({"9", "4", "3", "2"}, sorted)
	end)

	-- Try sorting with a 'by' pattern.

	client:sort('x', 'by', 'w*', 'asc', function (redis, err, sorted)
		test:assert_nil(err)
		test:assert_deep_equal({"3", "9", "4", "2"}, sorted)
	end)

	-- Try sorting with a 'by' pattern and 1 'get' pattern.

	client:sort('x', 'by', 'w*', 'asc', 'get', 'o*', function (redis, err, sorted)
		test:assert_nil(err)
		test:assert_deep_equal({'foo', 'bar', 'baz', 'buz'}, sorted)
	end)

	-- Try sorting with a 'by' pattern and 2 'get' patterns.

	client:sort('x', 'by', 'w*', 'asc', 'get', 'o*', 'get', 'p*', function (redis, err, sorted)
		test:assert_nil(err)
		test:assert_deep_equal({'foo', 'bux', 'bar', 'tux', 'baz', 'lux', 'buz', 'qux'}, sorted)
	end)

	-- Try sorting with a 'by' pattern and 2 'get' patterns.
	-- Instead of getting back the sorted set/list, store the values to a list.
	-- Then check that the values are there in the expected order.

	client:sort('x', 'by', 'w*', 'asc', 'get', 'o*', 'get', 'p*', 'store', 'bacon', function (redis, err)
		test:assert_nil(err)
	end)

	client:lrange('bacon', 0, -1, test:Last(function (redis, err, values)
		test:assert_nil(err)
		test:assert_deep_equal({'foo', 'bux', 'bar', 'tux', 'baz', 'lux', 'buz', 'qux'}, values)
	end))
	
	-- TODO - sort by hash value
end)

--[=[
AddTest("MONITOR", function (test)
	local responses = {}
	
	local monitor_client = redis.createClient()
	monitor_client:monitor(function (emitter, err, res)
		client:mget("some", "keys", "foo", "bar")
		client:set("json", [[{"foo":"123","bar":"sdflkdfsjk","another":false}]])
	end)
	monitor_client:on("monitor", function (emitter, time, args)
		table.insert(responses, args)
		console.warn("blah")
		if #responses == 3 then
			test:assert_equal(1, #responses[1])
			test:assert_equal("monitor", responses[1][1])
			test:assert_equal(5, #responses[2])
			test:assert_equal("mget", responses[2][1])
			test:assert_equal("some", responses[2][2])
			test:assert_equal("keys", responses[2][3])
			test:assert_equal("foo", responses[2][4])
			test:assert_equal("bar", responses[2][5])
			test:assert_equal(3, #responses[3])
			test:assert_equal("set", responses[3][1])
			test:assert_equal("json", responses[3][2])
			test:assert_equal('{"foo":"123","bar":"sdflkdfsjk","another":false}', responses[3][3])
			monitor_client:quit(test:Last())
		end
	end)
end)
--]=]

AddTest("BLPOP", function (test)
	client:rpush("blocking list", "initial value", function (redis, err, res)
		client2:BLPOP("blocking list", 0, function (redis, err, res)
			test:assert_equal("blocking list", res[1])
			test:assert_equal("initial value", res[2])
			
			client:rpush("blocking list", "wait for this value")
		end)
		client2:BLPOP("blocking list", 0, test:Last(function (redis, err, res)
			test:assert_equal("blocking list", res[1])
			test:assert_equal("wait for this value", res[2])
		end))
	end)
end)

AddTest("BLPOP_TIMEOUT", function (test)
	-- try to BLPOP the list again, which should be empty.  This should timeout and return null.
	client2:BLPOP("blocking list", 1, test:Last(function (_, err, res)
		test:assert_nil(err)
		test:assert_nil(res)
	end))
end)

AddTest("EXPIRE", function (test)
	client:set('expiry key', 'bar', test:require_string("OK"))
	client:EXPIRE("expiry key", "1", test:require_number_pos())
	setTimeout(function ()
		client:exists("expiry key", test:Last(test:require_number(0)))
	end, 2000)
end)

AddTest("TTL", function (test)
	client:set("ttl key", "ttl val", test:require_string("OK"))
	client:expire("ttl key", "100", test:require_number_pos())
	setTimeout(function ()
		client:TTL("ttl key", test:Last(test:require_number_pos(0)))
	end, 500)
end)

AddTest("OPTIONAL_CALLBACK", function (test)
	client:del("op_cb1")
	client:set("op_cb1", "x")
	client:get("op_cb1", test:Last(test:require_string("x")))
end)

AddTest("OPTIONAL_CALLBACK_UNDEFINED", function (test)
	client:del("op_cb2")
	client:set("op_cb2", "y", nil)
	client:get("op_cb2", test:Last(test:require_string("y")))
end)



-- Exit immediately on connection failure, which triggers "exit", below, which fails the test
client:on("error", function (self, err)
	console.error("client: " .. err)
	process:exit()
end)
client2:on("error", function (self, err)
	console.error("client2: " .. err)
	process:exit()
end)
client3:on("error", function (self, err)
	console.error("client3: " .. err)
	process:exit()
end)

client:on("reconnecting", function (self, params)
	console.log("reconnecting: " .. luanode.utils.inspect(params))
end)

process:on('uncaughtException', function (err)
	console.error("Uncaught exception: " .. err)
	process:exit(1)
end)
