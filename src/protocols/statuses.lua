-- protocols/statuses.lua
local Logger = require("util.logger")

-- Create logger for statuses module
local logger = Logger and Logger:new({
    title = "Protocol Statuses",
    logFile = "logs/statuses.log",
    maxLogs = 100
}) or nil

local STATUSES = {
    -- Common statuses for network connections
    initialized = "initialized",
    connecting = "connecting",
    connected = "connected",
    disconnected = "disconnected",
    reconnecting = "reconnecting",
    error = "error",
    closed = "closed",
    timeout = "timeout",

    -- Protocol-specific statuses
    websocket_open = "websocket_open",
    websocket_closing = "websocket_closing",
    websocket_closed = "websocket_closed",
    http_request_sent = "http_request_sent",
    http_response_received = "http_response_received",
    webrtc_offer = "webrtc_offer",
    webrtc_answer = "webrtc_answer",
    webrtc_ice = "webrtc_ice",
    tcp_listening = "tcp_listening",
    tcp_established = "tcp_established",
    mqtt_subscribed = "mqtt_subscribed",
    mqtt_published = "mqtt_published",
    ftp_logged_in = "ftp_logged_in",
    ftp_transferring = "ftp_transferring",
    ssh_authenticated = "ssh_authenticated",
    ssh_channel_open = "ssh_channel_open",

    -- Additional nested status structures for specific protocols
    WEBSOCKET = {
        OK = "ok",
        ALREADY_CONNECTED = "already_connected",
        CONNECTION_FAILED = "connection_failed",
        NOT_CONNECTED = "not_connected",
        CLOSED = "closed",
        SEND_FAILED = "send_failed",
        CALLBACK_ERROR = "callback_error"
    },

    HTTP = {
        OK = "ok",
        REQUEST_FAILED = "request_failed",
        NO_RESPONSE = "no_response",
        CLOSED = "closed"
    },

    TCP = {
        DISCONNECTED = "disconnected",
        SYN_SENT = "syn_sent",
        ESTABLISHED = "established",
        CONNECTED = "connected",
        CONNECTION_FAILED = "connection_failed",
        CLOSE_WAIT = "close_wait",
        FIN_WAIT_1 = "fin_wait_1",
        TIME_WAIT = "time_wait"
    },

    MQTT = {
        SUCCESS = "success",
        CONNECTION_FAILED = "connection_failed",
        NOT_CONNECTED = "not_connected",
        SUBSCRIPTION_FAILED = "subscription_failed",
        UNSUBSCRIPTION_FAILED = "unsubscription_failed",
        INVALID_EVENT = "invalid_event"
    },

    FTP = {
        SUCCESS = "success",
        ALREADY_CONNECTED = "already_connected",
        CONNECTION_FAILED = "connection_failed",
        NOT_AUTHENTICATED = "not_authenticated",
        LIST_FAILED = "list_failed",
        CHANGE_DIR_FAILED = "change_dir_failed",
        PWD_FAILED = "pwd_failed",
        LOCAL_FILE_NOT_FOUND = "local_file_not_found",
        FILE_OPEN_FAILED = "file_open_failed",
        UPLOAD_FAILED = "upload_failed",
        DOWNLOAD_FAILED = "download_failed",
        DELETE_FAILED = "delete_failed",
        MKDIR_FAILED = "mkdir_failed",
        RMDIR_FAILED = "rmdir_failed",
        DISCONNECT_FAILED = "disconnect_failed",
        NOT_CONNECTED = "not_connected",
        INVALID_MODE = "invalid_mode"
    },

    SSH = {
        ALREADY_CONNECTED = "already_connected",
        NOT_CONNECTED = "not_connected",
        AUTH_FAILED = "auth_failed",
        NOT_AUTHENTICATED = "not_authenticated",
        CHANNEL_OPEN_FAILED = "channel_open_failed",
        INVALID_COMMAND = "invalid_command",
        COMMAND_EXEC_FAILED = "command_exec_failed",
        CHANNEL_CLOSED = "channel_closed",
        INVALID_DATA = "invalid_data",
        SEND_FAILED = "send_failed",
        CHANNEL_CLOSE_FAILED = "channel_close_failed",
        SFTP_COMMAND_FAILED = "sftp_command_failed",
        DISCONNECT_FAILED = "disconnect_failed"
    },

    WEBRTC = {
        CONNECTING = "connecting",
        CONNECTED = "connected",
        NOT_CONNECTED = "not_connected",
        CLOSED = "closed",
        SIGNALING_SERVER_NOT_CONNECTED = "signaling_server_not_connected",
        DATA_CHANNEL = {
            OPEN = "open",
            CLOSED = "closed",
            SENT = "sent",
            NOT_OPEN = "not_open"
        }
    }
}

-- Add metatable for logging access
setmetatable(STATUSES, {
    __index = function(t, k)
        local value = rawget(t, k)
        if logger and value then
            logger:trace("Status accessed: %s = %s", k, tostring(value))
        elseif logger then
            logger:warn("Status not found: %s", k)
        end
        return value
    end
})

if logger then
    logger:info("Statuses module loaded")
end

return STATUSES