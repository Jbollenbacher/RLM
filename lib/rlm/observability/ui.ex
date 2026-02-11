defmodule RLM.Observability.UI do
  @moduledoc false

  def html do
    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <title>RLM Observability</title>
        <style>
          :root {
            --bg: #0b0d12;
            --panel: #151824;
            --text: #e9eef8;
            --muted: #9aa3b2;
            --accent: #6bdcff;
            --border: #263044;
            --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
          }
          body {
            margin: 0;
            background: radial-gradient(circle at 20% 20%, #1a2030 0%, #0b0d12 50%, #07080c 100%);
            color: var(--text);
            font-family: system-ui, -apple-system, Segoe UI, sans-serif;
          }
          header {
            padding: 16px 20px;
            border-bottom: 1px solid var(--border);
            display: flex;
            align-items: center;
            gap: 12px;
          }
          header .dot {
            width: 8px;
            height: 8px;
            background: var(--accent);
            border-radius: 999px;
            box-shadow: 0 0 12px rgba(107, 220, 255, 0.9);
          }
          main {
            display: grid;
            grid-template-columns: 260px 1fr 320px;
            gap: 16px;
            padding: 16px;
            height: calc(100vh - 58px);
            box-sizing: border-box;
          }
          .panel {
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 12px;
            display: flex;
            flex-direction: column;
            min-height: 0;
          }
          .panel h2 {
            margin: 0 0 8px 0;
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.12em;
            color: var(--muted);
          }
          .panel-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 8px;
          }
          .toggle {
            font-size: 12px;
            color: var(--muted);
            display: inline-flex;
            align-items: center;
            gap: 6px;
            user-select: none;
          }
          .toggle input {
            accent-color: var(--accent);
          }
          #agents {
            overflow: auto;
            font-size: 13px;
          }
          .agent {
            padding: 6px 8px;
            border-radius: 8px;
            cursor: pointer;
            border: 1px solid transparent;
            display: flex;
            align-items: center;
            gap: 6px;
          }
          .agent.active {
            border-color: var(--accent);
            background: rgba(107, 220, 255, 0.08);
          }
          .agent-toggle {
            width: 16px;
            height: 16px;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            border: 0;
            border-radius: 4px;
            background: transparent;
            color: var(--muted);
            cursor: pointer;
            font-size: 12px;
            line-height: 1;
          }
          .agent-toggle:hover {
            background: rgba(107, 220, 255, 0.12);
            color: var(--text);
          }
          .agent-toggle.placeholder {
            cursor: default;
            color: rgba(154, 163, 178, 0.4);
          }
          .agent-label {
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          #context {
            flex: 1;
            background: #0b0f18;
            border-radius: 8px;
            border: 1px solid var(--border);
            padding: 12px;
            font-family: var(--mono);
            font-size: 12px;
            white-space: pre-wrap;
            overflow: auto;
          }
          #events {
            flex: 1;
            overflow: auto;
            font-family: var(--mono);
            font-size: 11px;
          }
          .event {
            padding: 6px 0;
            border-bottom: 1px dashed rgba(38, 48, 68, 0.6);
          }
          .muted {
            color: var(--muted);
          }
          @media (max-width: 980px) {
            main {
              grid-template-columns: 1fr;
              height: auto;
            }
          }
        </style>
      </head>
      <body>
        <header>
          <div class="dot"></div>
          <strong>RLM Observability</strong>
        </header>
        <main>
          <section class="panel">
            <h2>Agents</h2>
            <div id="agents"></div>
          </section>
          <section class="panel">
            <div class="panel-header">
              <h2>Context Window</h2>
              <label class="toggle">
                <input type="checkbox" id="toggle-system" />
                Show system prompt
              </label>
            </div>
            <div id="context" class="muted">Select an agent to view context.</div>
          </section>
          <section class="panel">
            <h2>Event Feed</h2>
            <div id="events"></div>
          </section>
        </main>
        <script>
          const state = {
            agents: [],
            selectedAgent: null,
            lastEventTs: 0,
            lastEventId: 0,
            lastSnapshotId: 0,
            showSystem: false,
            expandedAgents: new Set()
          };

          async function fetchJSON(url) {
            const res = await fetch(url);
            return res.json();
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

          function renderAgentNode(node, depth) {
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
            label.textContent = `${node.id} (${node.status || "unknown"})`;

            div.appendChild(toggle);
            div.appendChild(label);
            div.onclick = () => {
              state.selectedAgent = node.id;
              state.lastEventTs = 0;
              state.lastEventId = 0;
              state.lastSnapshotId = 0;
              document.getElementById("events").innerHTML = "";
              loadContext(true);
              renderAgents();
            };

            container.appendChild(div);

            if (hasChildren && isExpanded) {
              node.children.forEach(child => renderAgentNode(child, depth + 1));
            }
          }

          function renderAgents() {
            const container = document.getElementById("agents");
            container.innerHTML = "";
            const roots = buildAgentTree(state.agents);
            roots.forEach(root => renderAgentNode(root, 0));
          }

          async function loadAgents() {
            const data = await fetchJSON("/api/agents");
            const nextAgents = data.agents || [];
            ensureExpandedForNewAgents(nextAgents);
            state.agents = nextAgents;
            if (!state.selectedAgent && state.agents.length > 0) {
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
              agent_id: state.selectedAgent
            });
            const data = await fetchJSON(`/api/events?${params.toString()}`);
            const events = data.events || [];
            const eventsEl = document.getElementById("events");
            const nearBottom = eventsEl.scrollTop + eventsEl.clientHeight + 40 >= eventsEl.scrollHeight;
            events.forEach(evt => {
              const line = document.createElement("div");
              line.className = "event";
              const detail = evt.payload && evt.payload.duration_ms ? ` (${evt.payload.duration_ms}ms)` : "";
              line.textContent = `[${new Date(evt.ts).toLocaleTimeString()}] ${evt.type}${detail}`;
              eventsEl.appendChild(line);
            });
            if (events.length > 0) {
              const last = events[events.length - 1];
              state.lastEventTs = last.ts || state.lastEventTs;
              state.lastEventId = last.id || state.lastEventId;
              if (nearBottom) {
                eventsEl.scrollTop = eventsEl.scrollHeight;
              }
            }
          }

          async function loop() {
            await loadAgents();
            await loadContext(false);
            await pollEvents();
            setTimeout(loop, 1000);
          }

          const systemToggle = document.getElementById("toggle-system");
          if (systemToggle) {
            systemToggle.addEventListener("change", () => {
              state.showSystem = systemToggle.checked;
              state.lastSnapshotId = 0;
              loadContext(true);
            });
          }

          loadAgents().then(() => {
            loadContext(true);
            loop();
          });
        </script>
      </body>
    </html>
    """
  end
end
