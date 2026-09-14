import Foundation
import Darwin

@main
struct HistoryMemoryBenchmark {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, let count = Int(args[3]) else { fatalError("usage: benchmark prepare|read directory count") }
        let root = URL(fileURLWithPath: args[2])
        if args[1] == "prepare" {
            let store = ClipboardStore(storageDirectory: root, getCleanupDays: { 0 })
            for index in 0..<count {
                try autoreleasepool {
                    // 64 KiB per format, plus text. Synthetic storage payload, not image-decoder input.
                    let bytes = Data((0..<(64 * 1024)).map { UInt8(($0 + index) % 251) })
                    let item = ClipboardItem(id: UUID(), content: "Synthetic fixture \(index)", type: .text,
                        timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + index)), representations: ["com.synthetic.binary": bytes])
                    _ = try store.upsert(item)
                }
            }
            return
        }
        let before = footprint(), start = Date()
        let store = ClipboardStore(storageDirectory: root, getCleanupDays: { 0 })
        var rows: [ClipboardItem] = []
        try autoreleasepool { rows = try store.readItems() }
        guard rows.count == count else { throw ClipboardStorageError.database("Fixture count mismatch") }
        let elapsed = Date().timeIntervalSince(start)
        withExtendedLifetime(rows) {
            let after = footprint()
            print("{\"count\":\(count),\"footprint_before\":\(before),\"footprint_after\":\(after),\"delta\":\(after >= before ? after - before : 0),\"load_seconds\":\(elapsed)}")
        }
    }
}
