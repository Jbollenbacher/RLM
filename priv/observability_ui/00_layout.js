const state = {
  agents: [],
  selectedAgent: null,
  lastEventTs: 0,
  lastEventId: 0,
  lastSnapshotId: 0,
  showSystem: false,
  debugLogs: false,
  fullLogsVisible: false,
  expandedAgents: new Set(),
  chatSessionId: null,
  chatLastMessageId: 0,
  chatBusy: false,
  selectedEventKey: null,
  eventMap: new Map()
};

function isMobileLayout() {
  return window.matchMedia("(max-width: 980px)").matches;
}

function setupMainSplitter() {
  const main = document.querySelector("main");
  const splitter = document.getElementById("main-splitter");
  if (!main || !splitter) return;

  const MIN_CHAT = 320;
  const MIN_OBSERVABILITY = 420;
  const SPLITTER_WIDTH = 10;
  let dragging = false;
  let activePointerId = null;

  function clampChatWidth(nextWidth) {
    const rect = main.getBoundingClientRect();
    const maxChat = Math.max(MIN_CHAT, rect.width - SPLITTER_WIDTH - MIN_OBSERVABILITY);
    return Math.min(maxChat, Math.max(MIN_CHAT, nextWidth));
  }

  function applyChatWidth(nextWidth) {
    const clamped = clampChatWidth(nextWidth);
    main.style.setProperty("--chat-col", `${clamped}px`);
  }

  function stopDrag(event) {
    if (!dragging) return;
    dragging = false;
    document.body.classList.remove("resizing-col");

    if (
      event &&
        activePointerId != null &&
        splitter.hasPointerCapture &&
        splitter.hasPointerCapture(activePointerId)
    ) {
      splitter.releasePointerCapture(activePointerId);
    }

    activePointerId = null;
  }

  splitter.addEventListener("pointerdown", event => {
    if (isMobileLayout()) return;
    dragging = true;
    activePointerId = event.pointerId;
    document.body.classList.add("resizing-col");
    splitter.setPointerCapture(event.pointerId);
    const rect = main.getBoundingClientRect();
    applyChatWidth(event.clientX - rect.left);
    event.preventDefault();
  });

  splitter.addEventListener("pointermove", event => {
    if (!dragging || event.pointerId !== activePointerId) return;
    const rect = main.getBoundingClientRect();
    applyChatWidth(event.clientX - rect.left);
  });

  splitter.addEventListener("pointerup", stopDrag);
  splitter.addEventListener("pointercancel", stopDrag);
  window.addEventListener("pointerup", stopDrag);

  window.addEventListener("resize", () => {
    if (isMobileLayout()) {
      stopDrag();
      main.style.removeProperty("--chat-col");
      return;
    }

    const current = Number.parseFloat(getComputedStyle(main).getPropertyValue("--chat-col"));
    if (Number.isFinite(current)) {
      applyChatWidth(current);
    }
  });
}

function setupObsColumnSplitter() {
  const container = document.getElementById("observability-column");
  const splitter = document.getElementById("obs-column-splitter");
  if (!container || !splitter) return;

  const MIN_CONTEXT = 320;
  const MIN_SIDE = 220;
  const SPLITTER_WIDTH = 10;
  let dragging = false;
  let activePointerId = null;

  function applyFromPointer(clientX) {
    const rect = container.getBoundingClientRect();
    const desiredContext = clientX - rect.left;
    const maxContext = Math.max(MIN_CONTEXT, rect.width - SPLITTER_WIDTH - MIN_SIDE);
    const contextWidth = Math.min(maxContext, Math.max(MIN_CONTEXT, desiredContext));
    const sideWidth = rect.width - SPLITTER_WIDTH - contextWidth;
    container.style.setProperty("--obs-side-col", `${sideWidth}px`);
  }

  function clampSideWidth(sideWidth) {
    const rect = container.getBoundingClientRect();
    const maxSide = Math.max(MIN_SIDE, rect.width - SPLITTER_WIDTH - MIN_CONTEXT);
    return Math.min(maxSide, Math.max(MIN_SIDE, sideWidth));
  }

  function stopDrag(event) {
    if (!dragging) return;
    dragging = false;
    document.body.classList.remove("resizing-col");

    if (
      event &&
        activePointerId != null &&
        splitter.hasPointerCapture &&
        splitter.hasPointerCapture(activePointerId)
    ) {
      splitter.releasePointerCapture(activePointerId);
    }

    activePointerId = null;
  }

  splitter.addEventListener("pointerdown", event => {
    if (isMobileLayout()) return;
    dragging = true;
    activePointerId = event.pointerId;
    document.body.classList.add("resizing-col");
    splitter.setPointerCapture(event.pointerId);
    applyFromPointer(event.clientX);
    event.preventDefault();
  });

  splitter.addEventListener("pointermove", event => {
    if (!dragging || event.pointerId !== activePointerId) return;
    applyFromPointer(event.clientX);
  });

  splitter.addEventListener("pointerup", stopDrag);
  splitter.addEventListener("pointercancel", stopDrag);
  window.addEventListener("pointerup", stopDrag);

  window.addEventListener("resize", () => {
    if (isMobileLayout()) {
      stopDrag();
      container.style.removeProperty("--obs-side-col");
      return;
    }

    const current = Number.parseFloat(
      getComputedStyle(container).getPropertyValue("--obs-side-col")
    );

    if (Number.isFinite(current)) {
      container.style.setProperty("--obs-side-col", `${clampSideWidth(current)}px`);
    }
  });
}

function setupObsStackSplitter() {
  const container = document.getElementById("obs-side-stack");
  const splitter = document.getElementById("obs-stack-splitter");
  if (!container || !splitter) return;

  const MIN_AGENTS = 140;
  const MIN_EVENTS = 140;
  const SPLITTER_HEIGHT = 10;
  let dragging = false;
  let activePointerId = null;

  function applyFromPointer(clientY) {
    const rect = container.getBoundingClientRect();
    const desiredAgents = clientY - rect.top;
    const maxAgents = Math.max(MIN_AGENTS, rect.height - SPLITTER_HEIGHT - MIN_EVENTS);
    const agentsHeight = Math.min(maxAgents, Math.max(MIN_AGENTS, desiredAgents));
    container.style.setProperty("--obs-agents-row", `${agentsHeight}px`);
  }

  function clampAgentsHeight(height) {
    const rect = container.getBoundingClientRect();
    const maxAgents = Math.max(MIN_AGENTS, rect.height - SPLITTER_HEIGHT - MIN_EVENTS);
    return Math.min(maxAgents, Math.max(MIN_AGENTS, height));
  }

  function stopDrag(event) {
    if (!dragging) return;
    dragging = false;
    document.body.classList.remove("resizing-row");

    if (
      event &&
        activePointerId != null &&
        splitter.hasPointerCapture &&
        splitter.hasPointerCapture(activePointerId)
    ) {
      splitter.releasePointerCapture(activePointerId);
    }

    activePointerId = null;
  }

  splitter.addEventListener("pointerdown", event => {
    if (isMobileLayout()) return;
    dragging = true;
    activePointerId = event.pointerId;
    document.body.classList.add("resizing-row");
    splitter.setPointerCapture(event.pointerId);
    applyFromPointer(event.clientY);
    event.preventDefault();
  });

  splitter.addEventListener("pointermove", event => {
    if (!dragging || event.pointerId !== activePointerId) return;
    applyFromPointer(event.clientY);
  });

  splitter.addEventListener("pointerup", stopDrag);
  splitter.addEventListener("pointercancel", stopDrag);
  window.addEventListener("pointerup", stopDrag);

  window.addEventListener("resize", () => {
    if (isMobileLayout()) {
      stopDrag();
      container.style.removeProperty("--obs-agents-row");
      return;
    }

    const current = Number.parseFloat(
      getComputedStyle(container).getPropertyValue("--obs-agents-row")
    );

    if (Number.isFinite(current)) {
      container.style.setProperty("--obs-agents-row", `${clampAgentsHeight(current)}px`);
    }
  });
}

async function fetchJSON(url, opts = {}) {
  const res = await fetch(url, opts);
  const data = await res.json().catch(() => ({}));

  if (!res.ok) {
    const message = data.error || `Request failed (${res.status})`;
    throw new Error(message);
  }

  return data;
}

