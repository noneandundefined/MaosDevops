import Foundation

/// Minimal git status via SSH CLI (no libgit2).
enum GitService {
    static func status(server: Server, path: String, completion: @escaping (Result<String, Error>) -> Void) {
        let cmd = """
        cd \(path) 2>/dev/null || exit 1
        echo BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        echo COMMIT=$(git log -1 --oneline 2>/dev/null)
        echo AHEAD_BEHIND=$(git rev-list --left-right --count @{upstream}...HEAD 2>/dev/null)
        echo ---STATUS---
        git status --porcelain 2>/dev/null
        """
        AppServices.shared.sshManager.execute(on: server, command: cmd, completion: { result in
            switch result {
            case .success(let r) where r.exitCode == 0:
                completion(.success(r.stdout))
            case .success(let r):
                completion(.failure(SSHError.commandFailed(r.exitCode, r.stderr)))
            case .failure(let e):
                completion(.failure(e))
            }
        })
    }
}
