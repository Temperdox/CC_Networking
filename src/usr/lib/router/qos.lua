-- /usr/lib/router/qos.lua
-- Quality of Service manager for router with traffic shaping and prioritization

local QoS = {}
QoS.__index = QoS

-- Priority levels
QoS.PRIORITY = {
    CRITICAL = 0,    -- Network control, router management
    HIGH = 1,        -- VoIP, real-time gaming
    MEDIUM = 2,      -- Web browsing, streaming
    NORMAL = 3,      -- Default traffic
    LOW = 4,         -- File downloads, backups
    BULK = 5         -- P2P, large transfers
}

-- DSCP (Differentiated Services Code Point) mappings
QoS.DSCP = {
    CS7 = 56,   -- Network control
    CS6 = 48,   -- Network control
    EF = 46,    -- Expedited Forwarding (VoIP)
    AF41 = 34,  -- Assured Forwarding (video)
    AF31 = 26,  -- Assured Forwarding (streaming)
    AF21 = 18,  -- Assured Forwarding (low latency data)
    CS0 = 0     -- Best effort
}

function QoS:new(config)
    local obj = {
        config = config,

        -- Bandwidth allocation (percentages)
        bandwidth = {
            total = 10000,  -- Total bandwidth in kbps
            reserved = {
                [QoS.PRIORITY.CRITICAL] = 0.10,  -- 10%
                [QoS.PRIORITY.HIGH] = 0.30,      -- 30%
                [QoS.PRIORITY.MEDIUM] = 0.25,    -- 25%
                [QoS.PRIORITY.NORMAL] = 0.20,    -- 20%
                [QoS.PRIORITY.LOW] = 0.10,       -- 10%
                [QoS.PRIORITY.BULK] = 0.05       -- 5%
            }
        },

        -- Traffic queues by priority
        queues = {},

        -- Statistics
        stats = {
            packets_queued = 0,
            packets_dropped = 0,
            packets_shaped = 0,
            bytes_shaped = 0
        },

        -- Traffic classifiers
        classifiers = {},

        -- Connection tracking for stateful QoS
        connections = {},

        -- Rate limiters per IP
        rateLimiters = {},

        -- Settings
        settings = {
            enabled = true,
            maxQueueSize = 100,
            dropPolicy = "tail", -- tail, head, random
            burstAllowance = 1.5,
            windowSize = 1000 -- ms
        }
    }

    -- Initialize queues
    for priority = QoS.PRIORITY.CRITICAL, QoS.PRIORITY.BULK do
        obj.queues[priority] = {
            packets = {},
            bytes = 0,
            dropped = 0
        }
    end

    -- Initialize default classifiers
    obj:initDefaultClassifiers()

    setmetatable(obj, self)
    return obj
end

function QoS:initDefaultClassifiers()
    -- Add default traffic classifiers

    -- VoIP ports
    self:addClassifier({
        name = "VoIP",
        protocol = "udp",
        dport_range = {5060, 5061}, -- SIP
        priority = QoS.PRIORITY.HIGH
    })

    self:addClassifier({
        name = "RTP",
        protocol = "udp",
        dport_range = {10000, 20000}, -- RTP media
        priority = QoS.PRIORITY.HIGH
    })

    -- Gaming
    self:addClassifier({
        name = "Gaming",
        protocol = "udp",
        dport_range = {27000, 27100}, -- Common game ports
        priority = QoS.PRIORITY.HIGH
    })

    -- Web
    self:addClassifier({
        name = "HTTP",
        protocol = "tcp",
        dport = 80,
        priority = QoS.PRIORITY.MEDIUM
    })

    self:addClassifier({
        name = "HTTPS",
        protocol = "tcp",
        dport = 443,
        priority = QoS.PRIORITY.MEDIUM
    })

    -- DNS
    self:addClassifier({
        name = "DNS",
        protocol = "udp",
        dport = 53,
        priority = QoS.PRIORITY.HIGH
    })

    -- Email
    self:addClassifier({
        name = "SMTP",
        protocol = "tcp",
        dport = 25,
        priority = QoS.PRIORITY.NORMAL
    })

    -- File transfer
    self:addClassifier({
        name = "FTP",
        protocol = "tcp",
        dport = 21,
        priority = QoS.PRIORITY.LOW
    })

    -- SSH
    self:addClassifier({
        name = "SSH",
        protocol = "tcp",
        dport = 22,
        priority = QoS.PRIORITY.MEDIUM
    })

    -- BitTorrent
    self:addClassifier({
        name = "BitTorrent",
        protocol = "tcp",
        dport_range = {6881, 6889},
        priority = QoS.PRIORITY.BULK
    })
end

function QoS:addClassifier(rule)
    table.insert(self.classifiers, rule)
end

function QoS:classifyPacket(packet)
    -- First check for DSCP marking
    if packet.dscp then
        if packet.dscp >= QoS.DSCP.CS6 then
            return QoS.PRIORITY.CRITICAL
        elseif packet.dscp >= QoS.DSCP.EF then
            return QoS.PRIORITY.HIGH
        elseif packet.dscp >= QoS.DSCP.AF31 then
            return QoS.PRIORITY.MEDIUM
        elseif packet.dscp >= QoS.DSCP.AF21 then
            return QoS.PRIORITY.NORMAL
        else
            return QoS.PRIORITY.LOW
        end
    end

    -- Check against classifiers
    for _, classifier in ipairs(self.classifiers) do
        local match = true

        -- Check protocol
        if classifier.protocol and packet.protocol ~= classifier.protocol then
            match = false
        end

        -- Check destination port
        if match and classifier.dport and packet.dport ~= classifier.dport then
            match = false
        end

        -- Check port range
        if match and classifier.dport_range then
            if packet.dport < classifier.dport_range[1] or
                    packet.dport > classifier.dport_range[2] then
                match = false
            end
        end

        -- Check source IP
        if match and classifier.source and packet.source ~= classifier.source then
            match = false
        end

        -- Check destination IP
        if match and classifier.destination and packet.destination ~= classifier.destination then
            match = false
        end

        if match then
            return classifier.priority
        end
    end

    -- Check connection tracking
    local conn_id = self:getConnectionId(packet)
    if self.connections[conn_id] then
        return self.connections[conn_id].priority
    end

    -- Dynamic classification based on packet size and protocol
    if packet.protocol == "udp" and packet.size and packet.size < 100 then
        -- Small UDP packets are often real-time
        return QoS.PRIORITY.HIGH
    elseif packet.protocol == "tcp" and packet.size and packet.size > 1400 then
        -- Large TCP packets are likely bulk transfer
        return QoS.PRIORITY.LOW
    end

    -- Default priority
    return QoS.PRIORITY.NORMAL
end

function QoS:getConnectionId(packet)
    if packet.protocol == "tcp" or packet.protocol == "udp" then
        return string.format("%s:%s:%d:%s:%d",
                packet.protocol,
                packet.source or "0.0.0.0",
                packet.sport or 0,
                packet.destination or "0.0.0.0",
                packet.dport or 0)
    end
    return string.format("%s:%s:%s",
            packet.protocol or "unknown",
            packet.source or "0.0.0.0",
            packet.destination or "0.0.0.0")
end

function QoS:trackConnection(packet, priority)
    local conn_id = self:getConnectionId(packet)

    if not self.connections[conn_id] then
        self.connections[conn_id] = {
            priority = priority,
            packets = 0,
            bytes = 0,
            last_seen = os.epoch("utc"),
            created = os.epoch("utc")
        }
    end

    local conn = self.connections[conn_id]
    conn.packets = conn.packets + 1
    conn.bytes = conn.bytes + (packet.size or 0)
    conn.last_seen = os.epoch("utc")

    -- Adaptive priority adjustment
    if conn.packets > 100 and priority == QoS.PRIORITY.HIGH then
        -- Downgrade long-running high priority connections
        conn.priority = QoS.PRIORITY.MEDIUM
    end
end

function QoS:enqueue(packet)
    if not self.settings.enabled then
        return packet -- Pass through if QoS disabled
    end

    local priority = self:classifyPacket(packet)
    local queue = self.queues[priority]

    -- Track connection
    self:trackConnection(packet, priority)

    -- Check queue size
    if #queue.packets >= self.settings.maxQueueSize then
        -- Apply drop policy
        if self.settings.dropPolicy == "tail" then
            -- Drop new packet (tail drop)
            queue.dropped = queue.dropped + 1
            self.stats.packets_dropped = self.stats.packets_dropped + 1
            return nil
        elseif self.settings.dropPolicy == "head" then
            -- Drop oldest packet (head drop)
            local dropped = table.remove(queue.packets, 1)
            queue.bytes = queue.bytes - (dropped.size or 0)
        elseif self.settings.dropPolicy == "random" then
            -- Random Early Detection (RED)
            if math.random() > 0.5 then
                queue.dropped = queue.dropped + 1
                self.stats.packets_dropped = self.stats.packets_dropped + 1
                return nil
            end
        end
    end

    -- Add packet to queue
    packet.enqueue_time = os.epoch("utc")
    packet.priority = priority
    table.insert(queue.packets, packet)
    queue.bytes = queue.bytes + (packet.size or 0)
    self.stats.packets_queued = self.stats.packets_queued + 1

    return nil -- Packet queued, not forwarded yet
end

function QoS:dequeue()
    -- Weighted Fair Queuing with priority
    local weights = {
        [QoS.PRIORITY.CRITICAL] = 32,
        [QoS.PRIORITY.HIGH] = 16,
        [QoS.PRIORITY.MEDIUM] = 8,
        [QoS.PRIORITY.NORMAL] = 4,
        [QoS.PRIORITY.LOW] = 2,
        [QoS.PRIORITY.BULK] = 1
    }

    local total_weight = 0
    for _, weight in pairs(weights) do
        total_weight = total_weight + weight
    end

    -- Check each queue based on weighted probability
    for priority = QoS.PRIORITY.CRITICAL, QoS.PRIORITY.BULK do
        local queue = self.queues[priority]

        if #queue.packets > 0 then
            local probability = weights[priority] / total_weight

            if priority == QoS.PRIORITY.CRITICAL then
                -- Always dequeue critical packets first
                local packet = table.remove(queue.packets, 1)
                queue.bytes = queue.bytes - (packet.size or 0)
                self:updateStats(packet)
                return packet

            elseif math.random() <= probability then
                -- Dequeue based on probability
                local packet = table.remove(queue.packets, 1)
                queue.bytes = queue.bytes - (packet.size or 0)
                self:updateStats(packet)
                return packet
            end
        end
    end

    -- Fallback: dequeue from highest priority non-empty queue
    for priority = QoS.PRIORITY.CRITICAL, QoS.PRIORITY.BULK do
        local queue = self.queues[priority]
        if #queue.packets > 0 then
            local packet = table.remove(queue.packets, 1)
            queue.bytes = queue.bytes - (packet.size or 0)
            self:updateStats(packet)
            return packet
        end
    end

    return nil -- No packets to dequeue
end

function QoS:updateStats(packet)
    if packet then
        local queue_time = os.epoch("utc") - packet.enqueue_time

        -- Update statistics
        self.stats.packets_shaped = self.stats.packets_shaped + 1
        self.stats.bytes_shaped = self.stats.bytes_shaped + (packet.size or 0)

        -- Track queue latency
        if not self.stats.avg_queue_time then
            self.stats.avg_queue_time = queue_time
        else
            self.stats.avg_queue_time = (self.stats.avg_queue_time * 0.9) + (queue_time * 0.1)
        end
    end
end

function QoS:applyRateLimit(source_ip)
    if not self.rateLimiters[source_ip] then
        self.rateLimiters[source_ip] = {
            tokens = 100,
            last_update = os.epoch("utc"),
            max_tokens = 100,
            refill_rate = 10 -- tokens per second
        }
    end

    local limiter = self.rateLimiters[source_ip]
    local now = os.epoch("utc")
    local elapsed = (now - limiter.last_update) / 1000

    -- Refill tokens
    limiter.tokens = math.min(
            limiter.max_tokens,
            limiter.tokens + (elapsed * limiter.refill_rate)
    )
    limiter.last_update = now

    -- Check if we have tokens
    if limiter.tokens >= 1 then
        limiter.tokens = limiter.tokens - 1
        return true -- Allow packet
    else
        return false -- Drop packet
    end
end

function QoS:cleanupConnections()
    local now = os.epoch("utc")
    local timeout = 300000 -- 5 minutes

    for conn_id, conn in pairs(self.connections) do
        if (now - conn.last_seen) > timeout then
            self.connections[conn_id] = nil
        end
    end
end

function QoS:getStatistics()
    local stats = {
        packets_queued = self.stats.packets_queued,
        packets_dropped = self.stats.packets_dropped,
        packets_shaped = self.stats.packets_shaped,
        bytes_shaped = self.stats.bytes_shaped,
        avg_queue_time = self.stats.avg_queue_time or 0,

        queues = {},
        connections = 0
    }

    -- Queue statistics
    for priority = QoS.PRIORITY.CRITICAL, QoS.PRIORITY.BULK do
        local queue = self.queues[priority]
        local priority_name = self:getPriorityName(priority)

        stats.queues[priority_name] = {
            packets = #queue.packets,
            bytes = queue.bytes,
            dropped = queue.dropped,
            bandwidth_allocated = self.bandwidth.reserved[priority] * self.bandwidth.total
        }
    end

    -- Connection count
    for _ in pairs(self.connections) do
        stats.connections = stats.connections + 1
    end

    return stats
end

function QoS:getPriorityName(priority)
    local names = {
        [QoS.PRIORITY.CRITICAL] = "Critical",
        [QoS.PRIORITY.HIGH] = "High",
        [QoS.PRIORITY.MEDIUM] = "Medium",
        [QoS.PRIORITY.NORMAL] = "Normal",
        [QoS.PRIORITY.LOW] = "Low",
        [QoS.PRIORITY.BULK] = "Bulk"
    }
    return names[priority] or "Unknown"
end

function QoS:reset()
    -- Reset all queues
    for priority = QoS.PRIORITY.CRITICAL, QoS.PRIORITY.BULK do
        self.queues[priority] = {
            packets = {},
            bytes = 0,
            dropped = 0
        }
    end

    -- Reset statistics
    self.stats = {
        packets_queued = 0,
        packets_dropped = 0,
        packets_shaped = 0,
        bytes_shaped = 0
    }

    -- Clear connections
    self.connections = {}
    self.rateLimiters = {}
end

function QoS:setEnabled(enabled)
    self.settings.enabled = enabled
end

function QoS:setBandwidth(total_kbps)
    self.bandwidth.total = total_kbps
end

function QoS:setPriorityBandwidth(priority, percentage)
    if priority >= QoS.PRIORITY.CRITICAL and priority <= QoS.PRIORITY.BULK then
        self.bandwidth.reserved[priority] = percentage
    end
end

return QoS