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
}

var scopes = [
    "scui": [
        "swift-cross-ui": Package(path: "/"),
        "gtk-backend": Package(path: "/"),
        "": Package(path: "/"),
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

let app = Vapor.Application()

app.get(":scope", ":name") { req -> Result<String, APIError> in
    print("scope:", req.parameters.get("scope")!)
    print("name:", req.parameters.get("name")!)
    return .failure(APIError(.notFound, "Not found"))
}

try app.run()
