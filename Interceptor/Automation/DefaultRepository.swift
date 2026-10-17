import AutomationCore
import Foundation

/// Publisher identity shipped with the app. Only repository metadata is registered automatically.
struct DefaultRepository: Sendable {
    let url: RepositoryURL
    let repositoryID: UUID
    let fingerprint: String

    static let official: DefaultRepository = {
        guard let url = try? RepositoryURL(parsing: "https://qtmleap.github.io/Interceptor-Plugins/repository.json"),
              let repositoryID = UUID(uuidString: "90A213C0-9D3C-47F5-ABB8-C15C7472E2AD") else {
            preconditionFailure("Invalid bundled repository identity")
        }
        return DefaultRepository(url: url, repositoryID: repositoryID,
                                 fingerprint: "b29b13755f2df72858c5d14ea7c1b293fa379b9ad3ea2f86f016dfa0735cd96a")
    }()
}
