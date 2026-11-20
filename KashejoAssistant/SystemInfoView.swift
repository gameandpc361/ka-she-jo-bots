import SwiftUI
import UIKit
import Darwin
import MachO

struct SystemInfoView: View {
    @State private var snapshot = Snapshot()
    @State private var lastCPUTime: Double?
    @State private var lastSample = Date()
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        List {
            Section("端末") {
                LabeledContent("機種", value: machineIdentifier())
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("端末名", value: UIDevice.current.model)
                LabeledContent("アプリ", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "不明")
                LabeledContent("ビルド", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "不明")
                LabeledContent("稼働時間", value: ProcessInfo.processInfo.systemUptime.formatted(.number.precision(.fractionLength(0))) + " 秒")
            }
            Section("ストレージ") {
                LabeledContent("端末の総容量", value: ByteCountFormatter.string(fromByteCount: snapshot.totalStorage, countStyle: .file))
                LabeledContent("端末の空き容量", value: ByteCountFormatter.string(fromByteCount: snapshot.freeStorage, countStyle: .file))
                LabeledContent("アプリ領域の概算", value: ByteCountFormatter.string(fromByteCount: snapshot.appStorage, countStyle: .file))
                Text("アプリ領域はDocuments・Library・Cachesのファイルサイズ合計です。OS管理領域などを含む厳密なインストールサイズとは異なります。").font(.caption).foregroundStyle(.secondary)
            }
            Section("メモリ") {
                LabeledContent("物理メモリ", value: ByteCountFormatter.string(fromByteCount: snapshot.physicalMemory, countStyle: .memory))
                LabeledContent("システム空きメモリ（推定）", value: ByteCountFormatter.string(fromByteCount: snapshot.freeMemory, countStyle: .memory))
                LabeledContent("アプリ使用メモリ", value: ByteCountFormatter.string(fromByteCount: snapshot.appMemory, countStyle: .memory))
                Text("空きメモリはMachのVM統計から算出した推定値です。iOSのメモリ圧縮やページキャッシュにより、一般的なPCの空きメモリ表示とは意味が異なります。").font(.caption).foregroundStyle(.secondary)
            }
            Section("CPU") {
                LabeledContent("Kashejo Assistant", value: snapshot.appCPU.map { String(format: "%.1f%%", $0) } ?? "計測中")
                LabeledContent("システム全体", value: "取得不可（iOS公開APIの制限）")
            }
            Section { LabeledContent("最終更新", value: snapshot.updated.formatted(date: .omitted, time: .standard)); Text("このページを表示している間だけ約2秒ごとに更新します。ページを離れると計測を停止します。").font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("システム情報")
        .navigationBarTitleDisplayMode(.inline)
        .task { startSampling() }
        .onDisappear { timerTask?.cancel(); timerTask = nil }
    }

    private struct Snapshot {
        var totalStorage: Int64 = 0; var freeStorage: Int64 = 0; var appStorage: Int64 = 0
        var physicalMemory: Int64 = Int64(ProcessInfo.processInfo.physicalMemory); var freeMemory: Int64 = 0
        var appMemory: Int64 = 0; var appCPU: Double?; var updated = Date()
    }

    private func startSampling() {
        timerTask?.cancel()
        sample()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                sample()
            }
        }
    }

    private func sample() {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            snapshot.totalStorage = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
            snapshot.freeStorage = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
        snapshot.appStorage = directorySize(fm.urls(for: .documentDirectory, in: .userDomainMask).first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory()))
        snapshot.appMemory = residentMemory()
        snapshot.freeMemory = systemFreeMemory()
        let cpu = processCPUSeconds()
        let now = Date()
        if let previous = lastCPUTime {
            let elapsed = now.timeIntervalSince(lastSample)
            if elapsed > 0 { snapshot.appCPU = max(0, min(100 * Double(ProcessInfo.processInfo.activeProcessorCount), (cpu - previous) / elapsed * 100)) }
        }
        lastCPUTime = cpu; lastSample = now; snapshot.updated = now
    }

    private func directorySize(_ url: URL) -> Int64 {
        let roots = [URL(fileURLWithPath: NSHomeDirectory())]
        var total: Int64 = 0
        for root in Set(roots) {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in e {
                if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
            }
        }
        return total
    }

    private func residentMemory() -> Int64 {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private func systemFreeMemory() -> Int64 {
        var stats = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Int64(vm_kernel_page_size)
        return Int64(stats.free_count + stats.inactive_count) * page
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private func machineIdentifier() -> String {
        var size = 0; sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}
