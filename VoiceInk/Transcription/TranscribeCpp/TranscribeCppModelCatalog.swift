import Foundation

struct TranscribeCppModelArtifact: Sendable {
    let modelName: String
    let fileName: String
    let repository: String
    let repositoryRevision: String
    let expectedFileSize: Int64
    let expectedSHA256: String
    let architectureHint: String?
    let enablesInverseTextNormalization: Bool
    let maximumChunkSeconds: Int
    let boundarySearchSeconds: Int
    let boundaryEnergyWindowSamples: Int

    var downloadURL: URL {
        URL(
            string: "https://huggingface.co/\(repository)/resolve/\(repositoryRevision)/\(fileName)"
        )!
    }

    var modelDirectory: URL {
        Self.applicationSupportDirectory
            .appendingPathComponent("TranscribeCpp", isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
    }

    var modelFileURL: URL {
        modelDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    var checksumFileURL: URL {
        modelDirectory.appendingPathComponent(".\(fileName).sha256", isDirectory: false)
    }

    var installedModelFileURL: URL? {
        modelFileIsValid(in: modelDirectory) ? modelFileURL : nil
    }

    func modelFileIsValid(in directory: URL) -> Bool {
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        let checksumURL = directory.appendingPathComponent(".\(fileName).sha256", isDirectory: false)

        guard
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize,
            Int64(size) == expectedFileSize
        else {
            return false
        }

        let installedChecksum = try? String(contentsOf: checksumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return installedChecksum == expectedSHA256
    }

    func removeInstalledFiles() {
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    private static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
    }
}

enum TranscribeCppModelCatalog {
    static let senseVoiceSmall = TranscribeCppModelArtifact(
        modelName: "sensevoice-small",
        fileName: "SenseVoiceSmall-Q8_0.gguf",
        repository: "handy-computer/SenseVoiceSmall-gguf",
        repositoryRevision: "4a08b8e900b38a977e32eb08d5d0697d6e72ba04",
        expectedFileSize: 252_684_608,
        expectedSHA256: "6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29",
        architectureHint: "sensevoice",
        enablesInverseTextNormalization: true,
        maximumChunkSeconds: 30,
        boundarySearchSeconds: 3,
        boundaryEnergyWindowSamples: 1_600
    )

    /// Parakeet TDT v3 finetune published by Oruk. The Q8_0 export runs on
    /// transcribe.cpp's existing Parakeet implementation, so no runtime change is needed.
    static let orukeet = TranscribeCppModelArtifact(
        modelName: "orukeet",
        fileName: "orukeet-transcribe-cpp-Q8_0.gguf",
        repository: "oruk/orukeet",
        repositoryRevision: "debfb0d5423d4b0446361e0ea024e6891e23a249",
        expectedFileSize: 739_508_608,
        expectedSHA256: "cad2f52ac91cad829279422301989687c2cf02e19157352ed25ea501b90dbb7e",
        architectureHint: "parakeet",
        enablesInverseTextNormalization: false,
        maximumChunkSeconds: 300,
        boundarySearchSeconds: 5,
        boundaryEnergyWindowSamples: 1_600
    )

    private static let artifactsByModelName = [
        senseVoiceSmall.modelName: senseVoiceSmall,
        orukeet.modelName: orukeet,
    ]

    static func artifact(for modelName: String) -> TranscribeCppModelArtifact? {
        artifactsByModelName[modelName]
    }
}
