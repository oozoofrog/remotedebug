import Darwin

enum ProcessMemory {
    /// 이 프로세스의 phys_footprint(MiB). iOS가 확장 메모리 한도에 쓰는 값이다. 읽지 못하면 `nil`.
    static func physFootprintMiB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10
    }
}
