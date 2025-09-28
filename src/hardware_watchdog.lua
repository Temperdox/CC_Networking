-- hardware_watchdog.lua
-- Hardware monitoring daemon that detects peripheral changes and manages network services
-- Version 1.0.2 - Enhanced with global stop signal support for cleaning up multiple netd instances

local WATCHDOG_VERSION = "1.0.2"
local PID_FILE = "/var/run/hardware_watchdog.pid"
local LOG_FILE = "logs/hardware_watchdog.log"
local CHECK_INTERVAL = 5 -- seconds

-- Ensure directories exist
local function ensureDirs()
    if not fs.exists("logs") then fs.makeDir("logs") end
    if not fs.exists("/var") then fs.makeDir("/var") end
    if not fs.exists("/var/run") then fs.makeDir("/var/run") end
end

-- Buffered logging
local logBuf, tmr = {}, nil
local function flushBuf()
    if #logBuf == 0 then return end
    ensureDirs()
    local f = fs.open(LOG_FILE, "a")
    if f then
        for _, v in ipairs(logBuf) do f.writeLine(v) end
        f.close()
    end
    logBuf = {}
end

local function writeLog(msg, level)
    level = level or "INFO"
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local entry = string.format("[%s] [%s] %s", ts, level, msg)
    print(entry)
    table.insert(logBuf, entry)
    if tmr then os.cancelTimer(tmr) end
    tmr = os.startTimer(0.5)
end

local function logInfo(msg) writeLog(msg, "INFO") end
local function logWarning(msg) writeLog(msg, "WARNING") end
local function logError(msg) writeLog(msg, "ERROR") end
local function logSuccess(msg) writeLog(msg, "SUCCESS") end

-- PID management
local function writePid()
    ensureDirs()
    local f = fs.open(PID_FILE, "w")
    if f then
        f.write(tostring(os.getComputerID()) .. ":" .. tostring(os.clock()))
        f.close()
        logInfo("Watchdog PID file created")
        return true
    end
    return false
end

local function removePid()
    if fs.exists(PID_FILE) then
        fs.delete(PID_FILE)
        logInfo("Watchdog PID file removed")
    end
end

-- Process management
local function getProcessPid(pidFile)
    if not fs.exists(pidFile) then return nil end
    local f = fs.open(pidFile, "r")
    if f then
        local content = f.readAll()
        f.close()
        return content
    end
    return nil
end

local function isProcessRunning(processName)
    -- Simply check if PID file exists
    -- In ComputerCraft, if the process is running, it maintains its PID file
    -- When it stops, it deletes the PID file
    local pidFile = "/var/run/" .. processName .. ".pid"
    return fs.exists(pidFile)
end

local function isNetdRunning()
    return fs.exists("/var/run/netd.pid")
end

local function killProcess(processName)
    local pidFile = "/var/run/" .. processName .. ".pid"

    -- First try to send terminate signal
    logInfo("Attempting to stop " .. processName)

    if fs.exists(pidFile) then
        -- Read PID before deleting
        local pid = getProcessPid(pidFile)
        logInfo(processName .. " PID: " .. tostring(pid))

        -- Create a stop signal file
        local stopFile = "/var/run/" .. processName .. ".stop"
        local f = fs.open(stopFile, "w")
        if f then
            f.write("stop")
            f.close()
            logInfo("Created stop signal for " .. processName)
        end

        -- Wait for process to stop
        local maxWait = 10 -- seconds
        local waited = 0
        while waited < maxWait do
            sleep(0.5)
            waited = waited + 0.5

            -- Check if process stopped (PID file removed)
            if not fs.exists(pidFile) then
                logSuccess(processName .. " stopped successfully")

                -- Clean up stop file
                if fs.exists(stopFile) then
                    fs.delete(stopFile)
                end
                return true
            end
        end

        logError(processName .. " did not stop gracefully after " .. maxWait .. " seconds")

        -- Force cleanup
        if fs.exists(stopFile) then
            fs.delete(stopFile)
        end
        -- Force remove PID file
        if fs.exists(pidFile) then
            fs.delete(pidFile)
            logWarning("Forcefully removed " .. processName .. " PID file")
        end
    else
        logInfo("No PID file found for " .. processName)
    end

    return false
end

-- Kill all netd processes (including orphaned ones without PID files)
local function killAllNetdProcesses()
    logInfo("Cleaning up all netd processes...")

    -- First, try the normal shutdown via PID file
    if fs.exists("/var/run/netd.pid") then
        killProcess("netd")
    end

    -- Create a global stop signal that all netd instances should check
    local globalStopFile = "/var/run/netd.stop.all"
    local f = fs.open(globalStopFile, "w")
    if f then
        f.write(tostring(os.epoch("utc")))
        f.close()
        logInfo("Created global stop signal for all netd instances")
    end

    -- Wait for processes to clean up
    sleep(3) -- Give more time for all instances to see the signal

    -- Clean up the stop file
    if fs.exists(globalStopFile) then
        fs.delete(globalStopFile)
        logInfo("Removed global stop signal")
    end

    -- Remove any stale PID files
    if fs.exists("/var/run/netd.pid") then
        fs.delete("/var/run/netd.pid")
        logInfo("Removed stale netd PID file")
    end

    -- Clean up any remaining stop signals
    if fs.exists("/var/run/netd.stop") then
        fs.delete("/var/run/netd.stop")
    end
end

local function getCurrentPeripherals()
    local p = {}
    for _, side in ipairs(peripheral.getNames()) do
        p[side] = peripheral.getType(side)
    end
    return p
end

local function comparePeripherals(old, new)
    local ch = { added={}, removed={}, changed={} }
    for side, t in pairs(new) do
        if not old[side] then
            table.insert(ch.added, {side=side, type=t})
        elseif old[side] ~= t then
            table.insert(ch.changed, {side=side, old_type=old[side], new_type=t})
        end
    end
    for side, t in pairs(old) do
        if not new[side] then
            table.insert(ch.removed, {side=side, type=t})
        end
    end
    return ch
end

local function updateNetworkInfo()
    local modem = peripheral.find("modem")
    local modem_available = modem ~= nil
    local info = {}

    if fs.exists("/var/run/network.info") then
        local f = fs.open("/var/run/network.info", "r")
        if f then
            local c = f.readAll()
            f.close()
            info = textutils.unserialize(c) or {}
        end
    end

    local old = info.modem_available
    info.modem_available = modem_available
    info.modem_side = modem and peripheral.getName(modem) or nil

    local w = fs.open("/var/run/network.info", "w")
    if w then
        w.write(textutils.serialize(info))
        w.close()
    end

    if old ~= modem_available then
        logSuccess("Network info updated - modem status changed: " .. tostring(old) .. " -> " .. tostring(modem_available))
    else
        logInfo("Network info updated")
    end

    return modem_available, old
end

local function restartNetd(reason)
    logWarning("Restarting netd: " .. reason)

    -- Kill ALL netd processes, not just the one with PID file
    killAllNetdProcesses()

    -- Wait a bit to ensure cleanup
    sleep(1)

    -- Now start a new instance
    logInfo("Starting new netd instance...")
    local ok = shell.run("bg", "/bin/netd.lua")

    if ok then
        logSuccess("Netd restart command issued")
        sleep(2) -- Give it time to start

        if fs.exists("/var/run/netd.pid") then
            logSuccess("Netd restart verified - PID file created")
            return true
        else
            logError("Netd restart failed - no PID file created")
            return false
        end
    else
        logError("Failed to restart netd - shell.run failed")
        return false
    end
end

local function handleModemChange(change_type, side, ptype)
    if ptype ~= "modem" then return end

    if change_type == "added" then
        logInfo("Modem added on side: " .. side)
        local modem_available, old = updateNetworkInfo()

        if isNetdRunning() then
            logInfo("Netd is already running, will restart to use new modem")
            restartNetd("New modem detected - enabling network features")
        else
            logInfo("Starting netd - modem now available")
            shell.run("bg", "/bin/netd.lua")
            sleep(1)
        end

    elseif change_type == "removed" then
        logWarning("Modem removed from side: " .. side)
        local modem_available, old = updateNetworkInfo()

        if isNetdRunning() and old and not modem_available then
            restartNetd("Modem removed - switching to limited mode")
        end
    end
end

local function watchdogLoop()
    logInfo("Hardware watchdog started - version " .. WATCHDOG_VERSION)
    logInfo("Monitoring interval: " .. CHECK_INTERVAL .. " seconds")

    local current = getCurrentPeripherals()
    for side, t in pairs(current) do
        logInfo("Initial: " .. side .. " = " .. t)
    end

    local checks = 0
    local nextCheck = os.clock() + CHECK_INTERVAL

    while true do
        local ev, p1 = os.pullEventRaw()

        if ev == "timer" and tmr and p1 == tmr then
            flushBuf()
            tmr = nil
        elseif ev == "terminate" then
            logInfo("Received terminate signal")
            break
        end

        -- Check for hardware changes periodically
        if os.clock() >= nextCheck then
            checks = checks + 1
            nextCheck = os.clock() + CHECK_INTERVAL

            local new = getCurrentPeripherals()
            local ch = comparePeripherals(current, new)

            if #ch.added > 0 or #ch.removed > 0 or #ch.changed > 0 then
                logInfo(string.format("Hardware changes detected (check #%d):", checks))

                for _, v in ipairs(ch.added) do
                    logInfo(string.format("  ADDED: %s = %s", v.side, v.type))
                    handleModemChange("added", v.side, v.type)
                end

                for _, v in ipairs(ch.removed) do
                    logInfo(string.format("  REMOVED: %s = %s", v.side, v.type))
                    handleModemChange("removed", v.side, v.type)
                end

                for _, v in ipairs(ch.changed) do
                    logInfo(string.format("  CHANGED: %s = %s -> %s", v.side, v.old_type, v.type))
                    if v.old_type == "modem" then
                        handleModemChange("removed", v.side, v.old_type)
                    end
                    if v.type == "modem" then
                        handleModemChange("added", v.side, v.type)
                    end
                end

                current = new
            else
                -- Periodic status check
                if checks % 4 == 0 then  -- Every 20 seconds
                    logInfo(string.format("Hardware check #%d - no changes detected", checks))
                    updateNetworkInfo()

                    -- Health check for netd - only start if not running AND modem exists
                    if not isNetdRunning() and peripheral.find("modem") then
                        logWarning("Netd not running but modem available - starting netd")
                        shell.run("bg", "/bin/netd.lua")
                        sleep(1) -- Give it a moment to start
                    elseif isNetdRunning() then
                        -- Netd is running, all good
                        if checks % 12 == 0 then  -- Every minute
                            logInfo("Netd is running normally")
                        end
                    end
                end
            end
        end
    end
end

-- Main
local function main()
    -- Check if already running
    if fs.exists(PID_FILE) then
        logWarning("Hardware watchdog already running or PID file exists")
        print("Hardware watchdog appears to be already running")
        print("If it's not running, delete " .. PID_FILE .. " and try again")
        return
    end

    -- Create PID file
    if not writePid() then
        logError("Failed to create PID file")
        return
    end

    -- Run watchdog with cleanup on exit
    local ok, err = pcall(watchdogLoop)

    -- Cleanup
    removePid()
    flushBuf()

    if not ok then
        logError("Watchdog error: " .. tostring(err))
        error(err)
    else
        logSuccess("Hardware watchdog stopped gracefully")
    end
end

-- Check for stop signal and handle it
if fs.exists("/var/run/hardware_watchdog.stop") then
    print("Stop signal detected, exiting...")
    fs.delete("/var/run/hardware_watchdog.stop")
    return
end

main()