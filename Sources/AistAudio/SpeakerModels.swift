import AistCore
import CryptoKit
import FluidAudio
import Foundation

/// The speaker-separation models: what they are, where they can be fetched from, and getting them
/// onto this Mac. They are the same files wherever they come from: each is checked against its
/// SHA-256 here, so a mirror is as good as the original and a damaged download is noticed.
public enum SpeakerModels {
    struct File: Sendable {
        let path: String
        let size: Int
        let sha256: String

        init(_ path: String, _ size: Int, _ sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    /// FluidInference/speaker-diarization-coreml (pyannote community-1 for Core ML, CC BY 4.0) at the
    /// commit this version of FluidAudio is pinned to: the four model bundles and the PLDA
    /// parameters its offline pipeline loads.
    static let revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    static let files: [File] = [
        File("Embedding.mlmodelc/analytics/coremldata.bin", 243, "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
        File("Embedding.mlmodelc/coremldata.bin", 704, "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
        File("Embedding.mlmodelc/metadata.json", 2818, "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
        File("Embedding.mlmodelc/model.mil", 78432, "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
        File("Embedding.mlmodelc/weights/weight.bin", 13412288, "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
        File("FBank.mlmodelc/analytics/coremldata.bin", 243, "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
        File("FBank.mlmodelc/coremldata.bin", 853, "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
        File("FBank.mlmodelc/metadata.json", 3409, "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
        File("FBank.mlmodelc/model.mil", 15667, "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
        File("FBank.mlmodelc/weights/weight.bin", 1776896, "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
        File("PldaRho.mlmodelc/analytics/coremldata.bin", 243, "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
        File("PldaRho.mlmodelc/coremldata.bin", 763, "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
        File("PldaRho.mlmodelc/metadata.json", 2749, "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
        File("PldaRho.mlmodelc/model.mil", 7613, "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
        File("PldaRho.mlmodelc/weights/weight.bin", 200192, "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
        File("Segmentation.mlmodelc/analytics/coremldata.bin", 243, "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
        File("Segmentation.mlmodelc/coremldata.bin", 812, "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
        File("Segmentation.mlmodelc/metadata.json", 3410, "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
        File("Segmentation.mlmodelc/model.mil", 43063, "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
        File("Segmentation.mlmodelc/weights/weight.bin", 5959360, "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
        File("plda-parameters.json", 89416, "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
    ]

    /// The small file each source is timed on.
    static let probe = "Segmentation.mlmodelc/metadata.json"
    /// FluidAudio's note of which revision a folder holds. For a pinned repository it only accepts
    /// the folder when this names the pinned commit, so it is written once the files are all there.
    static let marker = ".fluidaudio-revision"

    /// A place the files can be fetched from: `base` followed by a file's path.
    public struct Source: Sendable, Equatable {
        public let name: String
        let base: String
    }

    /// A copy on ModelScope ("owner/repository"), for where Hugging Face is slow or blocked; nil
    /// until one is published.
    static let modelScope: String? = nil

    public static let sources: [Source] = {
        let hub = "FluidInference/speaker-diarization-coreml/resolve/\(revision)/"
        var all = [
            Source(name: "Hugging Face", base: "https://huggingface.co/" + hub),
            Source(name: "hf-mirror.com", base: "https://hf-mirror.com/" + hub),
        ]
        if let modelScope {
            all.append(Source(name: "ModelScope", base: "https://www.modelscope.cn/models/\(modelScope)/resolve/master/"))
        }
        return all
    }()

    public enum Failure: LocalizedError {
        case unreachable
        case incomplete(String)

        public var errorDescription: String? {
            switch self {
            case .unreachable: "下载说话人模型的几个地址都连不上"
            case let .incomplete(path): "说话人模型没有下载完整：\(path)"
            }
        }
    }

    /// Where FluidAudio looks for them.
    public static var directory: URL {
        OfflineDiarizerModels.defaultModelsDirectory().appendingPathComponent("speaker-diarization", isDirectory: true)
    }

    /// Every file is in `directory` at its full size, and the folder is marked as this revision.
    public static func isReady(in directory: URL = directory) -> Bool {
        let noted = (try? String(contentsOf: directory.appendingPathComponent(marker), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return noted == revision && files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.path).path)
            return (attributes?[.size] as? NSNumber)?.intValue == file.size
        }
    }

    private static func session(timeout: Double) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private static func matches(_ data: Data, _ file: File) -> Bool {
        data.count == file.size && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256
    }

    /// The sources that answer within `seconds`, fastest first, with how long each took. All are
    /// asked at once for one small file, and must return the right one: a source that is up but
    /// doesn't hold these files is no use.
    public static func reachable(within seconds: Double = 4, from sources: [Source] = sources) async -> [(source: Source, seconds: Double)] {
        guard let file = files.first(where: { $0.path == probe }) else { return [] }
        let session = session(timeout: seconds)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: (Source, Double)?.self) { group in
            for source in sources {
                group.addTask {
                    guard let url = URL(string: source.base + file.path) else { return nil }
                    let started = Date()
                    guard let (data, response) = try? await session.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200, matches(data, file) else { return nil }
                    return (source, Date().timeIntervalSince(started))
                }
            }
            var found: [(source: Source, seconds: Double)] = []
            for await result in group {
                if let result { found.append((result.0, result.1)) }
            }
            return found.sorted { $0.seconds < $1.seconds }
        }
    }

    /// Fetches whatever isn't in `directory` yet: from the fastest source that answers, falling back
    /// to the next for a file that fails or doesn't match its hash. Returns the sources as timed
    /// (empty when nothing needed fetching).
    @discardableResult
    public static func fetch(into directory: URL = directory, from sources: [Source] = sources) async throws -> [(source: Source, seconds: Double)] {
        guard !isReady(in: directory) else { return [] }
        let fm = FileManager.default
        // What an earlier fetch that was cut short already brought, whole, isn't fetched again.
        let missing = files.filter { file in
            guard let have = try? Data(contentsOf: directory.appendingPathComponent(file.path)) else { return true }
            return !matches(have, file)
        }
        var ranked: [(source: Source, seconds: Double)] = []
        if !missing.isEmpty {
            ranked = await reachable(from: sources)
            guard !ranked.isEmpty else { throw Failure.unreachable }
            NSLog("aist: speaker models from %@", ranked.map { String(format: "%@ (%.2f s)", $0.source.name, $0.seconds) }.joined(separator: ", "))
        }
        let session = session(timeout: 30)
        defer { session.finishTasksAndInvalidate() }
        for file in missing {
            let target = directory.appendingPathComponent(file.path)
            var done = false
            for (source, _) in ranked {
                try Task.checkCancellation()
                guard let url = URL(string: source.base + file.path), let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200, matches(data, file) else { continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                done = true
                break
            }
            guard done else { throw Failure.incomplete(file.path) }
        }
        try Data((revision + "\n").utf8).write(to: directory.appendingPathComponent(marker), options: .atomic)
        return ranked
    }
}
