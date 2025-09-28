-- startup.lua (quiet + buffered logging)
-- ComputerCraft startup file with comprehensive logging

-- Startup configuration
local STARTUP_CONFIG = {
    enableNetd = true,
    enableLogger = false,       -- when false, logging won't spam the console
    netdBackground = true,
    hardwareWatchdog = true,
    showNetInfo = true,
    startupDelay = 0.5,
    consoleMinLevel = "WARN",   -- only WARN/ERROR/CRITICAL print to screen
    flushInterval = 0.5,        -- seconds between log flushes
}

-- map severities
local LEVELS = { TRACE=1, DEBUG=2, INFO=3, SUCCESS=3, WARN=4, ERROR=5, CRITICAL=6 }
local function sev(name) return LEVELS[(name or "INFO"):upper()] or 3 end

-- buffered logger (file)
local LOG_DIR, LOG_PATH = "logs", "logs/startup.log"
local _buf, _timer = {}, nil

local function flushLog()
    if #_buf == 0 then return end
    if not fs.exists(LOG_DIR) then fs.makeDir(LOG_DIR) end
    local f = fs.open(LOG_PATH, "a")
    if f then
        for i=1,#_buf do f.writeLine(_buf[i]) end
        f.close()
    end
    _buf = {}
end

local function queueFlush()
    if _timer then os.cancelTimer(_timer) end
    _timer = os.startTimer(STARTUP_CONFIG.flushInterval)
end

local function writeLog(message, level)
    level = (level or "INFO"):upper()
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("[%s] [%s] %s", ts, level, message)

    -- console: only show >= consoleMinLevel OR if enableLogger=true
    if STARTUP_CONFIG.enableLogger or sev(level) >= sev(STARTUP_CONFIG.consoleMinLevel) then
        print(line)
    end

    table.insert(_buf, line)
    queueFlush()
end

local function logError(msg, err) writeLog(msg .. (err and (" - "..tostring(err)) or ""), "ERROR") end
local function logSuccess(msg)     writeLog(msg, "SUCCESS") end
local function logInfo(msg)        writeLog(msg, "INFO") end
local function logWarn(msg)        writeLog(msg, "WARN") end

-- Print startup banner (kept minimal)
local function printBanner()
    term.clear() term.setCursorPos(1,1)
    print("=====================================")
    print(" ComputerCraft Network System v1.0")
    print("=====================================")
    print()
    logInfo("System startup initiated - Computer ID: " .. os.getComputerID())
end

local function fileExists(path)
    local exists = fs.exists(path)
    logInfo("File check: " .. path .. " - " .. (exists and "EXISTS" or "NOT FOUND"))
    return exists
end

local function createDirectories()
    logInfo("Creating required directories...")
    local dirs = {"/etc","/bin","/lib","/var","/var/log","/var/run","/var/cache","/logs","/protocols"}
    local created = 0
    for _,d in ipairs(dirs) do
        if not fs.exists(d) then
            local ok, e = pcall(function() fs.makeDir(d) end)
            if ok then logInfo("Created directory: "..d); created = created + 1
            else logError("Failed to create directory: "..d, e) end
        end
    end
    logSuccess("Directory creation complete - " .. created .. " directories created")
end

local function setupNetworkConfig()
    logInfo("Setting up network configuration...")
    local configPath = "/etc/network.cfg"
    local persistPath = "/etc/network.persistent"

    if fileExists(persistPath) then
        logInfo("Loading persistent network configuration...")
        local ok, e = pcall(function()
            local file = fs.open(persistPath, "r"); if not file then return end
            local data = file.readAll(); file.close()
            local cfgFile = fs.open(configPath, "w"); if not cfgFile then return end
            cfgFile.write(data); cfgFile.close()
            logSuccess("Network configuration loaded from persistent storage")
        end)
        if not ok then logError("Failed to load persistent configuration", e) end
    end

    if not fileExists(configPath) then
        logInfo("Generating new network configuration...")
        local computerId = os.getComputerID()
        local label = os.getComputerLabel() or ""
        local ok, e = pcall(function()
            local cfg = string.format([[
-- Auto-generated network configuration
-- Computer ID: %d
-- Generated: %s

local config = {}
config.id = %d
config.label = "%s"
config.modem_side = "auto"
config.proto = "ccnet"
config.mac = "%s"
config.ipv4 = "%s"
config.hostname = "%s"
config.domain = "local"
config.fqdn = config.hostname .. "." .. config.domain

return config
]],
                    computerId, os.date(), computerId, label,
                    string.format("CC:AF:%02X:%02X:%02X:%02X",
                            bit.band(bit.brshift(computerId,24),0xFF) or 0,
                            bit.band(bit.brshift(computerId,16),0xFF) or 0,
                            bit.band(bit.brshift(computerId, 8),0xFF) or 0,
                            bit.band(computerId,0xFF) or 0),
                    string.format("10.0.%d.%d", math.floor(computerId/254)%256, (computerId%254)+1),
                    (label ~= "" and (label:lower():gsub("[^%w%-]","") .. "-" .. computerId) or ("cc-"..computerId))
            )
            local f = fs.open(configPath, "w"); if not f then return end
            f.write(cfg); f.close()
            local p = fs.open(persistPath, "w"); if p then p.write(cfg); p.close() end
            logSuccess("Network configuration generated successfully")
        end)
        if not ok then logError("Failed to generate network configuration", e); return false end
    end
    return fileExists(configPath)
end

local function startNetd()
    logInfo("Starting network daemon...")
    if not fileExists("/bin/netd.lua") then logError("Network daemon not found", "/bin/netd.lua missing"); return false end
    if fileExists("/var/run/netd.pid") then logInfo("Network daemon appears to be already running"); return true end
    local ok, e = pcall(function()
        if STARTUP_CONFIG.netdBackground then shell.run("bg", "/bin/netd.lua")
        else shell.run("/bin/netd.lua") end
    end)
    if not ok then logError("Failed to start network daemon", e); return false end
    logSuccess("Network daemon startup completed")
    return true
end

local function startHardwareWatchdog()
    if not fileExists("hardware_watchdog.lua") then logWarn("hardware_watchdog not found at hardware_watchdog.lua"); return false end
    if fileExists("/var/run/hardware_watchdog.pid") then logInfo("hardware_watchdog appears to be already running"); return true end
    local ok, e = pcall(function()
        if STARTUP_CONFIG.hardwareWatchdog then shell.run("bg", "hardware_watchdog.lua")
        else shell.run("hardware_watchdog.lua") end
    end)
    if not ok then logError("Failed to start Hardware watchdog daemon", e); return false end
    logSuccess("Hardware watchdog daemon startup completed")
    return true
end

local function showNetworkInfo()
    logInfo("Displaying network information...")
    local configPath = "/etc/network.cfg"
    if fileExists(configPath) then
        local ok, e = pcall(function()
            local cfg = dofile(configPath)
            if cfg then
                print(); print("Network Information:")
                print("  Computer ID: " .. cfg.id)
                print("  Hostname:    " .. cfg.hostname)
                print("  IP Address:  " .. cfg.ipv4)
                print("  MAC Address: " .. cfg.mac); print()
                logInfo("Network information displayed successfully")
            else
                logError("Failed to load network configuration for display", "Config returned nil")
            end
        end)
        if not ok then logError("Failed to display network information", e) end
    else
        logError("Cannot display network info", "Configuration file not found")
    end
end

local function runUserStartup()
    if fileExists("/user_startup.lua") then
        logInfo("Running user startup script...")
        local t0 = os.epoch("utc")
        local ok, e = pcall(function() shell.run("/user_startup.lua") end)
        local dt = os.epoch("utc") - t0
        if ok then logSuccess("User startup completed successfully in " .. dt .. "ms")
        else logError("User startup failed", e) end
    else
        logInfo("No user startup script found - skipping")
    end
end

local function main()
    printBanner()
    logInfo("System Information:")
    logInfo("  ComputerCraft Version: " .. (_HOST or "Unknown"))
    logInfo("  Computer ID: " .. os.getComputerID())
    logInfo("  Computer Label: " .. (os.getComputerLabel() or "None"))
    logInfo("  Startup Configuration: " .. textutils.serialize(STARTUP_CONFIG))

    createDirectories()
    local okCfg = setupNetworkConfig()
    if STARTUP_CONFIG.startupDelay > 0 then logInfo("Waiting " .. STARTUP_CONFIG.startupDelay .. " seconds before starting services..."); sleep(STARTUP_CONFIG.startupDelay) end
    local ok = okCfg
    if STARTUP_CONFIG.enableNetd and ok then ok = startNetd() or ok end
    if STARTUP_CONFIG.showNetInfo then showNetworkInfo() end
    if STARTUP_CONFIG.hardwareWatchdog then startHardwareWatchdog() end
    runUserStartup()

    if ok then logSuccess("System startup completed successfully"); print("Startup complete!")
    else logWarn("System startup completed with errors - check logs/startup.log"); print("Startup complete with errors - check logs/startup.log") end
    print()

    -- drain any pending flush timer before exiting
    if _timer then
        while true do
            local ev, id = os.pullEvent()
            if ev == "timer" and id == _timer then flushLog(); _timer = nil; break end
        end
    else
        flushLog()
    end
end

local ok, err = pcall(main)
if not ok then writeLog("CRITICAL: Startup failed completely: " .. tostring(err), "CRITICAL"); print("CRITICAL STARTUP FAILURE - Check logs/startup.log"); print("Error: " .. tostring(err)); flushLog() end
