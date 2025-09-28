-- startup.lua
-- Boots network services unless netinst.cfg says to hand off to installer.
-- - Honors start_background_processes flag in netinst.cfg
-- - Starts daemons (netd, hardware_watchdog) safely (MultiShell if available)
-- - Avoids duplicate starts by checking PID files
-- - Logs to logs/startup.log
-- - Optionally runs user_startup.lua at the end

local STARTUP_LOG = "logs/startup.log"
local CFG_PATH    = "netinst.cfg"

-- ---------- tiny utils ----------
local function log(msg)
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local line = ("[%s] %s"):format(ts, msg)
    print(line)
    local dir = fs.getDir(STARTUP_LOG)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(STARTUP_LOG, "a")
    if f then f.writeLine(line); f.close() end
end

local function readCfg()
    if not fs.exists(CFG_PATH) then
        return { start_background_processes = true }
    end
    local ok, cfg = pcall(function() return dofile(CFG_PATH) end)
    if not ok or type(cfg) ~= "table" then
        return { start_background_processes = true }
    end
    if cfg.start_background_processes == nil then
        cfg.start_background_processes = true
    end
    return cfg
end

local function writeCfg(cfg)
    local ok, ser = pcall(textutils.serialize, cfg)
    if not ok then return false end
    local f = fs.open(CFG_PATH, "w")
    if not f then return false end
    f.write("return " .. ser)
    f.close()
    return true
end

local function banner()
    term.setTextColor(colors.cyan)
    print("CC Network System Startup")
    print("=========================")
    term.setTextColor(colors.white)
end

-- ---------- PID helpers ----------
local function pidPath(name) return "/var/run/" .. name .. ".pid" end

local function isRunning(name)
    local p = pidPath(name)
    if not fs.exists(p) then return false end
    -- Treat any existing PID file as "running" – daemons manage their own lifecycle.
    return true
end

local function ensureRuntimeDirs()
    local dirs = {
        "logs", "var", "var/run", "var/lib", "var/lib/dhcp",
        "var/log", "var/cache", "usr", "usr/lib", "usr/lib/router"
    }
    for _, d in ipairs(dirs) do
        if not fs.exists(d) then pcall(fs.makeDir, d) end
    end
end

-- ---------- launcher ----------
local function launchTabOrRun(title, program, ...)
    -- Prefer MultiShell tabs (non-blocking). Fallback to foreground run (blocking).
    if multishell and fs.exists(program) then
        local env = _ENV
        local tabID = multishell.launch(env, program, ...)
        if tabID then
            pcall(multishell.setTitle, tabID, title)
            return true, ("launched tab #%d"):format(tabID)
        end
    end
    -- Fallback: run in the same shell (blocking). Use separate shell to avoid clobber?
    -- We run in a new tab only if multishell available; otherwise we just run and return.
    if fs.exists(program) then
        -- Spawn via parallel to avoid blocking the remainder of startup.
        local args = { ... }
        parallel.waitForAny(function()
            shell.run(program, table.unpack(args))
        end, function() sleep(0) end)
        return true, "started (no multishell)"
    end
    return false, "program not found"
end

local function startDaemon(name, program, ...)
    -- Respect existing PID
    if isRunning(name) then
        log(("[%s] already running (PID file present)"):format(name))
        return true
    end
    local ok, why = launchTabOrRun(name, program, ...)
    if ok then
        log(("Started %s (%s)"):format(name, why))
    else
        log(("Failed to start %s: %s"):format(name, why or "unknown"))
    end
    return ok
end

-- ---------- main ----------
local function main()
    term.clear(); term.setCursorPos(1,1)
    banner()

    ensureRuntimeDirs()

    local cfg = readCfg()

    if cfg.start_background_processes == false then
        -- Handshake: startup is intentionally paused for a clean installer run.
        log("[startup] start_background_processes=false -> chaining to install.lua")
        if fs.exists("install.lua") then
            -- Run installer in foreground. It will flip the flag back to true.
            shell.run("install.lua")
        else
            log("ERROR: install.lua not found; cannot continue clean install")
            print("Press any key to continue")
            os.pullEvent("key")
        end
        return
    end

    -- Normal boot path: start background services
    log("Starting background services...")

    -- netd (network daemon)
    if fs.exists("bin/netd.lua") then
        startDaemon("netd", "bin/netd.lua")
    elseif fs.exists("netd.lua") then
        startDaemon("netd", "netd.lua")
    else
        log("[netd] not found; skipping")
    end

    -- hardware_watchdog
    if fs.exists("hardware_watchdog.lua") then
        startDaemon("hardware_watchdog", "hardware_watchdog.lua")
    else
        log("[hardware_watchdog] not found; skipping")
    end

    -- You can add more here, e.g. routerd, web_admin, etc.
    -- Example:
    -- if fs.exists("bin/routerd.lua") then startDaemon("routerd", "bin/routerd.lua") end

    log("Background services launch attempted.")

    -- Optional: run user_startup.lua last, if present
    if fs.exists("user_startup.lua") then
        log("Running user_startup.lua...")
        local ok, err = pcall(function() shell.run("user_startup.lua") end)
        if not ok then log("user_startup.lua error: " .. tostring(err)) end
    end

    log("Startup sequence complete.")
end

local ok, err = pcall(main)
if not ok then
    log("CRITICAL startup failure: " .. tostring(err))
    print("CRITICAL startup failure: " .. tostring(err))
    print("See " .. STARTUP_LOG)
    print("Press any key to continue")
    os.pullEvent("key")
end
