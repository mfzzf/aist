@testable import AistAudio
import Foundation
import Testing

@Test func speakerModelsAreTheSameFilesFromEverySource() throws {
    // The four bundles FluidAudio's offline pipeline loads and its PLDA parameters: about 22 MB.
    let files = SpeakerModels.files
    #expect(files.count == 21 && Set(files.map(\.path)).count == 21)
    #expect(files.reduce(0) { $0 + $1.size } == 21_599_417)
    for bundle in ["Segmentation", "Embedding", "PldaRho", "FBank"] {
        // Core ML won't open a bundle without these.
        for part in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
            #expect(files.contains { $0.path == "\(bundle).mlmodelc/\(part)" })
        }
    }
    #expect(files.contains { $0.path == "plda-parameters.json" })
    #expect(files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
    #expect(files.contains { $0.path == SpeakerModels.probe })

    // Every source serves them by path under one address, over HTTPS; the original comes first.
    let sources = SpeakerModels.sources
    #expect(sources.first?.name == "Hugging Face" && sources.contains { $0.name == "hf-mirror.com" })
    #expect(sources.allSatisfy { $0.base.hasPrefix("https://") && $0.base.hasSuffix("/") })
    #expect(Set(sources.map(\.base)).count == sources.count)

    // Ready means every file at its full size, not just a folder being there.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-models-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(!SpeakerModels.isReady(in: folder))
    for file in files {
        let url = folder.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The last one a byte short, as a download cut off would leave it.
        try Data(count: file.path == files.last?.path ? file.size - 1 : file.size).write(to: url)
    }
    #expect(!SpeakerModels.isReady(in: folder))
    try Data(count: files[files.count - 1].size).write(to: folder.appendingPathComponent(files[files.count - 1].path))
    // …and the folder marked as the revision FluidAudio is pinned to, or FluidAudio won't take it.
    #expect(!SpeakerModels.isReady(in: folder))
    try Data((SpeakerModels.revision + "\n").utf8).write(to: folder.appendingPathComponent(SpeakerModels.marker))
    #expect(SpeakerModels.isReady(in: folder))
    try Data("main\n".utf8).write(to: folder.appendingPathComponent(SpeakerModels.marker))
    #expect(!SpeakerModels.isReady(in: folder))
}

@Test func nothingIsFetchedWhenNoSourceAnswers() async {
    // An address nothing listens on: no source, so no models, and it says so rather than hanging.
    let dead = [SpeakerModels.Source(name: "nowhere", base: "https://127.0.0.1:9/")]
    #expect(await SpeakerModels.reachable(within: 2, from: dead).isEmpty)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-models-\(UUID().uuidString)")
    await #expect(throws: SpeakerModels.Failure.self) {
        try await SpeakerModels.fetch(into: folder, from: dead)
    }
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}
