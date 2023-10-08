struct Package {
    var path: String
    var repository: String
    var releases: [String]

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
}

struct Scope {
    var packages: [String: Package]
}

struct Registry {
    var scopes: [String: Scope]

    func package(_ scope: String, _ name: String) -> Package? {
        scopes[scope]?.packages[name]
    }

    func releaseExists(_ scope: String, _ name: String, _ version: String) -> Bool {
        guard let package = package(scope, name) else {
            return false
        }

        return package.releases.contains(version)
    }
}
