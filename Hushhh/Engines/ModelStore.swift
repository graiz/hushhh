import Foundation
import CryptoKit
import Combine
import WhisperKit

enum ModelID: Hashable {
    case qvac
    case whisper(WhisperModel)
}

enum ModelStatus: Equatable {
    case notInstalled
    case downloading(Double)
    case installed
    case failed(String)
}

/// Downloads, locates and deletes the on-device speech models.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    nonisolated static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Hushhh/Models", isDirectory: true)
    }()
    nonisolated static let whisperBase = root.appendingPathComponent("whisper", isDirectory: true)
    nonisolated static let qvacFolder = root.appendingPathComponent("qvac", isDirectory: true)
    nonisolated static let qvacModelURL = qvacFolder.appendingPathComponent("transcribepsy-250m-eu-sub.gguf")
    // Pinned to a commit and checked against its published SHA-256, so the file can't
    // change underneath us before it's loaded into native code.
    nonisolated static let qvacRemoteURL = URL(string: "https://huggingface.co/qvac/TranscribePsy-250M-EU-sub-gguf/resolve/92460e0a8e7dc20f2fb126198bdd9eebb9ba2dc7/transcribepsy-250m-eu-sub.gguf")!
    nonisolated static let qvacSHA256 = "a93ef324d38e410b5e49389db95d06364eddbb890b74a69f311e482d2fda6f4b"
    static let qvacSizeLabel = "305 MB"

    @Published private(set) var statuses: [ModelID: ModelStatus] = [:]

    private var tasks: [ModelID: Task<Void, Never>] = [:]
    private var progressObservation: NSKeyValueObservation?
    private let defaults = UserDefaults.standard

    private init() {
        try? FileManager.default.createDirectory(at: Self.whisperBase, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.qvacFolder, withIntermediateDirectories: true)
        refresh()
    }

    func status(_ id: ModelID) -> ModelStatus { statuses[id] ?? .notInstalled }

    func isInstalled(_ id: ModelID) -> Bool { status(id) == .installed }

    func refresh() {
        statuses[.qvac] = FileManager.default.fileExists(atPath: Self.qvacModelURL.path) ? .installed : (downloadingStatus(.qvac) ?? .notInstalled)
        for model in WhisperModel.allCases {
            let id = ModelID.whisper(model)
            statuses[id] = whisperFolder(model) != nil ? .installed : (downloadingStatus(id) ?? .notInstalled)
        }
    }

    private func downloadingStatus(_ id: ModelID) -> ModelStatus? {
        if case .downloading = statuses[id] { return statuses[id] }
        return nil
    }

    func whisperFolder(_ model: WhisperModel) -> URL? {
        guard let path = defaults.string(forKey: "whisperFolder.\(model.rawValue)") else { return nil }
        let url = URL(fileURLWithPath: path)
        let encoder = url.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path) ? url : nil
    }

    // MARK: Download

    func download(_ id: ModelID) {
        guard tasks[id] == nil else { return }
        statuses[id] = .downloading(0)
        switch id {
        case .qvac: downloadQVAC()
        case .whisper(let model): downloadWhisper(model)
        }
    }

    private func downloadQVAC() {
        let task = URLSession.shared.downloadTask(with: Self.qvacRemoteURL) { [weak self] tempURL, response, error in
            var failure: String?
            if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = "The server returned an error (\(http.statusCode))."
            } else if let tempURL {
                if Self.sha256(of: tempURL) != Self.qvacSHA256 {
                    failure = "The downloaded model didn’t match its checksum. Try again."
                } else {
                    do {
                        // Replace the old model only once the new one is verified and in place.
                        if FileManager.default.fileExists(atPath: Self.qvacModelURL.path) {
                            _ = try FileManager.default.replaceItemAt(Self.qvacModelURL, withItemAt: tempURL)
                        } else {
                            try FileManager.default.moveItem(at: tempURL, to: Self.qvacModelURL)
                        }
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.progressObservation = nil
                self.tasks[.qvac] = nil
                self.statuses[.qvac] = failure.map { .failed($0) } ?? .installed
                if failure == nil { NotificationCenter.default.post(name: .modelsDidChange, object: nil) }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.statuses[.qvac] { self?.statuses[.qvac] = .downloading(fraction) }
            }
        }
        tasks[.qvac] = Task {}
        task.resume()
    }

    /// SHA-256 of a file, read in 1 MB chunks.
    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func downloadWhisper(_ model: WhisperModel) {
        let id = ModelID.whisper(model)
        tasks[id] = Task { [weak self] in
            do {
                let folder = try await WhisperKit.download(
                    variant: model.rawValue,
                    downloadBase: Self.whisperBase,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            if case .downloading = self?.statuses[id] { self?.statuses[id] = .downloading(fraction) }
                        }
                    }
                )
                await MainActor.run {
                    guard let self else { return }
                    self.defaults.set(folder.path, forKey: "whisperFolder.\(model.rawValue)")
                    self.tasks[id] = nil
                    self.statuses[id] = .installed
                    NotificationCenter.default.post(name: .modelsDidChange, object: nil)
                }
            } catch {
                await MainActor.run {
                    self?.tasks[id] = nil
                    self?.statuses[id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Delete

    func delete(_ id: ModelID) {
        switch id {
        case .qvac:
            try? FileManager.default.removeItem(at: Self.qvacModelURL)
        case .whisper(let model):
            if let folder = whisperFolder(model) { try? FileManager.default.removeItem(at: folder) }
            defaults.removeObject(forKey: "whisperFolder.\(model.rawValue)")
        }
        statuses[id] = .notInstalled
        NotificationCenter.default.post(name: .modelsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let modelsDidChange = Notification.Name("HushhhModelsDidChange")
}
