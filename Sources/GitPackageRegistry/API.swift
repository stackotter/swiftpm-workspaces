import Vapor
import SHA2

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

extension String: CodingKey {
    public init?(stringValue: String) {
        self = stringValue
    }

    public init?(intValue: Int) {
        return nil
    }

    public var stringValue: String {
        self
    }

    public var intValue: Int? {
        nil
    }
}

/// Conforms to the Swift Package Registry specification.
///
/// See https://github.com/apple/swift-package-manager/blob/main/Documentation/PackageRegistry/Registry.md
struct API {
    var registry: Registry

    init(_ registry: Registry) {
        self.registry = registry
    }

    func registerRoutes(with app: Application) {
        // TODO: All routes should allow `.json` to be appended to the URL for whatever reason
        app.get(":scope", ":name", use: listPackageReleases)
        app.get(":scope", ":name", ":version", use: getReleaseDetailsOrSourceArchive)
        app.get(":scope", ":name", ":version", "Package.swift", use: getReleaseManifest)
        app.get("identifiers", use: getPackageIdentifiers)
        app.put(":scope", ":name", ":version", use: unimplemented)
    }
}

/// Request types.
extension API {
    struct IdentifiersQuery: Content {
        var url: String
    }
}

/// Response types
extension API {
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
        /// Stored as an array instead of a dictionary to maintain ordering.
        var releases: [(String, ReleaseSummary)]

        init(_ releases: [(String, ReleaseSummary)]) {
            self.releases = releases
        }

        /// Creates a list of releases with no metadata.
        init(_ releases: [String]) {
            self.releases = releases.map { release in
                (release, ReleaseSummary())
            }
        }

        init(from decoder: Decoder) throws {
            releases = try decoder.singleValueContainer()
                .decode([String: ReleaseSummary].self)
                .map { ($0, $1) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: String.self)
            for (version, summary) in releases {
                try container.encode(summary, forKey: version)
            }
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
}

/// Response helper methods.
extension API {
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

    static func notFound<T>(_ details: String) -> Result<T, APIError> {
        .failure(APIError(.notFound, details))
    }

    static func badRequest<T>(_ details: String) -> Result<T, APIError> {
        .failure(APIError(.badRequest, details))
    }

    static func internalServerError<T>(_ details: String) -> Result<T, APIError> {
        .failure(APIError(.internalServerError, details))
    }
}

/// Route handlers.
extension API {
    func listPackageReleases(_ req: Request) -> APIResult<Releases, [String: String?]> {
        let scope = req.parameters.get("scope")!
        let name = req.parameters.get("name")!

        guard let repository = registry.repository(scope, name) else {
            return Self.notFound("Non-existent package")
        }

        let releases: [String]
        switch repository.listReleases() {
            case let .failure(error):
                return Self.internalServerError(error.localizedDescription)
            case let .success(versions):
                releases = versions
        }

        return .success(APIResponse(
            Releases(releases),
            links: [
                "latest-version": releases.last,
                "canonical": repository.remoteRepository.absoluteString,
                "payment": "https://github.com/sponsors/stackotter"
            ]
        ))
    }

    /// Ideally this would be two separate routes but Vapor doesn't really let that
    /// happen in a nice way since the API spec is a bit weird (Vapor doesn't have a
    /// way to express that /0.1.0 and /0.1.0.zip should be routed differently).
    func getReleaseDetailsOrSourceArchive(_ req: Request) -> EventLoopFuture<Response> {
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

    func getReleaseDetails(
        _ scope: String, _ name: String, _ version: String
    ) -> APIResult<Release, [String: String?]> {
        guard let package = registry.package(scope, name) else {
            return Self.notFound("non-existent package")
        }
    
        let releases: Registry.Releases
        switch registry.releases(scope, name) {
            case .failure(.noSuchPackage):
                return Self.notFound("non-existent package")
            case let .failure(error):
                return Self.internalServerError(error.localizedDescription)
            case let .success(versions):
                releases = versions
        }

        guard releases.contains(version) else {
            return Self.notFound("non-existent release")
        }

        let checksum: SHA2.SHA256
        switch registry.archive(package, version) {
            case let .failure(error):
                return Self.internalServerError(error.localizedDescription)
            case let .success(archive):
                checksum = archive.checksum
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
                        checksum: checksum.hex
                    )
                ],
                metadata: [:],
                publishedAt: nil
            ),
            links: [
                "latest-version": releases.latest,
                "successor-version": releases.releaseAfter(version),
                "predecessor-version": releases.releaseBefore(version)
            ]
        ))
    }

    func getSourceArchive(
        _ scope: String, _ name: String, _ version: String
    ) -> APIResult<Data, NoLinks> {
        guard let package = registry.package(scope, name) else {
            return Self.notFound("non-existent release")
        }
        
        return registry.archive(package, version)
            .mapError { error in
                print(error)
                return APIError(.internalServerError, "failed to create source archive: \(error)")
            }
            .flatMap { archive in
                let data: Data
                do {
                    data = try Data(contentsOf: archive.path)
                } catch {
                    print(error)
                    return Self.internalServerError("failed to read source archive")
                }

                return .success(APIResponse(
                    data,
                    additionalHeaders: [
                        ("Digest", "sha-256=\(archive.checksum.base64String())"),
                        ("Content-Type", "application/zip"),
                        ("Cache-Control", "public, immutable"),
                    ]
                ))
            }
    }

    func getReleaseManifest(_ req: Request) -> APIResult<Data, NoLinks> {
        let scope = req.parameters.get("scope")!
        let name = req.parameters.get("name")!
        let version = req.parameters.get("version")!

        switch registry.releaseExists(scope, name, version) {
            case .failure(.noSuchPackage):
                return Self.notFound("non-existent package")
            case let .failure(error):
                return Self.internalServerError(error.localizedDescription)
            case .success(false):
                return Self.notFound("non-existent release")
            default:
                break
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

    func getPackageIdentifiers(_ req: Request) -> APIResult<Identifiers, NoLinks> {
        guard let query = try? req.query.get(IdentifiersQuery.self) else {
            return Self.badRequest("missing 'url' query parameter")
        }

        let url = if query.url.hasSuffix(".git") {
            String(query.url.dropLast(4))
        } else {
            query.url
        }

        var identifiers: [String] = []
        for (scopeName, scope) in registry.scopes {
            for (packageName, package) in scope.packages {
                if package.path == "/" && package.repository.absoluteString == url {
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

    func unimplemented(_ req: Request) -> APIError {
        APIError(.unauthorized, "unimplemented")
    }
}
