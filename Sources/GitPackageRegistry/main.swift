import Foundation
import Vapor

let registry = try Registry(
    root: URL(fileURLWithPath: "./tmp"),
    scopes: [
        "stackotter": Registry.Scope(packages: [
            "swift-macro-toolkit": Registry.Package(
                path: "/",
                repository: URL(string: "https://github.com/stackotter/swift-macro-toolkit")!
            ),
            "swift-cross-ui": Registry.Package(
                path: "/",
                repository: URL(string: "https://github.com/stackotter/swift-cross-ui")!
            ),
            "gtk-backend": Registry.Package(
                path: "/Sources/GtkBackend",
                repository: URL(string: "https://github.com/stackotter/swift-cross-ui")!
            )
        ])
    ]
)

let app = Vapor.Application()

let api = API(registry)
api.registerRoutes(with: app)

try app.run()
