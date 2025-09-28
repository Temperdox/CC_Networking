-- startup.lua
-- ComputerCraft startup file with comprehensive logging

-- Startup configuration
local STARTUP_CONFIG = {
    enableNetd = true,
    enableLogger = false,
    netdBackground = true,
    hardwareWatchdog = true,
    showNetInfo = true,
    startupDelay = 0.5,
}

-- Logging utility
local function writeLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_entry = string.format("[%s] [%s] %s", timestamp, level, message)

    -- Print to console
    print(log_entry)

    -- Ensure logs directory exists
    if not fs.exists("logs") then
        fs.makeDir("logs")
    end

    -- Write to startup log
    local log_file = fs.open("logs/startup.log", "a")
    if log_file then
        log_file.writeLine(log_entry)
        log_file.close()
    end
end

local function logError(message, error_details)
    writeLog(message .. " - " .. tostring(error_details), "ERROR")
end

local function logSuccess(message)
    writeLog(message, "SUCCESS")
end

local function logInfo(message)
    writeLog(message, "INFO")
end

-- Print startup banner
local function printBanner()
    term.clear()
    term.setCursorPos(1, 1)
    print("=====================================")
    print(" ComputerCraft Network System v1.0")
    print("=====================================")
    print()
    logInfo("System startup initiated - Computer ID: " .. os.getComputerID())
end

-- Check if file exists
local function fileExists(path)
    local exists = fs.exists(path)
    logInfo("File check: " .. path .. " - " .. (exists and "EXISTS" or "NOT FOUND"))
    return exists
end

-- Create required directories
local function createDirectories()
    logInfo("Creating required directories...")
    local dirs = {
        "/etc",
        "/bin",
        "/lib",
        "/var",
        "/var/log",
        "/var/run",
        "/var/cache",
        "/logs",
        "/protocols"
    }

    local created_count = 0
    for _, dir in ipairs(dirs) do
        if not fs.exists(dir) then
            local success, error = pcall(function() fs.makeDir(dir) end)
            if success then
                logInfo("Created directory: " .. dir)
                created_count = created_count + 1
            else
                logError("Failed to create directory: " .. dir, error)
            end
        end
    end
    logSuccess("Directory creation complete - " .. created_count .. " directories created")
end

-- Load or generate network configuration
local function setupNetworkConfig()
    logInfo("Setting up network configuration...")
    local configPath = "/etc/network.cfg"
    local persistPath = "/etc/network.persistent"

    -- Check if we have a persistent configuration
    if fileExists(persistPath) then
        logInfo("Loading persistent network configuration...")
        local success, error = pcall(function()
            local file = fs.open(persistPath, "r")
            if file then
                local data = file.readAll()
                file.close()

                -- Write to network.cfg
                local cfgFile = fs.open(configPath, "w")
                if cfgFile then
                    cfgFile.write(data)
                    cfgFile.close()
                    logSuccess("Network configuration loaded from persistent storage")
                    return true
                end
            end
        end)

        if not success then
            logError("Failed to load persistent configuration", error)
        end
    end

    -- Generate new configuration if none exists
    if not fileExists(configPath) then
        logInfo("Generating new network configuration...")

        local computerId = os.getComputerID()
        local computerLabel = os.getComputerLabel() or ""

        local success, error = pcall(function()
            -- Generate configuration (shortened for brevity)
            local config = string.format([[
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
                    computerId,
                    os.date(),
                    computerId,
                    computerLabel,
            -- Generate MAC
                    string.format("CC:AF:%02X:%02X:%02X:%02X",
                            bit.band(bit.brshift(computerId, 24), 0xFF) or 0,
                            bit.band(bit.brshift(computerId, 16), 0xFF) or 0,
                            bit.band(bit.brshift(computerId, 8), 0xFF) or 0,
                            bit.band(computerId, 0xFF) or 0),
            -- Generate IP
                    string.format("10.0.%d.%d",
                            math.floor(computerId / 254) % 256,
                            (computerId % 254) + 1),
            -- Generate hostname
                    (computerLabel ~= "" and
                            string.format("%s-%d", computerLabel:lower():gsub("[^%w%-]", ""), computerId) or
                            string.format("cc-%d", computerId))
            )

            -- Write configuration
            local file = fs.open(configPath, "w")
            if file then
                file.write(config)
                file.close()

                -- Save persistent copy
                local persistFile = fs.open(persistPath, "w")
                if persistFile then
                    persistFile.write(config)
                    persistFile.close()
                end

                logSuccess("Network configuration generated successfully")
                return true
            end
        end)

        if not success then
            logError("Failed to generate network configuration", error)
            return false
        end
    end

    return fileExists(configPath)
end

-- Start network daemon
local function startNetd()
    logInfo("Starting network daemon...")
    if not fileExists("/bin/netd.lua") then
        logError("Network daemon not found", "/bin/netd.lua missing")
        return false
    end

    -- Check if already running
    if fileExists("/var/run/netd.pid") then
        logInfo("Network daemon appears to be already running")
        return true
    end

    local success, error = pcall(function()
        if STARTUP_CONFIG.netdBackground then
            -- Start in background using shell
            shell.run("bg", "/bin/netd.lua")
            logInfo("Network daemon started in background mode")
        else
            -- Start in foreground (blocks)
            shell.run("/bin/netd.lua")
            logInfo("Network daemon started in foreground mode")
        end
    end)

    if not success then
        logError("Failed to start network daemon", error)
        return false
    end

    logSuccess("Network daemon startup completed")
    return true
end

local function startHardwareWatchdog()
    if not fileExists("hardware_watchdog.lua") then
        print("Warning: hardware_watchdog not found at hardware_watchdog.lua")
        return false
    end

    -- Check if already running
    if fileExists("/var/run/hardware_watchdog.pid") then
        print("hardware_watchdog appears to be already running")
        return true
    end

    local success, error = pcall(function()
        if STARTUP_CONFIG.hardwareWatchdog then
            -- Start in background using shell
            shell.run("bg", "hardware_watchdog.lua")
            logInfo("Hardware watchdog daemon started in background mode")
        else
            -- Start in foreground (blocks)
            shell.run("hardware_watchdog.lua")
            logInfo("Hardware watchdog started in foreground mode")
        end
    end)

    if not success then
        logError("Failed to start Hardware watchdog daemon", error)
        return false
    end

    logSuccess("Hardware watchdog daemon startup completed")
    return true
end

-- Show network information
local function showNetworkInfo()
    logInfo("Displaying network information...")
    local configPath = "/etc/network.cfg"
    if fileExists(configPath) then
        local success, error = pcall(function()
            local cfg = dofile(configPath)
            if cfg then
                print()
                print("Network Information:")
                print("  Computer ID: " .. cfg.id)
                print("  Hostname:    " .. cfg.hostname)
                print("  IP Address:  " .. cfg.ipv4)
                print("  MAC Address: " .. cfg.mac)
                print()
                logInfo("Network information displayed successfully")
            else
                logError("Failed to load network configuration for display", "Config returned nil")
            end
        end)

        if not success then
            logError("Failed to display network information", error)
        end
    else
        logError("Cannot display network info", "Configuration file not found")
    end
end

-- Run user startup with logging
local function runUserStartup()
    if fileExists("/user_startup.lua") then
        logInfo("Running user startup script...")
        local start_time = os.epoch("utc")

        local success, error = pcall(function()
            shell.run("/user_startup.lua")
        end)

        local duration = os.epoch("utc") - start_time

        if success then
            logSuccess("User startup completed successfully in " .. duration .. "ms")
        else
            logError("User startup failed", error)
        end
    else
        logInfo("No user startup script found - skipping")
    end
end

-- Main startup function with comprehensive logging
local function main()
    local startup_begin = os.epoch("utc")

    printBanner()

    -- Log system information
    logInfo("System Information:")
    logInfo("  ComputerCraft Version: " .. (_HOST or "Unknown"))
    logInfo("  Computer ID: " .. os.getComputerID())
    logInfo("  Computer Label: " .. (os.getComputerLabel() or "None"))
    logInfo("  Startup Configuration: " .. textutils.serialize(STARTUP_CONFIG))

    -- Create required directories
    local success = true
    createDirectories()

    -- Setup network configuration
    if not setupNetworkConfig() then
        logError("Network configuration setup failed", "Cannot continue without network config")
        success = false
    end

    -- Small delay before starting services
    if STARTUP_CONFIG.startupDelay > 0 then
        logInfo("Waiting " .. STARTUP_CONFIG.startupDelay .. " seconds before starting services...")
        sleep(STARTUP_CONFIG.startupDelay)
    end

    -- Start network daemon if enabled
    if STARTUP_CONFIG.enableNetd and success then
        if not startNetd() then
            logError("Network daemon startup failed", "Continuing without network services")
            success = false
        end
    else
        logInfo("Network daemon disabled in configuration")
    end

    -- Show network info if enabled
    if STARTUP_CONFIG.showNetInfo then
        showNetworkInfo()
    end

    if STARTUP_CONFIG.hardwareWatchdog then
        startHardwareWatchdog()
    end

    -- Run user startup file if it exists
    runUserStartup()

    local startup_duration = os.epoch("utc") - startup_begin

    if success then
        logSuccess("System startup completed successfully in " .. startup_duration .. "ms")
        print("Startup complete!")
    else
        logError("System startup completed with errors", "Duration: " .. startup_duration .. "ms")
        print("Startup complete with errors - check logs/startup.log")
    end

    print()
end

-- Run startup with global error handling
local startup_success, startup_error = pcall(main)

if not startup_success then
    -- Critical startup failure
    writeLog("CRITICAL: Startup failed completely: " .. tostring(startup_error), "CRITICAL")
    print("CRITICAL STARTUP FAILURE - Check logs/startup.log")
    print("Error: " .. tostring(startup_error))
end