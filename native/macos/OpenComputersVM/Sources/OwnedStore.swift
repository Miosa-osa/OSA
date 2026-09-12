import Foundation
import CryptoKit
import Darwin

/// Private per-user storage, not an isolation boundary against that same OS user.
final class OwnedStore {
    let root: URL
    let artifacts: URL
    private let lockFD: Int32
    private let files = ["kernel", "rootfs.ext4", "metadata.json"]

    init(root: String, artifacts: String) throws {
        guard root.hasPrefix("/"), artifacts.hasPrefix("/") else { throw VMError.unsafePath }
        self.root = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        self.artifacts = URL(fileURLWithPath: artifacts).resolvingSymlinksInPath()
        guard self.root.path != "/", self.root != self.artifacts else { throw VMError.unsafePath }
        for url in [self.root, self.artifacts] {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw VMError.unsafePath }
        }
        lockFD = open(self.root.appendingPathComponent(".owner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw VMError.ioFailure }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            throw VMError.busy
        }
    }

    deinit { close(lockFD) }

    func directory(_ id: String) throws -> URL {
        guard Request.validUUID(id) else { throw VMError.unsafePath }
        let url = root.appendingPathComponent(id)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { throw VMError.notOwned }
            throw VMError.ioFailure
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { throw VMError.unsafePath }
        return url
    }

    func inspect(_ id: String) throws -> Metadata {
        let url = try directory(id).appendingPathComponent("metadata.json")
        let handle = try regular(url, maximum: 16384)
        defer { try? handle.close() }
        let metadata = try JSONDecoder().decode(Metadata.self, from: handle.readToEnd() ?? Data())
        try metadata.validate()
        return metadata
    }

    func create(_ id: String, metadata: Metadata) throws {
        guard Request.validUUID(id) else { throw VMError.unsafePath }
        try metadata.validate()
        do {
            let previous = try inspect(id)
            guard previous == metadata else { throw VMError.ownershipConflict }
            return
        } catch VMError.notOwned { }
        let destination = root.appendingPathComponent(id)
        guard mkdir(destination.path, 0o700) == 0 else { throw VMError.ioFailure }
        do {
            try copyVerified(metadata.kernel_sha256, suffix: ".kernel", destination: destination.appendingPathComponent("kernel"), maximum: 256 * 1024 * 1024, magic: (56, Data([0x41, 0x52, 0x4d, 0x64])))
            try copyVerified(metadata.rootfs_sha256, suffix: ".rootfs", destination: destination.appendingPathComponent("rootfs.ext4"), maximum: UInt64(metadata.disk_mib) * 1048576, magic: (1080, Data([0x53, 0xef])))
            let data = try JSONEncoder().encode(metadata)
            let fd = open(destination.appendingPathComponent("metadata.json").path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o400)
            guard fd >= 0 else { throw VMError.ioFailure }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try syncDirectory(destination)
            try syncDirectory(root)
        } catch {
            // Only the fixed files in the directory created by this invocation.
            for file in files { _ = unlink(destination.appendingPathComponent(file).path) }
            _ = rmdir(destination.path)
            throw error
        }
    }

    func validateBootFiles(_ id: String) throws -> Metadata {
        let metadata = try inspect(id)
        let directory = try self.directory(id)
        let kernel = try regular(directory.appendingPathComponent("kernel"), maximum: 256 * 1024 * 1024)
        defer { try? kernel.close() }
        guard try digest(kernel) == metadata.kernel_sha256 else { throw VMError.digestMismatch }
        let disk = try regular(directory.appendingPathComponent("rootfs.ext4"), maximum: UInt64(metadata.disk_mib) * 1048576)
        try disk.close()
        // Writable rootfs intentionally changes after boot; the imported source was pinned.
        return metadata
    }

    func delete(_ id: String) throws {
        _ = try inspect(id)
        let directory = try self.directory(id)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard Set(names) == Set(files) else { throw VMError.ownershipConflict }
        for file in files {
            let handle = try regular(directory.appendingPathComponent(file), maximum: UInt64.max)
            try handle.close()
        }
        // Metadata is removed last; never recursively delete an arbitrary directory.
        for file in files {
            guard unlink(directory.appendingPathComponent(file).path) == 0 else { throw VMError.ioFailure }
        }
        guard rmdir(directory.path) == 0 else { throw VMError.ioFailure }
        try syncDirectory(root)
    }

    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VMError.ioFailure }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw VMError.ioFailure }
    }

    private func regular(_ url: URL, maximum: UInt64) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? VMError.missingArtifact : VMError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid(), info.st_size > 0,
              UInt64(info.st_size) <= maximum else { close(fd); throw VMError.unsafePath }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func digest(_ input: FileHandle) throws -> String {
        var hash = SHA256()
        while let data = try input.read(upToCount: 1048576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copyVerified(_ digest: String, suffix: String, destination: URL, maximum: UInt64, magic: (UInt64, Data)) throws {
        let source = try regular(artifacts.appendingPathComponent(digest + suffix), maximum: maximum)
        defer { try? source.close() }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, suffix == ".kernel" ? 0o400 : 0o600)
        guard fd >= 0 else { throw VMError.ioFailure }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var hash = SHA256()
        var count: UInt64 = 0
        while let data = try source.read(upToCount: 1048576), !data.isEmpty {
            count += UInt64(data.count)
            guard count <= maximum else { throw VMError.invalidImage }
            hash.update(data: data)
            try output.write(contentsOf: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw VMError.digestMismatch }
        guard suffix != ".rootfs" || count == maximum else { throw VMError.invalidImage }
        // Inspect copied bytes, not a path that could have changed after verification.
        try output.synchronize()
        let verified = try regular(destination, maximum: maximum)
        defer { try? verified.close() }
        try verified.seek(toOffset: magic.0)
        guard try verified.read(upToCount: magic.1.count) == magic.1 else { throw VMError.invalidImage }
    }
}
