-- router_startup.lua
-- Router system startup with comprehensive logging

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

    -- Write to router startup log
    local log_file = fs.open("logs/router_startup.log", "a")
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

local function logWarning(message)
    writeLog(message, "WARNING")
end

-- Check if file exists with logging
local function fileExists(path)
    local exists = fs.exists(path)
    logInfo("File check: " .. path .. " - " .. (exists and "EXISTS" or "NOT FOUND"))
    return exists
end

-- Create router directories
local function createRouterDirectories()
    logInfo("Creating router directories...")
    local dirs = {
        "/etc",
        "/config",
        "/var/lib/dhcp",
        "/var/log",
        "/var/run",
        "/var/cache",
        "/logs",
        "/usr/lib/router"
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
    logSuccess("Router directories created - " .. created_count .. " new directories")
end

-- Load router configuration
local function loadRouterConfig()
    logInfo("Loading router configuration...")
    local config_paths = {
        "/config/router.cfg",
        "/etc/router.cfg"
    }

    for _, config_path in ipairs(config_paths) do
        if fileExists(config_path) then
            local success, result = pcall(function()
                return dofile(config_path)
            end)

            if success and result then
                logSuccess("Router configuration loaded from: " .. config_path)
                logInfo("Router ID: " .. (result.router_id or "Unknown"))
                logInfo("Hostname: " .. (result.hostname or "Unknown"))
                logInfo("LAN IP: " .. (result.lan and result.lan.ip or "Unknown"))
                return result
            else
                logError("Failed to load router config from: " .. config_path, result)
            end
        end
    end

    logWarning("No router configuration found - using defaults")
    return nil
end

-- Check hardware requirements
local function checkHardware()
    logInfo("Checking hardware requirements...")

    -- Check for modem
    local modem_found = false
    local modem_side = nil
    local sides = {"top", "bottom", "left", "right", "front", "back"}

    for _, side in ipairs(sides) do
        if peripheral.isPresent(side) then
            local ptype = peripheral.getType(side)
            if ptype == "modem" then
                modem_found = true
                modem_side = side
                logInfo("Modem found on side: " .. side)

                -- Check if it's a wireless modem
                local modem = peripheral.wrap(side)
                if modem.isWireless and modem.isWireless() then
                    logInfo("Wireless modem capabilities detected")
                end
                break
            end
        end
    end

    if not modem_found then
        logError("Hardware check failed", "No modem found - router requires a modem")
        return false
    end

    logSuccess("Hardware requirements met - Modem: " .. modem_side)
    return true, modem_side
end

-- Initialize network interfaces
local function initializeInterfaces(modem_side)
    logInfo("Initializing network interfaces...")

    local success, error = pcall(function()
        -- Open rednet if not already open
        if not rednet.isOpen(modem_side) then
            rednet.open(modem_side)
            logInfo("Rednet opened on side: " .. modem_side)
        else
            logInfo("Rednet already open on side: " .. modem_side)
        end

        -- Set up router as host for various services
        local services = {"router", "dhcp", "dns", "gateway"}
        for _, service in ipairs(services) do
            rednet.host(service, service .. "_" .. os.getComputerID())
            logInfo("Hosting service: " .. service)
        end
    end)

    if success then
        logSuccess("Network interfaces initialized successfully")
        return true
    else
        logError("Failed to initialize network interfaces", error)
        return false
    end
end

-- Start router daemon
local function startRouterDaemon()
    logInfo("Starting router daemon...")

    -- Check if router daemon exists
    local daemon_paths = {
        "/usr/lib/router/routerd.lua",
        "/bin/routerd.lua"
    }

    local daemon_path = nil
    for _, path in ipairs(daemon_paths) do
        if fileExists(path) then
            daemon_path = path
            break
        end
    end

    if not daemon_path then
        logError("Router daemon not found", "Checked: " .. table.concat(daemon_paths, ", "))
        return false
    end

    -- Check if daemon is already running
    if fileExists("/var/run/routerd.pid") then
        logWarning("Router daemon appears to be already running")
        return true
    end

    local success, error = pcall(function()
        -- Start daemon in background
        shell.run("bg", daemon_path)
        logInfo("Router daemon started from: " .. daemon_path)

        -- Wait a moment for daemon to start
        sleep(1)

        -- Verify daemon started by checking PID file
        if fileExists("/var/run/routerd.pid") then
            logSuccess("Router daemon startup verified - PID file created")
        else
            logWarning("Router daemon may not have started properly - no PID file")
        end
    end)

    if success then
        logSuccess("Router daemon startup completed")
        return true
    else
        logError("Failed to start router daemon", error)
        return false
    end
end

-- Start web administration interface
local function startWebAdmin(config)
    if not config or not config.services or not config.services.web_admin or not config.services.web_admin.enabled then
        logInfo("Web administration interface disabled")
        return true
    end

    logInfo("Starting web administration interface...")

    local admin_path = "/usr/lib/router/web_admin.lua"
    if not fileExists(admin_path) then
        logError("Web admin interface not found", admin_path)
        return false
    end

    local success, error = pcall(function()
        -- Load and start web admin
        local WebAdmin = dofile(admin_path)
        if WebAdmin and WebAdmin.new then
            local admin = WebAdmin:new(config)
            if admin and admin.start then
                -- Start in background
                parallel.waitForAny(function()
                    admin:start()
                end)
                logInfo("Web admin interface started on port: " .. (config.services.web_admin.port or 8080))
            end
        end
    end)

    if success then
        logSuccess("Web administration interface started")
        return true
    else
        logError("Failed to start web administration interface", error)
        return false
    end
end

-- Initialize DHCP service
local function initializeDHCP(config)
    if not config or not config.lan or not config.lan.dhcp or not config.lan.dhcp.enabled then
        logInfo("DHCP service disabled")
        return true
    end

    logInfo("Initializing DHCP service...")

    local success, error = pcall(function()
        -- Create DHCP lease file if it doesn't exist
        if not fileExists("/var/lib/dhcp/leases") then
            local lease_file = fs.open("/var/lib/dhcp/leases", "w")
            if lease_file then
                lease_file.write("return {}")
                lease_file.close()
                logInfo("Created empty DHCP lease database")
            end
        end

        -- Log DHCP configuration
        local dhcp_config = config.lan.dhcp
        logInfo("DHCP Range: " .. dhcp_config.start_ip .. " - " .. dhcp_config.end_ip)
        logInfo("DHCP Lease Time: " .. dhcp_config.lease_time .. " seconds")
        logInfo("DHCP Gateway: " .. dhcp_config.gateway)
    end)

    if success then
        logSuccess("DHCP service initialized")
        return true
    else
        logError("Failed to initialize DHCP service", error)
        return false
    end
end

-- Display router status
local function displayRouterStatus(config)
    logInfo("Displaying router status...")

    print()
    print("========== Router Status ==========")
    print("Computer ID: " .. os.getComputerID())
    if config then
        print("Hostname: " .. (config.hostname or "Unknown"))
        print("Router ID: " .. (config.router_id or "Unknown"))
        if config.lan then
            print("LAN IP: " .. (config.lan.ip or "Unknown"))
            if config.lan.dhcp and config.lan.dhcp.enabled then
                print("DHCP: Enabled (" .. config.lan.dhcp.start_ip .. " - " .. config.lan.dhcp.end_ip .. ")")
            else
                print("DHCP: Disabled")
            end
        end
        if config.wireless and config.wireless.enabled then
            print("Wireless: Enabled")
            if config.wireless.ap then
                print("WiFi SSID: " .. (config.wireless.ap.ssid or "Unknown"))
            end
        else
            print("Wireless: Disabled")
        end
        if config.firewall and config.firewall.enabled then
            print("Firewall: Enabled")
        else
            print("Firewall: Disabled")
        end
    end
    print("===================================")
    print()

    logInfo("Router status display completed")
end

-- Main router startup function
local function main()
    local startup_begin = os.epoch("utc")

    print("Router System Startup")
    print("====================")

    logInfo("Router startup initiated")
    logInfo("System Information:")
    logInfo("  ComputerCraft Version: " .. (_HOST or "Unknown"))
    logInfo("  Computer ID: " .. os.getComputerID())
    logInfo("  Computer Label: " .. (os.getComputerLabel() or "None"))

    local overall_success = true

    -- Create required directories
    createRouterDirectories()

    -- Load router configuration
    local config = loadRouterConfig()

    -- Check hardware requirements
    local hardware_ok, modem_side = checkHardware()
    if not hardware_ok then
        logError("Hardware requirements not met", "Cannot continue router startup")
        return false
    end

    -- Initialize network interfaces
    if not initializeInterfaces(modem_side) then
        logError("Network interface initialization failed", "Cannot continue")
        return false
    end

    -- Initialize DHCP service
    if not initializeDHCP(config) then
        logWarning("DHCP initialization failed", "Router will continue without DHCP")
        overall_success = false
    end

    -- Start router daemon
    if not startRouterDaemon() then
        logError("Router daemon startup failed", "Core routing may not work")
        overall_success = false
    end

    -- Start web admin interface
    if config then
        if not startWebAdmin(config) then
            logWarning("Web administration startup failed", "Router will continue without web interface")
            overall_success = false
        end
    end

    -- Display status
    displayRouterStatus(config)

    local startup_duration = os.epoch("utc") - startup_begin

    if overall_success then
        logSuccess("Router startup completed successfully in " .. startup_duration .. "ms")
        print("Router startup complete!")
    else
        logWarning("Router startup completed with some issues in " .. startup_duration .. "ms")
        print("Router startup complete with warnings - check logs/router_startup.log")
    end

    return overall_success
end

-- Run router startup with global error handling
local startup_success, startup_error = pcall(main)

if not startup_success then
    -- Critical startup failure
    writeLog("CRITICAL: Router startup failed completely: " .. tostring(startup_error), "CRITICAL")
    print("CRITICAL ROUTER STARTUP FAILURE")
    print("Check logs/router_startup.log for details")
    print("Error: " .. tostring(startup_error))
end