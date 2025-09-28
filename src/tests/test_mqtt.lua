local function test_mqtt()
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