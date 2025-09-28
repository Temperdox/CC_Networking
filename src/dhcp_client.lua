-- /dhcp_client.lua
-- DHCP client for obtaining network configuration from router

local DHCP_TIMEOUT = 10 -- seconds
local DHCP_RETRIES = 3

local function getMAC()
    local id = os.getComputerID()
    return string.format("CC:AF:%02X:%02X:%02X:%02X",
            bit.band(bit.brshift(id, 24), 0xFF),
            bit.band(bit.brshift(id, 16), 0xFF),
            bit.band(bit.brshift(id, 8), 0xFF),
            bit.band(id, 0xFF))
end

local function findModem()
    local sides = {"top", "bottom", "left", "right", "front", "back"}
    for _, side in ipairs(sides) do
        if peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
            local modem = peripheral.wrap(side)
            modem.open(os.getComputerID())
            modem.open(65535) -- Broadcast channel
            return modem, side
        end
    end
    return nil
end

local function saveNetworkConfig(config)
    -- Save to /etc/network.cfg
    local file = fs.open("/etc/network.cfg", "w")
    if file then
        file.write("-- DHCP Client Configuration\n")
        file.write("-- Generated: " .. os.date() .. "\n\n")
        file.write("return " .. textutils.serialize(config))
        file.close()

        -- Also update /config/network.cfg for compatibility
        if not fs.exists("/config") then
            fs.makeDir("/config")
        end

        local configFile = fs.open("/config/network.cfg", "w")
        if configFile then
            configFile.write("return " .. textutils.serialize(config))
            configFile.close()
        end

        return true
    end
    return false
end

local function updateNetworkInfo(config)
    -- Update /var/run/network.info
    if not fs.exists("/var/run") then
        fs.makeDir("/var/run")
    end

    local info = {
        ip = config.ip,
        mac = config.mac,
        hostname = config.hostname,
        fqdn = config.hostname .. ".local",
        gateway = config.gateway,
        dns = config.dns,
        modem_available = true
    }

    local file = fs.open("/var/run/network.info", "w")
    if file then
        file.write(textutils.serialize(info))
        file.close()
    end
end

local function requestDHCP(modem, side, attempt)
    attempt = attempt or 1

    print(string.format("DHCP Discovery... (Attempt %d/%d)", attempt, DHCP_RETRIES))

    -- Send DHCP DISCOVER
    local discover = {
        type = "DHCP",
        dhcp_type = "DISCOVER",
        client_mac = getMAC(),
        hostname = os.getComputerLabel() or ("cc-" .. os.getComputerID())
    }

    -- Broadcast on all channels
    modem.transmit(65535, os.getComputerID(), discover)

    -- Also try rednet if available
    if rednet.isOpen(side) or rednet.open(side) then
        rednet.broadcast(discover, "dhcp")
    end

    -- Wait for DHCP OFFER
    local timer = os.startTimer(DHCP_TIMEOUT)
    local offered_ip = nil
    local router_id = nil
    local offer_details = nil

    while true do
        local event = {os.pullEvent()}

        if event[1] == "modem_message" then
            local evt_side, freq, reply, message = event[2], event[3], event[4], event[5]

            if type(message) == "table" and message.type == "DHCP" then
                if message.dhcp_type == "OFFER" then
                    print("Received DHCP offer: " .. message.offered_ip)

                    offered_ip = message.offered_ip
                    router_id = reply
                    offer_details = message

                    -- Send DHCP REQUEST
                    local request = {
                        type = "DHCP",
                        dhcp_type = "REQUEST",
                        client_mac = getMAC(),
                        requested_ip = offered_ip,
                        hostname = os.getComputerLabel() or ("cc-" .. os.getComputerID())
                    }

                    modem.transmit(router_id, os.getComputerID(), request)

                elseif message.dhcp_type == "ACK" then
                    os.cancelTimer(timer)

                    print("Received DHCP acknowledgment")

                    -- Configure network
                    local config = {
                        -- Network identification
                        id = os.getComputerID(),
                        hostname = os.getComputerLabel() or ("cc-" .. os.getComputerID()),

                        -- IP configuration
                        ip = message.assigned_ip,
                        ipv4 = message.assigned_ip,
                        gateway = message.gateway,
                        netmask = message.netmask,
                        subnet_mask = message.netmask,

                        -- DNS configuration
                        dns = message.dns,

                        -- Hardware configuration
                        mac = getMAC(),
                        router_id = router_id,

                        -- Protocol configuration
                        proto = "ccnet",
                        discovery_proto = "ccnet_discovery",
                        dns_proto = "ccnet_dns",
                        arp_proto = "ccnet_arp",
                        http_proto = "ccnet_http",
                        ws_proto = "ccnet_ws",

                        -- Lease information
                        lease_time = message.lease_time,
                        lease_obtained = os.epoch("utc"),

                        -- Interface information
                        modem_side = side
                    }

                    -- Save configuration
                    if saveNetworkConfig(config) then
                        updateNetworkInfo(config)

                        print()
                        print("Network configured successfully!")
                        print("=====================================")
                        print("  Hostname:   " .. config.hostname)
                        print("  IP Address: " .. config.ip)
                        print("  Netmask:    " .. config.netmask)
                        print("  Gateway:    " .. config.gateway)
                        print("  DNS:        " .. table.concat(config.dns, ", "))
                        print("  MAC:        " .. config.mac)
                        print("  Lease Time: " .. config.lease_time .. " seconds")
                        print("=====================================")
                        print()

                        -- Set up routing via rednet
                        if not rednet.isOpen(side) then
                            rednet.open(side)
                        end
                        rednet.host("dhcp_client", config.hostname)

                        return true
                    else
                        print("Error: Failed to save network configuration")
                        return false
                    end

                elseif message.dhcp_type == "NAK" then
                    os.cancelTimer(timer)
                    print("DHCP request denied by server")
                    return false
                end
            end

        elseif event[1] == "timer" and event[2] == timer then
            if attempt < DHCP_RETRIES then
                print("DHCP timeout, retrying...")
                return requestDHCP(modem, side, attempt + 1)
            else
                print("DHCP timeout - no response from router")
                print()
                print("Troubleshooting:")
                print("1. Ensure a router is running on the network")
                print("2. Check that the router has DHCP enabled")
                print("3. Verify modem connections")
                print("4. Try running /router_monitor.lua on the router")
                return false
            end
        end
    end
end

local function renewLease()
    -- Load current configuration
    if not fs.exists("/etc/network.cfg") then
        print("No existing DHCP configuration found")
        return false
    end

    local file = fs.open("/etc/network.cfg", "r")
    local content = file.readAll()
    file.close()

    local func = loadstring(content)
    if not func then
        print("Invalid configuration file")
        return false
    end

    local config = func()

    print("Renewing DHCP lease for " .. config.ip)

    local modem, side = findModem()
    if not modem then
        print("Error: No modem found!")
        return false
    end

    -- Send DHCP REQUEST directly (renewal)
    local request = {
        type = "DHCP",
        dhcp_type = "REQUEST",
        client_mac = config.mac,
        requested_ip = config.ip,
        hostname = config.hostname,
        renewal = true
    }

    if config.router_id then
        modem.transmit(config.router_id, os.getComputerID(), request)
    else
        modem.transmit(65535, os.getComputerID(), request)
    end

    -- Wait for ACK
    local timer = os.startTimer(5)

    while true do
        local event = {os.pullEvent()}

        if event[1] == "modem_message" then
            local evt_side, freq, reply, message = event[2], event[3], event[4], event[5]

            if type(message) == "table" and message.type == "DHCP" then
                if message.dhcp_type == "ACK" then
                    os.cancelTimer(timer)

                    -- Update lease time
                    config.lease_time = message.lease_time
                    config.lease_obtained = os.epoch("utc")

                    saveNetworkConfig(config)
                    print("Lease renewed successfully")
                    return true

                elseif message.dhcp_type == "NAK" then
                    os.cancelTimer(timer)
                    print("Lease renewal denied, requesting new lease...")
                    return requestDHCP(modem, side)
                end
            end

        elseif event[1] == "timer" and event[2] == timer then
            print("Lease renewal timeout")
            return false
        end
    end
end

local function release()
    -- Load current configuration
    if not fs.exists("/etc/network.cfg") then
        print("No DHCP configuration to release")
        return
    end

    local file = fs.open("/etc/network.cfg", "r")
    local content = file.readAll()
    file.close()

    local func = loadstring(content)
    if not func then
        return
    end

    local config = func()

    print("Releasing DHCP lease for " .. config.ip)

    local modem = findModem()
    if modem and config.router_id then
        -- Send DHCP RELEASE
        local release = {
            type = "DHCP",
            dhcp_type = "RELEASE",
            client_mac = config.mac,
            released_ip = config.ip
        }

        modem.transmit(config.router_id, os.getComputerID(), release)
    end

    -- Remove configuration
    fs.delete("/etc/network.cfg")
    if fs.exists("/config/network.cfg") then
        fs.delete("/config/network.cfg")
    end

    print("DHCP lease released")
end

-- Main function
local function main(args)
    local command = args[1]

    if command == "renew" then
        return renewLease()

    elseif command == "release" then
        release()
        return true

    elseif command == "status" then
        if fs.exists("/etc/network.cfg") then
            local file = fs.open("/etc/network.cfg", "r")
            local content = file.readAll()
            file.close()

            local func = loadstring(content)
            if func then
                local config = func()
                print("DHCP Client Status:")
                print("  IP: " .. config.ip)
                print("  Gateway: " .. config.gateway)
                print("  Lease Time: " .. config.lease_time .. " seconds")

                local elapsed = os.epoch("utc") - config.lease_obtained
                local remaining = config.lease_time - (elapsed / 1000)

                if remaining > 0 then
                    print("  Lease Remaining: " .. math.floor(remaining) .. " seconds")
                else
                    print("  Lease: EXPIRED")
                end
            end
        else
            print("No DHCP configuration found")
        end
        return true

    else
        -- Default: request new lease
        print("DHCP Client v1.0")
        print("=====================================")
        print("Requesting network configuration...")
        print()

        local modem, side = findModem()
        if not modem then
            print("Error: No network modem found!")
            print("Please attach a modem (wired or wireless) and try again.")
            return false
        end

        print("Found modem on " .. side .. " side")

        return requestDHCP(modem, side)
    end
end

-- Run if executed directly
if not ... then
    local args = {...}

    -- Show help if requested
    if args[1] == "help" then
        print("Usage: dhcp_client [command]")
        print("Commands:")
        print("  <none>   - Request new DHCP lease")
        print("  renew    - Renew existing lease")
        print("  release  - Release current lease")
        print("  status   - Show current configuration")
        print("  help     - Show this help")
        return
    end

    main(args)
end

return {
    request = requestDHCP,
    renew = renewLease,
    release = release,
    getMAC = getMAC
}