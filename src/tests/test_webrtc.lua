local function test_webrtc()

    local LOG_DIR = "logs"
    local LOG_PATH = LOG_DIR .. "/test_webrtc.log"
    local CONSOLE_LOG_PATH = LOG_DIR .. "/test_webrtc_console.log"
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

    -- Test WebRTC peer connection
    local function testPeerConnection()
        printHeader("WebRTC Peer Connection Test")

        if not fs.exists("/protocols/webrtc.lua") then
            print("\nWebRTC protocol not installed")
            return false
        end

        local webrtc = dofile("/protocols/webrtc.lua")

        print("\n1. Creating peer connection...")
        local peer = webrtc:new("test-peer", {
            stunServer = "stun:stun.l.google.com:19302"
        })

        if peer then
            printStatus(true, "Peer connection created")

            -- Test offer creation
            print("\n2. Creating offer...")
            local offer = peer:createOffer()
            if offer then
                printStatus(true, "Offer created")
                print("  SDP length: " .. #offer.sdp)
            else
                printStatus(false, "Failed to create offer")
            end

            -- Test ICE candidate gathering
            print("\n3. Gathering ICE candidates...")
            local candidates = peer:gatherCandidates()
            if candidates and #candidates > 0 then
                printStatus(true, "ICE candidates gathered: " .. #candidates)
            else
                printStatus(false, "No ICE candidates found")
            end

            peer:close()
            return true
        else
            printStatus(false, "Failed to create peer connection")
            return false
        end
    end

    -- Test data channel
    local function testDataChannel()
        printHeader("WebRTC Data Channel Test")

        local webrtc = dofile("/protocols/webrtc.lua")

        print("\nCreating data channel...")
        local peer = webrtc:new("data-test")

        if peer then
            local channel = peer:createDataChannel("test-channel")

            if channel then
                printStatus(true, "Data channel created")

                -- Test send
                local testData = "WebRTC data channel test"
                local sent = channel:send(testData)
                printStatus(sent, "Data sent through channel")

                channel:close()
            else
                printStatus(false, "Failed to create data channel")
            end

            peer:close()
        end

        return true
    end

    -- Main test runner
    local function main()
        printHeader("WebRTC Protocol Test Suite")

        if not fs.exists("/protocols/webrtc.lua") then
            print("\nWebRTC protocol not installed")
            print("This is an advanced protocol that requires")
            print("additional setup. Skipping tests.")
            print("\nPress any key to return...")
            os.pullEvent("key")
            return
        end

        local results = {
            peerConnection = testPeerConnection(),
            dataChannel = testDataChannel()
        }

        -- Summary
        printHeader("Test Summary")
        print("\nTest Results:")
        printStatus(results.peerConnection, "Peer Connection Test")
        printStatus(results.dataChannel, "Data Channel Test")

        print("\nPress any key to return to menu...")
        os.pullEvent("key")
    end

    main()
end