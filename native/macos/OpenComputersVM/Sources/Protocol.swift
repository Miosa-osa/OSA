import Foundation

enum VMError: String, Error {
    case invalidRequest, unsupportedOperation, invalidMetadata, unsafePath, missingArtifact
    case digestMismatch, invalidImage, notOwned, ownershipConflict, busy, ioFailure
    case unsupportedPlatform, invalidConfiguration, virtualizationFailure, capacityExceeded
}

struct Metadata: Codable, Equatable {
    let backend: String
    let architecture: String
    let kernel_sha256: String
    let rootfs_sha256: String
    let vcpu_count: Int
    let memory_mib: Int
    let disk_mib: Int

    func validate() throws {
        let digest = "^[0-9a-f]{64}$"
        guard backend == "apple_virtualization", architecture == "arm64",
              kernel_sha256.range(of: digest, options: .regularExpression) != nil,
              rootfs_sha256.range(of: digest, options: .regularExpression) != nil,
              (1...64).contains(vcpu_count), (512...262144).contains(memory_mib),
              (64...1048576).contains(disk_mib) else { throw VMError.invalidMetadata }
    }
}

struct Request: Decodable {
    let version: Int
    let id: String
    let operation: String
    let workload_id: String?
    let metadata: Metadata?

    static func validUUID(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    static func decode(_ data: Data) throws -> Request {
        guard data.count <= 16384,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["operation"] as? String else { throw VMError.invalidRequest }
        var fields: Set<String> = ["version", "id", "operation"]
        if !["probe", "stop_all"].contains(op) { fields.insert("workload_id") }
        if op == "create" { fields.insert("metadata") }
        guard Set(object.keys) == fields else { throw VMError.invalidRequest }
        if let metadata = object["metadata"] as? [String: Any] {
            guard Set(metadata.keys) == Set(["backend", "architecture", "kernel_sha256", "rootfs_sha256", "vcpu_count", "memory_mib", "disk_mib"]) else { throw VMError.invalidMetadata }
        }
        let request = try JSONDecoder().decode(Request.self, from: data)
        guard request.version == 1, !request.id.isEmpty, request.id.utf8.count <= 128,
              request.workload_id.map(validUUID) ?? ["probe", "stop_all"].contains(op) else { throw VMError.invalidRequest }
        guard ["probe", "create", "start", "stop", "delete", "inspect", "stop_all"].contains(op) else { throw VMError.unsupportedOperation }
        try request.metadata?.validate()
        return request
    }
}

struct Limits {
    let cpus: Int
    let memoryMiB: Int
    let diskMiB: Int

    func validate(_ metadata: Metadata) throws {
        try metadata.validate()
        guard metadata.vcpu_count <= cpus, metadata.memory_mib <= memoryMiB,
              metadata.disk_mib <= diskMiB else { throw VMError.capacityExceeded }
    }
}
