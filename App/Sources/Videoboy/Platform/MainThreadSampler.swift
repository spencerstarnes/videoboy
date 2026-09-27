//
//  MainThreadSampler.swift — an in-process sampling profiler for the main thread.
//
//  Purpose : Finds what the main thread is doing during a stall that no labelled
//            measurement explains. `sample(1)` needs task access this app's shell
//            may not have; a process may always read its OWN threads, so this
//            suspends the main thread every millisecond from a background thread,
//            reads its registers, walks the frame-pointer chain and resumes it.
//  Inputs  : start/stop; stretches (start/end host times) to attribute.
//  Outputs : the most common functions in the samples inside those stretches.
//  Connects: self-QA only (ImportSelfQA, with VIDEOBOY_MAIN_SAMPLER=1). Never in a
//            normal run: suspending the main thread 1,000×/s costs a little.
//  Extend  : raise `maximumFrames` for deeper stacks.
//

import Darwin
import Foundation
import QuartzCore

final class MainThreadSampler {

    private static let maximumFrames = 48
    private let mainThread: thread_act_t
    private var samples: [(time: CFTimeInterval, frames: [UInt])] = []
    private let lock = NSLock()
    private var running = false

    /// Call on the main thread.
    init() {
        precondition(Thread.isMainThread)
        mainThread = mach_thread_self()
    }

    func start() {
        running = true
        let thread = Thread { [weak self] in
            while let self, self.running {
                self.takeSample()
                usleep(1000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { running = false }

    /// Strips arm64e pointer authentication bits.
    private static func strip(_ value: UInt64) -> UInt { UInt(value & 0x0000_000F_FFFF_FFFF) }

    /// Filled while the main thread is suspended. NOTHING may allocate in that window:
    /// if main was stopped holding the malloc lock, an allocation here deadlocks both
    /// threads (the first version of this did exactly that). Copied out after resume.
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: MainThreadSampler.maximumFrames)

    deinit { buffer.deallocate() }

    private func takeSample() {
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        var depth = 0
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            buffer[0] = Self.strip(state.__pc); buffer[1] = Self.strip(state.__lr); depth = 2
            var fp = Self.strip(state.__fp)
            while fp != 0, depth < Self.maximumFrames, fp % 8 == 0 {
                guard let frame = UnsafePointer<UInt>(bitPattern: fp) else { break }
                let next = frame.pointee
                let returnAddress = Self.strip(UInt64(frame.advanced(by: 1).pointee))
                if returnAddress == 0 { break }
                buffer[depth] = returnAddress; depth += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        guard depth > 0 else { return }
        let frames = Array(UnsafeBufferPointer(start: buffer, count: depth))
        let now = CACurrentMediaTime()
        lock.lock(); samples.append((now, frames)); lock.unlock()
    }

    /// The functions most often on the stack inside the given stretches, with how many
    /// samples each appears in, and the most common innermost (self) functions.
    func report(for stretches: [(start: CFTimeInterval, end: CFTimeInterval)], top: Int = 25) -> String {
        lock.lock(); let all = samples; lock.unlock()
        let inside = all.filter { sample in stretches.contains { sample.time >= $0.start && sample.time <= $0.end } }
        var inclusive: [String: Int] = [:]
        var leaf: [String: Int] = [:]
        var names: [UInt: String] = [:]
        func name(_ address: UInt) -> String {
            if let known = names[address] { return known }
            var info = Dl_info()
            var result = String(format: "0x%lx", address)
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let symbol = info.dli_sname {
                let raw = String(cString: symbol)
                result = demangle(raw)
            }
            names[address] = result
            return result
        }
        for sample in inside {
            for function in Set(sample.frames.map(name)) { inclusive[function, default: 0] += 1 }
            if let first = sample.frames.first { leaf[name(first), default: 0] += 1 }
        }
        func lines(_ table: [String: Int]) -> String {
            table.sorted { $0.value > $1.value }.prefix(top)
                .map { "  \($0.value)  \($0.key)" }.joined(separator: "\n")
        }
        return "main-thread samples inside \(stretches.count) stretches: \(inside.count)\n"
            + "INCLUSIVE (on the stack):\n\(lines(inclusive))\nSELF (innermost):\n\(lines(leaf))"
    }

    private func demangle(_ symbol: String) -> String {
        typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let handle = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return symbol }
        let demangle = unsafeBitCast(handle, to: Demangle.self)
        guard let out = symbol.withCString({ demangle($0, strlen($0), nil, nil, 0) }) else { return symbol }
        defer { free(out) }
        return String(cString: out)
    }
}
