#!/usr/bin/env python3
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run(cmd, **kwargs):
    timeout = kwargs.pop("timeout", 90)
    try:
        result = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired as exc:
        print("$ " + " ".join(str(part) for part in cmd))
        print(f"Timed out after {timeout}s", file=sys.stderr)
        if exc.stdout:
            print(exc.stdout, end="")
        if exc.stderr:
            print(exc.stderr, end="", file=sys.stderr)
        raise SystemExit(124)
    if result.returncode != 0:
        print("$ " + " ".join(str(part) for part in cmd))
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        raise SystemExit(result.returncode)
    return result


def compile_and_run_supervisor_shutdown_test():
    with tempfile.TemporaryDirectory(prefix="scriptdock-smoke-") as tmp:
        tmp_path = Path(tmp)
        home = tmp_path / "home"
        support = home / "Library" / "Application Support" / "ScriptDock"
        support.mkdir(parents=True)
        config = support / "scripts.json"
        config.write_text(
            textwrap.dedent(
                """
                {
                  "tasks": [
                    {
                      "id": "default-stop",
                      "name": "Default Stop",
                      "programArguments": ["/bin/sleep", "30"],
                      "mode": "daemon"
                    },
                    {
                      "id": "keep-running",
                      "name": "Keep Running",
                      "programArguments": ["/bin/sleep", "30"],
                      "mode": "daemon",
                      "keepRunningOnQuit": true
                    }
                  ]
                }
                """
            ).strip()
        )

        test_main = tmp_path / "SupervisorShutdownTest.swift"
        test_main.write_text(
            textwrap.dedent(
                """
                import Darwin
                import Foundation

                func assertCondition(_ condition: @autoclosure () -> Bool, _ message: String) {
                    if !condition() {
                        fputs("Assertion failed: \\(message)\\n", stderr)
                        exit(1)
                    }
                }

                func processIsRunning(_ pid: Int32) -> Bool {
                    kill(pid, 0) == 0
                }

                @main
                struct SupervisorShutdownTest {
                    static func main() {
                        let store = TaskStore(appSupportURL: URL(fileURLWithPath: "__APP_SUPPORT__"))
                        try! store.ensureSupportFiles()
                        _ = store.reload()
                        let supervisor = Supervisor(store: store)
                        supervisor.start(autoStart: false, startHTTPServer: false)

                        assertCondition(supervisor.startTask(id: "default-stop", source: "test") == nil, "default-stop should start")
                        assertCondition(supervisor.startTask(id: "keep-running", source: "test") == nil, "keep-running should start")
                        usleep(200_000)

                        guard let defaultPID = supervisor.taskStatus(id: "default-stop")?.pid else {
                            fputs("default-stop has no pid\\n", stderr)
                            exit(1)
                        }
                        guard let keepPID = supervisor.taskStatus(id: "keep-running")?.pid else {
                            fputs("keep-running has no pid\\n", stderr)
                            exit(1)
                        }

                        supervisor.shutdownForAppQuit(timeout: 1.0)
                        usleep(1_300_000)

                        assertCondition(!processIsRunning(defaultPID), "default-stop should be stopped on app quit")
                        assertCondition(processIsRunning(keepPID), "keep-running should remain alive on app quit")
                        _ = kill(keepPID, SIGTERM)
                        exit(0)
                    }
                }
                """
            ).strip().replace("__APP_SUPPORT__", str(support))
        )

        binary = tmp_path / "SupervisorShutdownTest"
        sources = [
            ROOT / "src/Models.swift",
            ROOT / "src/TaskStore.swift",
            ROOT / "src/ProcessRunner.swift",
            ROOT / "src/PortInspector.swift",
            ROOT / "src/Supervisor/SupervisorMain.swift",
            test_main,
        ]
        env = os.environ.copy()
        env["HOME"] = str(home)
        run(["swiftc", *map(str, sources), "-parse-as-library", "-o", str(binary)], env=env)
        run([str(binary)], env=env)


def pid_is_running(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def compile_and_run_detached_writer_test():
    with tempfile.TemporaryDirectory(prefix="scriptdock-detach-") as tmp:
        tmp_path = Path(tmp)
        home = tmp_path / "home"
        support = home / "Library" / "Application Support" / "ScriptDock"
        pid_file = tmp_path / "pids.txt"
        support.mkdir(parents=True)
        config = support / "scripts.json"
        config.write_text(
            textwrap.dedent(
                """
                {
                  "tasks": [
                    {
                      "id": "default-stop",
                      "name": "Default Stop",
                      "programArguments": ["/bin/sleep", "30"],
                      "mode": "daemon"
                    },
                    {
                      "id": "keep-writing",
                      "name": "Keep Writing",
                      "programArguments": ["/bin/sh", "-c", "while true; do echo tick >&2; sleep 0.1; done"],
                      "mode": "daemon",
                      "keepRunningOnQuit": true
                    }
                  ]
                }
                """
            ).strip()
        )

        test_main = tmp_path / "DetachedWriterTest.swift"
        test_main.write_text(
            textwrap.dedent(
                """
                import Darwin
                import Foundation

                func fail(_ message: String) -> Never {
                    fputs("\\(message)\\n", stderr)
                    exit(1)
                }

                @main
                struct DetachedWriterTest {
                    static func main() {
                        let store = TaskStore(appSupportURL: URL(fileURLWithPath: "__APP_SUPPORT__"))
                        try! store.ensureSupportFiles()
                        _ = store.reload()
                        let supervisor = Supervisor(store: store)
                        supervisor.start(autoStart: false, startHTTPServer: false)

                        guard supervisor.startTask(id: "default-stop", source: "test") == nil else {
                            fail("default-stop should start")
                        }
                        guard supervisor.startTask(id: "keep-writing", source: "test") == nil else {
                            fail("keep-writing should start")
                        }
                        usleep(300_000)

                        guard let defaultPID = supervisor.taskStatus(id: "default-stop")?.pid else {
                            fail("default-stop has no pid")
                        }
                        guard let keepPID = supervisor.taskStatus(id: "keep-writing")?.pid else {
                            fail("keep-writing has no pid")
                        }

                        try! "default=\\(defaultPID)\\nkeep=\\(keepPID)\\n".write(
                            to: URL(fileURLWithPath: "__PID_FILE__"),
                            atomically: true,
                            encoding: .utf8
                        )
                        supervisor.shutdownForAppQuit(timeout: 0.5)
                        exit(0)
                    }
                }
                """
            ).strip()
            .replace("__APP_SUPPORT__", str(support))
            .replace("__PID_FILE__", str(pid_file))
        )

        binary = tmp_path / "DetachedWriterTest"
        sources = [
            ROOT / "src/Models.swift",
            ROOT / "src/TaskStore.swift",
            ROOT / "src/ProcessRunner.swift",
            ROOT / "src/PortInspector.swift",
            ROOT / "src/Supervisor/SupervisorMain.swift",
            test_main,
        ]
        env = os.environ.copy()
        env["HOME"] = str(home)
        run(["swiftc", *map(str, sources), "-parse-as-library", "-o", str(binary)], env=env)
        run([str(binary)], env=env)

        pids = {}
        for line in pid_file.read_text().splitlines():
            key, value = line.split("=", maxsplit=1)
            pids[key] = int(value)

        time.sleep(1.2)
        if pid_is_running(pids["default"]):
            os.kill(pids["default"], signal.SIGTERM)
            raise SystemExit("default-stop should be stopped after app quit shutdown")
        if not pid_is_running(pids["keep"]):
            raise SystemExit("keep-writing should survive parent exit while continuing to write logs")
        os.kill(pids["keep"], signal.SIGTERM)


def compile_and_run_closed_stream_test():
    """回归测试：子进程关闭输出流但仍存活（如 ssh -N）时，readabilityHandler
    不得在 EOF 上空读 busy-loop。修复前会跑满一个 CPU 核心。"""
    with tempfile.TemporaryDirectory(prefix="scriptdock-closestream-") as tmp:
        tmp_path = Path(tmp)
        home = tmp_path / "home"
        support = home / "Library" / "Application Support" / "ScriptDock"
        support.mkdir(parents=True)
        config = support / "scripts.json"
        config.write_text(
            textwrap.dedent(
                """
                {
                  "tasks": [
                    {
                      "id": "close-streams",
                      "name": "Close Streams",
                      "programArguments": ["/bin/sh", "-c", "exec 1>&- 2>&-; sleep 5"],
                      "mode": "daemon"
                    }
                  ]
                }
                """
            ).strip()
        )

        test_main = tmp_path / "ClosedStreamTest.swift"
        test_main.write_text(
            textwrap.dedent(
                """
                import Darwin
                import Foundation

                func fail(_ message: String) -> Never {
                    fputs("\\(message)\\n", stderr)
                    exit(1)
                }

                func cpuSeconds(_ r: rusage) -> Double {
                    Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1_000_000
                        + Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1_000_000
                }

                @main
                struct ClosedStreamTest {
                    static func main() {
                        let store = TaskStore(appSupportURL: URL(fileURLWithPath: "__APP_SUPPORT__"))
                        try! store.ensureSupportFiles()
                        _ = store.reload()
                        let supervisor = Supervisor(store: store)
                        supervisor.start(autoStart: false, startHTTPServer: false)

                        guard supervisor.startTask(id: "close-streams", source: "test") == nil else {
                            fail("close-streams should start")
                        }
                        // 子进程立即关闭 stdout/stderr -> 读端收到 EOF，进程靠 sleep 维持存活。
                        // 修复前：readabilityHandler 在 EOF 上空读 busy-loop，单核 ~100%。
                        // 修复后：EOF 时注销 handler，CPU 约 0。
                        usleep(300_000)

                        var before = rusage()
                        getrusage(RUSAGE_SELF, &before)
                        let wallBefore = Date()
                        usleep(2_000_000)
                        var after = rusage()
                        getrusage(RUSAGE_SELF, &after)
                        let wall = Date().timeIntervalSince(wallBefore)
                        let cpu = cpuSeconds(after) - cpuSeconds(before)
                        let pct = (cpu / wall) * 100

                        if pct > 30 {
                            fail("readabilityHandler busy-loop: \\(String(format: "%.0f", pct))% CPU over \\(String(format: "%.1f", wall))s (threshold 30%)")
                        }
                        supervisor.shutdownForAppQuit(timeout: 1.0)
                        usleep(500_000)
                        exit(0)
                    }
                }
                """
            ).strip().replace("__APP_SUPPORT__", str(support))
        )

        binary = tmp_path / "ClosedStreamTest"
        sources = [
            ROOT / "src/Models.swift",
            ROOT / "src/TaskStore.swift",
            ROOT / "src/ProcessRunner.swift",
            ROOT / "src/PortInspector.swift",
            ROOT / "src/Supervisor/SupervisorMain.swift",
            test_main,
        ]
        env = os.environ.copy()
        env["HOME"] = str(home)
        run(["swiftc", *map(str, sources), "-parse-as-library", "-o", str(binary)], env=env)
        run([str(binary)], env=env)


def compile_and_run_tilde_path_test():
    """Regression test: execution expands ~ and ~/ without rewriting the config."""
    with tempfile.TemporaryDirectory(prefix="scriptdock-tilde-") as tmp:
        tmp_path = Path(tmp)
        support = tmp_path / "support"
        support.mkdir(parents=True)
        config = support / "scripts.json"
        config.write_text(
            textwrap.dedent(
                r'''
                {
                  "tasks": [
                    {
                      "id": "tilde-paths",
                      "name": "Tilde Paths",
                      "programArguments": [
                        "/bin/sh",
                        "-c",
                        "printf '%s\\n%s\\n' \"$PWD\" \"$1\"; sleep 0.2",
                        "probe",
                        "~"
                      ],
                      "workingDirectory": "~",
                      "mode": "oneshot"
                    }
                  ]
                }
                '''
            ).strip()
        )

        test_main = tmp_path / "TildePathTest.swift"
        test_main.write_text(
            textwrap.dedent(
                """
                import Darwin
                import Foundation

                func assertCondition(_ condition: @autoclosure () -> Bool, _ message: String) {
                    if !condition() {
                        fputs("Assertion failed: \\(message)\\n", stderr)
                        exit(1)
                    }
                }

                @main
                struct TildePathTest {
                    static func main() {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        assertCondition(UserPath.expandingTilde("~") == home, "~ should expand to the current user's home")
                        assertCondition(
                            UserPath.expandingTilde("~/example") == URL(fileURLWithPath: home).appendingPathComponent("example").path,
                            "~/example should expand below the current user's home"
                        )
                        assertCondition(
                            ManagedTask.resolveExecutable("~/bin/tool") == URL(fileURLWithPath: home).appendingPathComponent("bin/tool").path,
                            "executable paths should expand ~/"
                        )

                        let store = TaskStore(appSupportURL: URL(fileURLWithPath: "__APP_SUPPORT__"))
                        try! store.ensureSupportFiles()
                        _ = store.reload()
                        assertCondition(store.preflightProblem(for: store.tasks[0]) == nil, "preflight should accept ~ paths")

                        let supervisor = Supervisor(store: store)
                        supervisor.start(autoStart: false, startHTTPServer: false)
                        assertCondition(supervisor.startTask(id: "tilde-paths", source: "test") == nil, "tilde task should start")

                        let deadline = Date().addingTimeInterval(3)
                        while supervisor.taskStatus(id: "tilde-paths")?.state == .running && Date() < deadline {
                            usleep(50_000)
                        }
                        usleep(200_000)

                        let data = supervisor.readLogs(id: "tilde-paths", stream: .stdout, since: 0)?.data ?? Data()
                        let output = String(data: data, encoding: .utf8) ?? ""
                        let matchingLines = output.components(separatedBy: "\\n").filter { $0.contains(home) }
                        assertCondition(matchingLines.count >= 2, "working directory and argv should both expand ~; output: \\(output)")
                        exit(0)
                    }
                }
                """
            ).strip().replace("__APP_SUPPORT__", str(support))
        )

        binary = tmp_path / "TildePathTest"
        sources = [
            ROOT / "src/Models.swift",
            ROOT / "src/TaskStore.swift",
            ROOT / "src/ProcessRunner.swift",
            ROOT / "src/PortInspector.swift",
            ROOT / "src/Supervisor/SupervisorMain.swift",
            test_main,
        ]
        run(["swiftc", *map(str, sources), "-parse-as-library", "-o", str(binary)])
        run([str(binary)])


def compile_and_run_retry_lifecycle_test():
    """Regression test: retry backoff is cancellable and independent from Auto Start."""
    with tempfile.TemporaryDirectory(prefix="scriptdock-retry-") as tmp:
        tmp_path = Path(tmp)
        support = tmp_path / "support"
        support.mkdir(parents=True)
        fail_script = tmp_path / "fail.sh"
        stable_script = tmp_path / "stable-after-retry.sh"
        auto_counter = tmp_path / "auto-count.txt"
        retry_counter = tmp_path / "retry-count.txt"
        stable_counter = tmp_path / "stable-count.txt"

        fail_script.write_text(
            '#!/bin/sh\nprintf "attempt\\n" >> "$1"\nexit 1\n'
        )
        stable_script.write_text(
            textwrap.dedent(
                """
                #!/bin/sh
                count=0
                if [ -f "$1" ]; then count=$(wc -l < "$1"); fi
                printf "attempt\\n" >> "$1"
                if [ "$count" -gt 0 ]; then sleep 0.25; fi
                exit 1
                """
            ).lstrip()
        )
        fail_script.chmod(0o755)
        stable_script.chmod(0o755)

        config = support / "scripts.json"
        config.write_text(
            json.dumps(
                {
                    "tasks": [
                        {
                            "id": "auto-once",
                            "name": "Auto Once",
                            "programArguments": [str(fail_script), str(auto_counter)],
                            "runAtLoad": True,
                            "keepAlive": False,
                            "mode": "daemon",
                        },
                        {
                            "id": "retry-stop",
                            "name": "Retry Stop",
                            "programArguments": [str(fail_script), str(retry_counter)],
                            "runAtLoad": False,
                            "keepAlive": True,
                            "mode": "daemon",
                        },
                        {
                            "id": "stable-reset",
                            "name": "Stable Reset",
                            "programArguments": [str(stable_script), str(stable_counter)],
                            "runAtLoad": False,
                            "keepAlive": True,
                            "mode": "daemon",
                        },
                    ]
                },
                indent=2,
            )
        )

        test_main = tmp_path / "RetryLifecycleTest.swift"
        test_main.write_text(
            textwrap.dedent(
                """
                import Darwin
                import Foundation

                func assertCondition(_ condition: @autoclosure () -> Bool, _ message: String) {
                    if !condition() {
                        fputs("Assertion failed: \\(message)\\n", stderr)
                        exit(1)
                    }
                }

                func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        if condition() { return true }
                        usleep(10_000)
                    }
                    return condition()
                }

                func lineCount(_ path: String) -> Int {
                    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
                    return text.split(separator: "\\n").count
                }

                @main
                struct RetryLifecycleTest {
                    static func main() {
                        let policy = RetryPolicy(delays: RetryPolicy.defaultDelays, stableRunThreshold: 60)
                        let expected: [TimeInterval] = [2, 3, 5, 8, 13, 21, 30, 45, 60, 90, 120, 180, 300, 300]
                        for (index, delay) in expected.enumerated() {
                            assertCondition(
                                policy.delay(forAttempt: index + 1) == delay,
                                "unexpected production retry delay at attempt \\(index + 1)"
                            )
                        }

                        let store = TaskStore(appSupportURL: URL(fileURLWithPath: "__APP_SUPPORT__"))
                        try! store.ensureSupportFiles()
                        _ = store.reload()
                        let supervisor = Supervisor(
                            store: store,
                            retryDelays: [0.15, 0.25, 0.35],
                            stableRunThreshold: 0.2
                        )
                        supervisor.start(autoStart: true, startHTTPServer: false)

                        assertCondition(
                            waitUntil(1.0) { supervisor.taskStatus(id: "auto-once")?.state == .errored },
                            "Auto Start without Keep Alive should end in errored state"
                        )
                        usleep(400_000)
                        assertCondition(lineCount("__AUTO_COUNTER__") == 1, "Auto Start should launch only once")

                        assertCondition(supervisor.startTask(id: "retry-stop", source: "test") == nil, "retry-stop should start")
                        assertCondition(
                            waitUntil(1.0) {
                                let status = supervisor.taskStatus(id: "retry-stop")
                                return status?.state == .retrying && status?.retryAttempt == 1
                            },
                            "first failure should schedule retry attempt 1"
                        )
                        assertCondition(
                            waitUntil(1.0) {
                                let status = supervisor.taskStatus(id: "retry-stop")
                                return status?.state == .retrying && status?.retryAttempt == 2
                            },
                            "second failure should schedule retry attempt 2"
                        )

                        if let status = supervisor.taskStatus(id: "retry-stop") {
                            let encoder = JSONEncoder()
                            encoder.dateEncodingStrategy = .iso8601
                            let data = try! encoder.encode(status)
                            let decoder = JSONDecoder()
                            decoder.dateDecodingStrategy = .iso8601
                            let decoded = try! decoder.decode(TaskStatus.self, from: data)
                            assertCondition(decoded.state == .retrying, "retrying state should round-trip")
                            assertCondition(decoded.retryAttempt == 2, "retry attempt should round-trip")
                            assertCondition(decoded.nextRetryAt != nil, "next retry date should round-trip")
                        } else {
                            assertCondition(false, "retry-stop status should exist")
                        }

                        let attemptsBeforeStop = lineCount("__RETRY_COUNTER__")
                        assertCondition(supervisor.stopTask(id: "retry-stop") == nil, "Stop should cancel pending retry")
                        usleep(450_000)
                        assertCondition(
                            supervisor.taskStatus(id: "retry-stop")?.state == .stopped,
                            "stopped retry task should remain stopped"
                        )
                        assertCondition(
                            lineCount("__RETRY_COUNTER__") == attemptsBeforeStop,
                            "Stop during retry delay must prevent another launch"
                        )

                        assertCondition(supervisor.startTask(id: "stable-reset", source: "test") == nil, "stable-reset should start")
                        assertCondition(
                            waitUntil(2.0) {
                                lineCount("__STABLE_COUNTER__") >= 2
                                    && supervisor.taskStatus(id: "stable-reset")?.state == .retrying
                            },
                            "stable-reset should complete a failed run and a stable run"
                        )
                        assertCondition(
                            supervisor.taskStatus(id: "stable-reset")?.retryAttempt == 1,
                            "a stable run should reset backoff to attempt 1"
                        )

                        let stableAttemptsBeforeConfigChange = lineCount("__STABLE_COUNTER__")
                        var stableTask = store.task(byID: "stable-reset")!
                        stableTask.keepAlive = false
                        try! store.addOrUpdateTask(stableTask)
                        supervisor.syncTasks()
                        usleep(250_000)
                        assertCondition(
                            supervisor.taskStatus(id: "stable-reset")?.state == .errored,
                            "disabling Keep Alive should cancel a pending retry"
                        )
                        assertCondition(
                            lineCount("__STABLE_COUNTER__") == stableAttemptsBeforeConfigChange,
                            "config reload cancellation must prevent another launch"
                        )

                        stableTask.keepAlive = true
                        try! store.addOrUpdateTask(stableTask)
                        supervisor.syncTasks()
                        assertCondition(supervisor.startTask(id: "stable-reset", source: "test") == nil, "stable-reset should restart")
                        assertCondition(
                            waitUntil(1.0) { supervisor.taskStatus(id: "stable-reset")?.state == .retrying },
                            "stable-reset should enter retrying before shutdown"
                        )
                        let stableAttemptsBeforeShutdown = lineCount("__STABLE_COUNTER__")
                        supervisor.shutdownForAppQuit(timeout: 0.1)
                        usleep(250_000)
                        assertCondition(
                            lineCount("__STABLE_COUNTER__") == stableAttemptsBeforeShutdown,
                            "app shutdown should cancel pending retries"
                        )
                        exit(0)
                    }
                }
                """
            ).strip()
            .replace("__APP_SUPPORT__", str(support))
            .replace("__AUTO_COUNTER__", str(auto_counter))
            .replace("__RETRY_COUNTER__", str(retry_counter))
            .replace("__STABLE_COUNTER__", str(stable_counter))
        )

        binary = tmp_path / "RetryLifecycleTest"
        sources = [
            ROOT / "src/Models.swift",
            ROOT / "src/TaskStore.swift",
            ROOT / "src/ProcessRunner.swift",
            ROOT / "src/PortInspector.swift",
            ROOT / "src/Supervisor/SupervisorMain.swift",
            test_main,
        ]
        run(["swiftc", *map(str, sources), "-parse-as-library", "-o", str(binary)])
        run([str(binary)])


def main():
    if not shutil.which("swiftc"):
        print("swiftc not found", file=sys.stderr)
        return 1
    compile_and_run_supervisor_shutdown_test()
    compile_and_run_detached_writer_test()
    compile_and_run_closed_stream_test()
    compile_and_run_tilde_path_test()
    compile_and_run_retry_lifecycle_test()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
