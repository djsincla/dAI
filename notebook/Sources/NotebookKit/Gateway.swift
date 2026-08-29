import Foundation

/// The fleet, for the half a notebook cannot do locally.
///
/// Retrieval runs here; generation does not. That split is deliberate and is
/// the same one `examples/python` makes: the question and the corpus stay on
/// this machine, and only the retrieved passages and the question travel, to a
/// machine inside the same building.
public actor Gateway {

    public struct Configuration: Sendable, Equatable {
        public var baseURL: URL
        /// The control plane's own CA, so its certificate can be trusted
        /// without trusting everything else signed by nobody.
        public var caCertificatePath: String?

        public init(baseURL: URL, caCertificatePath: String? = nil) {
            self.baseURL = baseURL
            self.caCertificatePath = caCertificatePath
        }

        public static let localhost = Configuration(
            baseURL: URL(string: "https://localhost:8452")!)
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noCredential
        case refused(status: Int, message: String)
        case unreachable(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .noCredential:
                return "No API key. An operator mints one with "
                     + "POST /admin/v1/auth/keys."
            case let .refused(status, message):
                return "The gateway refused (\(status)): \(message)"
            case let .unreachable(why):
                // A fleet with nobody free is the ordinary daytime answer, not
                // a fault, and saying so stops somebody debugging a network.
                return "Could not reach the gateway: \(why)"
            case let .malformed(what):
                return "The gateway's answer was not what was expected: \(what)"
            }
        }
    }

    public struct Answer: Sendable, Equatable {
        public let text: String
        public let model: String?
        /// Which machine answered and what it was doing, from the gateway's own
        /// `dai` block. Recorded on the turn because a slow or odd answer is
        /// usually about the machine rather than the question.
        public let node: String?
        public let presenceState: String?
        public let seconds: Double

        /// Why the model stopped. `length` means it did not finish.
        ///
        /// **An answer cut off mid sentence must never be presented as a whole
        /// one.** The reader cannot tell the difference, and the difference is
        /// the model having more to say against the model being done. Three of
        /// the first eleven answers this app recorded end mid sentence and none
        /// of them said so, because the gateway sent this and nothing read it.
        public let finishReason: String?

        /// What the fleet actually allowed, against what was asked for.
        ///
        /// A harvested machine caps completions by presence: 256 tokens while
        /// somebody is using it, against 2,048 when it is locked and 4,096 when
        /// they have gone. So a truncated answer is usually a statement about
        /// where the work landed and what that machine's owner was doing, not
        /// about the setting in this app, and reporting the request alone would
        /// send somebody to change the wrong number.
        public let maxTokensApplied: Int?
        public let cappedByPolicy: Bool

        /// Whether the model stopped because it ran out of room.
        public var wasTruncated: Bool { finishReason == "length" }
    }

    private let configuration: Configuration
    private let credential: () -> String?
    private let session: URLSession

    /// The credential is read through a closure rather than held.
    ///
    /// It lives in the Keychain and is fetched per request, so a key changed in
    /// Settings takes effect on the next question rather than on the next
    /// launch, and a copy of it is never sitting in this actor's memory for
    /// longer than one call.
    public init(configuration: Configuration = .localhost,
                credential: @Sendable @escaping () -> String?) {
        self.configuration = configuration
        self.credential = credential
        self.session = URLSession(
            configuration: .ephemeral,
            delegate: PinnedCA(path: configuration.caCertificatePath),
            delegateQueue: nil)
    }

    // ------------------------------------------------------------ generation

    /// Ask the fleet, given what retrieval found.
    ///
    /// **The retrieved passages go in the user turn, not the system prompt.**
    /// The fleet keys its prompt cache on longest common prefix, measured at
    /// 34.6s cold against 0.8s warm, so anything that changes every turn must come
    /// last. Putting the passages in the system prompt, which is what a one
    /// shot script does, would change the prefix on every turn and make a
    /// conversation slower exactly as it became worth having.
    public func answer(question: String, passages: [(citation: String, text: String)],
                       history: [(question: String, answer: String)],
                       model: String? = nil,
                       maxTokens: Int = 800) async throws -> Answer {
        guard let key = credential(), !key.isEmpty else { throw Failure.noCredential }

        var messages: [[String: Any]] = [["role": "system", "content": Self.system]]
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": Self.userTurn(question, passages)])

        var body: [String: Any] = ["messages": messages, "max_tokens": maxTokens]
        if let model { body["model"] = model }

        let started = Date()
        let (data, response) = try await send("/v1/chat/completions", body: body,
                                              key: key)
        let seconds = Date().timeIntervalSince(started)

        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw Failure.malformed("not JSON")
        }
        if response.statusCode != 200 {
            let message = ((object["error"] as? [String: Any])?["message"] as? String)
                ?? "status \(response.statusCode)"
            throw Failure.refused(status: response.statusCode, message: message)
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw Failure.malformed("no choices[0].message.content")
        }
        let dai = object["dai"] as? [String: Any]
        let finish = (choices.first?["finish_reason"] as? String)
        return Answer(text: text,
                      model: object["model"] as? String,
                      node: dai?["node"] as? String,
                      presenceState: dai?["presenceState"] as? String,
                      seconds: seconds,
                      finishReason: finish,
                      maxTokensApplied: dai?["maxTokensApplied"] as? Int,
                      cappedByPolicy: (dai?["cappedByPolicy"] as? Bool) ?? false)
    }

    /// What the model is told, once, for the life of the conversation.
    ///
    /// Short, and every line of it about not inventing. The rules are the ones
    /// the Python examples arrived at after watching a model answer confidently
    /// from an empty retrieval.
    static let system = """
    You answer questions using only the passages provided with each question.

    Answer first, in two or three sentences, then only what is needed to act on
    it. If the passages do not answer the question, say so plainly and say what
    you would expect to find it in. An invented answer is worse than none here,
    because the person asking cannot tell the difference.

    Cite the passage a claim came from by its name, like (Delete a Workload
    Domain). Do not name a source that is not in the passages.

    Say plainly when something is destructive or irreversible, and say what is
    lost rather than that care is needed.
    """

    static func userTurn(_ question: String,
                         _ passages: [(citation: String, text: String)]) -> String {
        guard !passages.isEmpty else {
            return question + "\n\nNo passages were retrieved for this question."
        }
        let rendered = passages
            .map { "[\($0.citation)]\n\($0.text)" }
            .joined(separator: "\n\n")
        return "\(question)\n\nPassages:\n\n\(rendered)"
    }

    // --------------------------------------------------------------- sending

    private func send(_ path: String, body: [String: Any],
                      key: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: configuration.baseURL
            .appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // A completion is dispatched as one unit and a large prompt takes
        // minutes to read, so the default sixty seconds is far too short.
        request.timeoutInterval = 600

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.malformed("not an HTTP response")
            }
            return (data, http)
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // **A stopped request is not an unreachable fleet.**
            //
            // URLSession reports cancellation as a URLError rather than as a
            // CancellationError, so without this a question somebody stopped on
            // purpose would surface as "Could not reach the gateway", sending
            // them to look at a network that is working.
            throw CancellationError()
        } catch {
            throw Failure.unreachable("\(error.localizedDescription)")
        }
    }
}

/// Trusts the control plane's own CA, and nothing else unusual.
///
/// The fleet issues its own certificates, so the system trust store does not
/// know them. The alternative to pinning the CA is disabling validation
/// entirely, which would also accept anything else on that address: on a
/// laptop that moves between networks, that is the difference between a private
/// fleet and any machine claiming to be one.
private final class PinnedCA: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let anchor: SecCertificate?

    init(path: String?) {
        if let path, let data = FileManager.default.contents(atPath: path) {
            // PEM or DER: SecCertificateCreateWithData wants DER, so a PEM is
            // stripped of its armour first.
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("BEGIN CERTIFICATE") {
                let base64 = text
                    .components(separatedBy: .newlines)
                    .filter { !$0.hasPrefix("-----") }
                    .joined()
                anchor = Data(base64Encoded: base64)
                    .flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            } else {
                anchor = SecCertificateCreateWithData(nil, data as CFData)
            }
        } else {
            anchor = nil
        }
        super.init()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let anchor else {
            // No CA configured: the system decides, which for a self signed
            // fleet means the connection is refused. Refusing is right; the fix
            // is to point the app at the CA the installer printed.
            return (.performDefaultHandling, nil)
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        // Only this anchor, so the system store cannot also vouch for it.
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
            ? (.useCredential, URLCredential(trust: trust))
            : (.cancelAuthenticationChallenge, nil)
    }
}
