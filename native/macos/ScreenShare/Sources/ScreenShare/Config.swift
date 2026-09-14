import Foundation

enum ConfigError: Error { case invalidArguments }

struct Config {
    var port: UInt16 = 0
    var displayIndex = 0
    var stub = false
    var allowInput = false
    var check = false
    var memoryMB = 512
    var idleSeconds = 60

    static func parse(_ args: [String]) throws -> Config {
        var cfg = Config()
        var seen = Set<String>()
        var i = 0
        while i < args.count {
            let option = args[i]
            guard seen.insert(option).inserted else { throw ConfigError.invalidArguments }
            switch option {
            case "--stub": cfg.stub = true
            case "--check": cfg.check = true
            case "--allow-input": cfg.allowInput = true
            case "--read-only": break
            case "--port", "--display", "--max-memory-mb", "--idle-seconds":
                i += 1
                guard i < args.count, let value = Int(args[i]) else { throw ConfigError.invalidArguments }
                switch option {
                case "--port":
                    guard let port = UInt16(exactly: value) else { throw ConfigError.invalidArguments }
                    cfg.port = port
                case "--display":
                    guard (0...63).contains(value) else { throw ConfigError.invalidArguments }
                    cfg.displayIndex = value
                case "--max-memory-mb":
                    guard (1...512).contains(value) else { throw ConfigError.invalidArguments }
                    cfg.memoryMB = value
                default:
                    guard (1...60).contains(value) else { throw ConfigError.invalidArguments }
                    cfg.idleSeconds = value
                }
            default: throw ConfigError.invalidArguments
            }
            i += 1
        }
        guard !cfg.allowInput || (!seen.contains("--read-only") && !cfg.stub) else {
            throw ConfigError.invalidArguments
        }
        return cfg
    }
}
