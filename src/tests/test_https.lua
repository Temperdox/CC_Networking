local function test_https()
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