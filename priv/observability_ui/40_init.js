const systemToggle = document.getElementById("toggle-system");
if (systemToggle) {
  systemToggle.addEventListener("change", () => {
    state.showSystem = systemToggle.checked;
    state.lastSnapshotId = 0;
    loadContext(true);
  });
}

const debugLogsToggle = document.getElementById("toggle-debug-logs");
if (debugLogsToggle) {
  debugLogsToggle.addEventListener("change", () => {
    state.debugLogs = debugLogsToggle.checked;
    resetEventsView();
    pollEvents();
  });
}

const copyContextButton = document.getElementById("copy-context");
if (copyContextButton) {
  copyContextButton.addEventListener("click", () => {
    copyContextToClipboard();
  });
}

const previewLogsButton = document.getElementById("preview-logs");
if (previewLogsButton) {
  setPreviewButtonLabel();
  previewLogsButton.addEventListener("click", () => {
    loadFullLogsPreview();
  });
}

const exportLogsButton = document.getElementById("export-logs");
if (exportLogsButton) {
  exportLogsButton.addEventListener("click", () => {
    downloadFullLogs();
  });
}

const chatForm = document.getElementById("chat-form");
if (chatForm) {
  chatForm.addEventListener("submit", async event => {
    event.preventDefault();

    if (state.chatBusy) return;

    const input = document.getElementById("chat-input");
    const message = input.value.trim();
    if (!message) return;

    setChatBusy(true);

    try {
      await sendChatMessage(message);
      input.value = "";
      await loadChat(true);
      await loadAgents();
      await loadContext(true);
      await pollEvents();
    } catch (error) {
      setChatStatus(error.message, true);
      setChatBusy(false);
    }
  });
}

const chatInput = document.getElementById("chat-input");
if (chatInput && chatForm) {
  chatInput.addEventListener("keydown", event => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      chatForm.requestSubmit();
    }
  });
}

const stopButton = document.getElementById("chat-stop");
if (stopButton) {
  stopButton.addEventListener("click", async () => {
    if (!state.chatBusy) return;

    try {
      await stopChatMessage();
      await loadChat(true);
      await loadContext(true);
      await pollEvents();
    } catch (error) {
      setChatStatus(error.message, true);
    }
  });
}

setupMainSplitter();
setupObsColumnSplitter();
setupObsStackSplitter();

Promise.all([loadChat(true), loadAgents()])
  .then(() => {
    loadContext(true);
    loop();
  })
  .catch(error => {
    setChatStatus(error.message, true);
  });
