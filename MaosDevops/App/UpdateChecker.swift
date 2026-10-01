import AppKit
import Foundation

struct AppRelease {
    let version: String
    let pageURL: URL
    let publishedAt: Date?
}

enum UpdateCheckResult {
    case updateAvailable(AppRelease)
    case upToDate(currentVersion: String)
}

enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case invalidRelease
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an unexpected response."
        case .invalidRelease:
            return "The latest GitHub release is missing version information."
        case .requestFailed(let message):
            return message
        }
    }
}

final class UpdateChecker {
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }

    private let endpoint = URL(string: "https://api.github.com/repos/noneandundefined/MaosDevops/releases/latest")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func check(completion: @escaping (Result<UpdateCheckResult, Error>) -> Void) {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MaosDevOps Update Checker", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        session.dataTask(with: request) { data, response, error in
            let result: Result<UpdateCheckResult, Error>
            if let error = error {
                result = .failure(UpdateCheckError.requestFailed(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data = data {
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let remote = try decoder.decode(GitHubRelease.self, from: data)
                    let remoteVersion = Self.cleanVersion(remote.tagName)
                    guard !remoteVersion.isEmpty else {
                        throw UpdateCheckError.invalidRelease
                    }
                    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                    if Self.isNewer(remoteVersion, than: current) {
                        result = .success(.updateAvailable(AppRelease(
                            version: remoteVersion,
                            pageURL: remote.htmlURL,
                            publishedAt: remote.publishedAt
                        )))
                    } else {
                        result = .success(.upToDate(currentVersion: current))
                    }
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(UpdateCheckError.invalidResponse)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }.resume()
    }

    private static func cleanVersion(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = numericComponents(candidate)
        let rhs = numericComponents(current)
        let length = max(lhs.count, rhs.count)
        for index in 0..<length {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func numericComponents(_ value: String) -> [Int] {
        value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
