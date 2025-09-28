local function test_mqtt()

    local LOG_DIR = "logs"
    local LOG_PATH = LOG_DIR .. "/test_mqtt.log"
    local CONSOLE_LOG_PATH = LOG_DIR .. "/test_mqtt_console.log"
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

    -- Test MQTT connection
    local function testMqttConnection()
        printHeader("MQTT Connection Test")

        if not fs.exists("/protocols/mqtt.lua") then
            print("\nMQTT protocol not installed")
            return false
        end

        local mqtt = dofile("/protocols/mqtt.lua")

        print("\n1. Creating MQTT client...")

        -- Use test broker
        local client = mqtt:new("test.mosquitto.org", 1883, {
            clientId = "cc_test_" .. os.getComputerID(),
            cleanSession = true
        })

        if client then
            printStatus(true, "MQTT client created")

            print("\n2. Connecting to broker...")
            local status = client:connect()

            if status == mqtt.STATUSES.CONNECTED then
                printStatus(true, "Connected to MQTT broker")

                -- Test subscribe
                print("\n3. Subscribing to topic...")
                local subStatus = client:subscribe("computercraft/test", 0)
                printStatus(subStatus == mqtt.STATUSES.SUBSCRIBED, "Subscribed to topic")

                -- Test publish
                print("\n4. Publishing message...")
                local pubStatus = client:publish("computercraft/test", "Hello MQTT!", 0)
                printStatus(pubStatus == mqtt.STATUSES.PUBLISHED, "Message published")

                -- Disconnect
                client:disconnect()
                printStatus(true, "Disconnected from broker")

                return true
            else
                printStatus(false, "Failed to connect to broker")
                return false
            end
        else
            printStatus(false, "Failed to create MQTT client")
            return false
        end
    end

    -- Test MQTT QoS levels
    local function testQoSLevels()
        printHeader("MQTT QoS Levels Test")

        local mqtt = dofile("/protocols/mqtt.lua")

        local client = mqtt:new("test.mosquitto.org", 1883, {
            clientId = "cc_qos_test_" .. os.getComputerID()
        })

        if client and client:connect() == mqtt.STATUSES.CONNECTED then
            print("\nTesting QoS levels...")

            -- QoS 0 - At most once
            local status0 = client:publish("computercraft/qos0", "QoS 0 message", 0)
            printStatus(status0, "QoS 0 (At most once)")

            -- QoS 1 - At least once
            local status1 = client:publish("computercraft/qos1", "QoS 1 message", 1)
            printStatus(status1, "QoS 1 (At least once)")

            -- QoS 2 - Exactly once
            local status2 = client:publish("computercraft/qos2", "QoS 2 message", 2)
            printStatus(status2, "QoS 2 (Exactly once)")

            client:disconnect()
            return true
        end

        return false
    end

    -- Main test runner
    local function main()
        printHeader("MQTT Protocol Test Suite")

        if not fs.exists("/protocols/mqtt.lua") then
            print("\nMQTT protocol not installed")
            print("Please install /protocols/mqtt.lua first")
            print("\nPress any key to return...")
            os.pullEvent("key")
            return
        end

        local results = {
            connection = testMqttConnection(),
            qos = testQoSLevels()
        }

        -- Summary
        printHeader("Test Summary")
        print("\nTest Results:")
        printStatus(results.connection, "MQTT Connection Test")
        printStatus(results.qos, "QoS Levels Test")

        print("\nPress any key to return to menu...")
        os.pullEvent("key")
    end

    main()
end