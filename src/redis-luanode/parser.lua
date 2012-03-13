local EventEmitter = require "luanode.event_emitter"
local Class = require "luanode.class"

local Parser = Class.InheritsFrom(EventEmitter)

local m_states = {
	TYPE = 1,
	SINGLE_LINE = 2,
	MULTI_BULK_COUNT = 3,
	INTEGER_LINE = 4,
	BULK_LENGTH = 5,
	ERROR_LINE = 6,
	BULK_DATA = 7,
	UNKNOWN_TYPE = 8,
	FINAL_CR = 9,
	FINAL_LF = 10,
	MULTI_BULK_COUNT_LF = 11,
	BULK_LF = 12
}

-- este parser se puede optimizar mucho. Sobre todo la parte que inserta en una tabla caracter a caracter...
local m_dispatch = {
	[m_states.TYPE] = function(self, incoming_buf, pos)
		self.type = incoming_buf:sub(pos, pos)
		pos = pos + 1
		
		if self.type == "+" then
			self.state = m_states.SINGLE_LINE
			self.return_buffer = {}
			self.return_string = ""
		
		elseif self.type == "*" then
			self.state = m_states.MULTI_BULK_COUNT
			self.tmp_string = ""
		
		elseif self.type == ":" then
			self.state = m_states.INTEGER_LINE
			self.return_buffer = {}
			self.return_string = ""
		
		elseif self.type == "$" then
			self.state = m_states.BULK_LENGTH
			self.tmp_string = ""
		
		elseif self.type == "-" then
			self.state = m_states.ERROR_LINE
			self.return_buffer = {}
			self.return_string = ""
		
		else
			self.state = m_states.UNKNOWN_TYPE
		end
		
		return true, pos
	end,
	
	[m_states.INTEGER_LINE] = function(self, incoming_buf, pos)
		if incoming_buf:sub(pos, pos) == "\r" then
			local reply = table.concat(self.return_buffer)
			local number = tonumber(reply)
			if number then
				self:send_reply(number)
			else
				self:parser_error("expected a number reply but instead got '" .. reply .. "'")
				return false, pos
			end
			self.state = m_states.FINAL_LF
		else
			self.return_buffer[ #self.return_buffer + 1 ] = incoming_buf:sub(pos, pos)
		end
		return true, pos + 1
	end,
	
	[m_states.ERROR_LINE] = function(self, incoming_buf, pos)
		if incoming_buf:sub(pos, pos) == "\r" then
			self:send_error(table.concat(self.return_buffer))
			self.state = m_states.FINAL_LF
		else
			self.return_buffer[ #self.return_buffer + 1 ] = incoming_buf:sub(pos, pos)
		end
		return true, pos + 1
	end,
	
	[m_states.SINGLE_LINE] = function(self, incoming_buf, pos)
		if incoming_buf:sub(pos, pos) == "\r" then
			self:send_reply(self.return_string)
			self.state = m_states.FINAL_LF
		else
			self.return_string = self.return_string .. incoming_buf:sub(pos, pos)
		end
		return true, pos + 1
	end,
	
	[m_states.MULTI_BULK_COUNT] = function(self, incoming_buf, pos)
		if incoming_buf:sub(pos, pos) == "\r" then
			self.state = m_states.MULTI_BULK_COUNT_LF
		else
			self.tmp_string = self.tmp_string .. incoming_buf:sub(pos, pos)
		end
		return true, pos + 1
	end,
	
	[m_states.MULTI_BULK_COUNT_LF] = function(self, incoming_buf, pos)
		if incoming_buf:sub(pos, pos) == "\n" then
			if self.multi_bulk_length > 0 then	-- nested multi-bulk
				self.multi_bulk_nested_length = self.multi_bulk_length
				self.multi_bulk_nested_replies = self.multi_bulk_replies
				self.multi_bulk_nested_pos = self.multi_bulk_pos
			end

			self.multi_bulk_length = tonumber(self.tmp_string)
			self.multi_bulk_pos = 1 --0
			self.state = m_states.TYPE

			if self.multi_bulk_length < 0 then
				self:send_reply(nil)
				self.multi_bulk_length = 0

			elseif self.multi_bulk_length == 0 then
				self.multi_bulk_pos = 1--0
				self.multi_bulk_replies = nil
				self:send_reply({})

			else
				self.multi_bulk_replies = {}--this.multi_bulk_length);
			end
		else
			self:parser_error("didn't see LF after NL reading multi bulk count")
			return false, pos
		end
		return true, pos + 1
	end,
	
	[m_states.BULK_LENGTH] = function(self, incoming_buf, pos)
		if incoming_buf:sub(pos, pos) == "\r" then
			self.state = m_states.BULK_LF
		else
			self.tmp_string = self.tmp_string .. incoming_buf:sub(pos, pos)
		end
		return true, pos + 1
	end,
	
	[m_states.BULK_LF] = function(self, incoming_buf, pos)
		if incoming_buf:sub(pos, pos) == "\n" then
			self.bulk_length = tonumber(self.tmp_string)

			if self.bulk_length == -1 then
				self:send_reply(nil)
				self.state = m_states.TYPE

			elseif self.bulk_length == 0 then
				self:send_reply("")
				self.state = m_states.FINAL_CR
				
			else
				self.state = m_states.BULK_DATA
				self.return_buffer = {}
			end
		else
			self:parser_error("didn't see LF after NL while reading bulk length")
			return false, pos
		end
		return true, pos + 1
	end,
	
	[m_states.BULK_DATA] = function(self, incoming_buf, pos)
		self.return_buffer[#self.return_buffer + 1] = incoming_buf:sub(pos, pos)
		
		if #self.return_buffer == self.bulk_length then
			self:send_reply( table.concat(self.return_buffer) )
			self.state = m_states.FINAL_CR
		end
		return true, pos + 1
	end,
	
	[m_states.FINAL_CR] = function(self, incoming_buf, pos)
		if incoming_buf:sub(pos, pos) == "\r" then
			self.state = m_states.FINAL_LF
			return true, pos + 1
		else
			self:parser_error("saw " .. incoming_buf:sub(pos, sub) .. " when expecting final CR")
			return false, pos
		end
	end,
	
	[m_states.FINAL_LF] = function(self, incoming_buf, pos)
		if incoming_buf:sub(pos, pos) == "\n" then
			self.state = m_states.TYPE
			return true, pos + 1
		else
			self:parser_error("saw " .. incoming_buf:sub(pos, pos) .. " when expecting final LF")
			return false, pos
		end
	end
}

---
--
function Parser:__init (options)

	local newParser = Class.construct(Parser)
	
	newParser.name = "lua"
	newParser.options = options or {}
	newParser:reset()

	return newParser
end

---
-- Reset parser to it's original state.
function Parser:reset ()
	self.return_buffer = {}
	self.return_string = ""
	self.tmp_string = ""	-- for holding size fields
	
	self.multi_bulk_length = 0
	self.multi_bulk_replies = nil
	self.multi_bulk_pos = 1--0
	self.multi_bulk_nested_length = 0
	self.multi_bulk_nested_replies = nil
	
	self.state = m_states.TYPE
end

---
--
function Parser:parser_error (message)
	self:emit("error", message)
	self:reset()
end

---
--
function Parser:execute (incoming_buf)
	local ok
	for pos = 1, #incoming_buf do
		local handler = m_dispatch[self.state]
		if not handler then
			self:parser_error("invalid state " .. self.state)
		end
		ok, pos = handler(self, incoming_buf, pos)
		if not ok then
			break
		end
	end
end

---
--
function Parser:send_error (reply)
	if self.multi_bulk_length > 0 or  self.multi_bulk_nested_length > 0 then
		--// TODO - can this happen?  Seems like maybe not.
		self:add_multi_bulk_reply(reply)
	else
		self:emit("reply error", reply)
	end
end

---
--
function Parser:send_reply (reply)
	if self.multi_bulk_length > 0 or self.multi_bulk_nested_length > 0 then
		self:add_multi_bulk_reply(reply)
	else
		self:emit("reply", reply)
	end
end

---
--
function Parser:add_multi_bulk_reply (reply)
	if self.multi_bulk_replies then
		self.multi_bulk_replies[self.multi_bulk_pos] = reply
		self.multi_bulk_pos = self.multi_bulk_pos + 1
		if self.multi_bulk_pos <= self.multi_bulk_length then
			return
		end
	else
		self.multi_bulk_replies = reply
	end

	if self.multi_bulk_nested_length > 0 then
		self.multi_bulk_nested_replies[self.multi_bulk_nested_pos] = self.multi_bulk_replies
		self.multi_bulk_nested_pos = self.multi_bulk_nested_pos + 1

		self.multi_bulk_length = 0
		self.multi_bulk_replies = nil
		self.multi_bulk_pos = 1--0

		if self.multi_bulk_nested_length == self.multi_bulk_nested_pos - 1 then
			self:emit("reply", self.multi_bulk_nested_replies)
			self.multi_bulk_nested_length = 0
			self.multi_bulk_nested_pos = 1--0;
			self.multi_bulk_nested_replies = nil
		end
	else
		self:emit("reply", self.multi_bulk_replies)
		self.multi_bulk_length = 0
		self.multi_bulk_replies = nil
		self.multi_bulk_pos = 1--0;
	end
end


return Parser
