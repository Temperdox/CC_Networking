-- test_network.lua
-- Main network protocol testing menu system
-- Allows testing of all implemented network protocols

local function printHeader(text)
    term.clear()
    term.setCursorPos(1, 1)
    print(string.rep("=", 50))
    print("  " .. text)
    print(string.rep("=", 50))
end

local function printColored(text, color)
    if term.isColor() then
        term.setTextColor(color or colors.white)
    end
    print(text)
    if term.isColor() then
        term.setTextColor(colors.white)
    end
end

-- Protocol list with display names and test files
local PROTOCOLS = {
    {id = "websocket", name = "WebSocket", file = "/tests/test_websocket.lua"},
    {id = "http", name = "HTTP", file = "/tests/test_http.lua"},
    {id = "https", name = "HTTPS", file = "/tests/test_https.lua"},
    {id = "webrtc", name = "WebRTC", file = "/tests/test_webrtc.lua"},
    {id = "tcp", name = "TCP", file = "/tests/test_tcp.lua"},
    {id = "udp", name = "UDP", file = "/tests/test_udp.lua"},
    {id = "mqtt", name = "MQTT", file = "/tests/test_mqtt.lua"},
    {id = "ftp", name = "FTP", file = "/tests/test_ftp.lua"},
    {id = "ssh", name = "SSH", file = "/tests/test_ssh.lua"}
}

-- Check system status
local function checkSystemStatus()
    local status = {
        modem = peripheral.find("modem") ~= nil,
        netd = fs.exists("/var/run/netd.pid"),
        network_lib = fs.exists("/lib/network.lua"),
        protocols_dir = fs.exists("/protocols"),
        tests_dir = fs.exists("/tests")
    }

    printHeader("System Status Check")
    print()

    printColored("Core Components:", colors.cyan)
    printColored(string.format("  [%s] Modem Available",
            status.modem and "OK" or "FAIL"),
            status.modem and colors.green or colors.red)

    printColored(string.format("  [%s] Network Daemon (netd)",
            status.netd and "OK" or "FAIL"),
            status.netd and colors.green or colors.red)

    printColored(string.format("  [%s] Network Library",
            status.network_lib and "OK" or "FAIL"),
            status.network_lib and colors.green or colors.red)

    printColored(string.format("  [%s] Protocols Directory",
            status.protocols_dir and "OK" or "FAIL"),
            status.protocols_dir and colors.green or colors.red)

    print()
    printColored("Protocol Availability:", colors.cyan)

    -- Check each protocol
    for _, proto in ipairs(PROTOCOLS) do
        local protocol_file = "/protocols/" .. proto.id .. ".lua"
        local test_file = proto.file
        local protocol_exists = fs.exists(protocol_file)
        local test_exists = fs.exists(test_file)

        local status_text = "Not Installed"
        local status_color = colors.red

        if protocol_exists and test_exists then
            status_text = "Ready"
            status_color = colors.green
        elseif protocol_exists then
            status_text = "No Test"
            status_color = colors.yellow
        elseif test_exists then
            status_text = "No Protocol"
            status_color = colors.orange
        end

        printColored(string.format("  %-12s: %s", proto.name, status_text), status_color)
    end

    print()
    return status
end

-- Create test directory if it doesn't exist
local function ensureTestDirectory()
    if not fs.exists("/tests") then
        fs.makeDir("/tests")
        printColored("Created /tests directory", colors.green)
    end
end

-- Create a basic test file for a protocol if it doesn't exist
local function createBasicTestFile(protocol)
    local testCode = string.format([[
-- test_%s.lua
-- Test script for %s protocol

local function printHeader(text)
    print("\n" .. string.rep("=", 40))
    print(text)
    print(string.rep("=", 40))
end

local function test_%s()
    printHeader("%s Protocol Test")

    -- Check if protocol exists
    local protocol_file = "/protocols/%s.lua"
    if not fs.exists(protocol_file) then
        print("\nERROR: %s protocol not installed!")
        print("Please install the protocol first.")
        return false
    end

    -- Load protocol
    local success, %s = pcall(dofile, protocol_file)
    if not success then
        print("\nERROR: Failed to load %s protocol")
        print(%s)
        return false
    end

    print("\n%s protocol loaded successfully!")

    -- TODO: Add specific tests for %s
    print("\nTest implementation pending...")
    print("Protocol appears to be installed correctly.")

    return true
end

-- Main test function
local function main()
    local success = test_%s()

    print("\nTest " .. (success and "PASSED" or "FAILED"))
    print("\nPress any key to return to menu...")
    os.pullEvent("key")
end

main()
]], protocol.id, protocol.name, protocol.id, protocol.name,
            protocol.id, protocol.name, protocol.id, protocol.name,
            protocol.id, protocol.name, protocol.name, protocol.id)

    local file = fs.open(protocol.file, "w")
    if file then
        file.write(testCode)
        file.close()
        return true
    end
    return false
end

-- Run a protocol test
local function runProtocolTest(protocol)
    printHeader("Running " .. protocol.name .. " Test")

    -- Check if test file exists
    if not fs.exists(protocol.file) then
        print()
        printColored("Test file not found: " .. protocol.file, colors.yellow)
        print("\nWould you like to create a basic test file? (y/n)")
        local answer = read()

        if answer:lower() == "y" then
            if createBasicTestFile(protocol) then
                printColored("Created basic test file: " .. protocol.file, colors.green)
                print("\nPress any key to run the test...")
                os.pullEvent("key")
            else
                printColored("Failed to create test file", colors.red)
                print("\nPress any key to return...")
                os.pullEvent("key")
                return
            end
        else
            print("\nPress any key to return...")
            os.pullEvent("key")
            return
        end
    end

    -- Check if protocol exists
    local protocol_file = "/protocols/" .. protocol.id .. ".lua"
    if not fs.exists(protocol_file) then
        print()
        printColored("Warning: Protocol not installed: " .. protocol_file, colors.yellow)
        print("Test may fail without the protocol implementation.")
        print("\nContinue anyway? (y/n)")
        local answer = read()
        if answer:lower() ~= "y" then
            return
        end
    end

    -- Run the test
    print("\nStarting test...")
    sleep(1)

    -- Execute test file
    local success, error = pcall(function()
        shell.run(protocol.file)
    end)

    if not success then
        print()
        printColored("Test failed with error:", colors.red)
        print(error)
        print("\nPress any key to return...")
        os.pullEvent("key")
    end
end

-- Show main menu
local function showMainMenu()
    while true do
        printHeader("Network Protocol Test Suite")
        print()
        printColored("Select a protocol to test:", colors.cyan)
        print()

        -- Display protocol options
        for i, proto in ipairs(PROTOCOLS) do
            local protocol_file = "/protocols/" .. proto.id .. ".lua"
            local test_file = proto.file
            local status = ""

            if fs.exists(protocol_file) and fs.exists(test_file) then
                status = "[Ready]"
            elseif fs.exists(protocol_file) then
                status = "[No Test]"
            elseif fs.exists(test_file) then
                status = "[No Protocol]"
            else
                status = "[Not Available]"
            end

            print(string.format("%d. %-12s %s", i, proto.name, status))
        end

        print()
        print("S. System Status")
        print("A. Run All Available Tests")
        print("C. Create Missing Test Files")
        print("Q. Quit")
        print()
        print("Enter your choice: ")

        local choice = read():lower()

        if choice == "q" then
            printHeader("Exiting Test Suite")
            print("\nThank you for testing!")
            break
        elseif choice == "s" then
            checkSystemStatus()
            print("\nPress any key to continue...")
            os.pullEvent("key")
        elseif choice == "a" then
            -- Run all available tests
            printHeader("Running All Available Tests")
            local testsRun = 0

            for _, proto in ipairs(PROTOCOLS) do
                if fs.exists(proto.file) and fs.exists("/protocols/" .. proto.id .. ".lua") then
                    print("\n" .. string.rep("-", 40))
                    print("Running " .. proto.name .. " test...")
                    runProtocolTest(proto)
                    testsRun = testsRun + 1
                end
            end

            if testsRun == 0 then
                printColored("\nNo tests available to run!", colors.yellow)
                print("\nPress any key to continue...")
                os.pullEvent("key")
            else
                print("\n" .. string.rep("=", 40))
                printColored("Completed " .. testsRun .. " tests", colors.green)
                print("\nPress any key to continue...")
                os.pullEvent("key")
            end
        elseif choice == "c" then
            -- Create missing test files
            printHeader("Creating Missing Test Files")
            local created = 0

            for _, proto in ipairs(PROTOCOLS) do
                if not fs.exists(proto.file) then
                    print("Creating " .. proto.file .. "...")
                    if createBasicTestFile(proto) then
                        printColored("  Created", colors.green)
                        created = created + 1
                    else
                        printColored("  Failed", colors.red)
                    end
                end
            end

            if created > 0 then
                printColored("\nCreated " .. created .. " test files", colors.green)
            else
                printColored("\nNo test files needed to be created", colors.yellow)
            end

            print("\nPress any key to continue...")
            os.pullEvent("key")
        else
            -- Try to parse as number for protocol selection
            local num = tonumber(choice)
            if num and num >= 1 and num <= #PROTOCOLS then
                runProtocolTest(PROTOCOLS[num])
            else
                printColored("Invalid choice. Please try again.", colors.red)
                sleep(1)
            end
        end
    end
end

-- Main program
local function main()
    -- Ensure test directory exists
    ensureTestDirectory()

    -- Check for critical components
    if not peripheral.find("modem") then
        printHeader("Critical Error")
        printColored("\nNo modem found!", colors.red)
        print("Network testing requires a modem.")
        print("\nPlease attach a modem and try again.")
        return
    end

    -- Show welcome message
    printHeader("Welcome to Network Protocol Test Suite")
    print()
    print("This suite allows you to test various network")
    print("protocols implemented in the CC Networking system.")
    print()
    printColored("Press any key to continue...", colors.cyan)
    os.pullEvent("key")

    -- Run main menu
    showMainMenu()
end

-- Run the test suite
main()