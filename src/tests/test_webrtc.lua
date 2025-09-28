local function test_webrtc()
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