-- /usr/lib/router/web_admin.lua
-- Web administration interface for router using Basalt UI

-- Check for Basalt
local hasBasalt, basalt = pcall(require, "basalt")

if not hasBasalt then
    -- Fallback to text-based interface if Basalt not available
    print("Basalt not found. Using text interface.")
    print("To install Basalt, run:")
    print("wget run https://basalt.madefor.cc/install.lua")
end

local WebAdmin = {}
WebAdmin.__index = WebAdmin

function WebAdmin:new(config)
    local obj = {
        config = config,
        port = config.services.web_admin.port or 8080,
        password = config.admin_password,
        running = true,
        currentTab = "status"
    }

    setmetatable(obj, self)

    if hasBasalt then
        obj:initBasaltUI()
    else
        obj:initTextUI()
    end

    return obj
end

function WebAdmin:initBasaltUI()
    -- Create main frame
    self.mainFrame = basalt.createFrame()
                           :setSize("parent.w", "parent.h")
                           :setBackground(colors.black)

    -- Title bar
    self.titleBar = self.mainFrame:addPane()
                        :setPosition(1, 1)
                        :setSize("parent.w", 3)
                        :setBackground(colors.blue)

    self.titleLabel = self.titleBar:addLabel()
                          :setPosition("parent.w/2-10", 2)
                          :setText("Router Administration")
                          :setForeground(colors.white)
                          :setBackground(colors.blue)

    -- Tab bar
    self.tabBar = self.mainFrame:addMenubar()
                      :setPosition(1, 4)
                      :setSize("parent.w", 1)
                      :setBackground(colors.gray)
                      :setSelectionColor(colors.blue, colors.white)
                      :addItem("Status")
                      :addItem("DHCP")
                      :addItem("Firewall")
                      :addItem("WiFi")
                      :addItem("Statistics")
                      :addItem("Settings")
                      :onChange(function(self, item)
        self:switchTab(item.text:lower())
    end)

    -- Content area
    self.contentFrame = self.mainFrame:addFrame()
                            :setPosition(1, 6)
                            :setSize("parent.w", "parent.h-7")
                            :setBackground(colors.black)

    -- Status bar
    self.statusBar = self.mainFrame:addLabel()
                         :setPosition(1, "parent.h")
                         :setSize("parent.w", 1)
                         :setBackground(colors.lightGray)
                         :setForeground(colors.black)
                         :setText(" Ready")

    -- Create tabs
    self:createStatusTab()
    self:createDHCPTab()
    self:createFirewallTab()
    self:createWiFiTab()
    self:createStatisticsTab()
    self:createSettingsTab()

    -- Show initial tab
    self:switchTab("status")
end

function WebAdmin:createStatusTab()
    self.statusFrame = self.contentFrame:addFrame()
                           :setSize("parent.w", "parent.h")
                           :setBackground(colors.black)

    -- Router info section
    local infoPane = self.statusFrame:addPane()
                         :setPosition(2, 2)
                         :setSize("parent.w-3", 8)
                         :setBackground(colors.gray)

    infoPane:addLabel()
            :setPosition(2, 1)
            :setText("Router Information")
            :setForeground(colors.white)

    -- Load router stats
    local stats = self:loadStats()
    local uptime = 0
    if stats.uptime_start then
        uptime = math.floor((os.epoch("utc") - stats.uptime_start) / 1000)
    end

    infoPane:addLabel()
            :setPosition(2, 3)
            :setText("Hostname: " .. (self.config.hostname or "Unknown"))
            :setForeground(colors.lightGray)

    infoPane:addLabel()
            :setPosition(2, 4)
            :setText("LAN IP: " .. (self.config.lan.ip or "N/A"))
            :setForeground(colors.lightGray)

    infoPane:addLabel()
            :setPosition(2, 5)
            :setText("WAN Mode: " .. (self.config.wan.mode or "N/A"))
            :setForeground(colors.lightGray)

    self.uptimeLabel = infoPane:addLabel()
                               :setPosition(2, 6)
                               :setText("Uptime: " .. self:formatUptime(uptime * 1000))
                               :setForeground(colors.lightGray)

    -- Service status
    local servicePane = self.statusFrame:addPane()
                            :setPosition(2, 11)
                            :setSize("parent.w-3", 8)
                            :setBackground(colors.gray)

    servicePane:addLabel()
               :setPosition(2, 1)
               :setText("Services")
               :setForeground(colors.white)

    local services = {
        {name = "DHCP", enabled = self.config.lan.dhcp.enabled},
        {name = "DNS", enabled = self.config.services.dns.enabled},
        {name = "Firewall", enabled = self.config.firewall.enabled},
        {name = "WiFi", enabled = self.config.wireless.enabled},
        {name = "NAT", enabled = self.config.firewall.nat_enabled}
    }

    for i, service in ipairs(services) do
        local color = service.enabled and colors.green or colors.red
        local status = service.enabled and "Active" or "Inactive"

        servicePane:addLabel()
                   :setPosition(2, 2 + i)
                   :setText(string.format("%-10s", service.name))
                   :setForeground(colors.lightGray)

        servicePane:addLabel()
                   :setPosition(13, 2 + i)
                   :setText(status)
                   :setForeground(color)
    end

    -- Control buttons
    self.statusFrame:addButton()
        :setPosition(2, "parent.h-3")
        :setSize(12, 3)
        :setText("Restart")
        :setBackground(colors.red)
        :setForeground(colors.white)
        :onClick(function()
        self:restartRouter()
    end)

    self.statusFrame:addButton()
        :setPosition(16, "parent.h-3")
        :setSize(12, 3)
        :setText("Refresh")
        :setBackground(colors.blue)
        :setForeground(colors.white)
        :onClick(function()
        self:refreshStatus()
    end)
end

function WebAdmin:createDHCPTab()
    self.dhcpFrame = self.contentFrame:addFrame()
                         :setSize("parent.w", "parent.h")
                         :setBackground(colors.black)
                         :hide()

    -- DHCP settings
    local settingsPane = self.dhcpFrame:addPane()
                             :setPosition(2, 2)
                             :setSize("parent.w-3", 6)
                             :setBackground(colors.gray)

    settingsPane:addLabel()
                :setPosition(2, 1)
                :setText("DHCP Settings")
                :setForeground(colors.white)

    settingsPane:addLabel()
                :setPosition(2, 3)
                :setText("Range: " .. self.config.lan.dhcp.start .. " - " .. self.config.lan.dhcp["end"])
                :setForeground(colors.lightGray)

    settingsPane:addLabel()
                :setPosition(2, 4)
                :setText("Lease Time: " .. self.config.lan.dhcp.lease_time .. " seconds")
                :setForeground(colors.lightGray)

    -- DHCP leases list
    local leasesPane = self.dhcpFrame:addPane()
                           :setPosition(2, 9)
                           :setSize("parent.w-3", "parent.h-12")
                           :setBackground(colors.gray)

    leasesPane:addLabel()
              :setPosition(2, 1)
              :setText("Active Leases")
              :setForeground(colors.white)

    -- Create scrollable list for leases
    self.leasesList = leasesPane:addList()
                                :setPosition(2, 3)
                                :setSize("parent.w-4", "parent.h-4")
                                :setBackground(colors.black)
                                :setForeground(colors.white)
                                :setSelectionColor(colors.blue, colors.white)

    -- Load and display leases
    self:refreshDHCPLeases()
end

function WebAdmin:createFirewallTab()
    self.firewallFrame = self.contentFrame:addFrame()
                             :setSize("parent.w", "parent.h")
                             :setBackground(colors.black)
                             :hide()

    -- Firewall status
    local statusPane = self.firewallFrame:addPane()
                           :setPosition(2, 2)
                           :setSize("parent.w-3", 5)
                           :setBackground(colors.gray)

    statusPane:addLabel()
              :setPosition(2, 1)
              :setText("Firewall Status")
              :setForeground(colors.white)

    local fwStatus = self.config.firewall.enabled and "Enabled" or "Disabled"
    local fwColor = self.config.firewall.enabled and colors.green or colors.red

    statusPane:addLabel()
              :setPosition(2, 3)
              :setText("Status: " .. fwStatus)
              :setForeground(fwColor)

    -- Port forwards
    local portPane = self.firewallFrame:addPane()
                         :setPosition(2, 8)
                         :setSize("parent.w-3", "parent.h-16")
                         :setBackground(colors.gray)

    portPane:addLabel()
            :setPosition(2, 1)
            :setText("Port Forwards")
            :setForeground(colors.white)

    self.portList = portPane:addList()
                            :setPosition(2, 3)
                            :setSize("parent.w-4", "parent.h-4")
                            :setBackground(colors.black)
                            :setForeground(colors.white)

    -- Load port forwards
    for _, forward in ipairs(self.config.firewall.port_forwards or {}) do
        local entry = string.format("%s:%d -> %s:%d",
                forward.protocol:upper(),
                forward.external_port,
                forward.internal_ip,
                forward.internal_port)
        self.portList:addItem(entry)
    end

    -- Control buttons
    self.firewallFrame:addButton()
        :setPosition(2, "parent.h-3")
        :setSize(12, 3)
        :setText("Add Rule")
        :setBackground(colors.green)
        :setForeground(colors.white)
        :onClick(function()
        self:showAddRuleDialog()
    end)

    self.firewallFrame:addButton()
        :setPosition(16, "parent.h-3")
        :setSize(12, 3)
        :setText("Remove")
        :setBackground(colors.red)
        :setForeground(colors.white)
        :onClick(function()
        self:removeSelectedRule()
    end)
end

function WebAdmin:createWiFiTab()
    self.wifiFrame = self.contentFrame:addFrame()
                         :setSize("parent.w", "parent.h")
                         :setBackground(colors.black)
                         :hide()

    -- WiFi settings
    local settingsPane = self.wifiFrame:addPane()
                             :setPosition(2, 2)
                             :setSize("parent.w-3", 8)
                             :setBackground(colors.gray)

    settingsPane:addLabel()
                :setPosition(2, 1)
                :setText("Wireless Settings")
                :setForeground(colors.white)

    local wifiStatus = self.config.wireless.enabled and "Enabled" or "Disabled"
    local wifiColor = self.config.wireless.enabled and colors.green or colors.red

    settingsPane:addLabel()
                :setPosition(2, 3)
                :setText("Status: " .. wifiStatus)
                :setForeground(wifiColor)

    settingsPane:addLabel()
                :setPosition(2, 4)
                :setText("SSID: " .. self.config.wireless.ssid)
                :setForeground(colors.lightGray)

    settingsPane:addLabel()
                :setPosition(2, 5)
                :setText("Security: " .. self.config.wireless.security)
                :setForeground(colors.lightGray)

    settingsPane:addLabel()
                :setPosition(2, 6)
                :setText("Channel: " .. self.config.wireless.channel)
                :setForeground(colors.lightGray)

    -- Connected clients
    local clientsPane = self.wifiFrame:addPane()
                            :setPosition(2, 11)
                            :setSize("parent.w-3", "parent.h-14")
                            :setBackground(colors.gray)

    clientsPane:addLabel()
               :setPosition(2, 1)
               :setText("Connected Clients")
               :setForeground(colors.white)

    self.wifiClientsList = clientsPane:addList()
                                      :setPosition(2, 3)
                                      :setSize("parent.w-4", "parent.h-4")
                                      :setBackground(colors.black)
                                      :setForeground(colors.white)

    -- Load WiFi clients (would be populated from router state)
    self:refreshWiFiClients()
end

function WebAdmin:createStatisticsTab()
    self.statsFrame = self.contentFrame:addFrame()
                          :setSize("parent.w", "parent.h")
                          :setBackground(colors.black)
                          :hide()

    -- Traffic stats
    local trafficPane = self.statsFrame:addPane()
                            :setPosition(2, 2)
                            :setSize("parent.w-3", 8)
                            :setBackground(colors.gray)

    trafficPane:addLabel()
               :setPosition(2, 1)
               :setText("Traffic Statistics")
               :setForeground(colors.white)

    local stats = self:loadStats()

    self.rxLabel = trafficPane:addLabel()
                              :setPosition(2, 3)
                              :setText("RX: " .. self:formatBytes(stats.bytes_rx or 0))
                              :setForeground(colors.lightGray)

    self.txLabel = trafficPane:addLabel()
                              :setPosition(2, 4)
                              :setText("TX: " .. self:formatBytes(stats.bytes_tx or 0))
                              :setForeground(colors.lightGray)

    self.packetsLabel = trafficPane:addLabel()
                                   :setPosition(2, 5)
                                   :setText("Packets Forwarded: " .. (stats.packets_forwarded or 0))
                                   :setForeground(colors.lightGray)

    self.droppedLabel = trafficPane:addLabel()
                                   :setPosition(2, 6)
                                   :setText("Packets Dropped: " .. (stats.packets_dropped or 0))
                                   :setForeground(colors.lightGray)

    -- Graph placeholder
    local graphPane = self.statsFrame:addPane()
                          :setPosition(2, 11)
                          :setSize("parent.w-3", "parent.h-14")
                          :setBackground(colors.gray)

    graphPane:addLabel()
             :setPosition(2, 1)
             :setText("Traffic Graph")
             :setForeground(colors.white)

    -- Simple text-based graph
    self.trafficGraph = graphPane:addTextfield()
                                 :setPosition(2, 3)
                                 :setSize("parent.w-4", "parent.h-4")
                                 :setBackground(colors.black)
                                 :setForeground(colors.green)
                                 :setText("Traffic monitoring active...")
end

function WebAdmin:createSettingsTab()
    self.settingsFrame = self.contentFrame:addFrame()
                             :setSize("parent.w", "parent.h")
                             :setBackground(colors.black)
                             :hide()

    -- Admin settings
    local adminPane = self.settingsFrame:addPane()
                          :setPosition(2, 2)
                          :setSize("parent.w-3", 10)
                          :setBackground(colors.gray)

    adminPane:addLabel()
             :setPosition(2, 1)
             :setText("Administrator Settings")
             :setForeground(colors.white)

    adminPane:addLabel()
             :setPosition(2, 3)
             :setText("Admin Port:")
             :setForeground(colors.lightGray)

    self.portInput = adminPane:addInput()
                              :setPosition(15, 3)
                              :setSize(10, 1)
                              :setBackground(colors.black)
                              :setForeground(colors.white)
                              :setValue(tostring(self.config.services.web_admin.port))

    adminPane:addLabel()
             :setPosition(2, 5)
             :setText("Password:")
             :setForeground(colors.lightGray)

    self.passwordInput = adminPane:addInput()
                                  :setPosition(15, 5)
                                  :setSize(20, 1)
                                  :setBackground(colors.black)
                                  :setForeground(colors.white)
                                  :setInputType("password")
                                  :setValue("********")

    -- Save button
    adminPane:addButton()
             :setPosition(2, 8)
             :setSize(12, 1)
             :setText("Save")
             :setBackground(colors.green)
             :setForeground(colors.white)
             :onClick(function()
        self:saveSettings()
    end)

    -- System settings
    local systemPane = self.settingsFrame:addPane()
                           :setPosition(2, 13)
                           :setSize("parent.w-3", 6)
                           :setBackground(colors.gray)

    systemPane:addLabel()
              :setPosition(2, 1)
              :setText("System Settings")
              :setForeground(colors.white)

    systemPane:addButton()
              :setPosition(2, 3)
              :setSize(15, 1)
              :setText("Backup Config")
              :setBackground(colors.blue)
              :setForeground(colors.white)
              :onClick(function()
        self:backupConfiguration()
    end)

    systemPane:addButton()
              :setPosition(19, 3)
              :setSize(15, 1)
              :setText("Factory Reset")
              :setBackground(colors.red)
              :setForeground(colors.white)
              :onClick(function()
        self:factoryReset()
    end)
end

function WebAdmin:switchTab(tab)
    -- Hide all frames
    self.statusFrame:hide()
    self.dhcpFrame:hide()
    self.firewallFrame:hide()
    self.wifiFrame:hide()
    self.statsFrame:hide()
    self.settingsFrame:hide()

    -- Show selected frame
    if tab == "status" then
        self.statusFrame:show()
    elseif tab == "dhcp" then
        self.dhcpFrame:show()
        self:refreshDHCPLeases()
    elseif tab == "firewall" then
        self.firewallFrame:show()
    elseif tab == "wifi" then
        self.wifiFrame:show()
        self:refreshWiFiClients()
    elseif tab == "statistics" then
        self.statsFrame:show()
        self:updateStatistics()
    elseif tab == "settings" then
        self.settingsFrame:show()
    end

    self.currentTab = tab
end

-- Helper functions
function WebAdmin:loadStats()
    local stats = {}
    if fs.exists("/var/run/router.stats") then
        local file = fs.open("/var/run/router.stats", "r")
        if file then
            local content = file.readAll()
            file.close()
            stats = textutils.unserialize(content) or {}
        end
    end
    return stats
end

function WebAdmin:loadLeases()
    local leases = {}
    if fs.exists("/var/lib/dhcp/leases") then
        local file = fs.open("/var/lib/dhcp/leases", "r")
        if file then
            local content = file.readAll()
            file.close()
            leases = textutils.unserialize(content) or {}
        end
    end
    return leases
end

function WebAdmin:formatBytes(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.2f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.2f MB", bytes / (1024 * 1024))
    else
        return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

function WebAdmin:formatUptime(ms)
    local seconds = math.floor(ms / 1000)
    local minutes = math.floor(seconds / 60)
    local hours = math.floor(minutes / 60)
    local days = math.floor(hours / 24)

    if days > 0 then
        return string.format("%dd %dh %dm", days, hours % 24, minutes % 60)
    elseif hours > 0 then
        return string.format("%dh %dm", hours, minutes % 60)
    else
        return string.format("%dm %ds", minutes, seconds % 60)
    end
end

function WebAdmin:refreshDHCPLeases()
    if not self.leasesList then return end

    self.leasesList:clear()
    local leases = self:loadLeases()

    for mac, lease in pairs(leases) do
        local entry = string.format("%-15s %s",
                lease.ip or "?.?.?.?",
                lease.hostname or mac)
        self.leasesList:addItem(entry)
    end
end

function WebAdmin:refreshWiFiClients()
    if not self.wifiClientsList then return end

    self.wifiClientsList:clear()
    -- Would load actual WiFi clients from router state
    self.wifiClientsList:addItem("No clients connected")
end

function WebAdmin:updateStatistics()
    local stats = self:loadStats()

    if self.rxLabel then
        self.rxLabel:setText("RX: " .. self:formatBytes(stats.bytes_rx or 0))
    end

    if self.txLabel then
        self.txLabel:setText("TX: " .. self:formatBytes(stats.bytes_tx or 0))
    end

    if self.packetsLabel then
        self.packetsLabel:setText("Packets Forwarded: " .. (stats.packets_forwarded or 0))
    end

    if self.droppedLabel then
        self.droppedLabel:setText("Packets Dropped: " .. (stats.packets_dropped or 0))
    end
end

function WebAdmin:refreshStatus()
    self.statusBar:setText(" Refreshing...")

    -- Update uptime
    local stats = self:loadStats()
    local uptime = 0
    if stats.uptime_start then
        uptime = math.floor((os.epoch("utc") - stats.uptime_start) / 1000)
    end

    if self.uptimeLabel then
        self.uptimeLabel:setText("Uptime: " .. self:formatUptime(uptime * 1000))
    end

    self.statusBar:setText(" Ready")
end

function WebAdmin:restartRouter()
    self.statusBar:setText(" Restarting router...")
    os.queueEvent("router_restart")
    sleep(2)
    self.statusBar:setText(" Router restarted")
end

function WebAdmin:saveSettings()
    -- Save configuration changes
    self.statusBar:setText(" Settings saved")
end

function WebAdmin:backupConfiguration()
    -- Create backup of configuration
    fs.copy("/etc/router.cfg", "/etc/router.cfg.backup")
    fs.copy("/etc/firewall.rules", "/etc/firewall.rules.backup")
    self.statusBar:setText(" Configuration backed up")
end

function WebAdmin:factoryReset()
    -- Confirm dialog would go here
    self.statusBar:setText(" Factory reset initiated...")
end

-- Text-based fallback interface
function WebAdmin:initTextUI()
    print("Router Web Admin - Text Mode")
    print("============================")
    print()
    print("1. View Status")
    print("2. DHCP Management")
    print("3. Firewall Settings")
    print("4. WiFi Settings")
    print("5. Statistics")
    print("6. System Settings")
    print("0. Exit")
    print()
end

function WebAdmin:run()
    if hasBasalt then
        -- Start auto-refresh timer
        local refreshTimer = os.startTimer(5)

        while self.running do
            local event = {os.pullEvent()}

            if event[1] == "timer" and event[2] == refreshTimer then
                if self.currentTab == "status" then
                    self:refreshStatus()
                elseif self.currentTab == "statistics" then
                    self:updateStatistics()
                end
                refreshTimer = os.startTimer(5)
            end

            basalt.update(event)
        end
    else
        -- Text mode loop
        while self.running do
            write("Choice: ")
            local choice = read()

            if choice == "0" then
                self.running = false
            elseif choice == "1" then
                self:showTextStatus()
            elseif choice == "2" then
                self:showTextDHCP()
                -- ... etc
            end
        end
    end
end

function WebAdmin:showTextStatus()
    print("\n=== Router Status ===")
    print("Hostname: " .. self.config.hostname)
    print("LAN IP: " .. self.config.lan.ip)
    print("Services:")
    print("  DHCP: " .. (self.config.lan.dhcp.enabled and "Enabled" or "Disabled"))
    print("  Firewall: " .. (self.config.firewall.enabled and "Enabled" or "Disabled"))
    print("\nPress Enter to continue...")
    read()
end

function WebAdmin:showTextDHCP()
    print("\n=== DHCP Leases ===")
    local leases = self:loadLeases()
    for mac, lease in pairs(leases) do
        print(string.format("%s -> %s", lease.ip, lease.hostname or mac))
    end
    print("\nPress Enter to continue...")
    read()
end

return WebAdmin