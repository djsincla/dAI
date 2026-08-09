import Foundation
import Security

/// Server-trust only, no client certificate. Used to tell "TLS and HTTP work"
/// apart from "the mutual-auth path works".
final class TLSProbeDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let ca: SecCertificate?
    init(ca: SecCertificate?) { self.ca = ca }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let ca else {
            completionHandler(.performDefaultHandling, nil); return
        }
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var err: CFError?
        completionHandler(SecTrustEvaluateWithError(trust, &err) ? .useCredential : .cancelAuthenticationChallenge,
                          URLCredential(trust: trust))
    }
}
