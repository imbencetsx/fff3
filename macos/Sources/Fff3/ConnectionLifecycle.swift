import Foundation

/// Serial-queue lifecycle shared by connect timers, cancellation and delegate callbacks.
struct ConnectionLifecycle {
    enum Phase { case idle, connecting, discovering, ready, cancelling, waiting, suspended, closed }
    private(set) var phase = Phase.idle
    private(set) var generation = 0

    mutating func begin() -> Int? {
        guard phase == .idle || phase == .waiting || phase == .suspended else { return nil }
        generation += 1
        phase = .connecting
        return generation
    }

    mutating func connected() -> Bool {
        guard phase == .connecting else { return false }
        phase = .discovering
        return true
    }

    mutating func ready() -> Bool {
        guard phase == .discovering else { return false }
        generation += 1
        phase = .ready
        return true
    }

    mutating func cancel(generation: Int) -> Bool {
        guard generation == self.generation,
              phase == .connecting || phase == .discovering || phase == .ready else { return false }
        self.generation += 1
        phase = .cancelling
        return true
    }

    mutating func disconnected() -> Bool {
        guard phase == .connecting || phase == .discovering || phase == .ready || phase == .cancelling else { return false }
        generation += 1
        phase = .waiting
        return true
    }

    mutating func suspend() { generation += 1; phase = .suspended }
    mutating func close() { generation += 1; phase = .closed }
}

struct WriteAcknowledgementToken {
    private var sequence = 0
    private(set) var pending: Int?
    mutating func begin() -> Int { sequence += 1; pending = sequence; return sequence }
    mutating func complete(_ token: Int) -> Bool {
        guard pending == token else { return false }
        pending = nil
        return true
    }
    mutating func clear() { pending = nil }
}
