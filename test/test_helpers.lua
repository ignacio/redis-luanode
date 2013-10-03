local lapp = require "lapp"
local socket = require "socket"

-- Initialize the pseudo random number generator
math.randomseed( os.time() )

module(..., package.seeall)


---
-- Command-line Args
--
function CommandLine (...)
 	local args = lapp(...)

	for k,v in pairs(args) do
		if v == "?" then
			args[k] = nil
		end
	end
	--Esto es porque se tiene el valor default que hay que quitar
	if type(args.tests) == "table" and args.tests[1] == "?" then
		args.tests[1]  = nil
	end
	return args
end

---
-- Ports
--
function RandomPort ()
	
	local selected_port
	repeat
		selected_port = math.random(2000, 30000)
		
		local p = io.popen("netstat -an")
		for line in p:lines() do
			if line:match(":"..selected_port.." ") then
				selected_port = nil
				break
			end
		end
		p:close()
	until selected_port
	return selected_port
end


---
--
function TriggerGC ()
	for i=1,10 do collectgarbage() end
end


---
-- Configuration Files
--
Config = {}

---
-- Process startup
--
Process = {}

---
--
local function tryToConnect (address, port)
	for i=1, 20 do
		local client = socket.connect(address, port)
		if client then
			return true
		end
		print( ("Server at %s:%d not ready yet, retrying..."):format(address, port) )
		socket.sleep(1)
	end
	
	return false
end

function Process.StartAndWait (task_set, name, host, port, args)
	print( ("Starting %s on %s:%d"):format(name, host, port) )
	
	local pid = task_set:start(unpack(args))
								
	local connected = tryToConnect(host, port)
	if not connected then
		local msg = ("Could not connect to %s on %s:%d"):format(name, host, port) 
		print(msg)
		if args.reuse == "no" then
			task_set:killall()
		end
		error(msg)
	end
	
	return pid
end

---
-- No se
--
function GetHostName ()
	local host = socket.dns.gethostname() or "localhost"
	return host
end

function GetHostAddress ()
	local host = GetHostName()
	return socket.dns.toip(host)
end
