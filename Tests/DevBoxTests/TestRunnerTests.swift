import Foundation
import Testing

struct TestRunnerTests {
    @Test(arguments: [false, true], [Int32(0), Int32(23)])
    func runnerSerializesTestsAndPreservesArgumentsAndExitStatus(
        customBuildPath: Bool, exitStatus: Int32
    ) throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".build/test-temp/test-runner-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Substitute only the Swift CLI, never build or launch another test process.
        let swift = directory.appendingPathComponent("swift")
        try Data("""
            #!/bin/sh
            printf '%s\\n' "$@" > "$DEVBOX_TEST_ARGUMENTS"
            exit "$DEVBOX_TEST_EXIT_STATUS"
            """.utf8).write(to: swift)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        let argumentsFile = directory.appendingPathComponent("arguments")
        let buildPath = directory.appendingPathComponent("build with spaces").path
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(directory.path):/usr/bin:/bin"
        environment["SWIFT_BUILD_PATH"] = customBuildPath ? buildPath : nil
        environment["DEVBOX_TEST_ARGUMENTS"] = argumentsFile.path
        environment["DEVBOX_TEST_EXIT_STATUS"] = String(exitStatus)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            repository.appendingPathComponent("scripts/test.sh").path,
            "--filter", "ExampleSuite/test with spaces"
        ]
        process.environment = environment
        try process.run()
        process.waitUntilExit()

        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let scratchArguments = customBuildPath ? ["--scratch-path", buildPath] : []
        #expect(arguments == ["test", "--no-parallel"] + scratchArguments
                + ["--filter", "ExampleSuite/test with spaces"])
        #expect(process.terminationStatus == exitStatus)
    }
}
