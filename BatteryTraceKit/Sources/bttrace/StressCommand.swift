import Foundation
import Metal

/// Load generators for validation runs: a known app doing a known thing.
enum StressCommand {
    static func run(_ arguments: inout Arguments) {
        let kind = arguments.next() ?? "cpu"
        let seconds = arguments.double("--seconds", default: 30)
        switch kind {
        case "cpu":
            let threads = arguments.int("--threads", default: ProcessInfo.processInfo.activeProcessorCount)
            cpu(threads: threads, seconds: seconds)
        case "gpu":
            gpu(seconds: seconds)
        default:
            print("usage: bttrace stress cpu|gpu [--seconds 30] [--threads N]")
        }
    }

    static func cpu(threads: Int, seconds: Double) {
        print("CPU stress: \(threads) threads for \(Int(seconds)) s (pid \(getpid()))")
        let deadline = Date().addingTimeInterval(seconds)
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            Thread.detachNewThread {
                var x = 1.0
                while Date() < deadline {
                    for _ in 0..<100_000 { x = x * 1.000_000_1 + 1e-9 }
                }
                if x.isNaN { print(x) }
                group.leave()
            }
        }
        group.wait()
    }

    static func gpu(seconds: Double) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("no Metal device")
            return
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = float(id) * 0.0001;
            for (int i = 0; i < 4096; i++) { x = fma(x, 1.0001, 0.0001); x = sin(x) * cos(x) + x; }
            out[id] = x;
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "burn")!)
            let count = 1 << 20
            let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.size, options: .storageModePrivate)!
            print("GPU stress on \(device.name) for \(Int(seconds)) s (pid \(getpid()))")
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let commands = queue.makeCommandBuffer()!
                let encoder = commands.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
                encoder.endEncoding()
                commands.commit()
                commands.waitUntilCompleted()
            }
        } catch {
            print("Metal error: \(error)")
        }
    }
}
