import Darwin

/// Finds functions in private libraries at run time.
///
/// Nothing in Battery Trace links a private framework. Every private function
/// is looked up here, and a missing library or symbol becomes `nil`, which the
/// caller reports as "source unavailable". An OS update that removes a symbol
/// hides a metric and does not crash the app.
enum PrivateSymbols {
    /// `RTLD_DEFAULT`: search every image already loaded, libSystem included.
    nonisolated(unsafe) static let loadedImages = UnsafeMutableRawPointer(bitPattern: -2)

    static func open(_ path: String) -> UnsafeMutableRawPointer? {
        dlopen(path, RTLD_NOW | RTLD_LOCAL)
    }

    static func function<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as _: T.Type = T.self) -> T? {
        guard let pointer = dlsym(handle ?? loadedImages, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
