function renderChat(messages, forceScroll) {
  const log = document.getElementById("chat-log");
  const nearBottom = log.scrollTop + log.clientHeight + 40 >= log.scrollHeight;
  log.classList.remove("muted");
  log.innerHTML = "";

  if (messages.length === 0) {
    log.textContent = "No messages yet. Start chatting below.";
    log.classList.add("muted");
    return;
  }

  messages.forEach(msg => {
    const block = document.createElement("div");
    block.className = `chat-msg ${msg.role || "assistant"}`;

    const role = document.createElement("div");
    role.className = "role";
    role.textContent = msg.role || "assistant";

    const content = document.createElement("div");
    content.textContent = msg.content || "";

    block.appendChild(role);
    block.appendChild(content);
    log.appendChild(block);
  });

  if (forceScroll || nearBottom) {
    log.scrollTop = log.scrollHeight;
  }
}

async function loadChat(forceScroll) {
  try {
    const data = await fetchJSON("/api/chat");
    state.chatSessionId = data.session_id || state.chatSessionId;

    if (!state.selectedAgent && state.chatSessionId) {
      state.selectedAgent = state.chatSessionId;
      state.expandedAgents.add(state.chatSessionId);
    }

    const messages = data.messages || [];
    const last = messages[messages.length - 1];
    const lastId = last ? last.id : 0;

    if (forceScroll || lastId !== state.chatLastMessageId) {
      renderChat(messages, forceScroll);
    }

    state.chatLastMessageId = lastId;
    setChatBusy(Boolean(data.busy));
  } catch (error) {
    setChatStatus(error.message, true);
  }
}

function setChatBusy(busy) {
  state.chatBusy = busy;
  const input = document.getElementById("chat-input");
  const sendButton = document.getElementById("chat-send");
  const stopButton = document.getElementById("chat-stop");
  input.disabled = busy;
  sendButton.disabled = busy;
  stopButton.disabled = !busy;
  setChatStatus(busy ? "Running..." : "Ready");
}

async function sendChatMessage(message) {
  await fetchJSON("/api/chat", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message })
  });
}

async function stopChatMessage() {
  await fetchJSON("/api/chat/stop", {
    method: "POST",
    headers: { "content-type": "application/json" }
  });
}

async function loop() {
  await loadAgents();
  await loadContext(false);
  await pollEvents();
  await loadChat(false);
  setTimeout(loop, 1000);
}

