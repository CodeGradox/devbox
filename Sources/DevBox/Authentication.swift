import LocalAuthentication

@MainActor
enum OwnerAuthentication {
    static func authorize(reason: String) async throws {
        // A fresh context binds authentication to this confirmation, not a previous batch.
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? NSError(
                domain: "DevBox.Authentication",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "macOS authentication is unavailable. Nothing was deleted."]
            )
        }
        let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        guard success else {
            throw NSError(
                domain: "DevBox.Authentication",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Authentication was not completed. Nothing was deleted."]
            )
        }
    }
}
