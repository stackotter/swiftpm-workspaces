import Foundation
import Vapor

public struct APIError: LocalizedError {
    var status: HTTPResponseStatus
    var details: String

    init(_ status: HTTPResponseStatus, _ details: String) {
        self.status = status
        self.details = details
    }

    public var errorDescription: String? {
        details
    }
}

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

var registry = Registry(scopes: [
    "scui": Scope(packages: [
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

func jsonResponse(_ status: HTTPResponseStatus = .accepted, _ object: Any) -> Response {
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    return Response(
        status: status,
        headers: headers,
        body: try! Response.Body(
            data: JSONSerialization.data(
                withJSONObject: object,
                options: .prettyPrinted
            )
        )
    )
}

extension Result: ResponseEncodable where Success: ResponseEncodable, Failure == APIError {
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        switch self {
            case .success(let value):
                return value.encodeResponse(for: request)
            case .failure(let error):
                return request.eventLoop.makeSucceededFuture(jsonResponse(
                    error.status,
                    [
                        "details": error.details
                    ]
                ))
        }
    }
}

func badRequest<T>(_ details: String) -> Result<T, APIError> {
    .failure(APIError(.badRequest, details))
}

protocol ToLinks {
    var links: [(relation: String, link: String)] { get }
}

extension Dictionary<String, String?>: ToLinks {
    var links: [(relation: String, link: String)] {
        compactMapValues { $0 }.map { ($0, $1) }
    }
}

struct NoLinks: ToLinks {
    var links: [(relation: String, link: String)] {
        []
    }
}

extension Data: Content {}

struct APIResponse<ResponseContent: Content, Links: ToLinks>: ResponseEncodable {
    var content: ResponseContent
    var links: Links?
    var additionalHeaders: [(String, String)]

    init(_ content: ResponseContent, links: Links? = nil, additionalHeaders: [(String, String)] = []) {
        self.content = content
        self.links = links
        self.additionalHeaders = additionalHeaders
    }

    func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        var headers = additionalHeaders
        headers.append(("Content-Version", "1"))

        if let links {
            let linkContent = links.links.map { (key, link) in
                "<\(link)>; rel=\"\(key)\""
            }.joined(separator: ", ")
            headers.append(("Link", linkContent))
        }

        let body: Response.Body

        if let content = content as? String {
            body = Response.Body(string: content)
        } else if let content = content as? Data {
            body = Response.Body(data: content)
        } else {
            headers.append(("Content-Type", "application/json"))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            body = try! Response.Body(data: encoder.encode(content))
        }

        return request.eventLoop.makeSucceededFuture(Response(
            headers: HTTPHeaders(headers),
            body: body
        ))
    }
}

typealias APIResult<T: Content, L: ToLinks> = Result<APIResponse<T, L>, APIError>

enum API {
    struct Problem: Content {
        var status: Int
        var title: String
        var detail: String
    }

    struct ReleaseSummary: Content {
        /// If not provided, the client will infer it.
        var url: String?
        /// If provided, the client will ignore the release during package resolution.
        var problem: Problem?
    }

    struct Releases: Content {
        var releases: [String: ReleaseSummary]

        init(_ releases: [String: ReleaseSummary]) {
            self.releases = releases
        }
    }

    struct Resource: Content {
        var name: String
        var type: String
        var checksum: String
        var signing: Signing?
    }

    struct Signing: Content {
        var signatureBase64Encoded: String
        var signatureFormat: String
    }

    struct Release: Content {
        var id: String
        var version: String
        var resources: [Resource]
        var metadata: [String: String]
        var publishedAt: Date?
    }

    static func listPackageReleases(_ req: Request) -> APIResult<Releases, [String: String?]> {
        let scope = req.parameters.get("scope")!
        let name = req.parameters.get("name")!
    
        guard let package = registry.package(scope, name) else {
            return badRequest("Non-existent package")
        }

        var releases: [String: ReleaseSummary] = [:]
        for release in package.releases {
            releases[release] = ReleaseSummary()
        }

        return .success(APIResponse(
            Releases(releases),
            links: [
                "latest-version": package.releases.last,
                "canonical": package.repository,
                "payment": "https://github.com/sponsors/stackotter"
            ]
        ))
    }

    /// Ideally this would be two separate routes but Vapor doesn't really let that
    /// happen in a nice way since the API spec is a bit weird (Vapor doesn't have a
    /// way to express that /0.1.0 and /0.1.0.zip should be routed differently).
    static func getReleaseDetailsOrSourceArchive(_ req: Request) -> EventLoopFuture<Response> {
        let scope = req.parameters.get("scope")!
        let name = req.parameters.get("name")!
        let version = req.parameters.get("version")!

        if version.hasSuffix(".zip") {
            let version = String(version.dropLast(4))
            return getSourceArchive(scope, name, version).encodeResponse(for: req)
        } else {
            return getReleaseDetails(scope, name, version).encodeResponse(for: req)
        }
    }

    static func getSourceArchive(
        _ scope: String, _ name: String, _ version: String
    ) -> APIResult<Data, NoLinks> {
        guard registry.releaseExists(scope, name, version) else {
            return .failure(APIError(.notFound, "non-existent release"))
        }
        
        return .failure(APIError(.internalServerError, "not implemented"))
    }

    static func getReleaseDetails(
        _ scope: String, _ name: String, _ version: String
    ) -> APIResult<Release, [String: String?]> {
        guard let package = registry.package(scope, name) else {
            return .failure(APIError(.notFound, "non-existent package"))
        }

        guard package.releases.contains(version) else {
            return .failure(APIError(.notFound, "non-existent release"))
        }
        
        // Get release details
        return .success(APIResponse(
            Release(
                id: "\(scope).\(name)",
                version: version,
                resources: [
                    Resource(
                        name: "source-archive",
                        type: "application/zip",
                        checksum: "0"
                    )
                ],
                metadata: [:],
                publishedAt: nil
            ),
            links: [
                "latest-version": package.releases.last,
                "successor-version": package.releaseAfter(version),
                "predecessor-version": package.releaseBefore(version)
            ]
        ))
    }

    static func getReleaseManifest(_ req: Request) -> APIResult<Data, NoLinks> {
        let scope = req.parameters.get("scope")!
        let name = req.parameters.get("name")!
        let version = req.parameters.get("version")!

            guard registry.releaseExists(scope, name, version) else {
                return .failure(APIError(.notFound, "non-existent release"))
            }

            return .success(APIResponse(
                """
                // swift-tools-version: 5.9

                import PackageDescription

                let package = Package(
                    name: "dummy",
                    targets: [
                        .executableTarget(name: "Dummy")
                    ]
                )
                """.data(using: .utf8)!,
                additionalHeaders: [
                    ("Content-Type", "text/x-swift"),
                    ("Content-Disposition", "attachment; filename=\"Package.swift\"")
                ]
            ))
    }
}

let app = Vapor.Application()

app.get(":scope", ":name", use: API.listPackageReleases)
app.get(":scope", ":name", ":version", use: API.getReleaseDetailsOrSourceArchive)
app.get(":scope", ":name", ":version", "Package.swift", use: API.getReleaseManifest)

// TODO: All routes should allow `.json` to be appended to the URL for whatever reason
try app.run()
