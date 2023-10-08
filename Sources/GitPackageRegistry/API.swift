import Vapor

public struct APIError: LocalizedError, ResponseEncodable {
    var status: HTTPResponseStatus
    var details: String

    init(_ status: HTTPResponseStatus, _ details: String) {
        self.status = status
        self.details = details
    }

    public var errorDescription: String? {
        details
    }

    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        return request.eventLoop.makeSucceededFuture(API.jsonResponse(
            status,
            [
                "details": details
            ]
        ))
    }
}

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

extension Result: ResponseEncodable where Success: ResponseEncodable, Failure: ResponseEncodable {
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        switch self {
            case .success(let value):
                return value.encodeResponse(for: request)
            case .failure(let error):
                return error.encodeResponse(for: request)
        }
    }
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

    struct Identifiers: Content {
        var identifiers: [String]
    }

    static func jsonResponse(_ status: HTTPResponseStatus = .accepted, _ object: Any) -> Response {
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

    static func badRequest<T>(_ details: String) -> Result<T, APIError> {
        .failure(APIError(.badRequest, details))
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
        
        return .success(APIResponse(
            "dummy".data(using: .utf8)!,
            additionalHeaders: [
                ("Content-Type", "application/zip"),
                ("Cache-Control", "public, immutable"),
            ]
        ))
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

    struct IdentifiersQuery: Content {
        var url: String
    }

    static func getPackageIdentifiers(_ req: Request) -> APIResult<Identifiers, NoLinks> {
        guard let query = try? req.query.get(IdentifiersQuery.self) else {
            return badRequest("missing 'url' query parameter")
        }

        let url = if query.url.hasSuffix(".git") {
            String(query.url.dropLast(4))
        } else {
            query.url
        }

        var identifiers: [String] = []
        for (scopeName, scope) in registry.scopes {
            for (packageName, package) in scope.packages {
                if package.path == "/" && package.repository == url {
                    identifiers.append("\(scopeName).\(packageName)")
                }
            }
        }

        if identifiers.isEmpty {
            return .failure(APIError(.notFound, "no matching packages"))
        } else {
            return .success(APIResponse(Identifiers(
                identifiers: identifiers
            )))
        }
    }

    static func unimplemented(_ req: Request) -> APIError {
        APIError(.unauthorized, "unimplemented")
    }
}