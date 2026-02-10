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
          #agents {
            overflow: auto;
            font-size: 13px;
          }
          .agent {
            padding: 8px 10px;
            border-radius: 8px;
            cursor: pointer;
            border: 1px solid transparent;
          }
          .agent.active {
            border-color: var(--accent);
            background: rgba(107, 220, 255, 0.08);
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
            <h2>Context Window</h2>
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
            autoScroll: true
          };

          async function fetchJSON(url) {
            const res = await fetch(url);
            return res.json();
          }

          function renderAgents() {
            const container = document.getElementById("agents");
            container.innerHTML = "";
            state.agents.forEach(agent => {
              const div = document.createElement("div");
              div.className = "agent" + (state.selectedAgent === agent.id ? " active" : "");
              div.textContent = `${agent.id} (${agent.status || "unknown"})`;
              div.onclick = () => {
                state.selectedAgent = agent.id;
                state.lastEventTs = 0;
                state.lastEventId = 0;
                document.getElementById("events").innerHTML = "";
                loadContext(true);
                renderAgents();
              };
              container.appendChild(div);
            });
          }

          async function loadAgents() {
            const data = await fetchJSON("/api/agents");
            state.agents = data.agents || [];
            if (!state.selectedAgent && state.agents.length > 0) {
              state.selectedAgent = state.agents[state.agents.length - 1].id;
            }
            renderAgents();
          }

          async function loadContext(forceScroll) {
            if (!state.selectedAgent) return;
            const data = await fetchJSON(`/api/agents/${state.selectedAgent}/context`);
            const snapshot = data.snapshot;
            const contextEl = document.getElementById("context");
            if (!snapshot) {
              contextEl.textContent = "No context yet.";
              return;
            }
            const nearBottom = contextEl.scrollTop + contextEl.clientHeight + 40 >= contextEl.scrollHeight;
            contextEl.textContent = snapshot.transcript || snapshot.preview || "";
            if (forceScroll || nearBottom || state.autoScroll) {
              contextEl.scrollTop = contextEl.scrollHeight;
            }
          }

          async function pollEvents() {
            if (!state.selectedAgent) return;
            const data = await fetchJSON(`/api/events?since=${state.lastEventTs}&since_id=${state.lastEventId}&agent_id=${state.selectedAgent}`);
            const events = data.events || [];
            const eventsEl = document.getElementById("events");
            events.forEach(evt => {
              const line = document.createElement("div");
              line.className = "event";
              const detail = evt.payload && evt.payload.duration_ms ? ` (${evt.payload.duration_ms}ms)` : "";
              line.textContent = `[${new Date(evt.ts).toLocaleTimeString()}] ${evt.type}${detail}`;
              eventsEl.appendChild(line);
              if (evt.ts > state.lastEventTs) {
                state.lastEventTs = evt.ts;
                state.lastEventId = evt.id || 0;
              } else if (evt.ts === state.lastEventTs) {
                state.lastEventId = Math.max(state.lastEventId, evt.id || 0);
              }
            });
            if (events.length > 0) {
              eventsEl.scrollTop = eventsEl.scrollHeight;
            }
          }

          async function loop() {
            await loadAgents();
            await loadContext(false);
            await pollEvents();
            setTimeout(loop, 1000);
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
