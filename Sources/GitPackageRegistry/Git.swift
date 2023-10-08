import Foundation
import Version

enum GitError: LocalizedError {
    case failedToRunProcess(Error)
    case failedToReadStdout(Error)
    case failedToLocateTag(release: String)
    case invalidUTF8(Data)
    
    var errorDescription: String? {
        switch self {
            case let .failedToRunProcess(error):
                "Failed to run 'git' command: \(error)"
            case let .failedToReadStdout(error):
                "Failed to read output of 'git' command: \(error)"
            case let .failedToLocateTag(release):
                "Failed to locate tag for release '\(release)'"
            case .invalidUTF8:
                "The output of the 'git' command contained invalid utf8 data"
        }
    }
}

struct Repository {
    var remoteRepository: URL
    var localRepository: URL

    init(remote: URL, local: URL) {
        self.remoteRepository = remote
        self.localRepository = local
    }

    func localRepositoryExists() -> Bool {
        FileManager.default.fileExists(atPath: localRepository.path)
    }

    func listReleases() -> Result<[String], GitError> {
        if !localRepositoryExists(), case let .failure(error) = clone() {
            return .failure(error)
        }

        return fetchTags().flatMap { _ in
            listTags()
        }.map { tags in
            tags.compactMap(Version.init(tolerant:)).map(\.description)
        }
    }

    /// Creates an archive and returns its checksum.
    /// - Parameter relativePath: The path to the package to archive relative to its containing repository.
    func archive(_ relativePath: String, to archivePath: URL) -> Result<(), GitError> {
        runCommand(
            "swift",
            ["package", "archive-source", "-o", archivePath.path],
            workingDirectory: localRepository.appendingPathComponent(relativePath)
        ).map(Self.toVoid)
    }

    func checkoutRelease(_ version: String) -> Result<(), GitError> {
        listTags()
            .flatMap { tags in
                let result = tags.last { tag in
                    tag.contains(version)
                }
                return result.map(Result.success) ?? .failure(.failedToLocateTag(release: version))
            }
            .flatMap { tag in
                checkout(tag)
            }
    }
}

extension Repository {
    private func runGitSubcommand(
        _ subcommand: String,
        _ arguments: [String] = [],
        workingDirectory: URL? = nil
    ) -> Result<String, GitError> {
        runCommand(
            "git",
            [subcommand] + arguments,
            workingDirectory: workingDirectory
        )
    }

    private func runCommand(
        _ command: String,
        _ arguments: [String] = [],
        workingDirectory: URL? = nil
    ) -> Result<String, GitError> {
        let pipe = Pipe()
        let process = Process()        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = pipe
        process.currentDirectoryURL = workingDirectory ?? localRepository

        do {
            try process.run()
        } catch {
            return .failure(.failedToRunProcess(error))
        }

        process.waitUntilExit()

        let output: Data
        do {
            output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            return .failure(.failedToReadStdout(error))
        }

        guard let output = String(data: output, encoding: .utf8) else {
            return .failure(.invalidUTF8(output))
        }

        return .success(output)
    }

    private static func toVoid<T>(_ value: T) {}

    private func clone() -> Result<(), GitError> {
        runGitSubcommand(
            "clone",
            [remoteRepository.absoluteString, localRepository.path],
            workingDirectory: URL(fileURLWithPath: ".")
        ).map(Self.toVoid)
    }

    private func pull() -> Result<(), GitError> {
        runGitSubcommand("pull").map(Self.toVoid)
    }

    private func fetchTags() -> Result<(), GitError> {
        runGitSubcommand("fetch", ["--tags"]).map(Self.toVoid)
    }

    func listTags() -> Result<[String], GitError> {
        runGitSubcommand("tag", ["--list"]).map { output in
            output.split(separator: "\n").map(String.init)
        }
    }

    func checkout(_ ref: String) -> Result<(), GitError> {
        runGitSubcommand("checkout", [ref]).map(Self.toVoid)
    }
}
