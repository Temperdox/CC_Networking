-- /network_demo.lua
-- Demo script showing how to use the network system

-- Load the network library
local network = require("/lib/network")

-- Helper function to print a section
local function printSection(title)
    print()
    print("=== " .. title .. " ===")
    print()
end

-- Helper function to print key-value pairs
local function printInfo(data)
    for k, v in pairs(data) do
        if type(v) == "table" then
            print(k .. ": [table]")
        else
            print(k .. ": " .. tostring(v))
        end
    end
end

-- Main demo function
local function main()
    print("=====================================")
    print(" Network System Demo")
    print("=====================================")

    -- Check if netd is running
    printSection("Network Daemon Status")
    if network.isDaemonRunning() then
        print("✓ Network daemon (netd) is running")
    else
        print("✗ Network daemon (netd) is not running")
        print("Please run startup.lua first")
        return
    end

    -- Get network info
    printSection("Network Information")
    local info = network.getInfo()
    printInfo(info)

    -- Get network statistics
    printSection("Network Statistics")
    local stats = network.getStats()
    if stats then
        print("Packets sent: " .. stats.packets_sent)
        print("Packets received: " .. stats.packets_received)
        print("Bytes sent: " .. network.formatBytes(stats.bytes_sent))
        print("Bytes received: " .. network.formatBytes(stats.bytes_received))
        print("Errors: " .. stats.errors)
        print("Uptime: " .. math.floor(stats.uptime / 1000) .. " seconds")
    else
        print("No statistics available")
    end

    -- Discover local network devices
    printSection("Network Discovery")
    print("Discovering devices on local network...")
    local devices = network.discover(3)

    if next(devices) then
        print("Found " .. table.getn(devices) .. " device(s):")
        print()
        for ip, device in pairs(devices) do
            print("  Device: " .. (device.hostname or "unknown"))
            print("    IP: " .. (device.ip or ip))
            print("    MAC: " .. (device.mac or "unknown"))
            print("    ID: " .. device.id)
            if device.services and next(device.services) then
                print("    Services:")
                for service, port in pairs(device.services) do
                    print("      - " .. service .. " on port " .. port)
                end
            end
            print()
        end
    else
        print("No other devices found on network")
        print("(Make sure other computers are running netd)")
    end

    -- DNS resolution demo
    printSection("DNS Resolution")
    local hostnames = {"localhost", info.hostname, "google.com", "cc-1"}

    for _, hostname in ipairs(hostnames) do
        local ip = network.resolve(hostname)
        if ip then
            print(hostname .. " -> " .. ip)
        else
            print(hostname .. " -> [not resolved]")
        end
    end

    -- Ping demo
    printSection("Ping Test")
    print("Pinging localhost...")
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
        end
    else
        print("Ping failed")
    end

    -- HTTP demo (if another computer is available)
    printSection("HTTP Demo")

    -- Try to find another computer with HTTP service
    local httpTarget = nil
    for ip, device in pairs(devices) do
        if device.services and device.services.http then
            httpTarget = device
            break
        end
    end

    if httpTarget then
        print("Testing HTTP connection to " .. httpTarget.hostname)
        local response = network.http("http://" .. httpTarget.ip .. "/test", {
            method = "GET"
        })

        if response then
            print("Response code: " .. response.getResponseCode())
            print("Response body: " .. response.readAll())
            response.close()
        else
            print("HTTP request failed")
        end
    else
        print("No HTTP servers found on network")
    end

    -- Create a simple HTTP server
    printSection("HTTP Server Demo")
    print("Creating HTTP server on port 8888...")

    -- Fork to run server
    local serverRunning = false
    parallel.waitForAny(
            function()
                -- Server thread
                network.createServer(8888, function(request)
                    print("Received " .. request.method .. " request to " .. request.path)
                    return {
                        code = 200,
                        headers = {["Content-Type"] = "text/plain"},
                        body = "Hello from " .. info.hostname .. "!"
                    }
                end)
            end,
            function()
                -- Client thread
                sleep(1) -- Give server time to start

                print("Server started. Testing with local request...")
                local response = network.http("http://localhost:8888/test", {
                    method = "GET"
                })

                if response then
                    print("Response: " .. response.readAll())
                    response.close()
                else
                    print("Failed to connect to local server")
                end

                print()
                print("Server is running on port 8888")
                print("Other computers can connect to:")
                print("  http://" .. info.ip .. ":8888/")
                print("  http://" .. info.hostname .. ".local:8888/")
                print()
                print("Press any key to stop the demo...")
                os.pullEvent("key")
            end
    )

    printSection("Demo Complete")
    print("The network system is working correctly!")
    print()
    print("You can now use the network library in your")
    print("programs with: local network = require('/lib/network')")
end

-- Run the demo
main()