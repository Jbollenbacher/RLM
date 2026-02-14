const statusTimers = {};

function setTransientStatus(elementId, message, isError = false) {
  const el = document.getElementById(elementId);
  if (!el) return;

  el.textContent = message;
  el.className = isError ? "error" : "";

  if (statusTimers[elementId]) {
    clearTimeout(statusTimers[elementId]);
  }

  statusTimers[elementId] = setTimeout(() => {
    el.textContent = "";
    el.className = "";
    statusTimers[elementId] = null;
  }, 1500);
}

async function copyContextToClipboard() {
  const contextEl = document.getElementById("context");
  const text = (contextEl && contextEl.textContent ? contextEl.textContent : "").trim();

  if (!text || text === "Select an agent to view context." || text === "No context yet.") {
    setTransientStatus("context-copy-status", "Nothing to copy", true);
    return;
  }

  try {
    await navigator.clipboard.writeText(text);
    setTransientStatus("context-copy-status", "Copied");
  } catch (_error) {
    setTransientStatus("context-copy-status", "Copy failed", true);
  }
}

function exportFilenameFromHeader(headerValue) {
  if (!headerValue) return null;
  const match = headerValue.match(/filename=\"([^\"]+)\"/i);
  return match ? match[1] : null;
}

async function downloadFullLogs() {
  const includeSystem = state.showSystem ? "1" : "0";
  const debug = state.debugLogs ? "1" : "0";

  try {
    const response = await fetch(
      `/api/export/full_logs?include_system=${includeSystem}&debug=${debug}`
    );

    if (!response.ok) {
      throw new Error(`Export failed (${response.status})`);
    }

    const blob = await response.blob();
    const header = response.headers.get("content-disposition");
    const filename =
      exportFilenameFromHeader(header) ||
      `rlm_agent_logs_${new Date().toISOString().replace(/[:]/g, "-")}.json`;

    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);

    setTransientStatus("context-export-status", "Downloaded");
  } catch (error) {
    setTransientStatus("context-export-status", error.message || "Export failed", true);
  }
}

function setPreviewButtonLabel() {
  const previewLogsButton = document.getElementById("preview-logs");
  if (!previewLogsButton) return;
  previewLogsButton.textContent = state.fullLogsVisible ? "Refresh Logs" : "Show Full Agent Logs";
}

function setFullLogsPreviewVisible(visible) {
  const contextEl = document.getElementById("context");
  const previewEl = document.getElementById("full-logs-preview");

  state.fullLogsVisible = visible;

  if (contextEl) {
    contextEl.hidden = visible;
  }

  if (previewEl) {
    previewEl.hidden = !visible;
  }

  setPreviewButtonLabel();
}

function exitFullLogsPreview() {
  if (!state.fullLogsVisible) return;
  setFullLogsPreviewVisible(false);
}

async function loadFullLogsPreview() {
  const includeSystem = state.showSystem ? "1" : "0";
  const debug = state.debugLogs ? "1" : "0";
  const previewEl = document.getElementById("full-logs-preview");

  if (!previewEl) return;

  try {
    const response = await fetch(
      `/api/export/full_logs?include_system=${includeSystem}&debug=${debug}`
    );

    if (!response.ok) {
      throw new Error(`Preview failed (${response.status})`);
    }

    const text = await response.text();
    previewEl.textContent = text;
    previewEl.classList.remove("muted");
    setFullLogsPreviewVisible(true);
    setTransientStatus("context-preview-status", "Loaded");
  } catch (error) {
    setTransientStatus("context-preview-status", error.message || "Preview failed", true);
  }
}

