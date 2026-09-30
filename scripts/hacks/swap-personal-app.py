#!/usr/bin/env python3
"""Swap the installed "cmux Personal" app for a freshly built one, safely.

Runs as a detached daemon because the operator (a Claude Code session) lives
inside the very app being replaced. Phases:

  wait      until every Claude session hosted by cmux is idle for ~2 minutes
  repair    report each pane's true tty to the running app, quit it gracefully,
            then rewrite the saved session snapshot so every pane's agent
            session, resume binding, and working directory match the process
            that was really running in it (the pre-fix builds cross-wired them)
  swap      keep the old bundle as "cmux Personal.previous.app", install the new
            build at the same path, relaunch

Everything is logged to ~/Library/Logs/cmux-swap.log. `--plan` prints what
would happen and exits without touching anything.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import traceback
from datetime import datetime

HOME = os.path.expanduser("~")
BUNDLE_ID = "com.martinmana.cmuxterm"
APP = "/Applications/cmux Personal.app.bak"
PREVIOUS = "/Applications/cmux Personal.previous.app"
NEW_APP = os.path.join(
    HOME, "Library/Developer/Xcode/DerivedData/cmux-personal/Build/Products/Release/cmux Personal.app"
)
BINARY_REL = "Contents/MacOS/cmux Personal"
CLI_REL = "Contents/Resources/bin/cmux"
SOCKET = os.path.join(HOME, ".local/state/cmux/cmux.sock")
SNAPSHOT = os.path.join(HOME, "Library/Application Support/cmux", f"session-{BUNDLE_ID}.json")
HOOK_STORE = os.path.join(HOME, ".cmuxterm/claude-hook-sessions.json")
LOG = os.path.join(HOME, "Library/Logs/cmux-swap.log")
STATE_DIR = os.path.join(HOME, "Library/Logs/cmux-swap")

IDLE_CHECKS_REQUIRED = 4      # consecutive idle samples
IDLE_CHECK_INTERVAL = 30      # seconds between samples
CPU_SAMPLE_SECONDS = 10       # window for the per-process CPU delta
CPU_BUSY_THRESHOLD = 1.0      # seconds of CPU inside the window


DAEMONIZED = False


def log(msg):
    line = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  {msg}"
    if not DAEMONIZED:
        print(line, flush=True)
    with open(LOG, "a") as fh:
        fh.write(line + "\n")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def clean_env():
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("CMUX_") and key not in ("CMUX_SOCKET_PATH",):
            env.pop(key)
    env["CMUX_SOCKET_PATH"] = SOCKET
    env["CMUX_SOCKET"] = ""
    env["CMUX_QUIET"] = "1"
    return env


def rpc(cli, method, params=None, attempts=8):
    """The app socket occasionally drops a connection (broken pipe, timeouts
    while it is busy); retry with backoff instead of failing the whole job."""
    last = None
    for attempt in range(attempts):
        try:
            result = run([cli, "rpc", method, json.dumps(params or {})], env=clean_env(), timeout=30)
            if result.returncode == 0 and result.stdout.strip():
                return json.loads(result.stdout)
            last = result.stderr.strip()[:200] or "empty response"
        except (subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
            last = repr(exc)[:200]
        log(f"rpc {method} attempt {attempt + 1}/{attempts} failed: {last}")
        time.sleep(min(30, 3 * (attempt + 1)))
    raise RuntimeError(f"rpc {method} failed after {attempts} attempts: {last}")


def app_pids(path=APP):
    """pgrep -f cannot match the spaced bundle path reliably; scan ps."""
    needle = os.path.join(path, BINARY_REL)
    pids = []
    for line in run(["ps", "-axo", "pid=,command="]).stdout.splitlines():
        pid, _, command = line.strip().partition(" ")
        if command.startswith(needle):
            pids.append(int(pid))
    return pids


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


# ---------------------------------------------------------------- processes

def claude_processes():
    """Interactive Claude Code processes: pid, tty, session id, cputime."""
    out = run(["ps", "-axo", "pid=,tty=,time=,command="]).stdout
    procs = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        pid, tty, cputime, command = parts
        if not re.search(r"(^|/|\s)claude(\s|$)", command) or "bg-pty-host" in command or "daemon run" in command:
            continue
        if "/claude " not in command and not command.startswith("claude "):
            continue
        m = re.search(r"--(?:resume|session-id) ([0-9a-f-]{36})", command)
        procs.append({
            "pid": int(pid), "tty": tty, "cputime": cputime_seconds(cputime),
            "session": m.group(1) if m else None, "command": command[:120],
        })
    return procs


def cputime_seconds(value):
    # ps TIME looks like MM:SS.ss or HH:MM:SS
    total = 0.0
    for part in value.split(":"):
        total = total * 60 + float(part)
    return total


def process_env(pid):
    out = run(["ps", "-E", "-o", "command=", "-p", str(pid)]).stdout
    env = {}
    for token in out.split():
        if "=" in token and token.startswith("CMUX_"):
            key, _, val = token.partition("=")
            env[key] = val
    return env


def process_cwd(pid):
    out = run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"]).stdout
    for line in out.splitlines():
        if line.startswith("n"):
            return line[1:]
    return None


# ---------------------------------------------------------------- idle

def busy_reasons():
    reasons = []
    try:
        store = json.load(open(HOOK_STORE))
        for sid, rec in store.get("sessions", {}).items():
            pid = rec.get("pid")
            if rec.get("agentLifecycle") == "running" and pid and pid_alive(pid):
                reasons.append(f"hook:{sid[:8]}@{os.path.basename(rec.get('cwd') or '?')} running")
    except Exception as exc:  # noqa: BLE001
        reasons.append(f"hook store unreadable: {exc}")
    before = {p["pid"]: p["cputime"] for p in claude_processes()}
    time.sleep(CPU_SAMPLE_SECONDS)
    for proc in claude_processes():
        delta = proc["cputime"] - before.get(proc["pid"], proc["cputime"])
        if delta > CPU_BUSY_THRESHOLD:
            reasons.append(f"cpu:{proc['pid']} +{delta:.1f}s ({(proc['session'] or '?')[:8]})")
    return reasons


def wait_for_idle():
    consecutive = 0
    while consecutive < IDLE_CHECKS_REQUIRED:
        reasons = busy_reasons()
        if reasons:
            consecutive = 0
            log("busy: " + "; ".join(reasons[:6]))
        else:
            consecutive += 1
            log(f"idle sample {consecutive}/{IDLE_CHECKS_REQUIRED}")
        if consecutive < IDLE_CHECKS_REQUIRED:
            time.sleep(IDLE_CHECK_INTERVAL)
    log("all Claude sessions idle; proceeding")


# ---------------------------------------------------------------- truth

def build_truth(cli):
    """Per surface id: the session, cwd, and tty that really belong to it."""
    top = rpc(cli, "system.top", {"all_windows": True})
    app_tty, workspace_of, surfaces = {}, {}, []
    for window in top["windows"]:
        for ws in window["workspaces"]:
            for pane in ws["panes"]:
                for s in pane["surfaces"]:
                    app_tty[s["id"]] = s.get("tty")
                    workspace_of[s["id"]] = ws["id"]
            # surface.list only covers the selected workspace unless scoped.
            surfaces.extend(rpc(cli, "surface.list", {"workspace_id": ws["id"]})["surfaces"])

    ps = run(["ps", "-axo", "pid=,tty=,command="]).stdout
    script_tty = {}
    for line in ps.splitlines():
        m = re.search(r"cmux-surface-resume/claude-([A-F0-9-]{36})", line)
        if m:
            script_tty[m.group(1)] = line.split()[1]

    procs = claude_processes()
    for proc in procs:
        env = process_env(proc["pid"])
        proc["surface"] = env.get("CMUX_SURFACE_ID")
        proc["cwd"] = process_cwd(proc["pid"])

    truth = {}
    for s in surfaces:
        sid = s["id"]
        m = re.search(r"claude-([A-F0-9-]{36})", s.get("initial_command") or "")
        real_tty = script_tty.get(m.group(1)) if m else app_tty.get(sid)
        candidates = [p for p in procs if p["surface"] == sid]
        if len(candidates) > 1 and real_tty:
            narrowed = [p for p in candidates if p["tty"] == real_tty]
            candidates = narrowed or candidates
        if not candidates and real_tty:
            candidates = [p for p in procs if p["tty"] == real_tty and not p["surface"]]
        chosen = candidates[0] if candidates else None
        truth[sid] = {
            "workspace": workspace_of.get(sid),
            "app_tty": app_tty.get(sid),
            "real_tty": real_tty,
            "session": chosen["session"] if chosen else None,
            "cwd": chosen["cwd"] if chosen else None,
            "pid": chosen["pid"] if chosen else None,
        }
    return truth


def report_true_ttys(cli, truth):
    fixed = 0
    for sid, info in truth.items():
        if info["real_tty"] and info["app_tty"] != info["real_tty"] and info["workspace"]:
            rpc(cli, "surface.report_tty", {
                "workspace_id": info["workspace"], "surface_id": sid, "tty_name": info["real_tty"],
            })
            fixed += 1
    log(f"reported true tty for {fixed} pane(s)")
    return fixed


# ---------------------------------------------------------------- snapshot

def binding_session(binding):
    if not binding:
        return None
    if binding.get("checkpointId"):
        return binding["checkpointId"]
    m = re.search(r"--resume'?\\?'*'?\s*'?([0-9a-f-]{36})", binding.get("command", ""))
    return m.group(1) if m else None


def synthesize_binding(template, session, cwd):
    """Every agent-hook binding in the snapshot comes from one generator, so a
    lost binding can be rebuilt from any sibling by swapping cwd and session."""
    binding = dict(template)
    command = binding["command"]
    if template.get("cwd"):
        command = command.replace(template["cwd"], cwd)
    command = command.replace(template["checkpointId"], session)
    binding.update({"command": command, "checkpointId": session, "cwd": cwd, "updatedAt": time.time()})
    return binding


def synthesize_agent(template, session, cwd):
    agent = json.loads(json.dumps(template))
    agent["sessionId"] = session
    agent["workingDirectory"] = cwd
    if isinstance(agent.get("launchCommand"), dict):
        agent["launchCommand"]["workingDirectory"] = cwd
    return agent


def plan_snapshot_repairs(snapshot, truth):
    by_session = {}
    panels = []
    binding_template = agent_template = None
    for window in snapshot["windows"]:
        for ws in window["tabManager"]["workspaces"]:
            for panel in ws.get("panels", []):
                term = panel.get("terminal")
                if term is None:
                    continue
                panels.append(panel)
                rb, agent = term.get("resumeBinding"), term.get("agent")
                rb_sid, agent_sid = binding_session(rb), (agent or {}).get("sessionId")
                if rb_sid:
                    by_session.setdefault(rb_sid, {})["binding"] = rb
                    if rb.get("source") == "agent-hook" and rb.get("cwd") and binding_template is None:
                        binding_template = rb
                if agent_sid:
                    if agent_template is None and agent.get("launchCommand"):
                        agent_template = agent
                    by_session.setdefault(agent_sid, {})["agent"] = agent
                    if term.get("hibernation"):
                        by_session[agent_sid]["hibernation"] = term["hibernation"]
    changes = []
    for panel in panels:
        info = truth.get(panel["id"])
        if not info or not info["session"]:
            continue
        term = panel["terminal"]
        want = info["session"]
        have_rb, have_agent = binding_session(term.get("resumeBinding")), (term.get("agent") or {}).get("sessionId")
        cwd_ok = not info["cwd"] or term.get("workingDirectory") == info["cwd"]
        if have_rb == want and have_agent in (want, None) and cwd_ok:
            continue
        sources = dict(by_session.get(want, {}))
        sources["synthesized"] = []
        if info["cwd"]:
            if not sources.get("binding") and binding_template:
                sources["binding"] = synthesize_binding(binding_template, want, info["cwd"])
                sources["synthesized"].append("binding")
            if not sources.get("agent") and agent_template:
                sources["agent"] = synthesize_agent(agent_template, want, info["cwd"])
                sources["synthesized"].append("agent")
        changes.append((panel, want, sources, info))
    return changes


def apply_snapshot_repairs(snapshot, changes):
    for panel, want, sources, info in changes:
        term = panel["terminal"]
        if sources.get("binding"):
            term["resumeBinding"] = sources["binding"]
        else:
            term.pop("resumeBinding", None)
        if sources.get("agent"):
            term["agent"] = sources["agent"]
            if sources.get("hibernation"):
                term["hibernation"] = sources["hibernation"]
            else:
                term.pop("hibernation", None)
        else:
            term.pop("agent", None)
            term.pop("hibernation", None)
        if info["cwd"]:
            term["workingDirectory"] = info["cwd"]
            panel["directory"] = info["cwd"]
            if term.get("resumeBinding") and term["resumeBinding"].get("cwd") != info["cwd"]:
                term["resumeBinding"] = dict(term["resumeBinding"], cwd=info["cwd"])


def describe_change(change):
    panel, want, sources, info = change
    term = panel["terminal"]
    return (f"{panel['id'][:8]} cwd {os.path.basename(term.get('workingDirectory') or '?')}"
            f" -> {os.path.basename(info['cwd'] or '?')}; session"
            f" {(binding_session(term.get('resumeBinding')) or '-')[:8]} -> {want[:8]}"
            f" ({'binding' if sources.get('binding') else 'no binding'},"
            f" {'agent' if sources.get('agent') else 'no agent'}"
            f"{'; synthesized ' + '+'.join(sources['synthesized']) if sources.get('synthesized') else ''})")


# ---------------------------------------------------------------- app control

def set_quit_confirmation(disabled):
    if disabled:
        run(["defaults", "write", BUNDLE_ID, "confirmQuit", "-string", "never"])
        run(["defaults", "write", BUNDLE_ID, "warnBeforeQuitShortcut", "-bool", "false"])
    else:
        run(["defaults", "delete", BUNDLE_ID, "confirmQuit"])
        run(["defaults", "delete", BUNDLE_ID, "warnBeforeQuitShortcut"])


def quit_app():
    set_quit_confirmation(True)
    time.sleep(2)
    run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'], timeout=30)
    for _ in range(90):
        if not app_pids():
            log("app quit cleanly")
            return True
        time.sleep(2)
    log("app still running after 180s; sending SIGTERM")
    for pid in app_pids():
        os.kill(pid, 15)
    for _ in range(30):
        if not app_pids():
            log("app exited after SIGTERM")
            return True
        time.sleep(2)
    return False


def swap_bundles():
    if os.path.exists(PREVIOUS):
        shutil.rmtree(PREVIOUS)
    os.rename(APP, PREVIOUS)
    result = run(["ditto", NEW_APP, APP])
    if result.returncode != 0:
        raise RuntimeError(f"ditto failed: {result.stderr}")
    run(["xattr", "-dr", "com.apple.quarantine", APP])
    log(f"installed {NEW_APP} at {APP}; old bundle kept at {PREVIOUS}")


def launch(path):
    run(["open", "-g", path])
    for _ in range(20):
        if app_pids(path):
            return True
        time.sleep(1)
    log("open(1) did not start the app; launching the binary directly")
    subprocess.Popen(
        [os.path.join(path, BINARY_REL)],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True, env=clean_env(),
    )
    for _ in range(40):
        if app_pids(path):
            return True
        time.sleep(1)
    return False


def notify(title, text):
    run(["osascript", "-e", f'display notification "{text}" with title "{title}"'])


# ---------------------------------------------------------------- main

def preflight():
    problems = []
    if not os.path.isdir(NEW_APP):
        problems.append(f"new build missing: {NEW_APP}")
    if not os.path.isdir(APP):
        problems.append(f"installed app missing: {APP}")
    if not app_pids():
        problems.append("installed app is not running")
    if not os.path.isfile(SNAPSHOT):
        problems.append(f"snapshot missing: {SNAPSHOT}")
    return problems


def plan():
    problems = preflight()
    for p in problems:
        log("PREFLIGHT: " + p)
    cli = os.path.join(APP, CLI_REL)
    log("busy reasons now: " + ("; ".join(busy_reasons()) or "none"))
    truth = build_truth(cli)
    stale = [s for s, i in truth.items() if i["real_tty"] and i["real_tty"] != i["app_tty"]]
    log(f"{len(truth)} surfaces; {len(stale)} with a stale tty in the running app")
    snapshot = json.load(open(SNAPSHOT))
    changes = plan_snapshot_repairs(snapshot, truth)
    log(f"snapshot repairs planned: {len(changes)}")
    for change in changes:
        log("  " + describe_change(change))
    unknown = [s[:8] for s, i in truth.items() if not i["session"]]
    log(f"surfaces without a Claude process (left untouched): {len(unknown)}")
    return not problems


def execute():
    os.makedirs(STATE_DIR, exist_ok=True)
    problems = preflight()
    if problems:
        for p in problems:
            log("PREFLIGHT FAILED: " + p)
        return 2
    cli = os.path.join(APP, CLI_REL)
    truth = None
    for attempt in range(5):
        wait_for_idle()
        try:
            truth = build_truth(cli)
            json.dump(truth, open(os.path.join(STATE_DIR, "truth.json"), "w"), indent=1)
            report_true_ttys(cli, truth)
            break
        except Exception:  # noqa: BLE001
            log(f"truth/tty phase failed (attempt {attempt + 1}/5); waiting and retrying\n" + traceback.format_exc())
            time.sleep(60)
    if truth is None:
        log("ABORT: could not talk to the app; nothing changed on disk")
        notify("cmux swap aborted", "Could not talk to the app socket. Nothing was changed.")
        return 6
    time.sleep(15)  # let one autosave land with the corrected tty table

    snapshot_backup = os.path.join(STATE_DIR, f"session-pre-swap-{datetime.now():%Y%m%d-%H%M%S}.json")
    quit_ok = quit_app()
    set_quit_confirmation(False)
    if not quit_ok:
        log("ABORT: app would not quit; nothing changed on disk")
        notify("cmux swap aborted", "The app would not quit. Nothing was changed.")
        return 3

    shutil.copy2(SNAPSHOT, snapshot_backup)
    log(f"snapshot backed up to {snapshot_backup}")
    snapshot = json.load(open(SNAPSHOT))
    changes = plan_snapshot_repairs(snapshot, truth)
    for change in changes:
        log("  repair " + describe_change(change))
    apply_snapshot_repairs(snapshot, changes)
    tmp = SNAPSHOT + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(snapshot, fh, sort_keys=True)
    os.replace(tmp, SNAPSHOT)
    log(f"snapshot repaired: {len(changes)} pane(s) corrected")

    try:
        swap_bundles()
    except Exception:
        log("SWAP FAILED, restoring old bundle\n" + traceback.format_exc())
        if not os.path.isdir(APP) and os.path.isdir(PREVIOUS):
            os.rename(PREVIOUS, APP)
        launch(APP)
        notify("cmux swap failed", "Old app restored and relaunched. See ~/Library/Logs/cmux-swap.log")
        return 4

    if launch(APP):
        log("new app launched")
        notify("cmux updated", "New build installed; layout restored from the repaired snapshot.")
        return 0
    log("new app did not start; restoring old bundle")
    shutil.rmtree(APP, ignore_errors=True)
    os.rename(PREVIOUS, APP)
    launch(APP)
    notify("cmux swap rolled back", "New build failed to launch; old app restored.")
    return 5


def daemonize():
    if os.fork():
        os._exit(0)
    os.setsid()
    if os.fork():
        os._exit(0)
    os.chdir("/")
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    logfd = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(logfd, 1)
    os.dup2(logfd, 2)


if __name__ == "__main__":
    if "--plan" in sys.argv:
        sys.exit(0 if plan() else 1)
    if "--daemon" in sys.argv:
        daemonize()
        DAEMONIZED = True
    try:
        log(f"swap job started pid={os.getpid()}")
        code = execute()
        log(f"swap job finished code={code}")
    except Exception:
        log("swap job crashed\n" + traceback.format_exc())
        set_quit_confirmation(False)
        if not app_pids() and os.path.isdir(APP):
            launch(APP)
        code = 9
    sys.exit(code)
