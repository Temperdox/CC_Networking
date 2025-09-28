-- /tests/test_http.lua
-- HTTP Protocol Test Script

local LOG_DIR = "logs"
local LOG_PATH = LOG_DIR .. "/test_http.log"
local CONSOLE_LOG_PATH = LOG_DIR .. "/test_http_console.log"
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

local function printHeader(text)
    print("\n" .. string.rep("=", 45))
    print("  " .. text)
    print(string.rep("=", 45))
end

local function printStatus(success, message)
    if success then
        print("[PASS] " .. message)
    else
        print("[FAIL] " .. message)
    end
end

-- Test basic HTTP GET request
local function testHttpGet()
    printHeader("HTTP GET Test")

    -- Test external HTTP
    print("\n1. Testing External HTTP GET...")
    local response = http.get("http://httpbin.org/get")

    if response then
        local code = response.getResponseCode()
        local body = response.readAll()
        response.close()

        printStatus(code == 200, "GET request returned code " .. code)
        printStatus(body:find("args"), "Response contains expected data")

        -- Parse response
        local success, data = pcall(textutils.unserialiseJSON, body)
        if success then
            print("  User-Agent: " .. (data.headers["User-Agent"] or "unknown"))
            printStatus(true, "JSON response parsed successfully")
        end
    else
        printStatus(false, "GET request failed")
    end

    -- Test with network library if available
    if fs.exists("/lib/network.lua") then
        local network = dofile("/lib/network.lua")

        print("\n2. Testing Local HTTP GET...")

        -- Start local HTTP server
        local testData = "Hello from local server!"
        local server = network.httpServer(8080, function(request)
            if request.path == "/test" then
                return {
                    code = 200,
                    headers = {["Content-Type"] = "text/plain"},
                    body = testData
                }
            else
                return {code = 404, body = "Not Found"}
            end
        end)

        if server then
            -- Test in parallel
            parallel.waitForAny(
                    function() server:listen() end,
                    function()
                        sleep(1)

                        local response = network.http("http://localhost:8080/test")
                        if response then
                            local body = response.readAll()
                            printStatus(body == testData, "Local GET successful")
                            response.close()
                        else
                            printStatus(false, "Local GET failed")
                        end

                        server:stop()
                    end
            )
        end
    end

    return true
end

-- Test HTTP POST request
local function testHttpPost()
    printHeader("HTTP POST Test")

    print("\n1. Testing External HTTP POST...")

    local postData = textutils.serialiseJSON({
        test = "data",
        number = 42,
        array = {1, 2, 3}
    })

    local response = http.post(
            "http://httpbin.org/post",
            postData,
            {["Content-Type"] = "application/json"}
    )

    if response then
        local code = response.getResponseCode()
        local body = response.readAll()
        response.close()

        printStatus(code == 200, "POST request returned code " .. code)

        local success, data = pcall(textutils.unserialiseJSON, body)
        if success and data.json then
            printStatus(data.json.test == "data", "POST data received correctly")
            printStatus(data.json.number == 42, "Numeric data preserved")
        else
            printStatus(false, "Failed to verify POST data")
        end
    else
        printStatus(false, "POST request failed")
    end

    -- Test with network library
    if fs.exists("/lib/network.lua") then
        local network = dofile("/lib/network.lua")

        print("\n2. Testing Local HTTP POST...")

        local server = network.httpServer(8081, function(request)
            if request.method == "POST" then
                return {
                    code = 200,
                    headers = {["Content-Type"] = "application/json"},
                    body = textutils.serialiseJSON({
                        received = request.body,
                        method = request.method
                    })
                }
            end
            return {code = 405, body = "Method Not Allowed"}
        end)

        if server then
            parallel.waitForAny(
                    function() server:listen() end,
                    function()
                        sleep(1)

                        local response = network.http("http://localhost:8081", {
                            method = "POST",
                            body = "Test POST data"
                        })

                        if response then
                            local body = response.readAll()
                            local success, data = pcall(textutils.unserialiseJSON, body)
                            printStatus(success and data.received == "Test POST data",
                                    "Local POST successful")
                            response.close()
                        else
                            printStatus(false, "Local POST failed")
                        end

                        server:stop()
                    end
            )
        end
    end

    return true
end

-- Test HTTP headers
local function testHttpHeaders()
    printHeader("HTTP Headers Test")

    print("\nTesting custom headers...")

    local customHeaders = {
        ["X-Custom-Header"] = "TestValue",
        ["User-Agent"] = "ComputerCraft/Test"
    }

    local response = http.get("http://httpbin.org/headers", customHeaders)

    if response then
        local body = response.readAll()
        response.close()

        local success, data = pcall(textutils.unserialiseJSON, body)
        if success and data.headers then
            printStatus(data.headers["X-Custom-Header"] == "TestValue",
                    "Custom header sent correctly")
            printStatus(data.headers["User-Agent"] == "ComputerCraft/Test",
                    "User-Agent header overridden")

            print("\nReceived headers:")
            for key, value in pairs(data.headers) do
                print("  " .. key .. ": " .. tostring(value))
            end
        else
            printStatus(false, "Failed to parse headers response")
        end
    else
        printStatus(false, "Headers test request failed")
    end

    return true
end

-- Test HTTP status codes
local function testStatusCodes()
    printHeader("HTTP Status Codes Test")

    local codes = {200, 301, 404, 500}

    print("\nTesting various status codes...")

    for _, code in ipairs(codes) do
        local response = http.get("http://httpbin.org/status/" .. code)

        if response then
            local actualCode = response.getResponseCode()
            response.close()

            printStatus(actualCode == code,
                    "Status code " .. code .. " handled correctly")
        else
            -- 4xx and 5xx might not return a response object
            if code >= 400 then
                print("  Status " .. code .. ": Error (expected)")
            else
                printStatus(false, "Status code " .. code .. " failed")
            end
        end

        sleep(0.5)  -- Rate limiting
    end

    return true
end

-- Test download performance
local function testPerformance()
    printHeader("HTTP Performance Test")

    print("\nTesting download speed...")

    local sizes = {100, 1000, 10000}

    for _, size in ipairs(sizes) do
        local url = "http://httpbin.org/bytes/" .. size
        local startTime = os.epoch("utc")

        local response = http.get(url)
        if response then
            local data = response.readAll()
            response.close()

            local endTime = os.epoch("utc")
            local duration = endTime - startTime
            local speed = math.floor((#data * 1000) / duration)  -- bytes per second

            print(string.format("  %d bytes: %dms (%d B/s)",
                    #data, duration, speed))
        else
            print("  " .. size .. " bytes: Failed")
        end

        sleep(0.5)
    end

    return true
end

-- Main test runner
local function main()
    printHeader("HTTP Protocol Test Suite")

    local results = {
        get = false,
        post = false,
        headers = false,
        statusCodes = false,
        performance = false
    }

    -- Check for network connectivity
    print("\nChecking network connectivity...")
    local testResponse = http.get("http://httpbin.org/get")
    if not testResponse then
        print("\nERROR: Cannot reach test server (httpbin.org)")
        print("Please check your internet connection.")
        print("\nPress any key to return...")
        os.pullEvent("key")
        return
    end
    testResponse.close()
    printStatus(true, "Network connectivity confirmed")

    -- Run tests
    print("\nRunning HTTP tests...")

    results.get = testHttpGet()
    sleep(1)

    results.post = testHttpPost()
    sleep(1)

    results.headers = testHttpHeaders()
    sleep(1)

    results.statusCodes = testStatusCodes()
    sleep(1)

    results.performance = testPerformance()

    -- Summary
    printHeader("Test Summary")
    print("\nTest Results:")
    printStatus(results.get, "GET Request Test")
    printStatus(results.post, "POST Request Test")
    printStatus(results.headers, "Headers Test")
    printStatus(results.statusCodes, "Status Codes Test")
    printStatus(results.performance, "Performance Test")

    local passed = 0
    for _, result in pairs(results) do
        if result then passed = passed + 1 end
    end

    print("\nOverall: " .. passed .. "/5 tests passed")

    if passed == 5 then
        print("\nHTTP protocol is working perfectly!")
    elseif passed >= 3 then
        print("\nHTTP protocol is mostly working.")
    else
        print("\nHTTP protocol has issues that need attention.")
    end

    print("\nPress any key to return to menu...")
    os.pullEvent("key")
end

-- Run tests
main()