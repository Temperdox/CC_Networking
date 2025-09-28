local function test_ssh()

    local LOG_DIR = "logs"
    local LOG_PATH = LOG_DIR .. "/test_ssh.log"
    local CONSOLE_LOG_PATH = LOG_DIR .. "/test_ssh_console.log"
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

    -- Test SSH connection
    local function testSshConnection()
        printHeader("SSH Connection Test")

        if not fs.exists("/protocols/ssh.lua") then
            print("\nSSH protocol not installed")
            return false
        end

        local ssh = dofile("/protocols/ssh.lua")

        print("\n1. Creating SSH client...")

        -- Test with local SSH server if available
        local client = ssh:new("localhost", 22, {
            username = "test",
            password = "test"
        })

        if client then
            printStatus(true, "SSH client created")

            print("\n2. Connecting to server...")
            local status = client:connect()

            if status == ssh.STATUSES.CONNECTED then
                printStatus(true, "Connected to SSH server")

                -- Test authentication
                print("\n3. Authenticating...")
                local authStatus = client:authenticate()

                if authStatus == ssh.STATUSES.AUTHENTICATED then
                    printStatus(true, "Authenticated successfully")

                    -- Test command execution
                    print("\n4. Executing command...")
                    local output = client:exec("echo 'Hello from SSH'")
                    if output then
                        printStatus(true, "Command executed")
                        print("  Output: " .. output)
                    end

                    -- Test shell channel
                    print("\n5. Opening shell channel...")
                    local shell = client:shell()
                    if shell then
                        printStatus(true, "Shell channel opened")
                        shell:close()
                    end

                    client:disconnect()
                else
                    printStatus(false, "Authentication failed")
                end

                return true
            else
                printStatus(false, "Connection failed - SSH server may not be running")
                print("  This is normal if no SSH server is configured")
                return false
            end
        else
            printStatus(false, "Failed to create SSH client")
            return false
        end
    end

    -- Test SSH key authentication
    local function testKeyAuth()
        printHeader("SSH Key Authentication Test")

        local ssh = dofile("/protocols/ssh.lua")

        print("\nTesting public key authentication...")

        -- Check for key files
        if not fs.exists("/home/.ssh/id_rsa") then
            print("No SSH keys found")
            print("Generate keys with: ssh-keygen")
            return false
        end

        local client = ssh:new("localhost", 22, {
            username = "test",
            privateKey = "/home/.ssh/id_rsa"
        })

        if client then
            local status = client:connect()
            if status == ssh.STATUSES.CONNECTED then
                local authStatus = client:authenticateWithKey()
                printStatus(authStatus == ssh.STATUSES.AUTHENTICATED,
                        "Key authentication")
                client:disconnect()
                return authStatus == ssh.STATUSES.AUTHENTICATED
            end
        end

        return false
    end

    -- Main test runner
    local function main()
        printHeader("SSH Protocol Test Suite")

        if not fs.exists("/protocols/ssh.lua") then
            print("\nSSH protocol not installed")
            print("Please install /protocols/ssh.lua first")
            print("\nPress any key to return...")
            os.pullEvent("key")
            return
        end

        local results = {
            connection = testSshConnection(),
            keyAuth = testKeyAuth()
        }

        -- Summary
        printHeader("Test Summary")
        print("\nTest Results:")
        printStatus(results.connection, "SSH Connection Test")
        printStatus(results.keyAuth, "Key Authentication Test")

        if not results.connection then
            print("\nNote: SSH tests require an SSH server")
            print("to be running. The protocol may still")
            print("be correctly installed.")
        end

        print("\nPress any key to return to menu...")
        os.pullEvent("key")
    end

    main()
end
