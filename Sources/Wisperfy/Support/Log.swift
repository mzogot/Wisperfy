import os

/// One logger per subsystem area. Watch them all with `make logs`.
enum Log {
    static let subsystem = "com.wisperfy.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let inject = Logger(subsystem: subsystem, category: "inject")
    static let hud = Logger(subsystem: subsystem, category: "hud")
    static let polish = Logger(subsystem: subsystem, category: "polish")
}
