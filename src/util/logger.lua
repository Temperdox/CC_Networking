-- basalt_logger.lua
local basalt = require("basalt")

local Logger = {}
Logger.__index = Logger

-- Log levels
Logger.LEVELS = {
    TRACE = {level = 1, color = colors.gray, bg = colors.black, name = "TRACE"},
    DEBUG = {level = 2, color = colors.lightGray, bg = colors.black, name = "DEBUG"},
    INFO = {level = 3, color = colors.white, bg = colors.black, name = "INFO"},
    WARN = {level = 4, color = colors.yellow, bg = colors.black, name = "WARN"},
    ERROR = {level = 5, color = colors.red, bg = colors.black, name = "ERROR"},
    FATAL = {level = 6, color = colors.purple, bg = colors.black, name = "FATAL"}
}

function Logger:new(config)
    local o = {}
    setmetatable(o, self)

    -- Configuration
    o.config = config or {}
    o.title = config.title or "System Logger"
    o.maxLogs = config.maxLogs or 1000
    o.saveToFile = config.saveToFile ~= false
    o.logFile = config.logFile or "logs/system.log"
    o.dateFormat = config.dateFormat or "%H:%M:%S"

    -- Log storage
    o.logs = {}
    o.filteredLogs = {}
    o.currentFilter = nil
    o.searchTerm = ""
    o.minLevel = Logger.LEVELS.TRACE

    -- Create Basalt interface
    o:createUI()

    -- Load previous logs if they exist
    o:loadPreviousLogs()

    return o
end

function Logger:createUI()
    -- Create main frame
    self.mainFrame = basalt.createFrame()
                           :setSize("parent.w", "parent.h")
                           :setBackground(colors.black)

    -- Create container frame for logger window
    self.logFrame = self.mainFrame:addFrame()
                        :setPosition(self.config.x or "parent.w / 2 + 1", self.config.y or 1)
                        :setSize(self.config.width or "parent.w / 2", self.config.height or "parent.h")
                        :setBackground(colors.black)
                        :setBorder(colors.blue)

    -- Title bar
    self.titleBar = self.logFrame:addLabel()
                        :setPosition(1, 1)
                        :setSize("parent.w", 1)
                        :setText(self.title)
                        :setBackground(colors.blue)
                        :setForeground(colors.white)

    -- Stats label
    self.statsLabel = self.logFrame:addLabel()
                          :setPosition("parent.w - 10", 1)
                          :setSize(10, 1)
                          :setText("0/0")
                          :setBackground(colors.blue)
                          :setForeground(colors.white)

    -- Filter status bar
    self.filterBar = self.logFrame:addLabel()
                         :setPosition(1, 2)
                         :setSize("parent.w", 1)
                         :setText("No filters active")
                         :setBackground(colors.gray)
                         :setForeground(colors.white)

    -- Log list
    self.logList = self.logFrame:addList()
                       :setPosition(1, 3)
                       :setSize("parent.w", "parent.h - 6")
                       :setBackground(colors.black)
                       :setForeground(colors.white)
                       :setSelectionColor(colors.gray, colors.white)
                       :setScrollable(true)

    -- Search input (initially hidden)
    self.searchInput = self.logFrame:addInput()
                           :setPosition(1, "parent.h - 2")
                           :setSize("parent.w", 1)
                           :setBackground(colors.gray)
                           :setForeground(colors.white)
                           :setPlaceholder("Search...")
                           :hide()

    -- Button bar
    self.buttonFrame = self.logFrame:addFrame()
                           :setPosition(1, "parent.h - 1")
                           :setSize("parent.w", 1)
                           :setBackground(colors.lightGray)

    -- Create buttons
    self:createButtons()

    -- Set up event handlers
    self:setupEventHandlers()

    -- Create filter menu (initially hidden)
    self:createFilterMenu()

    -- Create help dialog (initially hidden)
    self:createHelpDialog()
end

function Logger:createButtons()
    local buttonWidth = 8
    local buttons = {
        {text = "Search", action = function() self:toggleSearch() end},
        {text = "Filter", action = function() self:showFilterMenu() end},
        {text = "Clear", action = function() self:clear() end},
        {text = "Export", action = function() self:export() end},
        {text = "Help", action = function() self:showHelp() end}
    }

    for i, btn in ipairs(buttons) do
        self.buttonFrame:addButton()
            :setPosition((i - 1) * buttonWidth + 1, 1)
            :setSize(buttonWidth, 1)
            :setText(btn.text)
            :setBackground(colors.gray)
            :setForeground(colors.white)
            :onClick(btn.action)
    end
end

function Logger:createFilterMenu()
    -- Create filter menu frame
    self.filterMenu = self.logFrame:addFrame()
                          :setPosition("parent.w / 2 - 15", "parent.h / 2 - 5")
                          :setSize(30, 12)
                          :setBackground(colors.blue)
                          :setBorder(colors.white)
                          :setZIndex(10)
                          :hide()

    self.filterMenu:addLabel()
        :setPosition(2, 1)
        :setText("Select Filter Level")
        :setForeground(colors.white)
        :setBackground(colors.blue)

    -- Create level buttons
    local levels = {"TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL", "NONE"}
    for i, levelName in ipairs(levels) do
        self.filterMenu:addButton()
            :setPosition(2, i + 1)
            :setSize(26, 1)
            :setText(levelName)
            :setBackground(colors.gray)
            :setForeground(colors.white)
            :onClick(function()
            if levelName == "NONE" then
                self.currentFilter = nil
            else
                self.currentFilter = Logger.LEVELS[levelName]
            end
            self:applyFilters()
            self.filterMenu:hide()
        end)
    end

    -- Close button
    self.filterMenu:addButton()
        :setPosition(2, 10)
        :setSize(26, 1)
        :setText("Cancel")
        :setBackground(colors.red)
        :setForeground(colors.white)
        :onClick(function()
        self.filterMenu:hide()
    end)
end

function Logger:createHelpDialog()
    self.helpDialog = self.logFrame:addFrame()
                          :setPosition("parent.w / 2 - 20", "parent.h / 2 - 8")
                          :setSize(40, 16)
                          :setBackground(colors.blue)
                          :setBorder(colors.white)
                          :setZIndex(10)
                          :hide()

    self.helpDialog:addLabel()
        :setPosition(2, 1)
        :setText("Logger Help")
        :setForeground(colors.white)
        :setBackground(colors.blue)

    local helpText = {
        "",
        "Keyboard Shortcuts:",
        "  Up/Down - Navigate logs",
        "  Page Up/Down - Fast scroll",
        "  Home/End - Jump to start/end",
        "",
        "Features:",
        "  Search - Find in messages",
        "  Filter - Show specific levels",
        "  Clear - Remove all logs",
        "  Export - Save to file",
        "",
        "Click anywhere to close"
    }

    for i, line in ipairs(helpText) do
        self.helpDialog:addLabel()
            :setPosition(2, i + 1)
            :setText(line)
            :setForeground(colors.white)
            :setBackground(colors.blue)
    end

    self.helpDialog:onClick(function()
        self.helpDialog:hide()
    end)
end

function Logger:setupEventHandlers()
    -- Search input handler
    self.searchInput:onChange(function()
        self.searchTerm = self.searchInput:getValue()
        self:applyFilters()
    end)

    -- Keyboard handler for search
    self.searchInput:onKey(function(key)
        if key == keys.enter or key == keys.escape then
            self.searchInput:hide()
            self.searchInput:setValue("")
            if key == keys.escape then
                self.searchTerm = ""
                self:applyFilters()
            end
        end
    end)

    -- List selection handler
    self.logList:onSelect(function(list, item, index)
        if self.filteredLogs[index] then
            -- Could show detailed view here
        end
    end)
end

function Logger:log(level, message, ...)
    -- Format message
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end

    -- Create log entry
    local entry = {
        timestamp = os.epoch("utc"),
        date = os.date(self.dateFormat),
        level = level,
        message = message,
        index = #self.logs + 1
    }

    -- Add to logs
    table.insert(self.logs, entry)

    -- Trim if exceeds max
    if #self.logs > self.maxLogs then
        table.remove(self.logs, 1)
        for i, log in ipairs(self.logs) do
            log.index = i
        end
    end

    -- Save to file
    if self.saveToFile then
        self:writeToFile(entry)
    end

    -- Update display
    self:applyFilters()
end

-- Convenience methods
function Logger:trace(message, ...)
    self:log(Logger.LEVELS.TRACE, message, ...)
end

function Logger:debug(message, ...)
    self:log(Logger.LEVELS.DEBUG, message, ...)
end

function Logger:info(message, ...)
    self:log(Logger.LEVELS.INFO, message, ...)
end

function Logger:warn(message, ...)
    self:log(Logger.LEVELS.WARN, message, ...)
end

function Logger:error(message, ...)
    self:log(Logger.LEVELS.ERROR, message, ...)
end

function Logger:fatal(message, ...)
    self:log(Logger.LEVELS.FATAL, message, ...)
end

function Logger:writeToFile(entry)
    local dir = fs.getDir(self.logFile)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local file = fs.open(self.logFile, "a")
    if file then
        file.writeLine(string.format("[%s] [%s] %s",
                entry.date,
                entry.level.name,
                entry.message
        ))
        file.close()
    end
end

function Logger:loadPreviousLogs()
    if not self.saveToFile or not fs.exists(self.logFile) then
        return
    end

    local file = fs.open(self.logFile, "r")
    if file then
        local lines = {}
        while true do
            local line = file.readLine()
            if not line then break end
            table.insert(lines, line)
            if #lines > self.maxLogs then
                table.remove(lines, 1)
            end
        end
        file.close()

        -- Parse logs
        for _, line in ipairs(lines) do
            local date, levelName, message = line:match("%[([^%]]+)%]%s*%[([^%]]+)%]%s*(.+)")
            if date and levelName and message then
                local level = Logger.LEVELS.INFO
                for _, lvl in pairs(Logger.LEVELS) do
                    if lvl.name == levelName then
                        level = lvl
                        break
                    end
                end

                table.insert(self.logs, {
                    timestamp = 0,
                    date = date,
                    level = level,
                    message = message,
                    index = #self.logs + 1
                })
            end
        end
    end

    self:applyFilters()
end

function Logger:applyFilters()
    self.filteredLogs = {}
    self.logList:clear()

    for _, log in ipairs(self.logs) do
        local include = true

        -- Level filter
        if self.currentFilter and log.level ~= self.currentFilter then
            include = false
        end

        -- Min level filter
        if self.minLevel and log.level.level < self.minLevel.level then
            include = false
        end

        -- Search filter
        if self.searchTerm and self.searchTerm ~= "" then
            local searchLower = string.lower(self.searchTerm)
            local messageLower = string.lower(log.message)
            if not string.find(messageLower, searchLower, 1, true) then
                include = false
            end
        end

        if include then
            table.insert(self.filteredLogs, log)

            -- Format log entry for display
            local displayText = string.format("%s [%s] %s",
                    log.date,
                    string.sub(log.level.name, 1, 1),
                    log.message
            )

            -- Add to list with color
            self.logList:addItem(displayText)
                :setBackground(log.level.bg)
                :setForeground(log.level.color)
        end
    end

    -- Update stats
    self.statsLabel:setText(string.format("%d/%d", #self.filteredLogs, #self.logs))

    -- Update filter bar
    local filterText = "Filters: "
    if self.currentFilter then
        filterText = filterText .. "[" .. self.currentFilter.name .. "] "
    end
    if self.searchTerm and self.searchTerm ~= "" then
        filterText = filterText .. "[Search: " .. self.searchTerm .. "] "
    end
    if filterText == "Filters: " then
        filterText = "No filters active"
    end
    self.filterBar:setText(filterText)

    -- Auto-scroll to bottom
    self.logList:setOffset(0, math.max(0, #self.filteredLogs - self.logList:getHeight()))
end

function Logger:toggleSearch()
    if self.searchInput:isVisible() then
        self.searchInput:hide()
        self.searchTerm = ""
        self:applyFilters()
    else
        self.searchInput:show()
        self.searchInput:setFocus()
    end
end

function Logger:showFilterMenu()
    self.filterMenu:show()
end

function Logger:showHelp()
    self.helpDialog:show()
end

function Logger:clear()
    self.logs = {}
    self.filteredLogs = {}
    self.logList:clear()

    if self.saveToFile and fs.exists(self.logFile) then
        fs.delete(self.logFile)
    end

    self:applyFilters()
end

function Logger:export(filename)
    filename = filename or "exported_logs.txt"

    local file = fs.open(filename, "w")
    if file then
        for _, log in ipairs(self.filteredLogs) do
            file.writeLine(string.format("[%s] [%s] %s",
                    log.date,
                    log.level.name,
                    log.message
            ))
        end
        file.close()
        self:info("Exported %d logs to %s", #self.filteredLogs, filename)
    end
end

function Logger:start()
    basalt.autoUpdate()
end

return Logger