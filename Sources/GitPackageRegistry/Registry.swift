import Foundation

enum RegistryError: LocalizedError {
    case noSuchPackage(scope: String, name: String)
    case failedToLocateTag(release: String)
    case gitError(GitError)
}

struct Registry {
    var root: URL
    var scopes: [String: Scope]

    var archivesDirectory: URL {
        root.appendingPathComponent("archives")
    }

    init(root: URL, scopes: [String: Scope]) throws {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        self.root = root
        self.scopes = scopes

        if !FileManager.default.fileExists(atPath: archivesDirectory.path) {
            try FileManager.default.createDirectory(
                at: archivesDirectory,
                withIntermediateDirectories: true
            )
        }
    }

    func package(_ scope: String, _ name: String) -> Package? {
        scopes[scope]?.packages[name]
    }

    func repository(_ scope: String, _ name: String) -> Repository? {
        package(scope, name).map(repository)
    }

    func repository(_ package: Package) -> Repository {
        // TODO: Share repository between packages that have the same backing repository
        return Repository(
            remote: package.repository,
            local: root.appendingPathComponent("\(package.scope).\(package.name)")
        )
    }

    func releases(_ scope: String, _ name: String) -> Result<Releases, RegistryError> {
        guard let repository = repository(scope, name) else {
            return .failure(.noSuchPackage(scope: scope, name: name))
        }

        return repository.listReleases().mapError(RegistryError.gitError).map(Releases.init)
    }

    /// Returns false if the package or release doesn't exist, throws if a git error is encountered.
    func releaseExists(_ scope: String, _ name: String, _ version: String) -> Result<Bool, RegistryError> {
        releases(scope, name).map { releases in
            releases.contains(version)
        }
    }

    func archive(_ package: Package, _ version: String) -> Result<SourceArchive, RegistryError> {
        let file = "\(package.scope).\(package.name)-\(version).zip"
        let archivePath = archivesDirectory.appendingPathComponent(file)
        
        // No need to fetch the tags first because this endpoint won't get requested unless we've already
        // told the client about the tag.
        let repository = repository(package)
        return repository.listTags()
            .mapError(RegistryError.gitError)
            .flatMap { tags in
                print(tags)
                let result = tags.last { tag in
                    tag.contains(version)
                }
                return result.map(Result.success) ?? .failure(.failedToLocateTag(release: version))
            }
            .flatMap { tag in
                repository.checkout(tag).mapError(RegistryError.gitError)
            }
            .flatMap { _ in
                repository.archive(to: archivePath).mapError(RegistryError.gitError)
            }
            .map { checksum in
                SourceArchive(path: archivePath, checksum: checksum)
            }
    }
}

extension Registry {
    struct Package {
        var scope: String
        var name: String
        var path: String
        var repository: URL
    }

    struct Scope {
        var packages: [String: Package]
    }

    struct Releases {
        var releases: [String]

        var latest: String? {
            releases.last
        }

        func releaseBefore(_ version: String) -> String? {
            guard
                let index = releases.firstIndex(of: version),
                index - 1 >= 0
            else {
                return nil
            }

            return releases[index - 1]
        }

        func releaseAfter(_ version: String) -> String? {
            guard
                let index = releases.firstIndex(of: version),
                index + 1 < releases.count
            else {
                return nil
            }

            return releases[index + 1]
        }

        func contains(_ release: String) -> Bool {
            releases.contains(release)
        }
    }

    struct SourceArchive {
        var path: URL
        var checksum: String
    }
}
