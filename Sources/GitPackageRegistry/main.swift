import Foundation
import Vapor

var registry = Registry(scopes: [
    "stackotter": Scope(packages: [
        "swift-cross-ui": Package(
            path: "/",
            repository: "https://github.com/stackotter/swift-cross-ui",
            releases: ["0.1.0", "0.2.0", "0.3.0"]
        ),
        "gtk-backend": Package(
            path: "/Sources/GtkBackend",
            repository: "https://github.com/stackotter/swift-cross-ui",
            releases: ["0.1.0", "0.2.0", "0.3.0"]
        )
    ])
])

let app = Vapor.Application()

app.get(":scope", ":name", use: API.listPackageReleases)
app.get(":scope", ":name", ":version", use: API.getReleaseDetailsOrSourceArchive)
app.get(":scope", ":name", ":version", "Package.swift", use: API.getReleaseManifest)
app.get("identifiers", use: API.getPackageIdentifiers)
app.put(":scope", ":name", ":version", use: API.unimplemented)

// TODO: All routes should allow `.json` to be appended to the URL for whatever reason
try app.run()
