// Models the old helper's signal resistance for the external watchdog test.
import Foundation

signal(SIGTERM, SIG_IGN)
let allocation = Data(repeating: 0x5A, count: 8 * 1024 * 1024)
print("READY")
fflush(stdout)
_ = withExtendedLifetime(allocation) { sleep(30) }
