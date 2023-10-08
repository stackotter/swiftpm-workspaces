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

struct APIResponse<ResponseContent: Content, Links: ToLinks>: ResponseEncodable {
    var content: ResponseContent
    var links: Links?

    init(_ content: ResponseContent, links: Links? = nil) {
        self.content = content
        self.links = links
    }

    func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        var headers: [(String, String)] = [
            ("Content-Type", "application/json")
        ]

        if let links {
            let linkContent = links.links.map { (key, link) in
                "<\(link)>; rel=\"\(key)\""
            }.joined(separator: ", ")
            headers.append(("Link", linkContent))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try! encoder.encode(content)

        return request.eventLoop.makeSucceededFuture(Response(
            headers: HTTPHeaders(headers),
            body: Response.Body(data: body)
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

    static func getReleaseDetails(_ req: Request) -> APIResult<Release, [String: String?]> {
        let scope = req.parameters.get("scope")!
        let name = req.parameters.get("name")!
        let version = req.parameters.get("version")!


        guard let package = registry.package(scope, name) else {
            return .failure(APIError(.notFound, "non-existent package"))
        }

        guard package.releases.contains(version) else {
            return .failure(APIError(.notFound, "non-existent release"))
        }

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
}

let app = Vapor.Application()

app.get(":scope", ":name", use: API.listPackageReleases)
app.get(":scope", ":name", ":version", use: API.getReleaseDetails)

// TODO: All routes should allow `.json` to be appended to the URL for whatever reason
try app.run()
