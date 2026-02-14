function setChatStatus(message, isError = false) {
  const el = document.getElementById("chat-status");
  el.textContent = message;
  el.className = isError ? "error" : "";
}

function buildAgentTree(agents) {
  const nodesById = new Map();
  const roots = [];

  agents.forEach(agent => {
    nodesById.set(agent.id, { ...agent, children: [] });
  });

  agents.forEach(agent => {
    const node = nodesById.get(agent.id);
    if (agent.parent_id && nodesById.has(agent.parent_id)) {
      nodesById.get(agent.parent_id).children.push(node);
    } else {
      roots.push(node);
    }
  });

  return roots;
}

function displayAgentId(node, treePath) {
  return `${treePath} ${node.id}`;
}

function ensureExpandedForNewAgents(nextAgents) {
  const existing = new Set(state.agents.map(agent => agent.id));

  nextAgents.forEach(agent => {
    if (!existing.has(agent.id)) {
      if (agent.parent_id) {
        state.expandedAgents.add(agent.parent_id);
      } else {
        state.expandedAgents.add(agent.id);
      }
    }
  });
}

function renderAgentNode(node, depth, treePath) {
  const container = document.getElementById("agents");
  const div = document.createElement("div");
  div.className = "agent" + (state.selectedAgent === node.id ? " active" : "");
  div.style.paddingLeft = `${8 + depth * 14}px`;

  const hasChildren = node.children && node.children.length > 0;
  const isExpanded = state.expandedAgents.has(node.id);
  const toggle = document.createElement("button");
  toggle.className = "agent-toggle" + (hasChildren ? "" : " placeholder");
  toggle.textContent = hasChildren ? (isExpanded ? "▾" : "▸") : "•";
  toggle.disabled = !hasChildren;
  toggle.onclick = event => {
    event.stopPropagation();
    if (!hasChildren) return;
    if (isExpanded) {
      state.expandedAgents.delete(node.id);
    } else {
      state.expandedAgents.add(node.id);
    }
    renderAgents();
  };

  const label = document.createElement("span");
  label.className = "agent-label";
  label.textContent = `${displayAgentId(node, treePath)} (${node.status || "unknown"})`;

  div.appendChild(toggle);
  div.appendChild(label);
  div.onclick = () => {
    exitFullLogsPreview();
    state.selectedAgent = node.id;
    state.lastSnapshotId = 0;
    resetEventsView();
    loadContext(true);
    renderAgents();
  };

  container.appendChild(div);

  if (hasChildren && isExpanded) {
    node.children.forEach((child, index) => {
      renderAgentNode(child, depth + 1, `${treePath}.${index + 1}`);
    });
  }
}

function renderAgents() {
  const container = document.getElementById("agents");
  container.innerHTML = "";
  const roots = buildAgentTree(state.agents);
  roots.forEach((root, index) => renderAgentNode(root, 0, String(index + 1)));
}

function indentLines(text, prefix = "  ") {
  return String(text || "")
    .split("\n")
    .map(line => `${prefix}${line}`)
    .join("\n");
}

function formatRequestTail(payload) {
  const tail = payload.request_tail;
  if (!Array.isArray(tail) || tail.length === 0) {
    return "  (not captured)";
  }

  return tail
    .map((entry, index) => {
      const role = entry.role || "unknown";
      const chars = Number.isFinite(entry.chars) ? entry.chars : "?";
      const preview = entry.preview || "";
      return `${index + 1}. [${role}] (${chars} chars)\n${indentLines(preview, "   ")}`;
    })
    .join("\n\n");
}

function formatEventDetails(event) {
  const payload = event.payload || {};
  const eventType = event.type || "unknown";
  const tsNum = Number(event.ts);
  const isoTime = Number.isFinite(tsNum) ? new Date(tsNum).toISOString() : "unknown";
  const lines = [];

  lines.push(`Event: ${eventType}`);
  lines.push(`Agent: ${event.agent_id || "unknown"}`);
  lines.push(`Time: ${isoTime}`);
  if (event.id != null) {
    lines.push(`ID: ${event.id}`);
  }

  if (eventType === "eval") {
    lines.push("");
    lines.push("Evaluation");
    if (payload.iteration != null) lines.push(`iteration: ${payload.iteration}`);
    if (payload.status != null) lines.push(`status: ${payload.status}`);
    if (payload.duration_ms != null) lines.push(`duration_ms: ${payload.duration_ms}`);
    if (payload.code_bytes != null) lines.push(`code_bytes: ${payload.code_bytes}`);

    if (payload.code_preview) {
      lines.push("code_preview:");
      lines.push(indentLines(payload.code_preview));
    }
  } else if (eventType === "lm_query") {
    lines.push("");
    lines.push("Subagent Dispatch");
    if (payload.child_agent_id) lines.push(`child_agent_id: ${payload.child_agent_id}`);
    if (payload.model_size != null) lines.push(`model_size: ${payload.model_size}`);
    if (payload.assessment_sampled != null) {
      lines.push(`assessment_sampled: ${payload.assessment_sampled}`);
    }
    if (payload.text_bytes != null) lines.push(`text_bytes: ${payload.text_bytes}`);
    if (payload.text_chars != null) lines.push(`text_chars: ${payload.text_chars}`);

    if (payload.query_preview) {
      lines.push("query_preview:");
      lines.push(indentLines(payload.query_preview));
    }
  } else if (eventType === "llm") {
    lines.push("");
    lines.push("Raw LLM Dispatch");
    if (payload.iteration != null) lines.push(`iteration: ${payload.iteration}`);
    if (payload.model != null) lines.push(`model: ${payload.model}`);
    if (payload.status != null) lines.push(`status: ${payload.status}`);
    if (payload.duration_ms != null) lines.push(`duration_ms: ${payload.duration_ms}`);
    if (payload.message_count != null) lines.push(`message_count: ${payload.message_count}`);
    if (payload.context_chars != null) lines.push(`context_chars: ${payload.context_chars}`);
    lines.push("request_tail (delta context):");
    lines.push(indentLines(formatRequestTail(payload), "  "));
  } else if (eventType === "survey_requested") {
    lines.push("");
    lines.push("Survey Requested");
    if (payload.survey_id != null) lines.push(`survey_id: ${payload.survey_id}`);
    if (payload.child_agent_id != null) lines.push(`child_agent_id: ${payload.child_agent_id}`);
    if (payload.scope != null) lines.push(`scope: ${payload.scope}`);
    if (payload.required != null) lines.push(`required: ${payload.required}`);
    if (payload.question != null) lines.push(`question: ${payload.question}`);
  } else if (eventType === "survey_answered") {
    lines.push("");
    lines.push("Survey Answered");
    if (payload.survey_id != null) lines.push(`survey_id: ${payload.survey_id}`);
    if (payload.child_agent_id != null) lines.push(`child_agent_id: ${payload.child_agent_id}`);
    if (payload.scope != null) lines.push(`scope: ${payload.scope}`);
    if (payload.response != null) lines.push(`response: ${payload.response}`);
    if (payload.reason != null) lines.push(`reason: ${payload.reason}`);
  } else if (eventType === "survey_missing") {
    lines.push("");
    lines.push("Survey Missing");
    if (payload.survey_id != null) lines.push(`survey_id: ${payload.survey_id}`);
    if (payload.child_agent_id != null) lines.push(`child_agent_id: ${payload.child_agent_id}`);
    if (payload.scope != null) lines.push(`scope: ${payload.scope}`);
    if (payload.status != null) lines.push(`status: ${payload.status}`);
  }

  lines.push("");
  lines.push("payload:");
  lines.push(JSON.stringify(payload, null, 2));

  return lines.join("\n");
}

function setEventDetails(event) {
  const detailsEl = document.getElementById("event-details");
  if (!detailsEl) return;

  if (!event) {
    detailsEl.textContent = "Click an event to inspect details.";
    detailsEl.classList.add("muted");
    return;
  }

  detailsEl.textContent = formatEventDetails(event);
  detailsEl.classList.remove("muted");
}

function selectEventByKey(eventKey) {
  const eventsEl = document.getElementById("events");
  if (!eventsEl) return;

  state.selectedEventKey = eventKey;

  eventsEl.querySelectorAll(".event.active").forEach(node => {
    node.classList.remove("active");
  });

  if (!eventKey) {
    setEventDetails(null);
    return;
  }

  const selectedNode = eventsEl.querySelector(`.event[data-event-key="${eventKey}"]`);
  if (selectedNode) {
    selectedNode.classList.add("active");
  }

  setEventDetails(state.eventMap.get(eventKey) || null);
}

function resetEventsView() {
  state.lastEventTs = 0;
  state.lastEventId = 0;
  state.selectedEventKey = null;
  state.eventMap = new Map();

  const eventsEl = document.getElementById("events");
  if (eventsEl) {
    eventsEl.innerHTML = "";
  }

  setEventDetails(null);
}

async function loadAgents() {
  const data = await fetchJSON("/api/agents");
  const nextAgents = data.agents || [];
  ensureExpandedForNewAgents(nextAgents);
  state.agents = nextAgents;

  if (!state.selectedAgent && state.chatSessionId) {
    state.selectedAgent = state.chatSessionId;
    state.expandedAgents.add(state.chatSessionId);
  } else if (!state.selectedAgent && state.agents.length > 0) {
    state.selectedAgent = state.agents[state.agents.length - 1].id;
    state.expandedAgents.add(state.selectedAgent);
  }

  renderAgents();
}

async function loadContext(forceScroll) {
  if (!state.selectedAgent) return;
  const includeSystem = state.showSystem ? "1" : "0";
  const data = await fetchJSON(
    `/api/agents/${state.selectedAgent}/context?include_system=${includeSystem}`
  );
  const snapshot = data.snapshot;
  const contextEl = document.getElementById("context");
  if (!snapshot) {
    contextEl.textContent = "No context yet.";
    return;
  }
  if (snapshot.id && snapshot.id === state.lastSnapshotId) {
    return;
  }
  const nearBottom = contextEl.scrollTop + contextEl.clientHeight + 40 >= contextEl.scrollHeight;
  contextEl.textContent = snapshot.transcript || snapshot.preview || "";
  state.lastSnapshotId = snapshot.id || state.lastSnapshotId;
  if (forceScroll || nearBottom) {
    contextEl.scrollTop = contextEl.scrollHeight;
  }
}

async function pollEvents() {
  if (!state.selectedAgent) return;
  const params = new URLSearchParams({
    since: String(state.lastEventTs),
    since_id: String(state.lastEventId),
    agent_id: state.selectedAgent,
    debug: state.debugLogs ? "1" : "0"
  });
  const data = await fetchJSON(`/api/events?${params.toString()}`);
  const events = data.events || [];
  const eventsEl = document.getElementById("events");
  const nearBottom = eventsEl.scrollTop + eventsEl.clientHeight + 40 >= eventsEl.scrollHeight;
  events.forEach(evt => {
    const eventKey = evt.id != null ? String(evt.id) : `${evt.ts}:${evt.type}`;
    state.eventMap.set(eventKey, evt);

    const line = document.createElement("div");
    line.className = "event";
    line.dataset.eventKey = eventKey;
    line.tabIndex = 0;
    const detail = evt.payload && evt.payload.duration_ms ? ` (${evt.payload.duration_ms}ms)` : "";
    line.textContent = `[${new Date(evt.ts).toLocaleTimeString()}] ${evt.type}${detail}`;
    line.addEventListener("click", () => {
      selectEventByKey(eventKey);
    });
    line.addEventListener("keydown", event => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        selectEventByKey(eventKey);
      }
    });
    eventsEl.appendChild(line);
  });

  if (state.selectedEventKey) {
    selectEventByKey(state.selectedEventKey);
  }

  if (events.length > 0) {
    const last = events[events.length - 1];
    state.lastEventTs = last.ts || state.lastEventTs;
    state.lastEventId = last.id || state.lastEventId;
    if (nearBottom) {
      eventsEl.scrollTop = eventsEl.scrollHeight;
    }
  }
}
