import Foundation
import Virtualization
import Security
import CryptoKit

/// Called only on the main dispatch queue, as required by VZVirtualMachine.
final class VirtualMachines {
    let store: OwnedStore
    let limits: Limits
    private var machines: [String: VZVirtualMachine] = [:]

    init(store: OwnedStore, limits: Limits) { self.store = store; self.limits = limits }

    static func entitled() -> Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.virtualization"] as? Bool == true
    }

    func handle(_ request: Request, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            if request.operation == "probe" {
                completion(.success(["backend": "apple_virtualization", "architecture": "arm64", "virtualization_supported": VZVirtualMachine.isSupported, "entitled": Self.entitled(), "guest_ready": false]))
                return
            }
            if request.operation == "stop_all" { stopAll(completion); return }
            guard let id = request.workload_id else { throw VMError.invalidRequest }
            switch request.operation {
            case "create":
                guard let metadata = request.metadata else { throw VMError.invalidMetadata }
                try limits.validate(metadata)
                try checkDiskBudget(id, metadata: metadata)
                try store.create(id, metadata: metadata)
                completion(.success(try inspect(id)))
            case "inspect": completion(.success(try inspect(id)))
            case "start": try start(id, completion: completion)
            case "stop": try stop(id, completion: completion)
            case "delete":
                guard machines[id].map({ $0.state == .stopped }) ?? true else { throw VMError.busy }
                try store.delete(id)
                machines.removeValue(forKey: id)
                completion(.success(result(id, state: "deleted")))
            default: throw VMError.unsupportedOperation
            }
        } catch { completion(.failure(error)) }
    }

    private func result(_ id: String, state: String) -> [String: Any] {
        ["backend": "apple_virtualization", "workload_id": id, "state": state, "guest_ready": false]
    }

    private func inspect(_ id: String) throws -> [String: Any] {
        let metadata = try store.inspect(id)
        var value = result(id, state: "stopped")
        value["resources"] = ["vcpu_count": metadata.vcpu_count, "memory_mib": metadata.memory_mib, "disk_mib": metadata.disk_mib]
        guard let vm = machines[id] else { return value }
        let state: String
        switch vm.state {
        case .running: state = "running"
        case .stopped: state = "stopped"
        case .error: state = "error"
        default: state = "transitioning"
        }
        value["state"] = state
        return value
    }

    private func checkDiskBudget(_ id: String, metadata: Metadata) throws {
        var allocated = metadata.disk_mib
        for name in try FileManager.default.contentsOfDirectory(atPath: store.root.path) where Request.validUUID(name) && name != id {
            allocated += try store.inspect(name).disk_mib
        }
        guard allocated <= limits.diskMiB else { throw VMError.capacityExceeded }
    }

    private func start(_ id: String, completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        if let machine = machines[id], machine.state == .running {
            completion(.success(result(id, state: "running"))); return
        }
        guard machines[id].map({ $0.state == .stopped }) ?? true else { throw VMError.busy }
        guard VZVirtualMachine.isSupported, Self.entitled() else { throw VMError.unsupportedPlatform }
        let metadata = try store.validateBootFiles(id)
        try limits.validate(metadata)
        var cpus = metadata.vcpu_count
        var memory = metadata.memory_mib
        for (other, vm) in machines where other != id && vm.state != .stopped {
            let allocation = try store.inspect(other)
            cpus += allocation.vcpu_count; memory += allocation.memory_mib
        }
        guard cpus <= limits.cpus, memory <= limits.memoryMiB else { throw VMError.capacityExceeded }
        let directory = try store.directory(id)
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = metadata.vcpu_count
        configuration.memorySize = UInt64(metadata.memory_mib) * 1048576
        let boot = VZLinuxBootLoader(kernelURL: directory.appendingPathComponent("kernel"))
        boot.commandLine = "console=hvc0 root=/dev/vda rw"
        configuration.bootLoader = boot
        configuration.platform = VZGenericPlatformConfiguration()
        let disk = try VZDiskImageStorageDeviceAttachment(url: directory.appendingPathComponent("rootfs.ext4"), readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        // Stable MAC for this owned UUID; locally administered unicast.
        let compact = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let octets = stride(from: 0, to: 10, by: 2).map { offset -> String in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            return String(compact[start..<compact.index(start, offsetBy: 2)])
        }
        network.macAddress = VZMACAddress(string: (["02"] + octets).joined(separator: ":"))!
        configuration.networkDevices = [network]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        // No console is connected to protocol stdout or another user's terminal.
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        do { try configuration.validate() } catch { throw VMError.invalidConfiguration }
        let vm = VZVirtualMachine(configuration: configuration)
        machines[id] = vm
        vm.start { outcome in
            switch outcome {
            case .success: completion(.success(self.result(id, state: "running")))
            case .failure: self.machines.removeValue(forKey: id); completion(.failure(VMError.virtualizationFailure))
            }
        }
    }

    private func stop(_ id: String, completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        _ = try store.inspect(id)
        guard let vm = machines[id], vm.state != .stopped else {
            completion(.success(result(id, state: "stopped"))); return
        }
        guard vm.canStop else { throw VMError.busy }
        vm.stop { error in
            if error != nil { completion(.failure(VMError.virtualizationFailure)) }
            else { self.machines.removeValue(forKey: id); completion(.success(self.result(id, state: "stopped"))) }
        }
    }

    func stopAll(_ completion: @escaping (Result<[String: Any], Error>) -> Void) {
        stopNext(Array(machines.keys), failure: nil, completion: completion)
    }

    private func stopNext(_ ids: [String], failure: Error?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let id = ids.first else {
            if let failure { completion(.failure(failure)) }
            else { completion(.success(["backend": "apple_virtualization", "state": "stopped", "disks_preserved": true])) }
            return
        }
        do {
            try stop(id) { result in
                switch result {
                case .success: self.stopNext(Array(ids.dropFirst()), failure: failure, completion: completion)
                case .failure(let error): self.stopNext(Array(ids.dropFirst()), failure: error, completion: completion)
                }
            }
        } catch { stopNext(Array(ids.dropFirst()), failure: error, completion: completion) }
    }
}
