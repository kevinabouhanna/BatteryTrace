import Darwin

public enum Clock {
    /// Nanoseconds of uptime, not counting sleep. Intervals measured on this
    /// clock match the kernel's counters, which also stop while asleep.
    @inline(__always)
    public static func uptimeNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// CPU time of the calling thread, in nanoseconds.
    @inline(__always)
    public static func threadCPUTimeNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// This process's own CPU time (user + system), in nanoseconds. Used to
    /// report what Battery Trace itself costs.
    public static func selfCPUTimeNS() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = UInt64(usage.ru_utime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_utime.tv_usec) * 1000
        let system = UInt64(usage.ru_stime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_stime.tv_usec) * 1000
        return user + system
    }
}
