-- hardware_watchdog.lua (quiet + buffered logging)
-- Hardware monitoring service for ComputerCraft

local WATCHDOG_VERSION = "1.0.0"
local CHECK_INTERVAL = 5 -- seconds

-- quiet, buffered logging
local LOG_DIR, LOG_PATH = "logs", "logs/hardware_watchdog.log"
local PRINT_MIN = "WARN" -- only WARN/ERROR print to console
local LEVELS = { INFO=3, SUCCESS=3, WARNING=4, WARN=4, ERROR=5, CRITICAL=6 }

local buf, tmr, FLUSH_EVERY = {}, nil, 1.0
local function sev(n) return LEVELS[(n or "INFO"):upper()] or 3 end

local function flushBuf()
    if #buf == 0 then return end
    if not fs.exists(LOG_DIR) then fs.makeDir(LOG_DIR) end
    local f = fs.open(LOG_PATH,"a")
    if f then for i=1,#buf do f.writeLine(buf[i]) end f.close() end
    buf = {}
end

local function qFlush()
    if tmr then os.cancelTimer(tmr) end
    tmr = os.startTimer(FLUSH_EVERY)
end

local function writeLog(message, level)
    level = level or "INFO"
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("[%s] [%s] %s", ts, level, message)
    if sev(level) >= sev(PRINT_MIN) then print(line) end
    table.insert(buf, line); qFlush()
end

local function logInfo(msg)    writeLog(msg, "INFO")    end
local function logSuccess(msg) writeLog(msg, "SUCCESS") end
local function logError(msg)   writeLog(msg, "ERROR")   end
local function logWarning(msg) writeLog(msg, "WARNING") end

local function isNetdRunning() return fs.exists("/var/run/netd.pid") end

local function getCurrentPeripherals()
    local p = {}; local sides = {"top","bottom","left","right","front","back"}
    for _,s in ipairs(sides) do if peripheral.isPresent(s) then p[s]=peripheral.getType(s) end end
    return p
end

local function comparePeripherals(old, new)
    local ch = { added={}, removed={}, changed={} }
    for side, t in pairs(new) do
        if not old[side] then table.insert(ch.added, {side=side, type=t})
        elseif old[side] ~= t then table.insert(ch.changed, {side=side, old_type=old[side], new_type=t}) end
    end
    for side, t in pairs(old) do
        if not new[side] then table.insert(ch.removed, {side=side, type=t}) end
    end
    return ch
end

local function updateNetworkInfo()
    local modem = peripheral.find("modem")
    local modem_available = modem ~= nil
    local info = {}
    if fs.exists("/var/run/network.info") then
        local f=fs.open("/var/run/network.info","r"); if f then local c=f.readAll(); f.close(); info=textutils.unserialize(c) or {} end
    end
    local old = info.modem_available
    info.modem_available = modem_available
    info.modem_side = modem and peripheral.getName(modem) or nil

    local w=fs.open("/var/run/network.info","w"); if w then w.write(textutils.serialize(info)); w.close() end

    if old ~= modem_available then
        logSuccess("Network info updated - modem status changed: " .. tostring(old) .. " -> " .. tostring(modem_available))
    else
        logInfo("Network info updated")
    end
    return modem_available, old
end

local function restartNetd(reason)
    logWarning("Restarting netd: " .. reason)
    if fs.exists("/var/run/netd.pid") then fs.delete("/var/run/netd.pid"); logInfo("Removed netd PID file") end
    sleep(1)
    local ok = shell.run("bg", "/bin/netd.lua")
    if ok then
        logSuccess("Netd restarted successfully"); sleep(2)
        if fs.exists("/var/run/netd.pid") then logSuccess("Netd restart verified - PID file created"); return true
        else logError("Netd restart failed - no PID file created"); return false end
    else
        logError("Failed to restart netd"); return false
    end
end

local function handleModemChange(change_type, side, ptype)
    if ptype ~= "modem" then return end
    if change_type == "added" then
        logInfo("Modem added on side: " .. side)
        local modem_available, old = updateNetworkInfo()
        if isNetdRunning() and not old and modem_available then restartNetd("New modem detected - enabling network features") end
    elseif change_type == "removed" then
        logWarning("Modem removed from side: " .. side)
        local modem_available, old = updateNetworkInfo()
        if isNetdRunning() and old and not modem_available then restartNetd("Modem removed - switching to limited mode") end
    end
end

local function watchdogLoop()
    logInfo("Hardware watchdog started - version " .. WATCHDOG_VERSION)
    logInfo("Monitoring interval: " .. CHECK_INTERVAL .. " seconds")

    local current = getCurrentPeripherals()
    for side, t in pairs(current) do logInfo("Initial: " .. side .. " = " .. t) end

    local checks = 0
    while true do
        -- use event loop to keep Ctrl+T responsive and handle log flush timer
        local ev, p1 = os.pullEvent()
        if ev == "timer" and tmr and p1 == tmr then
            flushBuf(); tmr = nil
        elseif ev == "terminate" then
            error("terminate") -- allow outer pcall to run cleanup
        end

        -- periodically do work
        if checks == 0 or (os.clock() % CHECK_INTERVAL) < 0.05 then
            checks = checks + 1
            local new = getCurrentPeripherals()
            local ch = comparePeripherals(current, new)

            if #ch.added>0 or #ch.removed>0 or #ch.changed>0 then
                logInfo(("Hardware changes detected (check #%d):"):format(checks))
                for _,c in ipairs(ch.added) do logInfo("  ADDED: " .. c.side .. " = " .. c.type); handleModemChange("added", c.side, c.type) end
                for _,c in ipairs(ch.removed) do logWarning("  REMOVED: " .. c.side .. " = " .. c.type); handleModemChange("removed", c.side, c.type) end
                for _,c in ipairs(ch.changed) do
                    logInfo("  CHANGED: " .. c.side .. " = " .. c.old_type .. " -> " .. c.new_type)
                    handleModemChange("removed", c.side, c.old_type); handleModemChange("added", c.side, c.new_type)
                end
                current = new
            elseif checks % 12 == 0 then
                logInfo("Hardware check #" .. checks .. " - no changes detected")
                updateNetworkInfo()
            end
        end
    end
end

local function writePID()
    if not fs.exists("/var/run") then fs.makeDir("/var/run") end
    local f=fs.open("/var/run/hardware_watchdog.pid","w"); if f then f.write(tostring(os.getComputerID())); f.close(); logInfo("Watchdog PID file created") end
end

local function cleanup()
    logInfo("Hardware watchdog shutting down")
    if fs.exists("/var/run/hardware_watchdog.pid") then fs.delete("/var/run/hardware_watchdog.pid"); logInfo("Removed watchdog PID file") end
    flushBuf()
end

local function main()
    print("Hardware Watchdog v" .. WATCHDOG_VERSION)
    print("Monitoring hardware changes...")

    writePID()
    local ok, err = pcall(watchdogLoop)
    if not ok and tostring(err) ~= "terminate" then logError("Watchdog loop error: " .. tostring(err)) end
    cleanup()
end

if fs.exists("/var/run/hardware_watchdog.pid") then print("Hardware watchdog already running"); return end
main()