local inconcert_devel = assert(os.getenv("INCONCERT_DEVEL"))

local is_windows

if package.cpath:match("%.so") then
	package.cpath = inconcert_devel..[[/bin/?.so;]]..package.cpath
	is_windows = false
else
	package.cpath = inconcert_devel..[[/bin/?.dll;]]..package.cpath
	is_windows = true
end

if is_windows then require "luarocks.require" end

local lapp = require "lapp"
local socket = require "socket"
local cosmo = require "cosmo"

local TestLauncher = require "luatestlauncher"

-- Initialize the pseudo random number generator
math.randomseed( os.time() )

module(..., package.seeall)


_M.is_windows = is_windows

---
-- Command-line Args
--
function CommandLine(...)
 	local args = lapp(...)

	for k,v in pairs(args) do
		--print(k,v)
		if v == "?" then
			args[k] = nil
		end
	end
	--Esto es porque se tiene el valor default que hay que quitar
	if args.tests[1] == "?" then
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
		--[[
		if is_windows then
			local p = io.popen('cmd /C "echo %RANDOM%"')
			selected_port = p:read("*l")
			p:close()
		else
			local p = io.popen('shuf -i 2000-30000 -n 1')
			selected_port = p:read("*l")
			p:close()
		end
		--]]
		selected_port = math.random(2000, 30000)
		--print(selected_port)
		--selected_port = 1900
		
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
function TriggerGC()
	for i=1,10 do collectgarbage() end
end


---
-- Configuration Files
--
Config = {}

---
-- @param filename el nombre del archivo con el template.
-- @param env una tabla con el environment para rellenar el template
-- @param template_file el nombre del archivo con el template (opcional). Si es nil, se asume
--           filename.template
--
function Config.CreateFile(filename, env, template_file)
	assert(filename and env)
	
	local input_file = assert(io.open(template_file or filename..".template", "rb"))
	local template = input_file:read("*a")
	input_file:close()
	
	local filled_template = cosmo.fill(template, env)
	
	local output_file = assert(io.open(filename, "wb"))
	output_file:write(filled_template)
	output_file:close()
end

---
-- Process startup
--
Process = {}

---
--
local function tryToConnect(address, port)
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
-- Tests
--
function _M.TestLauncher(name, ...)	-- el _M es necesario, por culpa del package.seeall y que TestLauncher es global
	assert(type(name) == "string")
	
	local launcher = TestLauncher.TestLauncher(name, ...)
	launcher.BeforeTest = function (test)
		print( ("Starting test %q"):format(test) )
	end

	launcher.AfterTest = function (test, result, err)
		print( ("Test %q => result: %q\n%s"):format(test, result, err or "") )	
		TriggerGC()
	end
	
	local oldRun = launcher.Run
	launcher.Run = function(...)
		local time_start = os.time()
		local result = oldRun(...)
		local time_end = os.time()
		print( ("Tests took %d seconds"):format(time_end - time_start) )
		launcher.SaveReport(name.."TestReport.xml")
		return results
	end
	
	return launcher
end

---
-- No se
--
function GetHostName ()
	local host = os.getenv("NODE_NAME") or socket.dns.gethostname() or "localhost"
	return host
end

function GetHostAddress ()
	local host = GetHostName()
	return socket.dns.toip(host)
end