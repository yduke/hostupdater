-- Copyright (c) 2025 Gxxkx
module("luci.controller.hostupdater", package.seeall)

local http = require "luci.http"
local nixio = require "nixio"
local sys = require "luci.sys"
local fs = require "nixio.fs"
local jsonc = require "luci.jsonc"
local uci = require "luci.model.uci"

local PROG = "/usr/bin/hostupdater"
local SOURCES_FILE = "/etc/hostupdater/sources.conf"
local LOG_FILE = "/var/log/hostupdater.log"
local STATE_FILE = "/tmp/hostupdater/state.json"
local DEFAULT_TARGET = "/etc/hostupdater/hosts"

local function prepare_content(ct)
	if http.prepare_content then
		http.prepare_content(ct)
	elseif http.prepare_context then
		http.prepare_context(ct)
	end
end

local function write_json(data)
	if http.write_json then
		http.write_json(data)
	else
		http.write(jsonc.stringify(data))
	end
end

local function get_post_data()
	if http.content then
		return http.content()
	end
	local cl = tonumber(http.getenv("CONTENT_LENGTH") or "0")
	if cl > 0 then
		local data = http.read(cl)
		if data and #data > 0 then
			return data
		end
	end
	return "{}"
end

local function read_json_body()
	local body = get_post_data()
	if not body or body == "" then
		return {}
	end
	local ok, data = pcall(jsonc.parse, body)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

local function valid_name(name)
	return name and name:match("^[A-Za-z0-9_%.%-]+$") and #name <= 64
end

local function valid_url(url)
	return url and url:match("^https?://[^%s|]+$") and not url:find("|", 1, true)
end

local function valid_target(path)
	return path and #path > 0 and #path <= 255
		and path:match("^/etc/hostupdater/[A-Za-z0-9_%.%-/]+$")
		and not path:find("..", 1, true)
		and path:sub(-1) ~= "/"
end

local function target_path()
	local c = uci.cursor()
	local path = c:get("hostupdater", "main", "target")
	if not valid_target(path) then
		return DEFAULT_TARGET
	end
	return path
end

local function spawn(cmd)
	if nixio.fork then
		local ok, pid = pcall(nixio.fork)
		if ok and pid == 0 then
			if nixio.setsid then
				pcall(nixio.setsid)
			end
			os.execute(cmd .. " >/dev/null 2>&1")
			os.exit(0)
		elseif ok and pid and pid > 0 then
			return true
		end
	end
	sys.call(string.format("( %s ) >/dev/null 2>&1 &", cmd))
	return true
end

local function read_sources()
	local list = {}
	local f = io.open(SOURCES_FILE, "r")
	if not f then
		return list
	end
	for line in f:lines() do
		line = line:gsub("\r$", "")
		if not line:match("^%s*#") and line:match("%S") then
			local name, url, enabled = line:match("^%s*([^|]+)%s*|%s*([^|]+)%s*|%s*([01])%s*$")
			if name and url then
				name = name:gsub("^%s+", ""):gsub("%s+$", "")
				url = url:gsub("^%s+", ""):gsub("%s+$", "")
				list[#list + 1] = {
					name = name,
					url = url,
					enabled = (enabled == "1")
				}
			end
		end
	end
	f:close()
	return list
end

local function source_header()
	local header = {}
	local f = io.open(SOURCES_FILE, "r")
	if f then
		for line in f:lines() do
			if line:match("^%s*#") then
				header[#header + 1] = line
			end
		end
		f:close()
	end
	if #header == 0 then
		header = {
			"# Host Updater 源配置文件",
			"# 格式: 名称|URL|启用状态(1=启用,0=禁用)",
			"# 名称只能包含字母、数字、下划线、点和短横线。",
			"# 从上到下的顺序即优先级：同一个域名在多个源中出现时，先出现的生效。",
			"# 支持任意纯文本 hosts 内容（IPv4/IPv6 均可）。",
			""
		}
	end
	return header
end

local function write_sources(list)
	if nixio.fs.mkdirr then
		nixio.fs.mkdirr("/etc/hostupdater")
	else
		nixio.fs.mkdir("/etc/hostupdater")
	end
	local tmp = SOURCES_FILE .. ".tmp"
	local f = io.open(tmp, "w+")
	if not f then
		return false, "cannot open sources file"
	end
	for _, line in ipairs(source_header()) do
		f:write(line, "\n")
	end
	for _, s in ipairs(list) do
		local en = s.enabled and "1" or "0"
		f:write(string.format("%s|%s|%s\n", s.name, s.url, en))
	end
	f:close()
	local ok, err = os.rename(tmp, SOURCES_FILE)
	if not ok then
		os.remove(tmp)
		return false, err or "cannot replace sources file"
	end
	return true
end

function index()
	if not nixio.fs.access("/etc/config/hostupdater") then
		return
	end

	local page = entry({"admin", "services", "hostupdater"},
		template("admin/services/hostupdater"), _("Host Updater"), 60)
	page.dependent = true
	page.acl_depends = { "luci-app-hostupdater" }

	entry({"admin", "services", "hostupdater", "status"}, call("action_status"))
	entry({"admin", "services", "hostupdater", "state"}, call("action_state"))
	entry({"admin", "services", "hostupdater", "update"}, call("action_update"))
	entry({"admin", "services", "hostupdater", "restore"}, call("action_restore"))
	entry({"admin", "services", "hostupdater", "config"}, call("action_config"))
	entry({"admin", "services", "hostupdater", "log"}, call("action_log"))
	entry({"admin", "services", "hostupdater", "target"}, call("action_target"))

	entry({"admin", "services", "hostupdater", "sources"}, call("action_sources"))
	entry({"admin", "services", "hostupdater", "sources", "toggle"}, call("action_source_toggle"))
	entry({"admin", "services", "hostupdater", "sources", "update"}, call("action_source_update"))
	entry({"admin", "services", "hostupdater", "sources", "delete"}, call("action_source_delete"))
end

function action_status()
	local out = sys.exec(PROG .. " status --json 2>/dev/null")
	if not out or out == "" then
		out = "{}"
	end
	prepare_content("application/json")
	http.write(out)
end

function action_state()
	local data = "{\"running\":false}"
	if fs.access(STATE_FILE) then
		local raw = fs.readfile(STATE_FILE)
		if raw and raw:match("^%s*{") then
			data = raw
		end
	end
	prepare_content("application/json")
	http.write(data)
end

function action_update()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		return
	end
	spawn(PROG .. " update")
	prepare_content("application/json")
	write_json({ started = true })
end

function action_restore()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		return
	end
	spawn(PROG .. " restore")
	prepare_content("application/json")
	write_json({ started = true })
end

function action_config()
	local method = http.getenv("REQUEST_METHOD")
	local c = uci.cursor()

	if method == "GET" then
		local live_target = c:get("hostupdater", "main", "target")
		if not valid_target(live_target) then
			live_target = DEFAULT_TARGET
		end
		prepare_content("application/json")
		write_json({
			enabled = (c:get("hostupdater", "main", "enabled") == "1"),
			interval = c:get("hostupdater", "main", "interval") or "6",
			target = live_target
		})
		return
	end

	if method ~= "POST" then
		http.status(405, "Method Not Allowed")
		return
	end

	local data = read_json_body()
	if next(data) == nil then
		data.enabled = (http.formvalue("enabled") == "1" or http.formvalue("enabled") == "true")
		data.interval = http.formvalue("interval")
		data.target = http.formvalue("target")
	end

	local interval = tonumber(data.interval or 6)
	if not interval or interval < 1 or interval > 168 then
		prepare_content("application/json")
		write_json({ success = false, error = "invalid interval" })
		return
	end

	local target = data.target
	if target ~= nil and target ~= "" and not valid_target(target) then
		prepare_content("application/json")
		write_json({ success = false, error = "invalid target path" })
		return
	end

	local enabled = data.enabled and true or false
	c:set("hostupdater", "main", "enabled", enabled and "1" or "0")
	c:set("hostupdater", "main", "interval", tostring(interval))
	if target and target ~= "" then
		c:set("hostupdater", "main", "target", target)
	end
	c:commit("hostupdater")

	if enabled then
		sys.call("/etc/init.d/hostupdater enable >/dev/null 2>&1")
		sys.call("/etc/init.d/hostupdater restart >/dev/null 2>&1")
	else
		sys.call("/etc/init.d/hostupdater stop >/dev/null 2>&1")
		sys.call("/etc/init.d/hostupdater disable >/dev/null 2>&1")
	end

	prepare_content("application/json")
	write_json({ success = true })
end

function action_sources()
	local method = http.getenv("REQUEST_METHOD")

	if method == "GET" then
		prepare_content("application/json")
		write_json(read_sources())
		return
	end

	if method ~= "POST" then
		http.status(405, "Method Not Allowed")
		return
	end

	local data = read_json_body()
	if next(data) == nil then
		data.name = http.formvalue("name")
		data.url = http.formvalue("url")
		local en = http.formvalue("enabled")
		if en ~= nil then
			data.enabled = (en == "1" or en == "true")
		end
	end

	local name = data.name
	local url = data.url
	if not valid_name(name) then
		prepare_content("application/json")
		write_json({ success = false, error = "invalid source name" })
		return
	end
	if not valid_url(url) then
		prepare_content("application/json")
		write_json({ success = false, error = "invalid url" })
		return
	end

	local list = read_sources()
	for _, s in ipairs(list) do
		if s.name == name then
			prepare_content("application/json")
			write_json({ success = false, error = "source exists" })
			return
		end
	end

	list[#list + 1] = { name = name, url = url, enabled = (data.enabled ~= false) }
	local ok, err = write_sources(list)
	prepare_content("application/json")
	write_json({ success = ok, error = err })
end

function action_source_toggle()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		return
	end
	local name = http.formvalue("name")
	if not valid_name(name) then
		prepare_content("application/json")
		write_json({ success = false, error = "invalid name" })
		return
	end

	local list = read_sources()
	local found = false
	for _, s in ipairs(list) do
		if s.name == name then
			s.enabled = not s.enabled
			found = true
			break
		end
	end
	local ok, err = write_sources(list)
	local success = found and ok
	local msg
	if not success then msg = found and err or "not found" end
	prepare_content("application/json")
	write_json({ success = success, error = msg })
end

function action_source_delete()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		return
	end
	local name = http.formvalue("name")
	if not valid_name(name) then
		prepare_content("application/json")
		write_json({ success = false, error = "invalid name" })
		return
	end

	local list = read_sources()
	local newlist = {}
	local removed = false
	for _, s in ipairs(list) do
		if s.name ~= name then
			newlist[#newlist + 1] = s
		else
			removed = true
		end
	end
	local ok, err = write_sources(newlist)
	local success = removed and ok
	local msg
	if not success then msg = removed and err or "not found" end
	prepare_content("application/json")
	write_json({ success = success, error = msg })
end

function action_source_update()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		return
	end
	local name = http.formvalue("name")
	if not valid_name(name) then
		prepare_content("application/json")
		write_json({ started = false, error = "invalid name" })
		return
	end

	local exists = false
	for _, s in ipairs(read_sources()) do
		if s.name == name then
			exists = true
			break
		end
	end
	if not exists then
		http.status(404, "Not Found")
		prepare_content("application/json")
		write_json({ started = false, error = "source not found" })
		return
	end

	spawn(string.format("%s update-source %q", PROG, name))
	prepare_content("application/json")
	write_json({ started = true })
end

function action_log()
	local method = http.getenv("REQUEST_METHOD")

	if method == "GET" then
		local lines = tonumber(http.formvalue("lines") or "100") or 100
		if lines < 1 then lines = 1 end
		if lines > 2000 then lines = 2000 end
		local data = ""
		if fs.access(LOG_FILE) then
			data = sys.exec(string.format("tail -n %d %s 2>/dev/null", lines, LOG_FILE)) or ""
		end
		prepare_content("text/plain; charset=utf-8")
		http.write(data)
		return
	end

	if method == "DELETE" or (method == "POST" and http.formvalue("op") == "delete") then
		if fs.access(LOG_FILE) then
			fs.remove(LOG_FILE)
		end
		prepare_content("application/json")
		write_json({ success = true })
		return
	end

	http.status(405, "Method Not Allowed")
end

function action_target()
	local path = target_path()
	local data = ""
	if fs.access(path) then
		data = fs.readfile(path) or ""
	end
	prepare_content("text/plain; charset=utf-8")
	http.write(data)
end
