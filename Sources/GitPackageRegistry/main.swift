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
}

var scopes = [
    "scui": [
        "swift-cross-ui": Package(path: "/", repository: "https://github.com/stackotter/swift-cross-ui"),
        "gtk-backend": Package(path: "/Sources/GtkBackend", repository: "https://github.com/stackotter/swift-cross-ui")
    ]
]

// Define a type that conforms to the generated protocol.
// func listPackageReleases(
//     _ input: Operations.listPackageReleases.Input
// ) async throws -> Operations.listPackageReleases.Output {
//     guard let scope = scopes[input.scope] else {
//         throw APIError("non-existent scope")
//     }

//     guard let package = scope[input.name] else {
//         throw APIError("non-existent package")
//     }

//     let response = OpenAPIObjectContainer()
//     return .ok(.init(headers: .init(Content_hyphen_Version: ._1), .json(.init(releases: response))))
// }

// /// Fetch release metadata
// ///
// /// - Remark: HTTP `GET /{scope}/{name}/{version}`.
// /// - Remark: Generated from `#/paths//{scope}/{name}/{version}/get(fetchReleaseMetadata)`.
// func fetchReleaseMetadata(
//     _ input: Operations.fetchReleaseMetadata.Input
// ) async throws -> Operations.fetchReleaseMetadata.Output {
//     throw APIError("unimplemented")
// }

// /// Publish package release
// ///
// /// - Remark: HTTP `PUT /{scope}/{name}/{version}`.
// /// - Remark: Generated from `#/paths//{scope}/{name}/{version}/put(publishPackageRelease)`.
// func publishPackageRelease(
//     _ input: Operations.publishPackageRelease.Input
// ) async throws -> Operations.publishPackageRelease.Output {
//     throw APIError("unimplemented")
// }

// /// Fetch manifest for a package release
// ///
// /// - Remark: HTTP `GET /{scope}/{name}/{version}/Package.swift`.
// /// - Remark: Generated from `#/paths//{scope}/{name}/{version}/Package.swift/get(fetchManifestForPackageRelease)`.
// func fetchManifestForPackageRelease(
//     _ input: Operations.fetchManifestForPackageRelease.Input
// ) async throws -> Operations.fetchManifestForPackageRelease.Output {
//     throw APIError("unimplemented")
// }

// /// Download source archive
// ///
// /// - Remark: HTTP `GET /{scope}/{name}/{version}.zip`.
// /// - Remark: Generated from `#/paths//{scope}/{name}/{version}.zip/get(downloadSourceArchive)`.
// func downloadSourceArchive(
//     _ input: Operations.downloadSourceArchive.Input
// ) async throws -> Operations.downloadSourceArchive.Output {
//     throw APIError("unimplemented")
// }

// /// Lookup package identifiers registered for a URL
// ///
// /// - Remark: HTTP `GET /identifiers`.
// /// - Remark: Generated from `#/paths//identifiers/get(lookupPackageIdentifiersByURL)`.
// func lookupPackageIdentifiersByURL(
//     _ input: Operations.lookupPackageIdentifiersByURL.Input
// ) async throws -> Operations.lookupPackageIdentifiersByURL.Output {
//     throw APIError("unimplemented")
// }

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

let app = Vapor.Application()

struct Problem: Content {
    var status: Int
    var title: String
    var detail: String
}

struct Release: Content {
    /// If not provided, the client will infer it.
    var url: String?
    /// If provided, the client will ignore the release during package resolution.
    var problem: Problem?
}

struct Releases: Content {
    var releases: [String: Release]

    init(_ releases: [String: Release]) {
        self.releases = releases
    }
}

struct ReleasesResponse: ResponseEncodable {
    var releases: Releases
    var latestVersion: String?
    var sourceRepository: String?
    var payment: String?

    func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        let body = try! JSONEncoder().encode(releases)

        let links: [String: String] = [
            "latest-version": latestVersion,
            "canonical": sourceRepository,
            "payment": payment
        ].compactMapValues({ $0 })

        let linkContent = links.map { key, link in
            "<\(link)>; rel=\"\(key)\""
        }.joined(separator: ", ")

        return request.eventLoop.makeSucceededFuture(Response(
            headers: ["Link": linkContent],
            body: .init(data: body)
        ))
    }
}

app.get(":scope", ":name") { req -> Result<ReleasesResponse, APIError> in
    let scope = req.parameters.get("scope")!
    let name = req.parameters.get("name")!

    
    guard let registryScope = scopes[scope] else {
        return badRequest("Non-existent scope")
    }

    guard let package = registryScope[name] else {
        return badRequest("Non-existent package")
    }

    return .success(ReleasesResponse(
        releases: Releases(["0.1.0": Release()]),
        latestVersion: "0.1.0",
        sourceRepository: package.repository,
        payment: "https://github.com/sponsors/stackotter"
    ))
}

// TODO: All routes should allow `.json` to be appended to the URL for whatever reason
try app.run()
