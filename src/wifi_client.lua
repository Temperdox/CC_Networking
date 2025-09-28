-- /wifi_client.lua
-- WiFi client for connecting to router's wireless network

local WiFiClient = {}
WiFiClient.__index = WiFiClient

function WiFiClient:new()
    local obj = {
        connected = false,
        ssid = nil,
        ip = nil,
        gateway = nil,
        dns = nil,
        wireless_interface = nil
    }

    setmetatable(obj, self)
    return obj
end

function WiFiClient:findWirelessInterface()
    local sides = {"top", "bottom", "left", "right", "front", "back"}

    for _, side in ipairs(sides) do
        if peripheral.isPresent(side) then
            local pType = peripheral.getType(side)
            if pType == "modem" then
                local modem = peripheral.wrap(side)
                if modem.isWireless and modem.isWireless() then
                    self.wireless_interface = {
                        modem = modem,
                        side = side
                    }
                    modem.open(os.getComputerID())
                    modem.open(65534) -- Beacon channel
                    modem.open(65535) -- Broadcast channel
                    return true
                end
            end
        end
    end

    return false
end

function WiFiClient:scanNetworks(timeout)
    timeout = timeout or 5
    local networks = {}

    if not self.wireless_interface then
        return networks
    end

    print("Scanning for wireless networks...")

    local timer = os.startTimer(timeout)

    while true do
        local event = {os.pullEvent()}

        if event[1] == "modem_message" then
            local side, freq, reply, message = event[2], event[3], event[4], event[5]

            if type(message) == "table" and message.type == "BEACON" then
                networks[message.ssid] = {
                    ssid = message.ssid,
                    security = message.security,
                    channel = message.channel,
                    router_id = reply,
                    signal = -50 - (event[6] or 0) -- Simulated signal strength
                }
            end

        elseif event[1] == "timer" and event[2] == timer then
            break
        end
    end

    return networks
end

function WiFiClient:connect(ssid, password)
    if not self.wireless_interface then
        return false, "No wireless interface found"
    end

    -- Find network
    local networks = self:scanNetworks(2)
    local network = networks[ssid]

    if not network then
        return false, "Network not found"
    end

    print("Connecting to " .. ssid .. "...")

    -- Start authentication
    if network.security == "OPEN" then
        return self:connectOpen(network)
    elseif network.security == "WPA2" then
        return self:connectWPA2(network, password)
    elseif network.security == "WPA3" then
        return self:connectWPA3(network, password)
    else
        return false, "Unsupported security type"
    end
end

function WiFiClient:connectOpen(network)
    -- Send association request
    local request = {
        type = "WIRELESS_AUTH",
        auth_type = "OPEN",
        client_mac = self:getMAC()
    }

    self.wireless_interface.modem.transmit(
            network.router_id, os.getComputerID(), request
    )

    -- Wait for response
    local timer = os.startTimer(5)

    while true do
        local event = {os.pullEvent()}

        if event[1] == "modem_message" then
            local side, freq, reply, message = event[2], event[3], event[4], event[5]

            if type(message) == "table" and
                    message.type == "WIRELESS_AUTH" and
                    message.auth_type == "ASSOCIATED" then

                os.cancelTimer(timer)

                if message.success then
                    self.connected = true
                    self.ssid = network.ssid
                    self.router_id = network.router_id

                    -- Request DHCP
                    return self:requestDHCP()
                else
                    return false, "Association failed"
                end
            end

        elseif event[1] == "timer" and event[2] == timer then
            return false, "Connection timeout"
        end
    end
end

function WiFiClient:connectWPA3(network, password)
    if not password then
        return false, "Password required for WPA3"
    end

    -- WPA3 SAE (Simultaneous Authentication of Equals)
    -- Simplified implementation for ComputerCraft

    -- Send SAE commit
    local commit = {
        type = "WIRELESS_AUTH",
        auth_type = "SAE_COMMIT",
        client_mac = self:getMAC(),
        commit_data = self:generateSAECommit(password, network.ssid)
    }

    self.wireless_interface.modem.transmit(
            network.router_id, os.getComputerID(), commit
    )

    -- Wait for SAE confirm
    local timer = os.startTimer(5)

    while true do
        local event = {os.pullEvent()}

        if event[1] == "modem_message" then
            local side, freq, reply, message = event[2], event[3], event[4], event[5]

            if type(message) == "table" and
                    message.type == "WIRELESS_AUTH" then

                if message.auth_type == "SAE_CONFIRM" then
                    -- Send confirm response
                    local confirm = {
                        type = "WIRELESS_AUTH",
                        auth_type = "SAE_CONFIRM",
                        client_mac = self:getMAC(),
                        auth_data = self:generateSAEConfirm(
                                password, network.ssid, message.challenge
                        )
                    }

                    self.wireless_interface.modem.transmit(
                            network.router_id, os.getComputerID(), confirm
                    )

                elseif message.auth_type == "ASSOCIATED" then
                    os.cancelTimer(timer)

                    if message.success then
                        self.connected = true
                        self.ssid = network.ssid
                        self.router_id = network.router_id

                        -- Request DHCP
                        return self:requestDHCP()
                    else
                        return false, "Authentication failed"
                    end
                end
            end

        elseif event[1] == "timer" and event[2] == timer then
            return false, "Authentication timeout"
        end
    end
end

function WiFiClient:connectWPA2(network, password)
    -- Simplified WPA2 implementation
    -- Similar to WPA3 but with different handshake
    return self:connectWPA3(network, password)
end

function WiFiClient:generateSAECommit(password, ssid)
    -- Simplified SAE commit generation
    local data = password .. ssid .. os.getComputerID()
    local hash = 0

    for i = 1, #data do
        hash = hash + string.byte(data, i) * i
    end

    return tostring(hash)
end

function WiFiClient:generateSAEConfirm(password, ssid, challenge)
    -- Simplified SAE confirm generation
    local data = password .. ssid .. challenge .. os.getComputerID()
    local hash = 0

    for i = 1, #data do
        hash = hash + string.byte(data, i) * i
    end

    return tostring(hash)
end

function WiFiClient:getMAC()
    -- Generate MAC address based on computer ID
    local id = os.getComputerID()
    return string.format("CC:AF:%02X:%02X:%02X:%02X",
            bit.band(bit.brshift(id, 24), 0xFF),
            bit.band(bit.brshift(id, 16), 0xFF),
            bit.band(bit.brshift(id, 8), 0xFF),
            bit.band(id, 0xFF))
end

function WiFiClient:requestDHCP()
    print("Requesting IP address via DHCP...")

    -- Send DHCP DISCOVER
    local discover = {
        type = "DHCP",
        dhcp_type = "DISCOVER",
        client_mac = self:getMAC(),
        hostname = os.getComputerLabel() or ("cc-" .. os.getComputerID())
    }

    self.wireless_interface.modem.transmit(
            self.router_id, os.getComputerID(), discover
    )

    -- Wait for DHCP OFFER
    local timer = os.startTimer(10)
    local offered_ip = nil

    while true do
        local event = {os.pullEvent()}

        if event[1] == "modem_message" then
            local side, freq, reply, message = event[2], event[3], event[4], event[5]

            if type(message) == "table" and
                    message.type == "DHCP" then

                if message.dhcp_type == "OFFER" then
                    offered_ip = message.offered_ip

                    -- Send DHCP REQUEST
                    local request = {
                        type = "DHCP",
                        dhcp_type = "REQUEST",
                        client_mac = self:getMAC(),
                        requested_ip = offered_ip,
                        hostname = os.getComputerLabel() or ("cc-" .. os.getComputerID())
                    }

                    self.wireless_interface.modem.transmit(
                            self.router_id, os.getComputerID(), request
                    )

                elseif message.dhcp_type == "ACK" then
                    os.cancelTimer(timer)

                    -- Configure network
                    self.ip = message.assigned_ip
                    self.gateway = message.gateway
                    self.netmask = message.netmask
                    self.dns = message.dns

                    print("Connected successfully!")
                    print("  IP Address: " .. self.ip)
                    print("  Gateway: " .. self.gateway)
                    print("  DNS: " .. table.concat(self.dns, ", "))

                    -- Save configuration
                    self:saveConfig()

                    return true
                end
            end

        elseif event[1] == "timer" and event[2] == timer then
            return false, "DHCP timeout"
        end
    end
end

function WiFiClient:saveConfig()
    local config = {
        ssid = self.ssid,
        ip = self.ip,
        gateway = self.gateway,
        netmask = self.netmask,
        dns = self.dns,
        mac = self:getMAC()
    }

    local file = fs.open("/etc/wifi.cfg", "w")
    if file then
        file.write(textutils.serialize(config))
        file.close()
    end
end

function WiFiClient:disconnect()
    if self.connected and self.wireless_interface then
        -- Send disconnect message
        local disconnect = {
            type = "WIRELESS_AUTH",
            auth_type = "DISCONNECT",
            client_mac = self:getMAC()
        }

        self.wireless_interface.modem.transmit(
                self.router_id, os.getComputerID(), disconnect
        )

        self.connected = false
        self.ssid = nil
        self.ip = nil

        print("Disconnected from wireless network")
    end
end

-- Interactive WiFi connection utility
local function main()
    print("=====================================")
    print(" WiFi Client Configuration")
    print("=====================================")
    print()

    local client = WiFiClient:new()

    -- Find wireless interface
    if not client:findWirelessInterface() then
        print("ERROR: No wireless modem found!")
        print("Please attach a wireless modem.")
        return
    end

    print("Wireless interface found")
    print()

    -- Scan for networks
    local networks = client:scanNetworks()

    if next(networks) == nil then
        print("No wireless networks found")
        return
    end

    -- Display networks
    print("Available Networks:")
    print()

    local network_list = {}
    local idx = 1

    for ssid, info in pairs(networks) do
        print(string.format("%d. %s (%s) [%d dBm]",
                idx, ssid, info.security, info.signal))
        network_list[idx] = info
        idx = idx + 1
    end

    print()
    write("Select network (number): ")
    local choice = tonumber(read())

    if not choice or not network_list[choice] then
        print("Invalid selection")
        return
    end

    local selected = network_list[choice]
    local password = nil

    if selected.security ~= "OPEN" then
        write("Enter password: ")
        password = read("*")
    end

    print()

    -- Connect to network
    local success, err = client:connect(selected.ssid, password)

    if success then
        print()
        print("Successfully connected to " .. selected.ssid)
        print()
        print("You can now access the network and internet (if available)")
        print("Router admin panel: http://" .. client.gateway .. ":8080")
    else
        print("Failed to connect: " .. (err or "Unknown error"))
    end
end

-- Run if executed directly
if not ... then
    main()
end

return WiFiClient