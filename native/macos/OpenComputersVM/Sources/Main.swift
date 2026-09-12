import Foundation
import Darwin

@main struct VMHelper {
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--version"] {
            print("osa-opencomputers-vm 0.1.0 protocol=1 backend=apple_virtualization")
            return
        }
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 10, args[0] == "--root", args[2] == "--artifacts",
              args[4] == "--max-cpus", args[6] == "--max-memory-mib", args[8] == "--max-disk-mib",
              let cpus = Int(args[5]), (1...64).contains(cpus),
              let memory = Int(args[7]), (512...262144).contains(memory),
              let disk = Int(args[9]), (64...1048576).contains(disk) else {
            fputs("invalid helper arguments\n", stderr); exit(64)
        }
        do {
            let store = try OwnedStore(root: args[1], artifacts: args[3])
            let manager = VirtualMachines(store: store, limits: Limits(cpus: cpus, memoryMiB: memory, diskMiB: disk))
            signal(SIGPIPE, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let shutdown = {
                // Process exit also releases the owned VZ objects, including a hung transition.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(1) }
                manager.stopAll { _ in exit(0) }
            }
            term.setEventHandler(handler: shutdown); term.resume()
            interrupt.setEventHandler(handler: shutdown); interrupt.resume()
            Thread.detachNewThread {
                var line = Data()
                while true {
                    var byte: UInt8 = 0
                    let count = Darwin.read(STDIN_FILENO, &byte, 1)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { DispatchQueue.main.async(execute: shutdown); return }
                    if byte != 10 {
                        line.append(byte)
                        if line.count > 16384 { exit(65) }
                        continue
                    }
                    let input = line; line = Data()
                    let gate = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        do {
                            let request = try Request.decode(input)
                            let deadline = DispatchWorkItem { exit(70) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: deadline)
                            manager.handle(request) { outcome in
                                deadline.cancel()
                                respond(id: request.id, outcome: outcome)
                                gate.signal()
                            }
                        } catch {
                            respond(id: "", outcome: .failure(error)); gate.signal()
                        }
                    }
                    gate.wait()
                }
            }
            withExtendedLifetime([term, interrupt]) { dispatchMain() }
        } catch { fputs("native VM helper initialization failed\n", stderr); exit(78) }
    }

    static func respond(id: String, outcome: Result<[String: Any], Error>) {
        let response: [String: Any]
        switch outcome {
        case .success(let value): response = ["version": 1, "id": id, "ok": true, "result": value]
        case .failure(let error): response = ["version": 1, "id": id, "ok": false, "error": (error as? VMError)?.rawValue ?? "invalidRequest"]
        }
        do {
            var bytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            bytes.append(10)
            try FileHandle.standardOutput.write(contentsOf: bytes)
        } catch { exit(74) }
    }
}
