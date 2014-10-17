# redis-luanode #

[![Build Status](https://travis-ci.org/ignacio/redis-luanode.png?branch=master)](https://travis-ci.org/ignacio/redis-luanode)

Redis client for LuaNode.

**redis-luanode** is a [Redis][1] client for [LuaNode][2]. It is based on heavily (it is mostly a rewrite) on
Matt Ranney's [node_redis][3] and less so on Daniele Alessandri's [redis-lua][4].

It supports most Redis commands, with the exception of *monitor*.

```lua
local redis = require "redis-luanode"
local client = redis.createClient()

client:set("string key", "string val", redis.print)
client:hset("hash key", "hashtest 1", "some value", redis.print)
client:hset({"hash key", "hashtest 2", "some other value"}, redis.print)
client:hkeys("hash key", function (self, err, replies)
   console.log(#replies .. " replies:")
   for i,reply in ipairs(replies) do
      console.log("    " .. i .. ": " .. reply)
   end
end)

client:quit()

process:loop()
```

### Features #
  - Redis transactions (MULTI/EXEC).
  - Pub-Sub
  - Reconnection
  - Scripting with Lua

## Installation #
The easiest way to install is with [LuaRocks][5].

  - luarocks install https://raw.github.com/ignacio/redis-luanode/github/rockspecs/redis-luanode-git-1.rockspec

If you don't want to use LuaRocks, just copy all files to Lua's path.
  
## Documentation #
Until I write some proper documentation you can take a look at [node_redis][3] docs, since the usage is quite similar.

## Testing #
A test suite is included, using [siteswap][6]. To run the test suite, install [siteswap][6], start a local Redis 
instance, open a shell in the *test* directory and type:

```bash
luanode run.lua
```

I've tested it with Redis 2.4.5, Redis 2.6.16 and Redis 2.8, on both Windows and Linux.

## Status #
Currently, *MONITOR* is not implemented yet.

## Acknowledgments #
I'd like to acknowledge the work of the following people:

 - Matt Ranney and all collaborators of [node_redis][3].
 - Daniele Alessandri and all collaborators of [redis-lua][4].

 
## License #
**redis-luanode** is available under the MIT license.


[1]: http://redis.io/
[2]: https://github.com/ignacio/LuaNode
[3]: https://github.com/mranney/node_redis
[4]: https://github.com/nrk/redis-lua
[5]: http://luarocks.org/
[6]: https://github.com/ignacio/siteswap
