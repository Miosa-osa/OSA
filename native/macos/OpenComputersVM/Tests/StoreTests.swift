import Foundation

@main struct StoreTests {
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = base.appendingPathComponent("cache")
        let root = base.appendingPathComponent("owned")
        for directory in [cache, root] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let store = try OwnedStore(root: root.path, artifacts: cache.path)
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)
        let metadata = Metadata(backend: "apple_virtualization", architecture: "arm64", kernel_sha256: digest, rootfs_sha256: digest, vcpu_count: 1, memory_mib: 512, disk_mib: 64)
        try Data("wrong kernel".utf8).write(to: cache.appendingPathComponent(digest + ".kernel"))
        do { try store.create(id, metadata: metadata); fatalError("accepted corrupt artifact") }
        catch VMError.digestMismatch { }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(id), withDestinationURL: cache)
        do { _ = try store.inspect(id); fatalError("accepted symlink workload") }
        catch VMError.unsafePath { }
        precondition(FileManager.default.fileExists(atPath: cache.appendingPathComponent(digest + ".kernel").path))
        print("store digest rejection and symlink isolation: PASS")
    }
}
