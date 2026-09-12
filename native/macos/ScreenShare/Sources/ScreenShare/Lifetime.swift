import Darwin
import Foundation

/// Limits apply across OSA backends and worktrees, not just one BEAM instance.
/// The watchdog has its own queue so it can exit even if capture/main is stuck.
final class Lifetime {
    private let queue = DispatchQueue(label: "osa.capture.watchdog")
    private var sources: [DispatchSourceProtocol] = []
    private var slot: Int32 = -1
    private let parent = getppid()
    private let memoryBytes: UInt64
    private let idleSeconds: Double
    private let lock = NSLock()
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var cleanupHook: () -> Void = {}
    var beforeExit: () -> Void {
        get { lock.lock(); defer { lock.unlock() }; return cleanupHook }
        set { lock.lock(); defer { lock.unlock() }; cleanupHook = newValue }
    }

    init(memoryMB: Int, idleSeconds: Int) {
        self.memoryBytes = UInt64(memoryMB) * 1024 * 1024
        self.idleSeconds = Double(idleSeconds)
    }

    func start() {
        // Private per-user directory, no symlink following. Locks stay on disk:
        // unlinking a held lock would let a new process lock a different inode.
        let directory = "/tmp/osa-screen-capture-\(getuid())"
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            finish("lock_directory_failed", status: 75)
        }
        var info = stat()
        guard lstat(directory, &info) == 0,
            info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
            (info.st_mode & 0o077) == 0
        else {
            finish("unsafe_lock_directory", status: 75)
        }
        for index in 0..<2 {
            let fd = open(
                "\(directory)/\(index).lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { continue }
            var entry = stat()
            if fstat(fd, &entry) == 0 && entry.st_uid == getuid()
                && (entry.st_mode & S_IFMT) == S_IFREG
                && flock(fd, LOCK_EX | LOCK_NB) == 0
            {
                slot = fd
                break
            }
            close(fd)
        }
        guard slot >= 0 else { finish("helper_limit", status: 75) }

        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { self.finish("signal") }
            source.resume()
            sources.append(source)
        }
        // Port.close and a dead port owner close this pipe, even if BEAM lives.
        DispatchQueue.global(qos: .utility).async {
            var bytes = [UInt8](repeating: 0, count: 256)
            while true {
                let count = read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { self.finish("owner_eof") }
                if count < 0 && errno != EINTR { self.finish("owner_pipe_error") }
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler {
            guard self.parent > 1, getppid() == self.parent else {
                self.finish("owner_exited")
            }
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { self.finish("memory_measurement_failed", status: 70) }
            // Physical footprint includes compressed memory, unlike RSS.
            if usage.ri_phys_footprint > self.memoryBytes {
                self.finish("memory_limit footprint=\(usage.ri_phys_footprint)", status: 70)
            }
            self.lock.lock()
            let idle = ProcessInfo.processInfo.systemUptime - self.lastActivity
            self.lock.unlock()
            if idle >= self.idleSeconds { self.finish("idle_timeout") }
        }
        timer.resume()
        sources.append(timer)
    }

    func activity() {
        lock.lock()
        lastActivity = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func finish(_ reason: String, status: Int32 = 0) -> Never {
        // Diagnostics must not block the watchdog if its owner stops reading.
        _ = fcntl(STDERR_FILENO, F_SETFL, fcntl(STDERR_FILENO, F_GETFL) | O_NONBLOCK)
        let message = "[ScreenShare] stopping reason=\(reason)\n"
        message.utf8CString.withUnsafeBufferPointer {
            _ = Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count - 1)
        }
        // Best-effort release of this viewer's held input, with a hard deadline
        // so an input/system call cannot strand the independent watchdog.
        let cleanup = DispatchGroup()
        cleanup.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            self.beforeExit()
            cleanup.leave()
        }
        _ = cleanup.wait(timeout: .now() + .milliseconds(100))
        // Kernel teardown closes sockets, releases capture surfaces and locks.
        // Do not await a possibly wedged capture task on an emergency exit.
        _exit(status)
    }
}
