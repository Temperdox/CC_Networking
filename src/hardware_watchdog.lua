-- hardware_watchdog.lua
-- Hardware monitoring service for ComputerCraft
-- Monitors peripheral changes and updates network configuration

local WATCHDOG_VERSION = "1.0.0"
local CHECK_INTERVAL = 5 -- seconds between hardware checks

-- Logging utility
local function writeLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_entry = string.format("[%s] [%s] %s", timestamp, level, message)

    print(log_entry)

    if not fs.exists("logs") then
        fs.makeDir("logs")
    end

    local log_file = fs.open("logs/hardware_watchdog.log", "a")
    if log_file then
        log_file.writeLine(log_entry)
        log_file.close()
    end
end

local function logInfo(msg) writeLog(msg, "INFO") end
local function logSuccess(msg) writeLog(msg, "SUCCESS") end
local function logError(msg) writeLog(msg, "ERROR") end
local function logWarning(msg) writeLog(msg, "WARNING") end

-- Check if netd is running
local function isNetdRunning()
    return fs.exists("/var/run/netd.pid")
end

-- Get current peripheral inventory
local function getCurrentPeripherals()
    local peripherals = {}
    local sides = {"top", "bottom", "left", "right", "front", "back"}

    for _, side in ipairs(sides) do
        if peripheral.isPresent(side) then
            local ptype = peripheral.getType(side)
            peripherals[side] = ptype
        end
    end

    return peripherals
end

-- Compare peripheral inventories
local function comparePeripherals(old, new)
    local changes = {
        added = {},
        removed = {},
        changed = {}
    }

    -- Check for additions and changes
    for side, ptype in pairs(new) do
        if not old[side] then
            table.insert(changes.added, {side = side, type = ptype})
        elseif old[side] ~= ptype then
            table.insert(changes.changed, {side = side, old_type = old[side], new_type = ptype})
        end
    end

    -- Check for removals
    for side, ptype in pairs(old) do
        if not new[side] then
            table.insert(changes.removed, {side = side, type = ptype})
        end
    end

    return changes
end

-- Update network info file
local function updateNetworkInfo()
    logInfo("Updating network information...")

    -- Check if we have a modem now
    local modem = peripheral.find("modem")
    local modem_available = modem ~= nil

    -- Load current network info
    local info = {}
    if fs.exists("/var/run/network.info") then
        local file = fs.open("/var/run/network.info", "r")
        if file then
            local content = file.readAll()
            file.close()
            info = textutils.unserialize(content) or {}
        end
    end

    -- Update modem availability
    local old_modem_status = info.modem_available
    info.modem_available = modem_available

    if modem_available and modem then
        info.modem_side = peripheral.getName(modem)
        logInfo("Modem detected on side: " .. info.modem_side)
    else
        info.modem_side = nil
        logWarning("No modem detected")
    end

    -- Write updated info
    local file = fs.open("/var/run/network.info", "w")
    if file then
        file.write(textutils.serialize(info))
        file.close()

        if old_modem_status ~= modem_available then
            logSuccess("Network info updated - modem status changed: " .. tostring(old_modem_status) .. " -> " .. tostring(modem_available))
        else
            logInfo("Network info updated")
        end
    end

    return modem_available, old_modem_status
end

-- Restart netd if needed
local function restartNetd(reason)
    logInfo("Restarting netd: " .. reason)

    -- Stop current netd
    if fs.exists("/var/run/netd.pid") then
        fs.delete("/var/run/netd.pid")
        logInfo("Removed netd PID file")
    end

    -- Wait a moment
    sleep(1)

    -- Start netd again
    local success = shell.run("bg", "/bin/netd.lua")
    if success then
        logSuccess("Netd restarted successfully")

        -- Wait for it to start
        sleep(2)

        -- Verify it started
        if fs.exists("/var/run/netd.pid") then
            logSuccess("Netd restart verified - PID file created")
            return true
        else
            logError("Netd restart failed - no PID file created")
            return false
        end
    else
        logError("Failed to restart netd")
        return false
    end
end

-- Handle modem changes
local function handleModemChange(change_type, side, ptype)
    if ptype == "modem" then
        if change_type == "added" then
            logInfo("Modem added on side: " .. side)

            -- Update network info
            local modem_available, old_status = updateNetworkInfo()

            -- If netd is running and modem status changed, restart netd
            if isNetdRunning() and not old_status and modem_available then
                restartNetd("New modem detected - enabling network features")
            end

        elseif change_type == "removed" then
            logWarning("Modem removed from side: " .. side)

            -- Update network info
            local modem_available, old_status = updateNetworkInfo()

            -- If netd is running and we lost the modem, restart with limited functionality
            if isNetdRunning() and old_status and not modem_available then
                restartNetd("Modem removed - switching to limited mode")
            end
        end
    end
end

-- Main watchdog loop
local function watchdogLoop()
    logInfo("Hardware watchdog started - version " .. WATCHDOG_VERSION)
    logInfo("Monitoring interval: " .. CHECK_INTERVAL .. " seconds")

    -- Get initial peripheral state
    local current_peripherals = getCurrentPeripherals()
    logInfo("Initial peripheral scan completed")

    -- Log initial state
    for side, ptype in pairs(current_peripherals) do
        logInfo("Initial: " .. side .. " = " .. ptype)
    end

    local check_count = 0

    while true do
        sleep(CHECK_INTERVAL)
        check_count = check_count + 1

        -- Get current peripheral state
        local new_peripherals = getCurrentPeripherals()

        -- Compare with previous state
        local changes = comparePeripherals(current_peripherals, new_peripherals)

        -- Log changes
        if #changes.added > 0 or #changes.removed > 0 or #changes.changed > 0 then
            logInfo("Hardware changes detected (check #" .. check_count .. "):")

            for _, change in ipairs(changes.added) do
                logInfo("  ADDED: " .. change.side .. " = " .. change.type)
                handleModemChange("added", change.side, change.type)
            end

            for _, change in ipairs(changes.removed) do
                logWarning("  REMOVED: " .. change.side .. " = " .. change.type)
                handleModemChange("removed", change.side, change.type)
            end

            for _, change in ipairs(changes.changed) do
                logInfo("  CHANGED: " .. change.side .. " = " .. change.old_type .. " -> " .. change.new_type)
                handleModemChange("removed", change.side, change.old_type)
                handleModemChange("added", change.side, change.new_type)
            end
        else
            -- Periodic status log (every 10 checks)
            if check_count % 10 == 0 then
                logInfo("Hardware check #" .. check_count .. " - no changes detected")
            end
        end

        -- Update current state
        current_peripherals = new_peripherals

        -- Also periodically update network info even without changes
        if check_count % 12 == 0 then -- Every minute
            updateNetworkInfo()
        end
    end
end

-- Write PID file for watchdog
local function writePID()
    if not fs.exists("/var/run") then
        fs.makeDir("/var/run")
    end

    local pid_file = fs.open("/var/run/hardware_watchdog.pid", "w")
    if pid_file then
        pid_file.write(tostring(os.getComputerID()))
        pid_file.close()
        logInfo("Watchdog PID file created")
    end
end

-- Cleanup on exit
local function cleanup()
    logInfo("Hardware watchdog shutting down")

    if fs.exists("/var/run/hardware_watchdog.pid") then
        fs.delete("/var/run/hardware_watchdog.pid")
        logInfo("Removed watchdog PID file")
    end
end

-- Main execution
local function main()
    print("Hardware Watchdog v" .. WATCHDOG_VERSION)
    print("Monitoring hardware changes...")

    writePID()

    -- Handle termination gracefully
    local success, err = pcall(watchdogLoop)
    if not success then
        logError("Watchdog loop error: " .. tostring(err))
    end

    cleanup()
end

-- Check if already running
if fs.exists("/var/run/hardware_watchdog.pid") then
    print("Hardware watchdog already running")
    return
end

-- Start the watchdog
main()