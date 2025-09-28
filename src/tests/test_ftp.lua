local function test_ftp()

    local LOG_DIR = "logs"
    local LOG_PATH = LOG_DIR .. "/test_ftp.log"
    local CONSOLE_LOG_PATH = LOG_DIR .. "/test_ftp_console.log"
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

    -- Test FTP connection
    local function testFtpConnection()
        printHeader("FTP Connection Test")

        if not fs.exists("/protocols/ftp.lua") then
            print("\nFTP protocol not installed")
            return false
        end

        local ftp = dofile("/protocols/ftp.lua")

        print("\n1. Creating FTP client...")

        -- Test with local FTP server if available
        local client = ftp:new("localhost", {
            port = 21,
            username = "test",
            password = "test"
        })

        if client then
            printStatus(true, "FTP client created")

            print("\n2. Connecting to server...")
            local status = client:connect()

            if status == ftp.STATUSES.CONNECTED then
                printStatus(true, "Connected to FTP server")

                -- Test login
                print("\n3. Logging in...")
                local loginStatus = client:login()
                if loginStatus == ftp.STATUSES.LOGGED_IN then
                    printStatus(true, "Logged in successfully")

                    -- Test list
                    print("\n4. Listing directory...")
                    local files = client:list()
                    if files then
                        printStatus(true, "Directory listed: " .. #files .. " items")
                    end

                    -- Test upload
                    print("\n5. Testing file upload...")
                    local uploadSuccess = client:put("test.txt", "Test content")
                    printStatus(uploadSuccess, "File uploaded")

                    -- Test download
                    print("\n6. Testing file download...")
                    local content = client:get("test.txt")
                    printStatus(content == "Test content", "File downloaded")

                    client:quit()
                else
                    printStatus(false, "Login failed")
                end

                return true
            else
                printStatus(false, "Connection failed - FTP server may not be running")
                print("  This is normal if no FTP server is configured")
                return false
            end
        else
            printStatus(false, "Failed to create FTP client")
            return false
        end
    end

    -- Main test runner
    local function main()
        printHeader("FTP Protocol Test Suite")

        if not fs.exists("/protocols/ftp.lua") then
            print("\nFTP protocol not installed")
            print("Please install /protocols/ftp.lua first")
            print("\nPress any key to return...")
            os.pullEvent("key")
            return
        end

        local results = {
            connection = testFtpConnection()
        }

        -- Summary
        printHeader("Test Summary")
        print("\nTest Results:")
        printStatus(results.connection, "FTP Connection Test")

        if not results.connection then
            print("\nNote: FTP tests require an FTP server")
            print("to be running. The protocol may still")
            print("be correctly installed.")
        end

        print("\nPress any key to return to menu...")
        os.pullEvent("key")
    end

    main()
end