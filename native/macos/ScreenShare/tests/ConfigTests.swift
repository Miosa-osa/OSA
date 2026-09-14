import Foundation

@main
struct ConfigTests {
    static func main() throws {
        let readOnly = try Config.parse([])
        let allowed = try Config.parse(["--allow-input", "--display", "2"])
        precondition(!readOnly.allowInput)
        precondition(allowed.allowInput)
        for args in [["--read-only", "--allow-input"], ["--allow-input", "--read-only"],
                     ["--stub", "--allow-input"], ["--display", "-1"], ["--typo"], ["--port"]] {
            do {
                _ = try Config.parse(args)
                fatalError("invalid arguments accepted: \(args)")
            } catch ConfigError.invalidArguments { }
        }
        print("config tests passed")
    }
}
