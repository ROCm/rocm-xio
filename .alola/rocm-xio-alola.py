#!/usr/bin/env python3
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
"""Consolidated SLURM test runner for the Alola
test cluster.

Subcommands
-----------
run      Submit and/or check SLURM test jobs.
results  Scan historical log directories.
monitor  Watch live SLURM job status.
"""

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

# ── Constants ──────────────────────────────────────────

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
JOB_IDS_FILE = SCRIPT_DIR / ".alola-job-ids"

TESTS = [
    ("single-gpu",
     "rocm-xio-tests.single-gpu.sbatch"),
    ("two-gpu",
     "rocm-xio-tests.two-gpu.sbatch"),
    ("nvme-ep",
     "rocm-xio-tests.nvme-ep.sbatch"),
    # rdma-ep disabled: GPU kernel illegal memory
    # access during loopback (under investigation)
    # ("rdma-ep",
    #  "rocm-xio-tests.rdma-ep.sbatch"),
]

STATUS_PASS = 0
STATUS_FAIL = 1
STATUS_UNKNOWN = 2
STATUS_NO_OUTPUT = 3
STATUS_RUNNING = 4

RC_TIMEOUT = 124

SEPARATOR = "=" * 42


# ── Colour helpers ─────────────────────────────────────


def _tty():
    return sys.stdout.isatty()


def green(text):
    if _tty():
        return f"\033[0;32m{text}\033[0m"
    return str(text)


def red(text):
    if _tty():
        return f"\033[0;31m{text}\033[0m"
    return str(text)


def yellow(text):
    if _tty():
        return f"\033[0;33m{text}\033[0m"
    return str(text)


# ── Subprocess / git helpers ───────────────────────────


def run_cmd(args, timeout=None):
    """Run *args*, return CompletedProcess or None."""
    try:
        return subprocess.run(
            args, capture_output=True,
            text=True, timeout=timeout,
        )
    except (subprocess.TimeoutExpired,
            FileNotFoundError):
        return None


def git_short_sha():
    r = run_cmd(
        ["git", "-C", str(REPO_DIR),
         "rev-parse", "--short", "HEAD"],
        timeout=5,
    )
    if r and r.returncode == 0:
        return r.stdout.strip()
    return "unknown"


def prepare_snapshot(ref):
    """Extract *ref* via ``git archive`` into a temp
    directory under ``/tmp``.

    Returns ``(snapshot_path, resolved_sha)``.
    """
    r = run_cmd(
        ["git", "-C", str(REPO_DIR),
         "rev-parse", "--short", ref],
        timeout=5,
    )
    if not r or r.returncode != 0:
        print(red(
            f"ERROR: cannot resolve ref: {ref}"))
        sys.exit(1)
    resolved = r.stdout.strip()
    snap = Path(tempfile.mkdtemp(
        prefix=f"rocm-xio-{resolved}-"))
    archive = subprocess.Popen(
        ["git", "-C", str(REPO_DIR),
         "archive", ref],
        stdout=subprocess.PIPE,
    )
    extract = subprocess.Popen(
        ["tar", "-x", "-C", str(snap)],
        stdin=archive.stdout,
    )
    archive.stdout.close()
    extract.communicate()
    if extract.returncode != 0:
        print(red(
            "ERROR: git archive | tar failed"))
        shutil.rmtree(snap, ignore_errors=True)
        sys.exit(1)
    print(f"Snapshot of {ref} ({resolved}) "
          f"extracted to {snap}")
    return snap, resolved


def squeue_node(job_id, timeout_sec=2):
    """Return the node a job is running on."""
    r = run_cmd(
        ["squeue", "-j", str(job_id),
         "-h", "-o", "%N"],
        timeout=timeout_sec,
    )
    if r and r.returncode == 0:
        return r.stdout.strip()
    return ""


def read_sbatch_constraint(script_path):
    """Parse the ``#SBATCH --constraint=`` value
    from a sbatch script."""
    try:
        for line in Path(
            script_path
        ).read_text().splitlines():
            m = re.match(
                r"^#SBATCH\s+--constraint=(.+)",
                line)
            if m:
                return m.group(1).strip()
    except OSError:
        pass
    return None


# ── Job-IDs file I/O ──────────────────────────────────


def load_job_ids():
    """Return ``(logs_dir, {name: job_id})``."""
    logs_dir = ""
    job_ids = {}
    if not JOB_IDS_FILE.is_file():
        return logs_dir, job_ids
    for line in JOB_IDS_FILE.read_text().splitlines():
        line = line.strip()
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        if key == "LOGS_DIR":
            logs_dir = value
        elif key and value:
            job_ids[key] = value
    return logs_dir, job_ids


def save_job_ids(logs_dir, job_ids):
    lines = [f"LOGS_DIR:{logs_dir}"]
    for name, jid in job_ids.items():
        lines.append(f"{name}:{jid}")
    JOB_IDS_FILE.write_text(
        "\n".join(lines) + "\n")


def remove_job_ids_file():
    try:
        JOB_IDS_FILE.unlink()
    except OSError:
        pass


# ── SLURM helpers ──────────────────────────────────────


def squeue_state(job_id, timeout_sec=1):
    """Return SLURM job state string, or ``""``."""
    r = run_cmd(
        ["squeue", "-j", str(job_id),
         "-h", "-o", "%T"],
        timeout=timeout_sec,
    )
    if r and r.returncode == 0:
        out = r.stdout.strip().splitlines()
        return out[0] if out else ""
    return ""


def squeue_detail(job_id, timeout_sec=2):
    """Return state + runtime + reason, or ``""``."""
    r = run_cmd(
        ["squeue", "-j", str(job_id),
         "-h", "-o", "%T %M %R"],
        timeout=timeout_sec,
    )
    if r and r.returncode == 0:
        return r.stdout.strip()
    return ""


def squeue_all_user(timeout_sec=5):
    """Show all jobs for the current user."""
    r = run_cmd(
        ["squeue", "-u",
         os.environ.get("USER", ""),
         "-o",
         "%.10i %.20j %.8T %.10M %.6D %R"],
        timeout=timeout_sec,
    )
    if r and r.returncode == 0:
        return r.stdout
    return ""


def sacct_state(job_id, timeout_sec=3):
    """Use sacct to query the final state of a job
    that has left the squeue.  Returns the state
    string (e.g. "COMPLETED") or "" on failure."""
    r = run_cmd(
        ["sacct", "-j", str(job_id),
         "--format=State", "-n", "-P",
         "--noconvert"],
        timeout=timeout_sec,
    )
    if r and r.returncode == 0:
        for line in r.stdout.strip().splitlines():
            s = line.strip()
            if s and s != "RUNNING":
                return s
    return ""


def is_terminal_state(state):
    return state in (
        "COMPLETED", "FAILED", "CANCELLED",
    )


def cancel_jobs(job_ids):
    """scancel each id and poll until gone."""
    ids = (
        list(job_ids.values())
        if isinstance(job_ids, dict)
        else list(job_ids)
    )
    if not ids:
        return
    print(f"Cancelling jobs: {' '.join(ids)}")
    for jid in ids:
        run_cmd(["scancel", jid], timeout=5)
    print("Waiting for queue to clear...")
    for _ in range(60):
        still = False
        for jid in ids:
            r = run_cmd(
                ["squeue", "-j", jid, "-h"],
                timeout=2,
            )
            if r and r.stdout.strip():
                still = True
                break
        if not still:
            break
        time.sleep(5)
    remove_job_ids_file()


# ── Output-file discovery ─────────────────────────────


def _test_script(test_name):
    for name, script in TESTS:
        if name == test_name:
            return script
    return None


def _base(script):
    """Strip ``.sbatch`` suffix."""
    if script.endswith(".sbatch"):
        return script[: -len(".sbatch")]
    return script


def _err_of(out):
    """Convert ``.out`` path to ``.err`` path."""
    if out and out.endswith(".out"):
        return out[:-4] + ".err"
    return None


def find_output_file(test_name, job_id, logs_dir):
    """Locate the ``.out`` file for a known job ID.

    Returns ``(out_path, err_path)`` or
    ``(None, None)``.
    """
    script = _test_script(test_name)
    if not script:
        return None, None
    base = _base(script)
    candidates = []
    if logs_dir and Path(logs_dir).is_dir():
        d = Path(logs_dir)
        candidates.append(
            d / f"{base}.{job_id}.out")
        candidates.append(
            d / f"{script}.{job_id}.out")
    candidates += [
        Path("logs") / f"{base}.{job_id}.out",
        Path("logs") / f"{script}.{job_id}.out",
    ]
    for c in candidates:
        if c.is_file():
            s = str(c)
            return s, _err_of(s)

    try:
        for p in sorted(
            Path("logs").rglob(
                f"*.{job_id}.out")
        ):
            if p.is_file():
                s = str(p)
                return s, _err_of(s)
    except OSError:
        pass
    return None, None


def _newest(paths):
    valid = [p for p in paths if p.is_file()]
    if not valid:
        return None
    return max(
        valid, key=lambda p: p.stat().st_mtime)


def find_latest_output(test_name, logs_dir):
    """Find the newest ``.out`` when no job ID is
    known."""
    script = _test_script(test_name)
    if not script:
        return None, None
    base = _base(script)
    pat = f"{base}.*.out"
    searches = []
    if logs_dir and Path(logs_dir).is_dir():
        searches.append(Path(logs_dir).glob(pat))
    searches += [
        Path("logs").glob(f"*/{pat}"),
        Path("logs").glob(pat),
        Path(".").glob(pat),
    ]
    for gen in searches:
        p = _newest(gen)
        if p:
            s = str(p)
            return s, _err_of(s)
    return None, None


# ── Status helpers ─────────────────────────────────────


def file_has_status(filepath, status_word):
    """Check whether *filepath* contains a
    ``Status: <status_word>`` line."""
    try:
        with open(filepath) as fh:
            for line in fh:
                if f"Status: {status_word}" in line:
                    return True
    except OSError:
        pass
    return False


def get_file_status(filepath):
    """Return STATUS_PASS, STATUS_FAIL, or None."""
    if not filepath or not Path(filepath).is_file():
        return None
    if file_has_status(filepath, "PASS"):
        return STATUS_PASS
    if file_has_status(filepath, "FAIL"):
        return STATUS_FAIL
    return None


def full_status_line(filepath):
    """Return the first ``Status:`` line, or None."""
    if not filepath or not Path(filepath).is_file():
        return None
    try:
        with open(filepath) as fh:
            for line in fh:
                if line.startswith("Status:"):
                    return line.strip()
    except OSError:
        pass
    return None


def file_age(filepath):
    """Seconds since last modification, or None."""
    try:
        return time.time() - (
            Path(filepath).stat().st_mtime)
    except OSError:
        return None


def determine_status(
    test_name, out_path, job_id, submitted,
):
    """Compute a ``STATUS_*`` code for one test."""
    if out_path and Path(out_path).is_file():
        fs = get_file_status(out_path)
        if fs is not None:
            return fs
        if submitted and job_id:
            st = squeue_state(job_id)
            if st and not is_terminal_state(st):
                return STATUS_RUNNING
        return STATUS_UNKNOWN
    return STATUS_NO_OUTPUT


# ── Summary extraction ─────────────────────────────────


def extract_test_summary(out_path):
    """Return indented summary lines, or None."""
    if not out_path or not Path(out_path).is_file():
        return None
    try:
        lines = (
            Path(out_path).read_text().splitlines())
    except OSError:
        return None
    idx = None
    for i, ln in enumerate(lines):
        if ln.strip() == "Test Summary":
            idx = i
            break
    if idx is None:
        return None
    start = max(0, idx - 1)
    sep_count = 0
    end = len(lines)
    for i in range(idx, len(lines)):
        if lines[i].strip() == SEPARATOR:
            sep_count += 1
            if sep_count == 2:
                end = i + 1
                break
    return [
        "  " + ln for ln in lines[start:end]]


# ── Submit jobs ────────────────────────────────────────


def submit_jobs(
    tag="", source_dir=None,
    commit_mode=False, exclude_nodes=None,
    partition=None, extra_exclude=None,
):
    """Submit sbatch jobs.

    *tag*: suffix for the logs directory name to
    avoid collisions in parallel waves.
    *source_dir*: path to a snapshot directory
    (--commit mode); sbatch runs from there.
    *commit_mode*: if True, strip MARKHAM constraint
    and --container-mount-home from sbatch flags.
    *exclude_nodes*: comma-separated node list
    passed to ``sbatch --exclude``.
    *partition*: SLURM partition name.
    *extra_exclude*: additional nodes to exclude
    (used by --spread).

    Returns ``(logs_dir, job_ids, out_files,
    err_files)``.
    """
    print(SEPARATOR)
    print("Submitting test jobs")
    print(SEPARATOR)
    print()

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    if tag:
        ts = f"{ts}_{tag}"
    abs_logs = (SCRIPT_DIR / "logs" / ts).resolve()
    abs_logs.mkdir(parents=True, exist_ok=True)
    logs_dir = str(abs_logs)
    print(f"Logs directory: {logs_dir}")
    print()

    submit_dir = (
        Path(source_dir) if source_dir
        else SCRIPT_DIR)

    exclude_list = []
    if exclude_nodes:
        exclude_list += exclude_nodes.split(",")
    if extra_exclude:
        exclude_list += [
            n for n in extra_exclude
            if n not in exclude_list]

    job_ids = {}
    out_files = {}
    err_files = {}
    for test_name, script in TESTS:
        script_path = submit_dir / script
        if not script_path.is_file():
            print(
                "ERROR: Test script not found: "
                f"{script_path}")
            continue
        print(yellow(
            f"Submitting {test_name}..."))
        base = _base(script)
        out_pat = f"{logs_dir}/%x.%j.out"
        err_pat = f"{logs_dir}/%x.%j.err"

        cmd = [
            "sbatch",
            f"--chdir={submit_dir}",
            "--export=ALL,"
            f"ALOLA_LOGS_DIR={logs_dir}",
            f"--job-name={base}",
            f"--output={out_pat}",
            f"--error={err_pat}",
        ]

        if commit_mode:
            orig = read_sbatch_constraint(
                script_path)
            if orig:
                relaxed = re.sub(
                    r"MARKHAM&?", "", orig)
                if relaxed:
                    cmd.append(
                        f"--constraint={relaxed}")
            cmd.append(
                "--container-mount-home=no")

        if exclude_list:
            cmd.append(
                "--exclude="
                + ",".join(exclude_list))

        if partition:
            cmd.append(
                f"--partition={partition}")

        cmd.append(str(script_path))

        r = run_cmd(cmd, timeout=30)

        if r and r.returncode == 0:
            m = re.search(r"\d+", r.stdout)
            jid = m.group() if m else ""
            job_ids[test_name] = jid
            print(
                f"  {yellow('Job ID:')} {jid}")
            out_files[test_name] = (
                f"{logs_dir}/{base}.{jid}.out")
            err_files[test_name] = (
                f"{logs_dir}/{base}.{jid}.err")
        else:
            msg = ""
            if r:
                msg = (
                    r.stderr or r.stdout or ""
                ).strip()
            if not msg:
                msg = "sbatch not available"
            print(f"  {red('ERROR:')} {msg}")

    print()
    print("All jobs submitted. Job IDs:")
    for name, jid in job_ids.items():
        print(f"  {name}: {jid}")
    save_job_ids(logs_dir, job_ids)
    print()
    print(f"Job IDs saved to: {JOB_IDS_FILE}")
    print(f"Logs directory: {logs_dir}")
    print()
    return logs_dir, job_ids, out_files, err_files


# ── Load existing state ───────────────────────────────


def load_existing_state():
    """Load state from job-IDs file.

    Returns ``(logs_dir, job_ids, out_files,
    err_files)``.
    """
    print(SEPARATOR)
    print("Finding existing test output files")
    print(SEPARATOR)
    print()

    logs_dir, job_ids = load_job_ids()
    out_files = {}
    err_files = {}

    if job_ids:
        print(
            f"{yellow('Loading job IDs from:')} "
            f"{JOB_IDS_FILE}")
        if logs_dir:
            print(
                f"  {yellow('Logs directory:')} "
                f"{logs_dir}")
        for name, jid in job_ids.items():
            print(f"  {name}: {jid}")
            o, e = find_output_file(
                name, jid, logs_dir)
            if o:
                out_files[name] = o
                err_files[name] = e
        print()
    else:
        for name, _ in TESTS:
            o, e = find_latest_output(
                name, logs_dir)
            if o:
                out_files[name] = o
                err_files[name] = e

    print()
    return logs_dir, job_ids, out_files, err_files


# ── Wait for completion ───────────────────────────────


def wait_for_completion(
    job_ids, out_files, logs_dir, deadline=None,
):
    """Block until every job finishes or *deadline*
    passes.

    Returns True if all completed, False on timeout.
    """
    print(SEPARATOR)
    print("Waiting for jobs to complete")
    print(SEPARATOR)
    print()

    prev_lines = 0
    no_output_retries = {}

    while True:
        if deadline and time.time() >= deadline:
            return False

        all_done = True
        status_lines = []

        for test_name, jid in job_ids.items():
            if not jid:
                continue

            out = out_files.get(test_name)
            if out and not Path(out).is_file():
                out = None
            if not out:
                o, _ = find_output_file(
                    test_name, jid, logs_dir)
                if o:
                    out_files[test_name] = o
                    out = o

            state = squeue_state(jid)
            if not state:
                state = sacct_state(jid)
            has_final = (
                out
                and Path(out).is_file()
                and get_file_status(out) is not None
            )

            is_running = False

            if state and not is_terminal_state(
                state
            ):
                is_running = True
                all_done = False
            elif not has_final:
                if (not out
                        or not Path(out).is_file()):
                    ret = no_output_retries.get(
                        test_name, 0)
                    no_output_retries[test_name] = (
                        ret + 1)
                    if ret < 12:
                        is_running = True
                        all_done = False
                elif not is_terminal_state(state):
                    is_running = True
                    all_done = False

            if out and Path(out).is_file():
                out_files[test_name] = out
                if file_has_status(out, "PASS"):
                    col = green
                elif file_has_status(out, "FAIL"):
                    col = red
                    if is_running:
                        all_done = False
                else:
                    col = yellow
                try:
                    last = (
                        Path(out).read_text()
                        .splitlines()[-1]
                        .strip()[:50]
                    )
                except (OSError, IndexError):
                    last = ""
                if last:
                    status_lines.append(
                        f"{col(test_name + ':')} "
                        f"{last}")
            elif is_running:
                status_lines.append(
                    f"{yellow(test_name + ':')} "
                    "(waiting for output...)")
            else:
                status_lines.append(
                    f"{red(test_name + ':')} "
                    "(output file not found)")

        if all_done:
            break

        if _tty():
            for _ in range(prev_lines):
                sys.stdout.write("\033[A\033[K")
        for sl in status_lines:
            print(f"\r{sl}")
        prev_lines = len(status_lines)
        time.sleep(5)

    if _tty():
        for _ in range(prev_lines):
            sys.stdout.write("\033[A\033[K")
    print()
    print(green("All jobs completed."))
    print()
    return True


# ── Display results ────────────────────────────────────


def display_results(
    job_ids, out_files, err_files,
    logs_dir, verbose, submitted,
):
    """Print per-test and overall results.

    Returns an exit code (0 / 1 / 2 / 3).
    """
    print(SEPARATOR)
    print("Test Results Summary")
    print(SEPARATOR)
    print()

    total_passed = 0
    total_failed = 0
    total_unknown = 0
    total_running = 0
    subtest_counts = []

    for test_name, script in TESTS:
        print("-" * 40)
        print(test_name)
        print("-" * 40)

        jid = job_ids.get(test_name, "")
        if jid:
            print(f"{yellow('Job ID:')} {jid}")

        out = out_files.get(test_name)
        err = err_files.get(test_name)

        if out and Path(out).is_file():
            print(f"stdout: {out}")
            if err:
                print(f"stderr: {err}")

        if (not out
                or not Path(out).is_file()) and jid:
            o, e = find_output_file(
                test_name, jid, logs_dir)
            if o:
                out_files[test_name] = o
                err_files[test_name] = e
                out, err = o, e
                print(f"stdout: {out}")
                if err:
                    print(f"stderr: {err}")

        sc = determine_status(
            test_name, out, jid, submitted)

        fsl = (
            full_status_line(out) if out else None)
        suffix = ""
        if fsl:
            if sc == STATUS_PASS:
                suffix = re.sub(
                    r"^Status:\s*PASS\s*", "",
                    fsl)
            elif sc == STATUS_FAIL:
                suffix = re.sub(
                    r"^Status:\s*FAIL\s*", "",
                    fsl)

        sub_count = 0
        if fsl:
            m = re.search(r"of (\d+)", fsl)
            if m:
                sub_count = int(m.group(1))
        subtest_counts.append(sub_count)

        if sc == STATUS_PASS:
            label = green("PASS")
            if suffix:
                print(
                    f"Status: {label} {suffix}")
            else:
                print(f"Status: {label}")
            total_passed += 1

        elif sc == STATUS_FAIL:
            label = red("FAIL")
            if suffix:
                print(
                    f"Status: {label} {suffix}")
            else:
                print(f"Status: {label}")
            total_failed += 1

        elif sc == STATUS_RUNNING:
            print(
                "Status: "
                f"{yellow('RUNNING')}")
            total_running += 1
            if verbose and jid:
                detail = squeue_detail(jid)
                if detail:
                    print(
                        f"  Job State: {detail}")

        elif sc == STATUS_NO_OUTPUT:
            print(
                "Status: "
                f"{yellow('NO_OUTPUT')}")
            total_unknown += 1

        else:
            print(
                "Status: "
                f"{yellow('Unknown')}"
                " (no summary found)")
            total_unknown += 1

        if out and Path(out).is_file():
            if sc not in (
                STATUS_RUNNING,
                STATUS_NO_OUTPUT,
            ):
                if verbose:
                    summary = (
                        extract_test_summary(out))
                    if summary:
                        print()
                        print("\n".join(summary))
                    else:
                        print()
                        print(
                            "  No test summary "
                            "found in output")
            elif sc == STATUS_RUNNING and verbose:
                print()
                print(yellow(
                    "Recent output "
                    "(last 10 lines):"))
                try:
                    tail = (
                        Path(out).read_text()
                        .splitlines()[-10:]
                    )
                    for ln in tail:
                        print(f"  {ln}")
                except OSError:
                    print("  (no output yet)")

        if (err
                and Path(err).is_file()
                and Path(err).stat().st_size > 0
                and verbose):
            print()
            print(red("Errors (last 10 lines):"))
            try:
                tail = (
                    Path(err).read_text()
                    .splitlines()[-10:]
                )
                for ln in tail:
                    print(f"  {ln}")
            except OSError:
                pass

        print()

    # Overall summary
    print(SEPARATOR)
    print("Overall Summary")
    print(SEPARATOR)
    sub_list = ", ".join(
        str(c) for c in subtest_counts)
    print(
        f"Total Tests: {len(TESTS)}"
        f" ({sub_list})")
    print(f"Passed: {green(total_passed)}")
    if total_failed > 0:
        print(f"Failed: {red(total_failed)}")
    else:
        print(f"Failed: {green(total_failed)}")
    if total_running > 0:
        print(
            f"Running: {yellow(total_running)}")
    if total_unknown > 0:
        print(
            "Unknown/No output: "
            f"{yellow(total_unknown)}")

    if total_running > 0:
        print(
            "Overall Status: "
            f"{yellow('RUNNING')}")
        return 3
    if total_failed == 0 and total_unknown == 0:
        print(
            "Overall Status: "
            f"{green('PASS')}")
        return 0
    if total_failed > 0:
        print(
            "Overall Status: "
            f"{red('FAIL')}")
        return 1
    print(
        "Overall Status: "
        f"{yellow('Unknown')}")
    return 2


# ── Single run cycle ──────────────────────────────────


def _run_once(submit, wait, verbose,
              deadline=None, source_dir=None,
              commit_mode=False,
              exclude_nodes=None,
              partition=None):
    """Execute one submit / wait / report cycle.

    Returns exit code (0-3, or 124 for timeout).
    """
    logs_dir = ""
    job_ids = {}
    out_files = {}
    err_files = {}

    if submit and JOB_IDS_FILE.is_file():
        print(
            f"{red('ERROR:')} Job IDs file "
            f"already exists: {JOB_IDS_FILE}")
        print()
        print(
            "This file contains job IDs from a "
            "previous submission.")
        print(
            "To submit new tests, first remove "
            "it:")
        print(f"  rm {JOB_IDS_FILE}")
        print()
        print(
            "Or run without --submit to check "
            "status.")
        return 1

    if not submit and not JOB_IDS_FILE.is_file():
        print(
            f"{red('ERROR:')} No existing job "
            f"IDs file: {JOB_IDS_FILE}")
        print()
        print("To submit new test jobs:")
        print(
            "  rocm-xio-alola.py run --submit")
        print()
        print("To wait for completion:")
        print(
            "  rocm-xio-alola.py run "
            "--submit --wait")
        return 1

    # Phase 1 -- submit
    if submit:
        (logs_dir, job_ids,
         out_files, err_files) = submit_jobs(
            source_dir=source_dir,
            commit_mode=commit_mode,
            exclude_nodes=exclude_nodes,
            partition=partition,
        )

    # Phase 2 -- load existing state
    if not submit or wait:
        ld, ji, of, ef = load_existing_state()
        if not logs_dir:
            logs_dir = ld
        for k, v in ji.items():
            job_ids.setdefault(k, v)
        for k, v in of.items():
            out_files.setdefault(k, v)
        for k, v in ef.items():
            err_files.setdefault(k, v)

    # Phase 3 -- wait
    if wait:
        ok = wait_for_completion(
            job_ids, out_files,
            logs_dir, deadline)
        if not ok:
            return RC_TIMEOUT
        if submit:
            remove_job_ids_file()

    # Phase 4 -- submit-only (no wait)
    if submit and not wait:
        print(green(
            "Jobs submitted successfully."))
        print(yellow(
            "Run 'rocm-xio-alola.py run' to "
            "check status later."))
        print(yellow(
            "Run 'rocm-xio-alola.py run --wait'"
            " to wait for completion."))
        return 0

    # Phase 5 -- display results
    return display_results(
        job_ids, out_files, err_files,
        logs_dir, verbose, submit)


# ── Wave-based parallel execution ─────────────────────


def _run_wave(
    wave_start, wave_size, timeout_sec,
    verbose, source_dir=None,
    commit_mode=False, exclude_nodes=None,
    partition=None, spread=False,
):
    """Submit *wave_size* iterations at once, wait
    for all, and return a list of exit codes.

    When *spread* is True, each iteration within
    the wave excludes nodes already allocated by
    earlier iterations in the same wave.
    """
    wave_jobs = {}
    wave_outs = {}
    wave_logs = []
    used_nodes = []

    for slot in range(wave_size):
        idx = wave_start + slot + 1
        tag = f"p{idx}"
        print("=" * 39)
        print(
            f"  Submitting iteration {idx} "
            f"(wave slot {slot + 1}/"
            f"{wave_size})")
        print("=" * 39)

        extra_ex = list(used_nodes) if spread else []
        remove_job_ids_file()
        logs_dir, job_ids, out_files, _ = (
            submit_jobs(
                tag=tag,
                source_dir=source_dir,
                commit_mode=commit_mode,
                exclude_nodes=exclude_nodes,
                partition=partition,
                extra_exclude=extra_ex,
            ))
        wave_logs.append(logs_dir)

        for tname, jid in job_ids.items():
            key = f"{tname}__p{idx}"
            wave_jobs[key] = jid
            if tname in out_files:
                wave_outs[key] = out_files[tname]

        if spread:
            time.sleep(1)
            for jid in job_ids.values():
                node = squeue_node(jid)
                if node and node not in used_nodes:
                    used_nodes.append(node)

    print()
    print("=" * 39)
    print(
        f"Wave submitted: {wave_size} iterations,"
        f" {len(wave_jobs)} total jobs")
    if used_nodes:
        print(
            f"Nodes allocated: "
            + ", ".join(used_nodes))
    print("=" * 39)
    print()

    dl = time.time() + timeout_sec
    ok = wait_for_completion(
        wave_jobs, wave_outs, "", dl)

    results = []
    for slot in range(wave_size):
        idx = wave_start + slot + 1
        ld = wave_logs[slot]
        all_pass = True
        for tname, _ in TESTS:
            key = f"{tname}__p{idx}"
            out = wave_outs.get(key)
            if not out:
                jid = wave_jobs.get(key, "")
                if jid:
                    out, _ = find_output_file(
                        tname, jid, ld)
            if out:
                st = get_file_status(out)
                if st != STATUS_PASS:
                    all_pass = False
            else:
                all_pass = False
        if not ok:
            results.append(RC_TIMEOUT)
        elif all_pass:
            results.append(0)
        else:
            results.append(1)

    remove_job_ids_file()
    return results


# ── cmd_run ────────────────────────────────────────────


def cmd_run(args):
    os.chdir(SCRIPT_DIR)

    original_handler = signal.getsignal(
        signal.SIGINT)
    snapshot_dir = None

    def _on_sigint(_sig, _frame):
        print()
        if JOB_IDS_FILE.is_file():
            print(
                "Interrupted. Jobs continue "
                "running in SLURM.")
            print(
                "Run 'rocm-xio-alola.py run' "
                "later to check status.")
        else:
            print(
                "Interrupted before job "
                "submission.")
        sys.exit(130)

    signal.signal(signal.SIGINT, _on_sigint)

    try:
        commit_mode = False
        source_dir = None
        if args.commit:
            snap, resolved = prepare_snapshot(
                args.commit)
            snapshot_dir = snap
            source_dir = str(snap)
            commit_mode = True
            print(
                f"Using snapshot: {snap} "
                f"({resolved})")
            print()

        if args.iterations == 1:
            rc = _run_once(
                args.submit, args.wait,
                args.verbose,
                source_dir=source_dir,
                commit_mode=commit_mode,
                exclude_nodes=args.exclude_nodes,
                partition=args.partition)
            sys.exit(rc)

        # ── repeat mode (iterations > 1) ──
        if commit_mode:
            sha = source_dir.split("-")[-1].rstrip(
                "/")
        else:
            sha = git_short_sha()
        timeout_sec = args.timeout
        total = args.iterations
        parallel = args.parallel
        tally = {
            "pass": 0, "fail": 0,
            "timeout": 0, "other": 0,
        }

        print("=" * 39)
        print(
            f"Repeat test run -- commit {sha}")
        print(f"Started: {datetime.now()}")
        print(f"Total iterations: {total}")
        print(f"Parallel: {parallel}")
        print(
            "Timeout per wave: "
            f"{timeout_sec // 60}m")
        if commit_mode:
            print(f"Snapshot: {source_dir}")
        if args.spread:
            print("Spread: enabled")
        if args.exclude_nodes:
            print(
                f"Exclude: {args.exclude_nodes}")
        if args.partition:
            print(
                f"Partition: {args.partition}")
        print("=" * 39)
        print()

        if parallel == 1:
            for i in range(1, total + 1):
                print("=" * 39)
                print(
                    f"Run {i} of {total} -- "
                    f"{datetime.now()}")
                print(f"  commit: {sha}")
                print("=" * 39)

                remove_job_ids_file()
                dl = time.time() + timeout_sec
                rc = _run_once(
                    submit=True, wait=True,
                    verbose=args.verbose,
                    deadline=dl,
                    source_dir=source_dir,
                    commit_mode=commit_mode,
                    exclude_nodes=(
                        args.exclude_nodes),
                    partition=args.partition)

                if rc == RC_TIMEOUT:
                    print()
                    print(
                        f"TIMEOUT after "
                        f"{timeout_sec}s"
                        f" on run {i}")
                    _, jids = load_job_ids()
                    if jids:
                        cancel_jobs(jids)

                print(
                    f"Run {i} exited "
                    f"with code {rc}")

                if rc == 0:
                    tally["pass"] += 1
                elif rc == 1:
                    tally["fail"] += 1
                elif rc == RC_TIMEOUT:
                    tally["timeout"] += 1
                else:
                    tally["other"] += 1

                print(
                    f"Running tally: "
                    f"pass={tally['pass']} "
                    f"fail={tally['fail']} "
                    f"timeout={tally['timeout']} "
                    f"other={tally['other']}")
                print()
        else:
            wave_num = 0
            for ws in range(0, total, parallel):
                wave_num += 1
                wave_size = min(
                    parallel, total - ws)
                print("=" * 39)
                print(
                    f"Wave {wave_num}: "
                    f"iterations "
                    f"{ws + 1}-{ws + wave_size} "
                    f"of {total}")
                print(f"  {datetime.now()}")
                print("=" * 39)
                print()

                codes = _run_wave(
                    ws, wave_size,
                    timeout_sec, args.verbose,
                    source_dir=source_dir,
                    commit_mode=commit_mode,
                    exclude_nodes=(
                        args.exclude_nodes),
                    partition=args.partition,
                    spread=args.spread,
                )

                for rc in codes:
                    if rc == 0:
                        tally["pass"] += 1
                    elif rc == 1:
                        tally["fail"] += 1
                    elif rc == RC_TIMEOUT:
                        tally["timeout"] += 1
                    else:
                        tally["other"] += 1

                print(
                    f"Running tally: "
                    f"pass={tally['pass']} "
                    f"fail={tally['fail']} "
                    f"timeout={tally['timeout']} "
                    f"other={tally['other']}")
                print()

        print("=" * 39)
        print(
            f"Final results after {total} runs")
        print(f"  commit: {sha}")
        print("=" * 39)
        print(f"Pass:    {tally['pass']}")
        print(f"Fail:    {tally['fail']}")
        print(f"Timeout: {tally['timeout']}")
        print(f"Other:   {tally['other']}")
        sys.exit(
            1 if tally["fail"] > 0 else 0)

    finally:
        if snapshot_dir:
            print(
                f"Cleaning up snapshot: "
                f"{snapshot_dir}")
            shutil.rmtree(
                snapshot_dir,
                ignore_errors=True)
        signal.signal(
            signal.SIGINT, original_handler)


# ── cmd_results ────────────────────────────────────────


def _test_name_from_out(path):
    """Extract test name from an output filename.

    ``rocm-xio-tests.single-gpu.12345.out``
    -> ``single-gpu``
    """
    parts = Path(path).name.split(".")
    if (len(parts) >= 4
            and parts[0] == "rocm-xio-tests"):
        return parts[1]
    return Path(path).name


def _per_test_status(outs):
    """Return per-test-name status for a log dir.

    Returns ``{test_name: "PASS"|"FAIL"|"UNKNOWN"}``
    """
    result = {}
    for f in outs:
        name = _test_name_from_out(f)
        s = str(f)
        if file_has_status(s, "FAIL"):
            result[name] = "FAIL"
        elif file_has_status(s, "PASS"):
            result[name] = "PASS"
        else:
            result[name] = "UNKNOWN"
    return result


def cmd_results(args):
    os.chdir(SCRIPT_DIR)
    logs = Path("logs")
    if not logs.is_dir():
        print("No logs/ directory found.")
        return

    verbose = args.verbose
    n_pass = 0
    n_fail = 0
    n_unknown = 0
    fail_by_test = {}
    unknown_by_test = {}

    print()
    for d in sorted(logs.iterdir()):
        if not d.is_dir():
            continue
        ts = d.name
        outs = list(d.glob("*.out"))
        if not outs:
            n_unknown += 1
            if verbose:
                print(f"{ts}: UNKNOWN")
            continue

        per_test = _per_test_status(outs)
        has_fail = "FAIL" in per_test.values()
        has_pass = "PASS" in per_test.values()

        if has_fail:
            n_fail += 1
            if verbose:
                print(f"{ts}: FAIL")
            for tn, st in per_test.items():
                if st == "FAIL":
                    cnt, first = fail_by_test.get(
                        tn, (0, ts))
                    fail_by_test[tn] = (
                        cnt + 1, first)
        elif has_pass:
            n_pass += 1
            if verbose:
                print(f"{ts}: PASS")
        else:
            n_unknown += 1
            if verbose:
                print(f"{ts}: UNKNOWN")
            for tn, st in per_test.items():
                if st == "UNKNOWN":
                    cnt, first = (
                        unknown_by_test.get(
                            tn, (0, ts)))
                    unknown_by_test[tn] = (
                        cnt + 1, first)

    total = n_pass + n_fail + n_unknown
    if verbose:
        print()
    print(SEPARATOR)
    print("Results Summary")
    print(SEPARATOR)
    print(f"Total:   {total}")
    print(f"Passed:  {green(n_pass)}")
    if n_fail > 0:
        print(f"Failed:  {red(n_fail)}")
        for tn in sorted(fail_by_test):
            cnt, first = fail_by_test[tn]
            print(
                f"  {tn}: {red(cnt)}"
                f" [{first}]")
    else:
        print(f"Failed:  {green(n_fail)}")
    if n_unknown > 0:
        print(
            f"Unknown: {yellow(n_unknown)}")
        for tn in sorted(unknown_by_test):
            cnt, first = unknown_by_test[tn]
            print(
                f"  {tn}: {yellow(cnt)}"
                f" [{first}]")
    else:
        print(f"Unknown: {n_unknown}")


# ── cmd_monitor ────────────────────────────────────────


def cmd_monitor(args):
    job_ids = args.job_ids

    if not job_ids:
        print("Showing all your SLURM jobs:")
        print()
        out = squeue_all_user()
        if out:
            print(out, end="")
        return

    print(
        "Monitoring job(s): "
        f"{' '.join(job_ids)}")
    print()

    try:
        while True:
            if _tty():
                sys.stdout.write("\033[2J\033[H")
                sys.stdout.flush()
            print(SEPARATOR)
            print(
                f"Job Status - {datetime.now()}")
            print(SEPARATOR)
            print()

            for jid in job_ids:
                print(f"Job {jid}:")
                r = run_cmd(
                    ["squeue", "-j", jid, "-o",
                     "%.10i %.20j %.8T "
                     "%.10M %.6D %R"],
                    timeout=5,
                )
                if (r and r.returncode == 0
                        and r.stdout.strip()):
                    print(r.stdout.rstrip())
                else:
                    print(
                        f"  Job {jid} not found"
                        " (may have completed)")
                print()

            all_done = True
            for jid in job_ids:
                r = run_cmd(
                    ["squeue", "-j", jid, "-h"],
                    timeout=2,
                )
                if r and r.stdout.strip():
                    all_done = False
                    break

            if all_done:
                print("All jobs completed!")
                break

            time.sleep(5)
    except KeyboardInterrupt:
        print("\nMonitoring stopped.")


# ── main ───────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        prog="rocm-xio-alola",
        description=(
            "Consolidated SLURM test runner "
            "for the Alola test cluster."
        ),
    )
    sub = parser.add_subparsers(dest="command")

    # ── run ──
    p_run = sub.add_parser(
        "run",
        help=(
            "Submit and/or check SLURM "
            "test jobs."),
    )
    p_run.add_argument(
        "--submit", action="store_true",
        help="Submit new test jobs.",
    )
    wait_grp = (
        p_run.add_mutually_exclusive_group())
    wait_grp.add_argument(
        "--wait", action="store_true",
        default=False,
        help="Wait for jobs to complete.",
    )
    wait_grp.add_argument(
        "--no-wait", dest="wait",
        action="store_false",
        help=(
            "Do not wait "
            "(only with --submit)."),
    )
    p_run.add_argument(
        "--verbose", action="store_true",
        help="Show detailed test output.",
    )
    p_run.add_argument(
        "--iterations", type=int, default=1,
        metavar="N",
        help=(
            "Run N iterations (default: 1). "
            "When >1, --submit --wait are "
            "implied."),
    )
    p_run.add_argument(
        "--timeout", type=int, default=1800,
        metavar="SEC",
        help=(
            "Per-iteration timeout in seconds "
            "(default: 1800). Only used when "
            "--iterations > 1."),
    )
    p_run.add_argument(
        "--parallel", type=int, default=1,
        metavar="P",
        help=(
            "Submit P iterations concurrently "
            "(default: 1). Requires "
            "--iterations. Spreads jobs across "
            "more nodes."),
    )
    p_run.add_argument(
        "--commit", type=str, default=None,
        metavar="REF",
        help=(
            "Test a specific commit, tag, or "
            "branch instead of the working "
            "tree. Creates a snapshot in /tmp "
            "via git archive."),
    )
    p_run.add_argument(
        "--spread", action="store_true",
        help=(
            "Spread parallel jobs across "
            "distinct nodes by excluding "
            "already-allocated nodes within "
            "each wave."),
    )
    p_run.add_argument(
        "--exclude-nodes", type=str,
        default=None, metavar="NODES",
        help=(
            "Comma-separated list of nodes to "
            "exclude (e.g. node1,node2)."),
    )
    p_run.add_argument(
        "--partition", type=str, default=None,
        metavar="PART",
        help="SLURM partition to submit to.",
    )
    p_run.set_defaults(func=cmd_run)

    # ── results ──
    p_res = sub.add_parser(
        "results",
        help=(
            "Scan log directories for "
            "PASS/FAIL."),
    )
    p_res.add_argument(
        "--verbose", action="store_true",
        help=(
            "Print per-directory PASS/FAIL "
            "lines (default: summary only)."),
    )
    p_res.set_defaults(func=cmd_results)

    # ── monitor ──
    p_mon = sub.add_parser(
        "monitor",
        help="Watch live SLURM job status.",
    )
    p_mon.add_argument(
        "job_ids", nargs="*",
        help=(
            "Job IDs to monitor. If omitted, "
            "show all user jobs."),
    )
    p_mon.set_defaults(func=cmd_monitor)

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    args.func(args)


if __name__ == "__main__":
    main()
