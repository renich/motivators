"use strict";

// The ten cards, in the order a participant first sees them.
const CARDS = [
  "Curiosity", "Honor", "Acceptance", "Mastery", "Power",
  "Freedom", "Relatedness", "Order", "Goal", "Status",
];

const state = {
  role: null,      // "facilitator" | "participant"
  code: null,
  myId: null,
  token: null,     // facilitator only
  order: CARDS.slice(),
  socket: null,
};

const $ = (id) => document.getElementById(id);
const show = (el) => el.hidden = false;
const hide = (el) => el.hidden = true;

// --- Home actions -----------------------------------------------------------

$("start").addEventListener("click", async () => {
  const res = await fetch("/sessions", { method: "POST" });
  const { code, facilitator_token } = await res.json();
  state.role = "facilitator";
  state.code = code;
  state.token = facilitator_token;
  state.myId = crypto.randomUUID();
  enterRoom();
});

$("join").addEventListener("submit", async (event) => {
  event.preventDefault();
  const code = $("code").value.toUpperCase();
  const name = $("name").value.trim();
  const res = await fetch(`/sessions/${code}/join`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  });
  if (!res.ok) {
    const { error } = await res.json();
    const box = $("home-error");
    box.textContent = error;
    show(box);
    return;
  }
  const { participant_id } = await res.json();
  state.role = "participant";
  state.code = code;
  state.myId = participant_id;
  enterRoom();
});

// --- Room -------------------------------------------------------------------

function enterRoom() {
  hide($("home"));
  show($("room"));
  $("room-code").textContent = state.code;

  if (state.role === "participant") {
    show($("editor"));
    renderEditor();
    $("ready").addEventListener("click", () => {
      send({ type: "submit", order: state.order });
      send({ type: "ready" });
    });
  }

  if (state.role === "facilitator") {
    show($("reveal"));
    $("reveal").addEventListener("click", () => {
      send({ type: "reveal", token: state.token });
    });
  }

  connect();
}

function connect() {
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  state.socket = new WebSocket(
    `${scheme}://${location.host}/sessions/${state.code}/ws?as=${state.myId}`
  );
  state.socket.addEventListener("message", (event) => {
    const view = JSON.parse(event.data);
    if (view.error) { flash(view.error); return; }
    render(view);
  });
}

function send(message) {
  state.socket.send(JSON.stringify(message));
}

// --- Ranking editor ---------------------------------------------------------

function renderEditor() {
  const list = $("cards");
  list.innerHTML = "";
  state.order.forEach((card, index) => {
    const li = document.createElement("li");
    li.innerHTML = `
      <span class="rank">${index + 1}</span>
      <span class="label">${card}</span>
      <button class="move" data-dir="-1" ${index === 0 ? "disabled" : ""}>↑</button>
      <button class="move" data-dir="1" ${index === state.order.length - 1 ? "disabled" : ""}>↓</button>
    `;
    li.querySelectorAll(".move").forEach((btn) => {
      btn.addEventListener("click", () => moveCard(index, Number(btn.dataset.dir)));
    });
    list.appendChild(li);
  });
}

function moveCard(index, dir) {
  const target = index + dir;
  const order = state.order;
  [order[index], order[target]] = [order[target], order[index]];
  renderEditor();
}

// --- Live rendering ---------------------------------------------------------

function render(view) {
  $("phase-label").textContent =
    view.phase === "revealed" ? "Revealed" : "In the lobby";

  renderPeople(view.participants);

  if (view.phase === "revealed") {
    hide($("editor"));
    hide($("reveal"));
    renderResults(view.participants);
  }
}

function renderPeople(participants) {
  const list = $("people");
  list.innerHTML = "";
  participants.forEach((person) => {
    const li = document.createElement("li");
    const you = person.id === state.myId ? " (you)" : "";
    const status = person.ready
      ? `<span class="ready">ready</span>`
      : `<span class="waiting">…</span>`;
    li.innerHTML = `<span>${person.name}${you}</span>${status}`;
    list.appendChild(li);
  });
}

function renderResults(participants) {
  const results = $("results");
  results.innerHTML = "";
  participants
    .filter((person) => person.ranking)
    .forEach((person) => {
      const column = document.createElement("div");
      column.className = "column";
      const cards = person.ranking.map((card) => `<li>${card}</li>`).join("");
      column.innerHTML = `<h3>${person.name}</h3><ol>${cards}</ol>`;
      results.appendChild(column);
    });
  show(results);
}

function flash(message) {
  $("phase-label").textContent = message;
}
