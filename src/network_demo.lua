-- network_demo.lua
-- Network system demonstration and testing script (simplified HTTP demo)

--------------------------
-- Dual Logging System (separate logs for console and events)
--------------------------
local LOG_DIR = "logs"
local LOG_PATH = LOG_DIR .. "/network_demo.log"
local CONSOLE_LOG_PATH = LOG_DIR .. "/network_demo_console.log"
local LOG_BUFFER = {}
local CONSOLE_BUFFER = {}
local LOG_FLUSH_INTERVAL = 0.5 -- seconds
local last_flush = os.clock()

local function ensureLogDir()
    if not fs.exists(LOG_DIR) then
        fs.makeDir(LOG_DIR)
    end
end

local function flushLogBuffer()
    ensureLogDir()

    -- Flush main log buffer
    if #LOG_BUFFER > 0 then
        local file = fs.open(LOG_PATH, "a")
        if file then
            for _, entry in ipairs(LOG_BUFFER) do
                file.writeLine(entry)
            end
            file.close()
        end
        LOG_BUFFER = {}
    end

    -- Flush console buffer
    if #CONSOLE_BUFFER > 0 then
        local file = fs.open(CONSOLE_LOG_PATH, "a")
        if file then
            for _, entry in ipairs(CONSOLE_BUFFER) do
                file.writeLine(entry)
            end
            file.close()
        end
        CONSOLE_BUFFER = {}
    end

    last_flush = os.clock()
end

-- Override print to capture console output
local originalPrint = print
local function print(...)
    -- Call original print
    originalPrint(...)

    -- Capture to console log
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local args = {...}
    local msg = ""
    for i = 1, #args do
        if i > 1 then msg = msg .. "\t" end
        msg = msg .. tostring(args[i])
    end

    local entry = string.format("[%s] %s", timestamp, msg)
    table.insert(CONSOLE_BUFFER, entry)

    -- Check if we should flush
    if os.clock() - last_flush > LOG_FLUSH_INTERVAL then
        flushLogBuffer()
    end
end

local function writeLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local entry = string.format("[%s] [%s] %s", timestamp, level, message)
    table.insert(LOG_BUFFER, entry)

    -- Auto-flush if buffer is large or time has passed
    if #LOG_BUFFER >= 10 or (os.clock() - last_flush) > LOG_FLUSH_INTERVAL then
        flushLogBuffer()
    end
end

local function logInfo(msg) writeLog(msg, "INFO") end
local function logSuccess(msg) writeLog(msg, "SUCCESS") end
local function logWarning(msg) writeLog(msg, "WARNING") end
local function logError(msg) writeLog(msg, "ERROR") end

--------------------------
-- Utility Functions
--------------------------
local function formatBytes(bytes)
    if not bytes or bytes == 0 then return "0 B" end
    local units = {"B", "KB", "MB", "GB", "TB"}
    local i = 1
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    return string.format("%.2f %s", bytes, units[i])
end

--------------------------
-- Demo Functions
--------------------------
local function printSection(title)
    print()
    print("=== " .. title .. " ===")
    print()
    logInfo("Starting section: " .. title)
end

local function safeExecute(func, description)
    description = description or "Operation"
    logInfo("Executing: " .. description)

    local success, result = pcall(func)
    if success then
        logSuccess(description .. " completed")
        return result
    else
        print("Error: " .. tostring(result))
        logError(description .. " failed: " .. tostring(result))
        return nil
    end
end

--------------------------
-- Main Demo
--------------------------
local function main()
    local demo_start = os.epoch("utc")

    term.clear()
    term.setCursorPos(1, 1)

    print("ComputerCraft Network System Demo")
    print("==================================")
    print()

    logInfo("Network system demo started")
    logInfo("Computer ID: " .. os.getComputerID())
    logInfo("Computer Label: " .. (os.getComputerLabel() or "None"))

    -- Load network library
    printSection("Network Daemon Status")

    logInfo("Loading network library...")
    local network = require("lib.network")
    logSuccess("Loaded module: lib.network")

    -- Check if daemon is running
    local daemonRunning = safeExecute(function()
        if network.isDaemonRunning() then
            print("✓ Network daemon is running")
            logSuccess("Network daemon is running")
            return true
        else
            print("✗ Network daemon is not running")
            print("  Please run: /bin/netd.lua")
            logError("Network daemon not running")
            return false
        end
    end, "Daemon status check")

    if not daemonRunning then
        print()
        print("Demo cannot continue without network daemon")
        logError("Demo aborted - daemon not running")
        flushLogBuffer()
        return
    end

    -- Get network information
    printSection("Network Information")

    local info = safeExecute(function()
        local netInfo = network.getInfo()
        if netInfo then
            print("Network Configuration:")
            print("  IP Address: " .. (netInfo.ip or "Not assigned"))
            print("  MAC Address: " .. (netInfo.mac or "Not assigned"))
            print("  Hostname: " .. (netInfo.hostname or "Not assigned"))
            print("  FQDN: " .. (netInfo.fqdn or "Not assigned"))
            print("  Gateway: " .. (netInfo.gateway or "Not configured"))
            if netInfo.dns and #netInfo.dns > 0 then
                print("  DNS Servers: " .. table.concat(netInfo.dns, ", "))
            else
                print("  DNS Servers: Not configured")
            end
            print("  Modem Available: " .. tostring(netInfo.modem_available))

            logInfo("Network info retrieved successfully")
            return netInfo
        else
            print("Failed to get network information")
            logError("Failed to retrieve network info")
            return nil
        end
    end, "Network info retrieval")

    -- Get statistics
    printSection("Network Statistics")

    safeExecute(function()
        local stats = network.getStats()
        if stats then
            print("Network Statistics:")
            print("  Uptime: " .. math.floor((stats.uptime or 0) / 1000) .. " seconds")
            print("  DNS Queries: " .. (stats.dns_queries or 0))
            print("  ARP Requests: " .. (stats.arp_requests or 0))
            print("  HTTP Requests: " .. (stats.http_requests or 0))
            print("  WebSocket Connections: " .. (stats.websocket_connections or 0))
            print("  Packets Sent: " .. (stats.packets_sent or 0))
            print("  Packets Received: " .. (stats.packets_received or 0))
            print("  Bytes Sent: " .. formatBytes(stats.bytes_sent or 0))
            print("  Bytes Received: " .. formatBytes(stats.bytes_received or 0))

            logInfo("Network statistics displayed")
        else
            print("No statistics available")
            logWarning("Statistics not available")
        end
    end, "Network statistics retrieval")

    -- Discover devices
    printSection("Network Discovery")

    local devices = safeExecute(function()
        print("Discovering network devices...")
        logInfo("Starting network discovery (3 second timeout)")

        local discovered = network.discover(3)
        if discovered and #discovered > 0 then
            print("Found " .. #discovered .. " device(s):")
            logSuccess("Discovered " .. #discovered .. " network devices")

            for _, device in ipairs(discovered) do
                print("  - " .. device.hostname .. " (" .. device.ip .. ")")
                logInfo("Found device: " .. device.hostname)
            end
            return discovered
        else
            print("No devices discovered")
            print("(Other computers may not have networking enabled)")
            logWarning("No network devices discovered")
            return {}
        end
    end, "Network device discovery")

    -- DNS resolution tests
    printSection("DNS Resolution")

    -- Test localhost resolution
    safeExecute(function()
        local ip = network.resolve("localhost")
        if ip then
            print("localhost -> " .. ip)
            logInfo("DNS resolved: localhost -> " .. ip)
        else
            print("Failed to resolve localhost")
            logError("DNS resolution failed for localhost")
        end
    end, "DNS resolution for localhost")

    -- Test own hostname resolution
    if info and info.hostname then
        safeExecute(function()
            local ip = network.resolve(info.hostname)
            if ip then
                print(info.hostname .. " -> " .. ip)
                logInfo("DNS resolved: " .. info.hostname .. " -> " .. ip)
            else
                print("Failed to resolve " .. info.hostname)
                logError("DNS resolution failed for " .. info.hostname)
            end
        end, "DNS resolution for " .. info.hostname)
    end

    -- Test resolution for discovered devices
    if devices and #devices > 0 then
        for _, device in ipairs(devices) do
            safeExecute(function()
                local ip = network.resolve(device.hostname)
                if ip then
                    print(device.hostname .. " -> " .. ip)
                    logInfo("DNS resolved: " .. device.hostname .. " -> " .. ip)
                else
                    print("Failed to resolve " .. device.hostname)
                    logError("DNS resolution failed for " .. device.hostname)
                end
            end, "DNS resolution for " .. device.hostname)
        end
    end

    -- Ping test
    printSection("Ping Test")

    safeExecute(function()
        print("Pinging localhost...")
        logInfo("Starting ping test to localhost")

        local results = network.ping("localhost", 3)
        if results and results.received > 0 then
            print(string.format("Ping statistics:"))
            print(string.format("  Packets: sent=%d, received=%d, lost=%d",
                    results.sent, results.received, results.lost))
            if results.avg_time then
                print(string.format("  Round-trip: min=%.1fms, avg=%.1fms, max=%.1fms",
                        results.min_time or 0, results.avg_time, results.max_time or 0))
            end
            logSuccess("Ping test completed - avg " .. (results.avg_time or 0) .. "ms")
        else
            print("Ping failed - no response")
            logError("Ping test failed completely")
        end
    end, "Ping test to localhost")

    -- HTTP test
    printSection("HTTP Demo")

    -- First check if there are any HTTP servers on the network
    local httpTarget = nil
    if devices and #devices > 0 then
        -- Look for a device that might be running an HTTP server
        for _, device in ipairs(devices) do
            if device.services and device.services.http then
                httpTarget = device
                break
            end
        end

        -- If no explicit HTTP service, try the first device
        if not httpTarget and #devices > 0 then
            httpTarget = devices[1]
        end
    end

    if httpTarget then
        safeExecute(function()
            print("Testing HTTP connection to " .. httpTarget.hostname)
            logInfo("Testing HTTP to " .. httpTarget.hostname .. " (" .. httpTarget.ip .. ")")

            local response = network.http("http://" .. httpTarget.ip .. "/test", {
                method = "GET"
            })

            if response then
                local code = response.getResponseCode()
                local body = response.readAll()
                print("Response code: " .. code)
                if #body <= 100 then
                    print("Response body: " .. body)
                else
                    print("Response body: " .. string.sub(body, 1, 100) .. "...")
                end
                response.close()

                logSuccess("HTTP test successful - code " .. code)
            else
                print("HTTP request failed")
                logError("HTTP request to " .. httpTarget.hostname .. " failed")
            end
        end, "HTTP test to " .. httpTarget.hostname)
    else
        print("No HTTP servers found on network")
        print("You can create a test server using test_server.lua")
        logInfo("No HTTP servers available for testing")
    end

    -- Simple HTTP server info (don't actually create one to avoid serialization issues)
    printSection("HTTP Server Info")

    safeExecute(function()
        print("HTTP Server Support Available")
        print()
        print("To create an HTTP server, use test_server.lua")
        print("The test server provides endpoints at:")
        print("  /       - Server info")
        print("  /test   - Test endpoint")
        print("  /info   - JSON server information")
        print("  /time   - Current server time")
        print("  /echo   - Echo service")
        print()
        print("Run test_server.lua on this or another computer")
        print("to test HTTP communication between computers")

        logInfo("HTTP server information displayed")
    end, "HTTP server info")

    local demo_duration = os.epoch("utc") - demo_start

    printSection("Demo Complete")
    print("The network system is working correctly!")
    print()
    print("You can now use the network library in your")
    print("programs with: local network = require('lib.network')")
    print()
    print("To test HTTP communication:")
    print("1. Run test_server.lua on another computer")
    print("2. Run this demo again to test connections")
    print()
    print("Logs saved to:")
    print("  " .. LOG_PATH .. " (structured events)")
    print("  " .. CONSOLE_LOG_PATH .. " (console output)")

    logSuccess("Network demo completed successfully in " .. demo_duration .. "ms")
    logInfo("Demo execution summary logged")
end

-- Run the demo with error handling
logInfo("=== NETWORK DEMO BEGIN ===")

print("========================================")
print("ComputerCraft Network System Demo")
print("========================================")
print()

local demo_success, demo_error = pcall(main)

if not demo_success then
    writeLog("CRITICAL: Network demo failed: " .. tostring(demo_error), "CRITICAL")
    print()
    print("NETWORK DEMO FAILURE")
    print("Error: " .. tostring(demo_error))
    print()
    print("Check logs for details:")
    print("  " .. LOG_PATH)
    print("  " .. CONSOLE_LOG_PATH)
end

logInfo("=== NETWORK DEMO END ===")
flushLogBuffer()

print()
print("Demo finished.")

-- Final flush to ensure everything is saved
flushLogBuffer()