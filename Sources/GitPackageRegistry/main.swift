import Foundation
import Vapor

let registry = try Registry(
    root: URL(fileURLWithPath: "./tmp"),
    scopes: [
        "stackotter": Registry.Scope(packages: [
            "swift-macro-toolkit": Registry.Package(
                scope: "stackotter",
                name: "swift-macro-toolkit",
                path: "/",
                repository: URL(string: "https://github.com/stackotter/swift-macro-toolkit")!
            ),
            "swift-cross-ui": Registry.Package(
                scope: "stackotter",
                name: "swift-cross-ui",
                path: "/",
                repository: URL(string: "https://github.com/stackotter/swift-cross-ui")!
            ),
            "gtk-backend": Registry.Package(
                scope: "stackotter",
                name: "gtk-backend",
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
