import Foundation
import Synchronization
import Testing
@testable import SimpleMediaPlayer

/// Two windows can save the same file. Each save here runs on its own dispatch queue, so a save waiting for
/// another never blocks a cooperative thread, and every wait has a timeout.
@MainActor
struct MetadataSaveSerializationTests {
    @Test(arguments: InPlaceTestFormat.allCases)
    func secondSaveOfTheSameFileWaitsForTheFirst(format: InPlaceTestFormat) throws {
        let fixture = try format.preparedFixture()
        defer { fixture.remove() }
        let url = fixture.url
        let samples = try decodedSamples(at: url)
        let gate = WriteGate()
        defer { gate.release() }

        let first = BackgroundSave {
            try MediaFileRewriter.$inPlaceWrite.withValue(gate.inPlaceWrite) {
                try format.write(titleDraft("First"), to: url)
            }
        }
        try #require(gate.waitUntilHeld())
        let second = BackgroundSave { try format.write(titleDraft("Second"), to: url) }
        #expect(try second.finished(within: 0.5) == false)
        gate.release()

        #expect(try first.finished(within: 10))
        #expect(try second.finished(within: 10))
        #expect(try format.title(at: url) == "Second")
        #expect(try decodedSamples(at: url) == samples)
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    /// The second save reads the bytes the first one wrote, whichever path each one takes.
    @Test(arguments: SaveKind.allCases, SaveKind.allCases)
    func savesOfTheSameFileRunOneAtATime(first firstKind: SaveKind, second secondKind: SaveKind) throws {
        let fixture = try rawFixture()
        defer { fixture.remove() }
        let url = fixture.url
        let original = try Data(contentsOf: url)
        let gate = WriteGate()
        defer { gate.release() }
        let observed = ObservedBytes()

        let first = BackgroundSave { try save(firstKind, marker: "AAAA", to: url, holdingAt: gate) }
        try #require(gate.waitUntilHeld())
        let second = BackgroundSave { try save(secondKind, marker: "BBBB", to: url, observe: observed.record) }
        #expect(try second.finished(within: 0.5) == false)
        #expect(observed.values.isEmpty)
        gate.release()

        #expect(try first.finished(within: 10))
        #expect(try second.finished(within: 10))
        #expect(observed.values == [Data("AAAA".utf8)])
        #expect(try Data(contentsOf: url) == Data("BBBB".utf8) + original.dropFirst(4))
        #expect(try fixture.temporaryLeftovers().isEmpty)
    }

    @Test(arguments: SaveKind.allCases)
    func savesThroughHardLinksOfTheSameFileRunOneAtATime(second secondKind: SaveKind) throws {
        let fixture = try rawFixture()
        defer { fixture.remove() }
        let link = fixture.directory.appendingPathComponent("link.mp3")
        try FileManager.default.linkItem(at: fixture.url, to: link)
        let original = try Data(contentsOf: fixture.url)
        let gate = WriteGate()
        defer { gate.release() }
        let observed = ObservedBytes()

        let first = BackgroundSave { try save(.update, marker: "AAAA", to: fixture.url, holdingAt: gate) }
        try #require(gate.waitUntilHeld())
        let second = BackgroundSave { try save(secondKind, marker: "BBBB", to: link, observe: observed.record) }
        #expect(try second.finished(within: 0.5) == false)
        #expect(observed.values.isEmpty)
        gate.release()

        #expect(try first.finished(within: 10))
        #expect(try second.finished(within: 10))
        #expect(observed.values == [Data("AAAA".utf8)])
        #expect(try Data(contentsOf: link) == Data("BBBB".utf8) + original.dropFirst(4))
        // A replacement gives the link its own file; an in-place edit changes both names.
        let marker = secondKind == .update ? "BBBB" : "AAAA"
        #expect(try Data(contentsOf: fixture.url) == Data(marker.utf8) + original.dropFirst(4))
    }

    /// A save waiting for a file that another save then replaces waits for the new file instead, so a save
    /// started after the replacement still waits for it.
    @Test func saveWaitingForAReplacedFileWaitsForTheNewFile() throws {
        let fixture = try rawFixture()
        defer { fixture.remove() }
        let url = fixture.url
        let original = try Data(contentsOf: url)
        let fileNumber = try fixture.fileNumber()
        let firstGate = WriteGate()
        defer { firstGate.release() }
        let secondGate = WriteGate()
        defer { secondGate.release() }
        let observedBySecond = ObservedBytes()
        let observedByThird = ObservedBytes()

        let first = BackgroundSave { try save(.rewrite, marker: "AAAA", to: url, holdingAt: firstGate) }
        try #require(firstGate.waitUntilHeld())
        let second = BackgroundSave {
            try save(.update, marker: "BBBB", to: url, holdingAt: secondGate, observe: observedBySecond.record)
        }
        #expect(try second.finished(within: 0.5) == false)
        firstGate.release()
        #expect(try first.finished(within: 10))
        #expect(try fixture.fileNumber() != fileNumber)

        try #require(secondGate.waitUntilHeld())
        let third = BackgroundSave { try save(.update, marker: "CCCC", to: url, observe: observedByThird.record) }
        #expect(try third.finished(within: 0.5) == false)
        #expect(observedByThird.values.isEmpty)
        secondGate.release()

        #expect(try second.finished(within: 10))
        #expect(try third.finished(within: 10))
        #expect(observedBySecond.values == [Data("AAAA".utf8)])
        #expect(observedByThird.values == [Data("BBBB".utf8)])
        #expect(try Data(contentsOf: url) == Data("CCCC".utf8) + original.dropFirst(4))
    }

    @Test func saveOfAnotherFileDoesNotWait() throws {
        let fixture = try rawFixture()
        defer { fixture.remove() }
        let other = try rawFixture()
        defer { other.remove() }
        let gate = WriteGate()
        defer { gate.release() }

        let first = BackgroundSave { try save(.update, marker: "AAAA", to: fixture.url, holdingAt: gate) }
        try #require(gate.waitUntilHeld())
        let second = BackgroundSave { try save(.update, marker: "BBBB", to: other.url) }
        #expect(try second.finished(within: 5))
        #expect(try first.finished(within: 0) == false)
        gate.release()

        #expect(try first.finished(within: 10))
        #expect(try Data(contentsOf: other.url).prefix(4) == Data("BBBB".utf8))
        #expect(try Data(contentsOf: fixture.url).prefix(4) == Data("AAAA".utf8))
    }

    @Test func cancelledSaveWaitingForTheFileDoesNothing() throws {
        let fixture = try rawFixture()
        defer { fixture.remove() }
        let url = fixture.url
        let original = try Data(contentsOf: url)
        let gate = WriteGate()
        defer { gate.release() }
        let observed = ObservedBytes()

        let first = BackgroundSave { try save(.update, marker: "AAAA", to: url, holdingAt: gate) }
        try #require(gate.waitUntilHeld())
        let second = BackgroundSave(cancelled: true) {
            try save(.update, marker: "BBBB", to: url, observe: observed.record)
        }
        #expect(try second.finished(within: 0.5) == false)
        gate.release()

        #expect(try first.finished(within: 10))
        #expect(throws: CancellationError.self) { try second.finished(within: 10) }
        #expect(observed.values.isEmpty)
        #expect(try Data(contentsOf: url) == Data("AAAA".utf8) + original.dropFirst(4))
    }

    // MARK: - Helpers

    nonisolated enum SaveKind: CaseIterable, Sendable {
        case update, rewrite
    }

    private func rawFixture() throws -> InPlaceFixture {
        let fixture = try InPlaceFixture(copying: InPlaceFixture.resource("untagged-mp3", "mp3"))
        try Data((0..<64).map { UInt8($0) }).write(to: fixture.url)
        return fixture
    }
}

/// Writes `marker` over the first four bytes in place or through a replacement, reporting the bytes it replaces.
/// With a gate, the save holds inside its write: the in-place write itself, or the replacement's copy.
nonisolated private func save(
    _ kind: MetadataSaveSerializationTests.SaveKind,
    marker: String,
    to url: URL,
    holdingAt gate: WriteGate? = nil,
    observe: @Sendable (Data) -> Void = { _ in }
) throws {
    let marker = Data(marker.utf8)
    switch kind {
    case .update:
        try MediaFileRewriter.$inPlaceWrite.withValue(gate?.inPlaceWrite ?? MediaFileRewriter.inPlaceWrite) {
            try MediaFileRewriter.update(at: url, analysisCacheDirectory: nil) { handle, _ in
                observe(try MediaFileRewriter.read(from: handle, at: 0, count: 4))
                return MediaFileRewriter.InPlaceEdit(offset: 0, originalLength: 4, data: marker)
            } rewrite: { _, _, _ in
                Issue.record("The edit fits in place")
            }
        }
    case .rewrite:
        try MediaFileRewriter.rewrite(at: url, analysisCacheDirectory: nil) { source, output, size in
            observe(try MediaFileRewriter.read(from: source, at: 0, count: 4))
            try output.write(contentsOf: marker)
            gate?.hold()
            try MediaFileRewriter.copy(from: source, range: 4..<size, to: output)
        }
    }
}

/// Holds a save inside its write until released; the timeout keeps a failed test from hanging.
nonisolated private final class WriteGate: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    var inPlaceWrite: @Sendable (FileHandle, Data) throws -> Void {
        { [self] handle, data in
            hold()
            try handle.write(contentsOf: data)
        }
    }

    func hold() {
        entered.signal()
        _ = released.wait(timeout: .now() + 10)
    }

    func waitUntilHeld() -> Bool { entered.wait(timeout: .now() + 10) == .success }

    func release() { released.signal() }
}

nonisolated private final class ObservedBytes: Sendable {
    private let storage = Mutex<[Data]>([])
    var values: [Data] { storage.withLock { $0 } }
    func record(_ data: Data) { storage.withLock { $0.append(data) } }
}

/// Runs a save in a task whose jobs run on its own serial queue instead of the cooperative pool.
nonisolated private final class BackgroundSave: TaskExecutor {
    private let queue = DispatchQueue(label: "MetadataSaveSerializationTests.BackgroundSave")
    private let done = DispatchSemaphore(value: 0)
    private let error = Mutex<(any Error)?>(nil)

    init(cancelled: Bool = false, _ body: @escaping @Sendable () throws -> Void) {
        Task.detached(executorPreference: self) { [self] in
            if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
            do { try body() } catch let thrown { error.withLock { $0 = thrown } }
            done.signal()
        }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    /// False while the save is still running after `seconds`; once it has finished, true or its error.
    func finished(within seconds: Double) throws -> Bool {
        guard done.wait(timeout: .now() + seconds) == .success else { return false }
        done.signal()
        if let error = error.withLock({ $0 }) { throw error }
        return true
    }
}
