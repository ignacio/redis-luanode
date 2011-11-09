package = "redis-luanode"
version = "git-1"
description = {
	summary = "Redis client for LuaNode",
	detailed = [[
Redis client for LuaNode, based on node-redis and redis-lua.
]],
	license = "MIT/X11"
}
dependencies = {
	"lua >= 5.1"
}
source = {
	url = "git://git.inconcert/inconcert-6/redis-luanode.git",
	dir = "redis-luanode"
}
external_dependencies = {

}
build = {
	type = "none",
	install = {
		lua = {
			["redis-luanode"] = "src/redis-luanode.lua",
			["redis-luanode.parser"] = "src/redis-luanode/parser.lua",
			["redis-luanode.commands"] = "src/redis-luanode/commands.lua"
		}
	}
}
