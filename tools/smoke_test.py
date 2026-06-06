#!/usr/bin/env python3
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


def main():
    if not shutil.which("swiftc"):
        print("swiftc not found", file=sys.stderr)
        return 1
    compile_and_run_supervisor_shutdown_test()
    compile_and_run_detached_writer_test()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
