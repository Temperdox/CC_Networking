-- /network_demo.lua
-- Demo script showing how to use the network system with comprehensive logging

-- Logging utility
local function writeLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_entry = string.format("[%s] [%s] %s", timestamp, level, message)

    print(log_entry)

    if not fs.exists("logs") then
        fs.makeDir("logs")
    end

    local log_file = fs.open("logs/network_demo.log", "a")
    if log_file then
        log_file.writeLine(log_entry)
        log_file.close()
    end
end

local function logInfo(msg) writeLog(msg, "INFO") end
local function logSuccess(msg) writeLog(msg, "SUCCESS") end
local function logError(msg) writeLog(msg, "ERROR") end
local function logWarning(msg) writeLog(msg, "WARNING") end

-- Safe require function
local function safeRequire(module)
    local success, result = pcall(require, module)
    if success then
        logSuccess("Loaded module: " .. module)
        return result
    else
        logError("Failed to load module " .. module .. ": " .. tostring(result))
        return nil
    end
end

-- Load the network library
logInfo("Loading network library...")
local network = safeRequire("lib.network")
if not network then
    logError("Network library not available - demo cannot continue")
    return
end

-- Helper function to print a section
local function printSection(title)
    print()
    print("=== " .. title .. " ===")
    logInfo("Starting section: " .. title)
    print()
end

-- Helper function to print key-value pairs safely
local function printInfo(data)
    for k, v in pairs(data) do
        if type(v) == "table" then
            print(k .. ": [table with " .. #v .. " items]")
        elseif type(v) == "function" then
            print(k .. ": [function]")
        else
            print(k .. ": " .. tostring(v))
        end
    end
end

-- Safe function execution wrapper
local function safeExecute(func, description)
    logInfo("Executing: " .. description)
    local success, result = pcall(func)

    if success then
        logSuccess(description .. " completed")
        return true, result
    else
        logError(description .. " failed: " .. tostring(result))
        return false, result
    end
end

-- Main demo function
local function main()
    local demo_start = os.epoch("utc")

    print("=====================================")
    print(" Network System Demo")
    print("=====================================")

    logInfo("Network system demo started")
    logInfo("Computer ID: " .. os.getComputerID())
    logInfo("Computer Label: " .. (os.getComputerLabel() or "None"))

    -- Check if netd is running
    printSection("Network Daemon Status")
    local daemon_running = false
    safeExecute(function()
        if network.isDaemonRunning() then
            print("✓ Network daemon (netd) is running")
            logSuccess("Network daemon is running")
            daemon_running = true
        else
            print("✗ Network daemon (netd) is not running")
            logError("Network daemon is not running")
            print("Please run startup.lua first")
        end
    end, "Daemon status check")

    if not daemon_running then
        logError("Demo cannot continue without network daemon")
        return
    end

    -- Get network info
    printSection("Network Information")
    local info = nil
    safeExecute(function()
        info = network.getInfo()
        if info then
            printInfo(info)
            logInfo("Network info retrieved successfully")
        else
            logWarning("No network info available")
        end
    end, "Network info retrieval")

    -- Get network statistics
    printSection("Network Statistics")
    safeExecute(function()
        local stats = network.getStats()
        if stats then
            print("Packets sent: " .. (stats.packets_sent or 0))
            print("Packets received: " .. (stats.packets_received or 0))
            print("Bytes sent: " .. network.formatBytes(stats.bytes_sent or 0))
            print("Bytes received: " .. network.formatBytes(stats.bytes_received or 0))
            print("Errors: " .. (stats.errors or 0))
            print("Uptime: " .. math.floor((stats.uptime or 0) / 1000) .. " seconds")
            logInfo("Network statistics displayed")
        else
            print("No statistics available")
            logWarning("Network statistics not available")
        end
    end, "Network statistics retrieval")

    -- Discover local network devices
    printSection("Network Discovery")
    local devices = {}
    safeExecute(function()
        print("Discovering devices on local network...")
        logInfo("Starting network discovery (3 second timeout)")
        devices = network.discover(3)

        if next(devices) then
            local device_count = 0
            for _ in pairs(devices) do device_count = device_count + 1 end

            print("Found " .. device_count .. " device(s):")
            logSuccess("Discovered " .. device_count .. " network devices")
            print()

            for ip, device in pairs(devices) do
                print("  Device: " .. (device.hostname or "unknown"))
                print("    IP: " .. (device.ip or ip))
                print("    MAC: " .. (device.mac or "unknown"))
                print("    ID: " .. (device.id or "unknown"))

                if device.services and next(device.services) then
                    print("    Services:")
                    for service, port in pairs(device.services) do
                        print("      - " .. service .. " on port " .. port)
                    end
                end
                print()

                logInfo("Found device: " .. (device.hostname or ip))
            end
        else
            print("No other devices found on network")
            print("(Make sure other computers are running netd)")
            logWarning("No network devices discovered")
        end
    end, "Network device discovery")

    -- DNS resolution demo
    printSection("DNS Resolution")
    if info then
        local hostnames = {"localhost", info.hostname}

        -- Add other discovered hostnames
        for ip, device in pairs(devices) do
            if device.hostname and device.hostname ~= info.hostname then
                table.insert(hostnames, device.hostname)
            end
        end

        for _, hostname in ipairs(hostnames) do
            safeExecute(function()
                local ip = network.resolve(hostname)
                if ip then
                    print(hostname .. " -> " .. ip)
                    logInfo("DNS resolved: " .. hostname .. " -> " .. ip)
                else
                    print(hostname .. " -> [not resolved]")
                    logWarning("DNS resolution failed: " .. hostname)
                end
            end, "DNS resolution for " .. hostname)
        end
    end

    -- Ping demo
    printSection("Ping Test")
    safeExecute(function()
        print("Pinging localhost...")
        logInfo("Starting ping test to localhost")
        local result = network.ping("localhost", 3)

        if result then
            print("Ping statistics for " .. result.host .. ":")
            print("  Packets: Sent = " .. result.sent ..
                    ", Received = " .. result.received ..
                    ", Lost = " .. result.lost ..
                    " (" .. string.format("%.0f%%", result.loss) .. " loss)")
            if #result.times > 0 then
                print("  Round trip times:")
                print("    Min = " .. result.min .. "ms")
                print("    Max = " .. result.max .. "ms")
                print("    Avg = " .. string.format("%.1f", result.avg) .. "ms")
                logSuccess("Ping test completed - avg " .. string.format("%.1f", result.avg) .. "ms")
            else
                logWarning("Ping test completed but no response times recorded")
            end
        else
            print("Ping failed")
            logError("Ping test failed completely")
        end
    end, "Ping test to localhost")

    -- HTTP demo
    printSection("HTTP Demo")
    local httpTarget = nil
    for ip, device in pairs(devices) do
        if device.services and device.services.http then
            httpTarget = device
            break
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
                print("Response body: " .. body)
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

    -- Create a simple HTTP server demo
    printSection("HTTP Server Demo")
    safeExecute(function()
        print("Creating HTTP server on port 8888...")
        logInfo("Starting HTTP server on port 8888")

        local serverRunning = false
        parallel.waitForAny(
                function()
                    -- Server thread
                    network.createServer(8888, function(request)
                        local msg = "Received " .. request.method .. " request to " .. request.path
                        print(msg)
                        logInfo("HTTP Server: " .. msg)

                        return {
                            code = 200,
                            headers = {["Content-Type"] = "text/plain"},
                            body = "Hello from " .. (info and info.hostname or "unknown") .. "!\nTime: " .. os.date()
                        }
                    end)
                end,
                function()
                    -- Client thread
                    sleep(1) -- Give server time to start

                    print("Server started. Testing with local request...")
                    logInfo("Testing local HTTP connection to demo server")

                    local response = network.http("http://localhost:8888/test", {
                        method = "GET"
                    })

                    if response then
                        local body = response.readAll()
                        print("Response: " .. body)
                        response.close()
                        logSuccess("Local HTTP test successful")
                    else
                        print("Failed to connect to local server")
                        logError("Local HTTP test failed")
                    end

                    print()
                    print("Server is running on port 8888")
                    if info then
                        print("Other computers can connect to:")
                        print("  http://" .. info.ip .. ":8888/")
                        print("  http://" .. info.hostname .. ".local:8888/")
                    end
                    print()
                    print("Press any key to stop the demo...")
                    logInfo("HTTP server demo ready - waiting for user input")
                    os.pullEvent("key")
                    logInfo("User requested demo stop")
                end
        )
    end, "HTTP server demo")

    local demo_duration = os.epoch("utc") - demo_start

    printSection("Demo Complete")
    print("The network system is working correctly!")
    print()
    print("You can now use the network library in your")
    print("programs with: local network = require('lib.network')")
    print()
    print("Check logs/network_demo.log for detailed execution log")

    logSuccess("Network demo completed successfully in " .. demo_duration .. "ms")
    logInfo("Demo execution summary logged")
end

-- Run the demo with error handling
logInfo("=== NETWORK DEMO BEGIN ===")

local demo_success, demo_error = pcall(main)

if not demo_success then
    writeLog("CRITICAL: Network demo failed: " .. tostring(demo_error), "CRITICAL")
    print("NETWORK DEMO FAILURE")
    print("Error: " .. tostring(demo_error))
    print("Check logs/network_demo.log for details")
end

logInfo("=== NETWORK DEMO END ===")