import Darwin
import Foundation

struct ElapsedTimeReading: Equatable {
    let durationSinceBoot: TimeInterval
    let bootIdentifier: String?
}

enum ElapsedTimeClock {
    static var current: ElapsedTimeReading {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanoseconds =
            Double(mach_continuous_time())
            * Double(timebase.numer)
            / Double(timebase.denom)

        return ElapsedTimeReading(
            durationSinceBoot: nanoseconds / 1_000_000_000,
            bootIdentifier: bootSessionIdentifier ?? bootTimeIdentifier
        )
    }

    private static var bootSessionIdentifier: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
            size > 1
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { pointer in
            sysctlbyname("kern.bootsessionuuid", pointer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return "session:\(String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self))"
    }

    private static var bootTimeIdentifier: String? {
        var managementInformationBase = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let result = managementInformationBase.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, 2, &bootTime, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<timeval>.size else { return nil }
        return "time:\(bootTime.tv_sec):\(bootTime.tv_usec)"
    }
}
