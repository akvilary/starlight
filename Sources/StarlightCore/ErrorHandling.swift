//===----------------------------------------------------------------------===//
//
//  ErrorHandling.swift
//  StarlightCore
//
//  Typed error responses — the `HTTPResponseError`-style mechanism
//  (Hummingbird) expressed as an axum-shaped layer.
//
//  Handlers and middleware throw domain errors (`AppError`, auth
//  failures, …). The server's last-resort behaviour for an unhandled
//  throw is a plain-text 500 + connection close. `errorLayer()`
//  converts every thrown error that conforms to `ResponseError`
//  into a proper response (status + JSON body) while letting
//  everything else propagate to the 500 path.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTPModel
import HTTPPrism

/// An `Error` that knows how to render itself as an HTTP response.
///
/// Conform your domain error and throw it from any handler or
/// middleware running inside `errorLayer()`:
///
/// ```swift
/// enum AppError: Error, ResponseError {
///     case notFound(String)
///     func intoResponse() -> Response {
///         Response(.notFound, from: Json(["error": "…"]))
///     }
/// }
///
/// let app = router.layer(errorLayer())
/// ```
///
/// `CancellationError` and other non-conforming errors are NOT
/// intercepted — they keep propagating (the server closes the
/// connection with a 500; shutdown/cancellation paths stay intact).
public protocol ResponseError: Error, IntoResponse, Sendable {}

/// An extractor rejection IS its response — render it verbatim when
/// it escapes a closure-style handler or middleware (typed handlers
/// already catch it internally).
extension ExtractionRejection: IntoResponse, ResponseError {
    public func intoResponse() -> Response {
        response
    }
}

/// Layer that converts thrown `ResponseError`s into responses.
///
/// Ordering: apply it around the routes/middleware whose errors it
/// should render — typically directly around the router, inside
/// CORS/trace layers so error responses get CORS headers too:
///
/// ```swift
/// let app = Router()
///     .get("/api/users/:id", handler)
///     .layer(errorLayer())      // innermost of the three
///     .layer(corsLayer)
///     .layer(traceLayer)
/// ```
public func errorLayer() -> Layer<HTTPModel.Request, HTTPModel.Response> {
    Layer { inner in
        BoxService { request in
            do {
                return try await inner.call(request)
            } catch let e as any ResponseError {
                return e.intoResponse()
            }
            // Non-conforming errors propagate — the server's 500 path.
        }
    }
}
