import Foundation

/// Runs `body` with the ambient Git setup some developers' machines really have: commit signing
/// through a program that fails, a global hook that rejects every commit, and an inherited
/// GIT_DIR. Test fixtures must neither inherit nor be broken by any of it.
/// Synchronous on purpose: it edits this process's environment, so keep `body` short.
func withHostileGitEnvironment<T>(_ body: () throws -> T) throws -> T {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("devbox-hostile-home-\(UUID().uuidString)")
    let hooks = home.appendingPathComponent("hooks")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let hook = hooks.appendingPathComponent("pre-commit")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try Data("""
        [commit]
        \tgpgsign = true
        [gpg]
        \tprogram = /usr/bin/false
        [core]
        \thooksPath = \(hooks.path)

        """.utf8).write(to: home.appendingPathComponent(".gitconfig"))

    let names = ["HOME", "GIT_DIR", "GIT_WORK_TREE"]
    let saved = names.map { name in getenv(name).map { String(cString: $0) } }
    setenv("HOME", home.path, 1)
    setenv("GIT_DIR", "/nonexistent/devbox-git-dir", 1)
    setenv("GIT_WORK_TREE", "/nonexistent/devbox-work-tree", 1)
    defer {
        for (name, value) in zip(names, saved) {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }
    return try body()
}
