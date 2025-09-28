local function test_ssh()
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
