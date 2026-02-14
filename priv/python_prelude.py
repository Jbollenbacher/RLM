import json
import re
import sys
import time
from pathlib import Path

def _rlm_to_text(value):
    if isinstance(value, (bytes, bytearray)):
        return value.decode("utf-8", errors="replace")
    return value

def _rlm_truthy(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return bool(value)

class _RLMHelperError(RuntimeError):
    pass

def _rlm_unwrap(result, name):
    if isinstance(result, tuple) and len(result) == 2:
        status, payload = result
        if status == "ok":
            return payload
        if status == "error":
            raise _RLMHelperError(f"{name} failed: {payload}")
    return result

for _name in ("context", "workspace_root", "compacted_history", "last_stdout", "last_stderr", "_rlm_bridge_dir"):
    if _name in globals():
        globals()[_name] = _rlm_to_text(globals()[_name])

_rlm_stdout_buffer = []
_rlm_stderr_buffer = []

class _RLMBufferIO:
    def __init__(self, target):
        self._target = target

    def write(self, value):
        text = _rlm_to_text(value)
        text = "" if text is None else (text if isinstance(text, str) else str(text))
        self._target.append(text)
        return len(text)

    def flush(self):
        return None

    def isatty(self):
        return False

_rlm_stdout = _RLMBufferIO(_rlm_stdout_buffer)
_rlm_stderr = _RLMBufferIO(_rlm_stderr_buffer)
sys.stdout = _rlm_stdout
sys.stderr = _rlm_stderr

def print(*values, sep=" ", end="\n", file=None, flush=False):
    target = _rlm_stderr if file is sys.stderr else _rlm_stdout
    text = sep.join(str(v) for v in values) + end
    target.write(text)
    if flush:
        target.flush()
    return None

def grep(pattern, string):
    text = _rlm_to_text(string)
    text = text if isinstance(text, str) else str(text)
    lines = text.split("\n")
    out = []

    if hasattr(pattern, "search"):
        for idx, line in enumerate(lines, 1):
            if pattern.search(line):
                out.append((idx, line))
        return out

    needle = str(pattern)
    for idx, line in enumerate(lines, 1):
        if needle in line:
            out.append((idx, line))
    return out

def latest_principal_message_status(context):
    if not isinstance(context, str):
        return ("error", "No chat entries found in context")
    pattern = re.compile(r"^\[RLM_Principal\]\n(.*?)(?=^\[RLM_(?:Principal|Agent)\]|\Z)", re.M | re.S)
    matches = pattern.findall(context)
    if not matches:
        return ("error", "No chat entries found in context")
    return ("ok", matches[-1].strip())

def latest_principal_message(context):
    return _rlm_unwrap(latest_principal_message_status(context), "latest_principal_message")

def _rlm_workspace_root():
    root = _rlm_to_text(globals().get("workspace_root"))
    if not root:
        raise ValueError("workspace_root not set")
    return Path(root).resolve()

def _rlm_resolve_workspace_path(path):
    root = _rlm_workspace_root()
    rel = "." if path is None else str(_rlm_to_text(path))
    target = (root / rel).resolve()
    if target != root and root not in target.parents:
        raise ValueError("Path is outside workspace root")
    return root, target

def ls_status(path="."):
    try:
        _root, target = _rlm_resolve_workspace_path(path)
        if not target.exists() or not target.is_dir():
            return ("error", "Not a directory")
        entries = []
        for child in sorted(target.iterdir(), key=lambda p: p.name):
            entries.append(child.name + "/" if child.is_dir() else child.name)
        return ("ok", entries)
    except Exception as exc:
        return ("error", str(exc))

def ls(path="."):
    return _rlm_unwrap(ls_status(path), "ls")

def read_file_status(path, max_bytes=None):
    try:
        _root, target = _rlm_resolve_workspace_path(path)
        if not target.exists() or not target.is_file():
            return ("error", "Not a file")

        if max_bytes is None:
            return ("ok", target.read_text(encoding="utf-8", errors="replace"))

        n = int(max_bytes)
        if n <= 0:
            return ("error", "max_bytes must be a positive integer or nil")
        with target.open("rb") as f:
            data = f.read(n)
        return ("ok", data.decode("utf-8", errors="replace"))
    except Exception as exc:
        return ("error", str(exc))

def read_file(path, max_bytes=None):
    return _rlm_unwrap(read_file_status(path, max_bytes=max_bytes), "read_file")

def _rlm_normalize_patch(patch):
    trimmed = patch.strip("\n")
    lines = trimmed.split("\n")
    non_empty = [line for line in lines if line != ""]
    if not non_empty:
        return ""

    min_indent = min(len(line) - len(line.lstrip(" \t")) for line in non_empty)
    if min_indent <= 0:
        return trimmed

    adjusted = []
    for line in lines:
        adjusted.append("" if line == "" else line[min_indent:])
    return "\n".join(adjusted)

def edit_file_status(path, patch):
    try:
        if globals().get("workspace_read_only", False):
            return ("error", "Workspace is read-only")

        _root, target = _rlm_resolve_workspace_path(path)
        if not target.exists() or not target.is_file():
            return ("error", "Not a file")

        patch_text = _rlm_normalize_patch(patch)
        regex = re.compile(r"<<<<<<< SEARCH\r?\n(.*?)\r?\n=======\r?\n(.*?)\r?\n>>>>>>> REPLACE", re.S)
        blocks = regex.findall(patch_text)
        if not blocks:
            return ("error", "No edit blocks found. Use <<<<<<< SEARCH ... ======= ... >>>>>>> REPLACE blocks.")

        if regex.sub("", patch_text).strip() != "":
            return ("error", "Patch contains text outside of edit blocks")

        for search, _replace in blocks:
            if search == "":
                return ("error", "Search blocks cannot be empty")

        content = target.read_text(encoding="utf-8", errors="replace")

        for search, replace in blocks:
            count = content.count(search)
            if count == 0:
                return ("error", "Search text not found in file")
            if count > 1:
                return ("error", "Search text matched multiple occurrences. Add more surrounding context to make it unique.")
            content = content.replace(search, replace, 1)

        target.write_text(content, encoding="utf-8")
        return ("ok", f"Applied {len(blocks)} edit(s) to {path}")
    except Exception as exc:
        return ("error", str(exc))

def edit_file(path, patch):
    return _rlm_unwrap(edit_file_status(path, patch), "edit_file")

def create_file_status(path, content):
    try:
        if globals().get("workspace_read_only", False):
            return ("error", "Workspace is read-only")

        rel = str(_rlm_to_text(path))
        if rel.strip() == "":
            return ("error", "Path must be a non-empty file path")
        if rel.endswith("/"):
            return ("error", "Path must be a file, not a directory")

        _root, target = _rlm_resolve_workspace_path(rel)
        if target.exists() and target.is_dir():
            return ("error", "Path is a directory")

        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("x", encoding="utf-8") as f:
            f.write(content)
        return ("ok", f"Created {path}")
    except FileExistsError:
        return ("error", "File already exists")
    except Exception as exc:
        return ("error", str(exc))

def create_file(path, content):
    return _rlm_unwrap(create_file_status(path, content), "create_file")

def ok(payload):
    return {"status": "ok", "payload": payload}

def fail(reason):
    return {"status": "error", "payload": reason}

def list_bindings():
    excluded = {
        "__builtins__", "json", "re", "sys", "time", "Path",
        "grep",
        "latest_principal_message", "latest_principal_message_status",
        "ls", "ls_status",
        "read_file", "read_file_status",
        "edit_file", "edit_file_status",
        "create_file", "create_file_status",
        "ok", "fail",
        "list_bindings",
        "lm_query", "poll_lm_query", "await_lm_query", "cancel_lm_query", "assess_lm_query",
        "assess_dispatch",
        "print"
    }
    out = []
    for name, value in globals().items():
        if name in excluded or name.startswith("_rlm_") or name.startswith("__"):
            continue
        try:
            if isinstance(value, str):
                size = len(value.encode("utf-8"))
            else:
                size = len(repr(value).encode("utf-8"))
        except Exception:
            size = 0
        out.append((name, type(value).__name__, size))
    out.sort(key=lambda item: item[0])
    return out

def _rlm_write_json_atomic(path, payload):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload), encoding="utf-8")
    tmp.replace(path)

class _RLMSubagentCrash(RuntimeError):
    pass

def _rlm_bridge_request(payload, timeout_ms=None):
    bridge_dir = _rlm_to_text(globals().get("_rlm_bridge_dir"))
    if not bridge_dir:
        return {"status": "error", "payload": "lm_query not available"}

    requests_dir = Path(bridge_dir) / "requests"
    responses_dir = Path(bridge_dir) / "responses"
    request_id = f"{int(time.time() * 1000)}_{time.perf_counter_ns()}"
    request_path = requests_dir / f"{request_id}.json"
    response_path = responses_dir / f"{request_id}.json"
    if timeout_ms is None:
        timeout_ms = int(globals().get("_rlm_bridge_timeout_ms", 180000))
    else:
        timeout_ms = int(timeout_ms)

    try:
        normalized_payload = {}
        for key, value in dict(payload).items():
            normalized_payload[key] = _rlm_to_text(value)

        _rlm_write_json_atomic(request_path, normalized_payload)

        deadline = time.time() + (timeout_ms / 1000.0)
        while time.time() < deadline:
            if response_path.exists():
                data = json.loads(response_path.read_text(encoding="utf-8"))
                try:
                    response_path.unlink()
                except Exception:
                    pass
                return data
            time.sleep(0.01)
    except Exception as exc:
        return {"status": "error", "payload": str(exc)}

    return {"status": "error", "payload": f"Bridge request timed out after {timeout_ms}ms"}

def lm_query(text, model_size="small"):
    subagent_timeout_ms = int(globals().get("_rlm_bridge_timeout_ms", 180000))

    response = _rlm_bridge_request(
        {
            "op": "dispatch",
            "text": _rlm_to_text(text),
            "model_size": _rlm_to_text(model_size),
            "timeout_ms": subagent_timeout_ms
        }
    )

    return _rlm_unwrap((response.get("status", "error"), response.get("payload")), "lm_query")

def poll_lm_query(child_agent_id):
    response = _rlm_bridge_request(
        {
            "op": "poll",
            "child_agent_id": _rlm_to_text(child_agent_id)
        }
    )

    return _rlm_unwrap((response.get("status", "error"), response.get("payload")), "poll_lm_query")

def await_lm_query(child_agent_id, timeout_ms=None, poll_interval_ms=50):
    if timeout_ms is not None:
        timeout_ms = int(timeout_ms)
        if timeout_ms <= 0:
            raise _RLMHelperError("await_lm_query timeout_ms must be positive or None")
        deadline = time.time() + (timeout_ms / 1000.0)
    else:
        deadline = None

    poll_interval = int(poll_interval_ms)
    if poll_interval <= 0:
        poll_interval = 50

    child_agent_id = _rlm_to_text(child_agent_id)

    while True:
        state = poll_lm_query(child_agent_id)
        kind = str(state.get("state", "error")).lower()

        if kind == "running":
            if deadline is not None and time.time() >= deadline:
                raise _RLMHelperError(
                    f"await_lm_query timed out after {timeout_ms}ms for {child_agent_id}"
                )
            time.sleep(poll_interval / 1000.0)
            continue

        if kind == "ok":
            if state.get("assessment_required") and not state.get("assessment_recorded"):
                _rlm_stderr.write(
                    f"[RLM] assessment required for {child_agent_id}: "
                    "call assess_lm_query(child_agent_id, verdict, reason='...') "
                    "with verdict='satisfied' or 'dissatisfied'.\n"
                )
            return state.get("payload")

        if kind == "error":
            if state.get("assessment_required") and not state.get("assessment_recorded"):
                _rlm_stderr.write(
                    f"[RLM] assessment required for {child_agent_id}: "
                    "call assess_lm_query(child_agent_id, verdict, reason='...') "
                    "with verdict='satisfied' or 'dissatisfied'.\n"
                )
            raise _RLMSubagentCrash(str(state.get("payload", "Subagent failed")))

        if kind == "cancelled":
            if state.get("assessment_required") and not state.get("assessment_recorded"):
                _rlm_stderr.write(
                    f"[RLM] assessment required for {child_agent_id}: "
                    "call assess_lm_query(child_agent_id, verdict, reason='...') "
                    "with verdict='satisfied' or 'dissatisfied'.\n"
                )
            raise _RLMSubagentCrash(str(state.get("payload", "Subagent cancelled")))

        raise _RLMHelperError(f"Unknown lm_query state for {child_agent_id}: {state}")

def cancel_lm_query(child_agent_id):
    response = _rlm_bridge_request(
        {
            "op": "cancel",
            "child_agent_id": _rlm_to_text(child_agent_id)
        }
    )

    return _rlm_unwrap((response.get("status", "error"), response.get("payload")), "cancel_lm_query")

def assess_lm_query(child_agent_id, verdict, reason=""):
    verdict_text = str(_rlm_to_text(verdict)).strip().lower()
    if verdict_text not in ("satisfied", "dissatisfied"):
        raise _RLMHelperError(
            "assess_lm_query verdict must be 'satisfied' or 'dissatisfied'"
        )

    response = _rlm_bridge_request(
        {
            "op": "assess",
            "child_agent_id": _rlm_to_text(child_agent_id),
            "verdict": verdict_text,
            "reason": _rlm_to_text(reason)
        }
    )

    return _rlm_unwrap(
        (response.get("status", "error"), response.get("payload")),
        "assess_lm_query"
    )

def assess_dispatch(verdict, reason=""):
    parent_agent_id = _rlm_to_text(globals().get("parent_agent_id"))
    if not parent_agent_id:
        raise _RLMHelperError(
            "assess_dispatch is only available for subagents with a parent agent"
        )

    required = _rlm_truthy(globals().get("dispatch_assessment_required", False))
    if not required:
        return {
            "status": "ignored",
            "reason": "dispatch assessment not requested for this subagent"
        }

    verdict_text = str(_rlm_to_text(verdict)).strip().lower()
    if verdict_text not in ("satisfied", "dissatisfied"):
        raise _RLMHelperError(
            "assess_dispatch verdict must be 'satisfied' or 'dissatisfied'"
        )

    assessment = {
        "verdict": verdict_text,
        "reason": _rlm_to_text(reason)
    }
    globals()["_rlm_dispatch_assessment"] = assessment
    return assessment
