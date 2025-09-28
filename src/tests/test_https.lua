local function test_https()

    local LOG_DIR = "logs"
    local LOG_PATH = LOG_DIR .. "/test_https.log"
    local CONSOLE_LOG_PATH = LOG_DIR .. "/test_https_console.log"
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

    -- Test HTTPS connection
    local function testHttpsConnection()
        printHeader("HTTPS Connection Test")

        print("\n1. Testing secure connection...")

        -- Test basic HTTPS GET
        local response = http.get("https://httpbin.org/get")

        if response then
            local code = response.getResponseCode()
            local body = response.readAll()
            response.close()

            printStatus(code == 200, "HTTPS GET successful (code " .. code .. ")")

            local success, data = pcall(textutils.unserialiseJSON, body)
            if success then
                printStatus(true, "Response parsed successfully")
                print("  URL accessed: " .. (data.url or "unknown"))
            end
        else
            printStatus(false, "HTTPS connection failed")
        end

        return response ~= nil
    end

    -- Test HTTPS with headers
    local function testHttpsHeaders()
        printHeader("HTTPS Headers Test")

        local headers = {
            ["User-Agent"] = "ComputerCraft/HTTPS-Test",
            ["Accept"] = "application/json"
        }

        local response = http.get("https://httpbin.org/headers", headers)

        if response then
            local body = response.readAll()
            response.close()

            local success, data = pcall(textutils.unserialiseJSON, body)
            if success and data.headers then
                printStatus(data.headers["User-Agent"] == headers["User-Agent"],
                        "Custom headers sent over HTTPS")
            end
        else
            printStatus(false, "HTTPS with headers failed")
        end

        return response ~= nil
    end

    -- Main test runner
    local function main()
        printHeader("HTTPS Protocol Test Suite")

        local results = {
            connection = testHttpsConnection(),
            headers = testHttpsHeaders()
        }

        -- Summary
        printHeader("Test Summary")
        print("\nTest Results:")
        printStatus(results.connection, "HTTPS Connection Test")
        printStatus(results.headers, "HTTPS Headers Test")

        local passed = 0
        for _, result in pairs(results) do
            if result then passed = passed + 1 end
        end

        print("\nOverall: " .. passed .. "/2 tests passed")

        print("\nPress any key to return to menu...")
        os.pullEvent("key")
    end

    main()
end