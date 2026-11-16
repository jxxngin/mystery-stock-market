'use strict';

// ───────── 설정 ─────────
const SB_URL = 'https://bftfsiwzhxyyjosyohjh.supabase.co';
// 공개(anon) 키: 브라우저용. 모든 테이블은 RLS로 막혀 있고 게임 RPC만 호출 가능.
const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJmdGZzaXd6aHh5eWpvc3lvaGpoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ3NDg5MTMsImV4cCI6MjExMDMyNDkxM30.zRTdCVB883-BCZDDOZOGuTcoaTPf11GhLtg6Zplkjcw';

const STOCKS = ['맛소금융', '무조건설', '방어제철', '알트엔터', '열림보안', '코요테크', '후자전자'];
const STOCK_COLORS = {
  맛소금융: '#FFCF5C', 무조건설: '#FF8A3D', 방어제철: '#A3ADC2', 알트엔터: '#C77DFF',
  열림보안: '#3DDC97', 코요테크: '#4DC9FF', 후자전자: '#FF5C8A',
};
const PLAYER_COLORS = ['#FFCF5C', '#FF5C8A', '#4DC9FF', '#3DDC97', '#C77DFF', '#FF8A3D', '#A3E635', '#F472B6', '#60A5FA', '#FBBF24', '#2DD4BF', '#E879F9'];
const NEXT_REVEAL = [5, 10, 15, 20, null];
const POLL_MS = 1500;
const AUTO_END_MS = 180000;
const START_CASH = 100000;
// 인원별 아이템 개수 (서버 start_game과 같은 기준)
const itemsFor = n => (n < 5 ? { tokens: 3, secrets: 2 } : n < 10 ? { tokens: 2, secrets: 1 } : { tokens: 1, secrets: 1 });
const secretsOf = me => me.secrets ?? (me.blind_used ? 0 : 1);

const LOGO = `<svg viewBox="0 0 64 64" aria-hidden="true"><rect x="2" y="2" width="60" height="60" rx="14" fill="#14141D" stroke="#FFCF5C" stroke-width="3"/><line x1="15" y1="30" x2="15" y2="52" stroke="#5B9BFF" stroke-width="2"/><rect x="11" y="35" width="8" height="12" rx="1.5" fill="#5B9BFF"/><line x1="49" y1="18" x2="49" y2="44" stroke="#FF5A6A" stroke-width="2"/><rect x="45" y="22" width="8" height="15" rx="1.5" fill="#FF5A6A"/><path d="M24.5 24c0-5 3.4-8 7.5-8s7.8 2.9 7.8 7.3c0 3.9-2.8 5.4-5.2 6.9-1.6 1-2.6 2.1-2.6 4.2V37" fill="none" stroke="#FFCF5C" stroke-width="5" stroke-linecap="round"/><circle cx="32" cy="46.5" r="3.3" fill="#FFCF5C"/></svg>`;
const I = {
  search: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>',
  eyeOff: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M3 3l18 18"/><path d="M10.6 5.1A10.5 10.5 0 0 1 12 5c6 0 9.5 7 9.5 7a17 17 0 0 1-3 3.9"/><path d="M6.6 6.6A17 17 0 0 0 2.5 12S6 19 12 19a9.6 9.6 0 0 0 5.4-1.6"/></svg>',
  clock: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
  close: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  check: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M5 12l5 5L20 7"/></svg>',
};

const $app = document.getElementById('app');
const $modal = document.getElementById('modal');
const $toast = document.getElementById('toast');
const $ = sel => document.querySelector(sel);
const isNarrow = () => window.matchMedia('(max-width: 999px)').matches;

const S = {
  session: load('msm_session'),
  state: null,
  prev: null,
  lastKey: '',
  offset: 0,
  pollTimer: null,
  connErr: false,
  busy: false,
  mounted: null,     // 'game' 이면 게임 화면 골격이 붙어 있음
  sel: null,         // 선택한 종목
  mode: 'buy',       // 주문서 모드
  ticketFor: null,   // 주문서가 어느 종목용으로 만들어졌는지
  sheetOpen: false,  // 모바일 하단 시트
  revealTimer: null,
};

// ───────── 유틸 ─────────
function load(k) { try { return JSON.parse(localStorage.getItem(k)); } catch { return null; } }
function store(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, JSON.stringify(v)); } catch {} }
function saveSession(s) { S.session = s; store('msm_session', s); }

const fmt = n => (n == null ? '???' : Number(n).toLocaleString('ko-KR'));
const won = n => (n == null ? '???' : fmt(n) + '원');
const signed = n => (n == null ? '???' : (n > 0 ? '+' : n < 0 ? '−' : '') + fmt(Math.abs(n)));
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const serverNow = () => Date.now() + S.offset;
const chgCls = c => (c == null ? 'unk' : c > 0 ? 'up' : c < 0 ? 'down' : 'flat');
const pctOf = (price, ch) => (price != null && ch != null && price - ch ? (ch / (price - ch)) * 100 : 0);

async function rpc(fn, args = {}) {
  const res = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) throw new Error((data && data.message) || `서버 오류 (${res.status})`);
  return data;
}
const auth = () => ({ p_player: S.session.player_id, p_secret: S.session.secret });

function toast(msg, kind = 'info') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  $toast.appendChild(el);
  setTimeout(() => el.classList.add('out'), 2200);
  setTimeout(() => el.remove(), 2600);
}

// ───────── 폴링 ─────────
function startPolling() {
  stopPolling();
  const loop = async () => { await refresh(); S.pollTimer = setTimeout(loop, POLL_MS); };
  loop();
}
function stopPolling() { clearTimeout(S.pollTimer); S.pollTimer = null; }

async function refresh() {
  if (!S.session) return;
  try {
    const st = await rpc('get_state', auth());
    S.offset = st.now - Date.now();
    const prev = S.state;
    S.state = st;
    S.connErr = false;
    if (prev && prev.room.status === 'playing' && st.room.status !== 'lobby' &&
        (st.room.round > prev.room.round || st.room.status === 'finished')) {
      showReveal(prev, st);
    }
    render();
  } catch (e) {
    if (String(e.message).includes('인증 실패')) {
      logout();
      toast('세션이 만료됐어요. 다시 입장해주세요', 'err');
    } else {
      S.connErr = true;
      updateLive();
    }
  }
}

function logout() {
  saveSession(null);
  stopPolling();
  Object.assign(S, { state: null, lastKey: '', mounted: null, sel: null, ticketFor: null, sheetOpen: false });
  document.body.classList.remove('sheet-open');
  history.replaceState(null, '', location.pathname);
  renderHome();
}

// ───────── 렌더 ─────────
function render(force = false) {
  const st = S.state;
  if (!st) return;
  const key = JSON.stringify({ ...st, now: 0 }) + S.sel + S.sheetOpen;
  if (!force && key === S.lastKey) { updateLive(); return; }
  S.lastKey = key;
  const status = st.room.status;
  if (status !== 'playing') { S.mounted = null; document.body.classList.remove('sheet-open'); }
  if (status === 'lobby') renderLobby(st);
  else if (status === 'playing') renderGame(st);
  else renderResult(st);
  updateLive();
}

function topbar(st, flat = false) {
  return `<header class="topbar ${flat ? 'flat' : ''}">
    <span class="logo-sm">${LOGO}</span><span class="title">미스터리 주식 시장</span>
    ${st ? `<span class="code-chip">${esc(st.room.code)}</span>` : ''}
    <span class="sp"></span>
    <button class="btn ghost sm" data-act="rules">규칙</button>
    <button class="btn ghost sm" data-act="leave">나가기</button>
  </header>`;
}

function renderHome() {
  S.mounted = null;
  const code = (new URLSearchParams(location.search).get('room') || '').toUpperCase().slice(0, 4);
  $app.innerHTML = `
  <main class="home">
    <div class="hero">
      <div class="logo-lg">${LOGO}</div>
      <h1>미스터리 주식 시장</h1>
      <p class="tag">숨겨진 규칙으로 움직이는 7개 종목.<br>24라운드 동안 규칙을 추리하고 최고의 자산가가 되세요.</p>
      <div class="hero-tk"><span class="tk hidden">□□□</span><span class="tk next">□□</span><span class="tk open">+12%</span><span class="tk hidden">□□□□</span></div>
    </div>
    <div class="card form">
      <label>닉네임<input id="in-name" maxlength="12" placeholder="최대 12자" value="${esc(load('msm_name') || '')}" autocomplete="off"></label>
      ${code ? '' : `<button class="btn primary big" data-act="create">방 만들기</button><div class="or"><span>또는 코드로 입장</span></div>`}
      <label>방 코드<input id="in-code" maxlength="4" placeholder="ABCD" value="${esc(code)}" autocomplete="off" autocapitalize="characters"></label>
      <button class="btn ${code ? 'primary' : ''} big" data-act="join">입장하기</button>
      ${code ? `<button class="link" data-act="home-clear">새 방 만들기</button>` : ''}
    </div>
    <button class="link center-link" data-act="rules">게임 규칙 보기</button>
  </main>`;
}

function renderLobby(st) {
  const n = st.players.length;
  $app.innerHTML = `${topbar(st)}
  <main class="lobby">
    <div class="card center">
      <div class="muted">방 코드</div>
      <div class="code">${esc(st.room.code)}</div>
      <button class="btn" data-act="copy-link">초대 링크 복사</button>
    </div>
    <div class="card">
      <h3>참가자 <small>${n}/12</small></h3>
      <ul class="plist">${st.players.map(p => `
        <li><i class="on ${p.online ? '' : 'off'}"></i><span class="nm">${esc(p.name)}</span>${p.host ? '<span class="tag-host">방장</span>' : ''}${p.id === st.me.id ? '<small class="muted">나</small>' : ''}</li>`).join('')}
      </ul>
    </div>
    <div class="card items-info">
      <h3>이번 판 아이템 <small>${n}명 기준 · 시작할 때 지급</small></h3>
      <div class="ii-row"><span>${I.search} 정보 토큰</span><b>${itemsFor(n).tokens}개</b></div>
      <div class="ii-row"><span>${I.eyeOff} 시크릿</span><b>${itemsFor(n).secrets}개</b></div>
      <p class="muted small">3~4명: 토큰 3 · 시크릿 2 / 5~9명: 토큰 2 · 시크릿 1 / 10명 이상: 토큰 1 · 시크릿 1</p>
    </div>
    ${st.room.is_host
      ? `<button class="btn primary big" data-act="start" ${n < 3 ? 'disabled' : ''}>${n < 3 ? `게임 시작 (최소 3명, ${3 - n}명 더 필요)` : '게임 시작'}</button>`
      : `<p class="muted center">방장이 게임을 시작하길 기다리는 중…</p>`}
  </main>`;
}

// ───────── 게임 화면 ─────────
function stockOf(st, name) { return st.stocks.find(s => s.name === name); }
function heldOf(st, name) { return (st.me.holdings || {})[name] || 0; }

function myValue(st) {
  let value = 0, unknown = false;
  for (const s of st.stocks) {
    const q = heldOf(st, s.name);
    if (!q) continue;
    if (s.price == null) unknown = true; else value += q * s.price;
  }
  return { value, unknown };
}

function renderGame(st) {
  if (S.mounted !== 'game') {
    $app.innerHTML = `${topbar(st, true)}
    <div class="hud" id="hud"></div>
    <div class="game">
      <section class="list-col">
        <div class="legend">
          <span><span class="tk hidden">□□</span> 가려짐</span>
          <span><span class="tk next">□□</span> 다음 공개 때 열림</span>
          <span><span class="tk peek">단어</span> 미리 연 단어</span>
        </div>
        <div id="list" class="slist"></div>
      </section>
      <div class="sheet-bd" data-act="sheet-close"></div>
      <section class="detail" id="detail" aria-label="종목 상세">
        <div class="grab" aria-hidden="true"></div>
        <div id="d-head"></div>
        <div id="d-chart"></div>
        <div id="d-rule"></div>
        <div id="d-ticket"></div>
        <div id="d-log"></div>
        <div id="d-memo"></div>
      </section>
      <aside class="side" id="side"></aside>
    </div>`;
    S.mounted = 'game';
    S.ticketFor = null;
  }
  if (!S.sel || !stockOf(st, S.sel)) {
    const owned = st.stocks.find(s => heldOf(st, s.name) > 0);
    S.sel = (owned || st.stocks[0]).name;
  }
  document.body.classList.toggle('sheet-open', S.sheetOpen && isNarrow());
  $('#hud').innerHTML = hudHtml(st);
  $('#list').innerHTML = st.stocks.map(s => rowHtml(s, st)).join('');
  renderDetail(st);
  $('#side').innerHTML = sideHtml(st);
}

function hudHtml(st) {
  const { room, me, votes } = st;
  const { value, unknown } = myValue(st);
  const total = unknown ? null : me.cash + value;
  const nextR = NEXT_REVEAL[room.stage];
  const owned = st.stocks.filter(s => heldOf(st, s.name) > 0);
  const totPct = total == null ? null : ((total - START_CASH) / START_CASH) * 100;
  return `<div class="hud-in">
    <div class="hud-r1">
      <div class="round"><span class="r-num">R${room.round}</span><span class="r-of">/24</span></div>
      <div class="stage" title="규칙 공개 단계"><span class="dots">${[1, 2, 3, 4].map(i => `<i class="${room.stage >= i ? 'lit' : ''}"></i>`).join('')}</span>
        <span class="stage-t">${nextR ? `다음 공개 <b>${nextR}R</b>` : '모든 규칙 공개됨'}</span></div>
      <span class="sp"></span>
      <div id="live" class="live"></div>
      <button class="btn vote ${me.vote ? 'on' : ''}" data-act="vote">${me.vote ? `${I.check} 투표함` : '종료 투표'}<span class="vc">${votes.votes}/${votes.need}</span></button>
      ${room.is_host ? `<button class="btn ghost sm force" data-act="force">강제 종료</button>` : ''}
    </div>
    <div class="hud-r2">
      <div class="money"><span class="lbl">현금</span><b>${won(me.cash)}</b></div>
      <div class="money"><span class="lbl">주식 평가</span><b>${unknown ? '???' : won(value)}</b></div>
      <div class="money"><span class="lbl">총자산</span><b class="gold">${won(total)}${totPct == null ? '' : ` <small class="${chgCls(totPct)}">${totPct >= 0 ? '+' : ''}${totPct.toFixed(1)}%</small>`}</b></div>
      <div class="items">
        <button class="btn item tok" data-act="open-token" ${me.tokens <= 0 || room.round > 19 ? 'disabled' : ''}>${I.search}<span>정보 토큰</span> <b>×${me.tokens}</b></button>
        <button class="btn item sec" data-act="open-blind" ${secretsOf(me) <= 0 || room.round >= 24 ? 'disabled' : ''}>${I.eyeOff}<span>시크릿</span> <b>×${secretsOf(me)}</b></button>
      </div>
    </div>
    <div class="holdbar">
      <span class="lbl">보유</span>
      ${owned.length ? owned.map(s => `<button class="hchip" data-act="select" data-s="${s.name}" style="--c:${STOCK_COLORS[s.name]}"><i></i>${s.name} <b>${heldOf(st, s.name)}주</b><small>${s.price == null ? '???' : won(heldOf(st, s.name) * s.price)}</small></button>`).join('') : '<span class="muted">보유 주식 없음</span>'}
    </div>
  </div>`;
}

function rowHtml(s, st) {
  const q = heldOf(st, s.name);
  const pct = pctOf(s.price, s.change);
  const n = nextCount(s);
  const sub = s.hidden
    ? `<span class="sec-t">시크릿 · ${s.secret_left}R 남음</span>`
    : s.level >= 4 ? '규칙 전부 공개' : `다음 공개 <span class="tk next">□${n}</span>${s.peeked ? ' · 엿봄' : ''}`;
  return `<button class="srow ${S.sel === s.name ? 'on' : ''} ${s.hidden ? 'blind' : ''}" data-act="select" data-s="${s.name}" style="--c:${STOCK_COLORS[s.name]}">
    <i class="bar"></i>
    <span class="sr-name"><b>${s.name}</b><small>${sub}</small></span>
    ${spark(s.name, st.history, 72, 28)}
    <span class="sr-price"><b>${s.hidden ? '???' : fmt(s.price)}</b><small class="${chgCls(s.change)}">${s.hidden ? '' : s.change > 0 ? `▲ ${pct.toFixed(1)}%` : s.change < 0 ? `▼ ${Math.abs(pct).toFixed(1)}%` : '— 0%'}</small></span>
    <span class="sr-mine">${q ? `${q}주` : ''}</span>
  </button>`;
}

function renderDetail(st) {
  const s = stockOf(st, S.sel);
  const pct = pctOf(s.price, s.change);
  const chText = s.hidden ? '' : s.change > 0 ? `▲ ${fmt(s.change)} (+${pct.toFixed(1)}%)` : s.change < 0 ? `▼ ${fmt(-s.change)} (${pct.toFixed(1)}%)` : '— 0 (0.0%)';
  $('#detail').style.setProperty('--c', STOCK_COLORS[s.name]);
  $('#d-head').innerHTML = `
    <div class="dh">
      <div class="dh-name"><i class="dot"></i>${s.name}</div>
      ${s.hidden ? `<span class="badge sec">시크릿 · ${s.secret_left}R 남음</span>` : ''}
      ${s.peeked ? '<span class="badge peekb">엿봄</span>' : ''}
      <span class="sp"></span>
      <button class="d-close" data-act="sheet-close" aria-label="닫기">${I.close}</button>
    </div>
    <div class="dh-price"><b>${s.hidden ? '???' : won(s.price)}</b><span class="chg ${chgCls(s.change)}">${chText}</span></div>
    <div class="dh-stats">
      <span>매수 <b>${fmt(s.buy)}</b></span><span>매도 <b>${fmt(s.sell)}</b></span>
      <span>보유총량 <b>${fmt(s.hold)}</b></span><span>보유자 <b>${s.holders == null ? '?' : s.holders + '명'}</b></span>
    </div>`;
  $('#d-chart').innerHTML = bigChart(s.name, st.history);
  const canPeek = st.me.tokens > 0 && st.room.round <= 19 && s.level < 4;
  const nextR = NEXT_REVEAL[Math.min(s.level, 4)];
  $('#d-rule').innerHTML = `
    <div class="rule ${s.level >= 4 ? 'full' : ''}">
      <div class="rule-h"><span>숨겨진 규칙</span>${s.level >= 4 ? '<span class="gold">전부 공개됨</span>' : `<span class="gold">다음 공개 □${nextCount(s)}개${nextR && s.level === st.room.stage ? ` · ${nextR}R` : ''}</span>`}</div>
      <p>${ruleHtml(s)}</p>
      ${canPeek ? `<button class="btn peek-btn" data-act="peek-this">${I.search} 정보 토큰으로 점선 □ 미리 열기 <b>×${st.me.tokens}</b></button>` : ''}
    </div>`;
  if (S.ticketFor !== s.name) buildTicket(st);
  updateTicket();
  $('#d-log').innerHTML = logHtml(s.name, st.history);
}

// 주문서: 입력칸이 폴링 갱신으로 지워지지 않도록 종목이 바뀔 때만 다시 만든다
function buildTicket(st) {
  const name = S.sel;
  $('#d-ticket').innerHTML = `
    <div class="ticket">
      <div class="seg" role="tablist">
        <button class="seg-b buy" data-act="mode" data-m="buy" role="tab">매수</button>
        <button class="seg-b sell" data-act="mode" data-m="sell" role="tab">매도</button>
      </div>
      <div class="qty-row">
        <button class="qs" data-act="q-step" data-d="-1" aria-label="수량 감소">−</button>
        <label class="q-wrap"><span class="sr">수량</span><input id="q-in" type="number" inputmode="numeric" min="1" step="1" value="1"><span class="q-unit">주</span></label>
        <button class="qs" data-act="q-step" data-d="1" aria-label="수량 증가">+</button>
      </div>
      <div class="quick">
        <button data-act="q-frac" data-f="0.25">1/4</button>
        <button data-act="q-frac" data-f="0.5">절반</button>
        <button data-act="q-frac" data-f="1">전부</button>
      </div>
      <div class="preview" id="t-prev"></div>
      <button class="btn go" id="t-go" data-act="submit">주문</button>
    </div>`;
  $('#d-memo').innerHTML = `
    <label class="memo"><span>내 추리 메모 <small>이 기기에만 저장돼요</small></span>
      <textarea id="memo" rows="3" placeholder="예) 매수가 많으면 다음 라운드에 떨어지는 듯?">${esc(load(memoKey(st, name)) || '')}</textarea>
    </label>`;
  S.ticketFor = name;
}
const memoKey = (st, name) => `msm_memo_${st.room.code}_${name}`;

function ticketMax(st, s) {
  if (S.mode === 'sell') return heldOf(st, s.name);
  return s.price == null ? null : Math.floor(st.me.cash / s.price);
}

function updateTicket() {
  const st = S.state;
  if (!st || S.mounted !== 'game') return;
  const s = stockOf(st, S.sel);
  const inp = $('#q-in');
  if (!inp) return;
  document.querySelectorAll('.seg-b').forEach(b => b.classList.toggle('on', b.dataset.m === S.mode));
  $('.ticket').classList.toggle('is-sell', S.mode === 'sell');
  const q = Math.max(0, Math.floor(Number(inp.value) || 0));
  const max = ticketMax(st, s);
  const held = heldOf(st, s.name);
  const amount = s.price == null ? null : q * s.price;
  const after = amount == null ? null : S.mode === 'buy' ? st.me.cash - amount : st.me.cash + amount;
  const over = max != null && q > max;
  document.querySelectorAll('[data-act="q-frac"]').forEach(b => { b.disabled = max == null || max <= 0; });
  $('#t-prev').innerHTML = `
    <div><span>보유</span><b>${held}주</b></div>
    <div><span>최대 ${S.mode === 'buy' ? '매수' : '매도'}</span><b>${max == null ? '가격 비공개' : max + '주'}</b></div>
    <div><span>예상 금액</span><b>${amount == null ? '체결 후 확인' : won(amount)}</b></div>
    <div><span>거래 후 현금</span><b class="${over ? 'warn' : ''}">${after == null ? '???' : won(after)}</b></div>`;
  const go = $('#t-go');
  go.textContent = over ? (S.mode === 'buy' ? '현금이 부족해요' : '보유 주식이 부족해요') : `${s.name} ${q}주 ${S.mode === 'buy' ? '매수' : '매도'}`;
  go.disabled = q <= 0 || over || (S.mode === 'sell' && held === 0);
}

function logHtml(name, hist) {
  const rows = hist.filter(h => h.round >= 1).slice().reverse();
  if (!rows.length) return `<div class="log-box"><h4>라운드별 기록</h4><p class="muted small">1라운드가 끝나면 여기에 쌓여요. 매수·보유량과 가격 변화를 비교해 규칙을 추리해 보세요.</p></div>`;
  const cell = v => (v == null ? '<td class="unk">?</td>' : `<td>${fmt(v)}</td>`);
  return `<div class="log-box"><h4>라운드별 기록 <small>매수·보유량과 등락을 비교해 보세요</small></h4>
    <div class="log-scroll"><table class="log-t">
      <thead><tr><th>R</th><th>가격</th><th>등락</th><th>매수</th><th>매도</th><th>총량</th><th>보유자</th></tr></thead>
      <tbody>${rows.map(h => {
        const c = h.change?.[name];
        return `<tr><td class="r">${h.round}</td>${cell(h.prices?.[name])}<td class="${chgCls(c)}">${c == null ? '?' : signed(c)}</td>${cell(h.buy?.[name])}${cell(h.sell?.[name])}${cell(h.hold?.[name])}${cell(h.holders?.[name])}</tr>`;
      }).join('')}</tbody>
    </table></div></div>`;
}

function sideHtml(st) {
  const { room, votes } = st;
  return `
    <div class="card">
      <h3>순위 <small>${room.round > 1 ? `${room.round - 1}R 종료 기준` : '시작 시점'}</small></h3>
      <ol class="rank">${st.ranking.map((r, i) => `
        <li class="${r.me ? 'me' : ''}"><span class="rk">${i + 1}</span>${deltaHtml(r.delta)}<span class="nm">${esc(r.name)}${r.me ? ' <small>나</small>' : ''}</span><span class="as">${r.asset == null ? '<span class="muted">비공개</span>' : won(r.asset)}</span></li>`).join('')}
      </ol>
    </div>
    <div class="card">
      <h3>플레이어 <small>종료 투표 ${votes.votes}/${votes.need} · 접속 ${votes.active}명</small></h3>
      <div class="players">${st.players.map(p => `
        <span class="pchip ${p.vote ? 'voted' : ''}"><i class="on ${p.online ? '' : 'off'}"></i>${esc(p.name)}${p.host ? ' <small>방장</small>' : ''}${p.vote ? `<span class="ck">${I.check}</span>` : ''}</span>`).join('')}
      </div>
    </div>
    <div class="card">
      <h3>거래소 소식</h3>
      <ul class="log">${st.events.slice(0, 6).map(e => `<li><b>R${e.round ?? '-'}</b>${esc(e.msg)}</li>`).join('')}</ul>
    </div>`;
}
const deltaHtml = d => (d == null ? '<span class="dl flat">·</span>' : d > 0 ? `<span class="dl up">▲${d}</span>` : d < 0 ? `<span class="dl down">▼${-d}</span>` : '<span class="dl flat">–</span>');

// 규칙 단어 상태: open(공개) / peek(토큰으로 미리 봄) / next(다음 공개 때 열림) / hidden
function ruleHtml(s) {
  if (!s.parts) return esc(s.rule);
  return s.parts.map(p => `<span class="tk ${p.k}">${esc(p.t)}</span>`).join(' ');
}
const nextCount = s => (s.parts || []).filter(p => p.k === 'next').length;

function spark(name, hist, W, H) {
  const P = 3;
  const vals = hist.map(h => h.prices?.[name] ?? null);
  const known = vals.filter(v => v != null);
  let mn = Math.min(10000, ...known), mx = Math.max(10000, ...known);
  if (mx - mn < 1000) { mx += 500; mn -= 500; }
  const x = i => P + (i * (W - 2 * P)) / 24;
  const y = v => H - P - ((v - mn) / (mx - mn)) * (H - 2 * P);
  let d = '', pen = false;
  vals.forEach((v, i) => { if (v == null) { pen = false; return; } d += `${pen ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)} `; pen = true; });
  return `<svg class="spark" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" aria-hidden="true"><line class="base" x1="0" x2="${W}" y1="${y(10000).toFixed(1)}" y2="${y(10000).toFixed(1)}"/><path class="ln" d="${d}"/></svg>`;
}

function bigChart(name, hist) {
  const W = 600, H = 150, L = 48, R = 10, T = 10, B = 22;
  const vals = hist.map(h => h.prices?.[name] ?? null);
  const known = vals.filter(v => v != null);
  let mn = Math.min(10000, ...known), mx = Math.max(10000, ...known);
  if (mx - mn < 2000) { mx += 1000; mn -= 1000; }
  mn = Math.max(0, mn);
  const x = i => L + (i * (W - L - R)) / 24;
  const y = v => T + (1 - (v - mn) / (mx - mn)) * (H - T - B);
  let d = '', pen = false, last = null;
  vals.forEach((v, i) => { if (v == null) { pen = false; return; } d += `${pen ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)} `; pen = true; last = [x(i), y(v)]; });
  const ticks = [mx, (mx + mn) / 2, mn];
  const lab = v => (v >= 10000 ? `${(v / 10000).toFixed(1)}만` : fmt(Math.round(v / 100) * 100));
  return `<svg class="bigchart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${name} 가격 추이">
    ${ticks.map(v => `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 6}" y="${y(v) + 4}" text-anchor="end">${lab(v)}</text>`).join('')}
    <line class="base" x1="${L}" x2="${W - R}" y1="${y(10000)}" y2="${y(10000)}"/>
    ${[0, 5, 10, 15, 20, 24].map(i => `<text x="${x(i)}" y="${H - 5}" text-anchor="middle">R${i}</text>`).join('')}
    <path class="ln" d="${d}"/>
    ${last ? `<circle cx="${last[0]}" cy="${last[1]}" r="4" class="pt"/>` : ''}
  </svg>`;
}

function lineChart(series) {
  const W = 640, H = 260, L = 64, R = 12, T = 12, B = 26;
  const all = series.flatMap(s => s.values.filter(v => v != null));
  if (!all.length) return '';
  let mn = Math.min(...all), mx = Math.max(...all);
  if (mx - mn < 1) { mx += 1; mn -= 1; }
  const n = Math.max(...series.map(s => s.values.length)) - 1 || 1;
  const x = i => L + (i * (W - L - R)) / n;
  const y = v => T + (1 - (v - mn) / (mx - mn)) * (H - T - B);
  const ticks = [0, 0.25, 0.5, 0.75, 1].map(t => mn + (mx - mn) * t);
  const lab = v => (v >= 10000 ? `${(v / 10000).toFixed(v >= 100000 ? 0 : 1)}만` : fmt(Math.round(v)));
  const paths = series.map(s => {
    let d = '', pen = false;
    s.values.forEach((v, i) => { if (v == null) { pen = false; return; } d += `${pen ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)} `; pen = true; });
    return `<path d="${d}" fill="none" stroke="${s.color}" stroke-width="2" stroke-linejoin="round"/>`;
  }).join('');
  return `<svg class="chart" viewBox="0 0 ${W} ${H}">
    ${ticks.map(v => `<line class="gl" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 6}" y="${y(v) + 4}" text-anchor="end">${lab(v)}</text>`).join('')}
    ${[0, 6, 12, 18, 24].filter(i => i <= n).map(i => `<text x="${x(i)}" y="${H - 6}" text-anchor="middle">R${i}</text>`).join('')}
    ${paths}
  </svg>
  <div class="legend">${series.map(s => `<span><i style="background:${s.color}"></i>${esc(s.name)}</span>`).join('')}</div>`;
}

// ───────── 라운드 결과 연출 ─────────
function showReveal(prev, st) {
  const t = prev.room.round;
  const row = st.history.find(h => h.round === t);
  if (!row) return;
  const hold = st.me.holdings || {};
  let pl = 0, plUnknown = false;
  for (const [name, q] of Object.entries(hold)) {
    const c = row.change?.[name];
    if (c == null) plUnknown = true; else pl += q * c;
  }
  const meRank = st.ranking.findIndex(r => r.me);
  const meDelta = meRank >= 0 ? st.ranking[meRank].delta : null;
  const opened = [];
  for (const s of st.stocks) {
    const p0 = stockOf(prev, s.name);
    if (!p0 || !p0.parts || !s.parts) continue;
    const words = s.parts.filter((p, i) => p0.parts[i] && ['hidden', 'next'].includes(p0.parts[i].k) && ['open', 'peek'].includes(p.k)).map(p => p.t);
    if (words.length) opened.push({ name: s.name, words });
  }
  const stageUp = st.room.stage > prev.room.stage;
  const items = STOCKS.map((name, i) => {
    const c = row.change?.[name], p = row.prices?.[name];
    const pct = pctOf(p, c);
    return `<li style="--c:${STOCK_COLORS[name]}; animation-delay:${0.15 + i * 0.12}s">
      <i class="bar"></i><span class="nm">${name}</span>
      <span class="pr">${p == null ? '???' : fmt(p)}</span>
      <span class="ch ${chgCls(c)}">${c == null ? '시크릿' : c > 0 ? `▲ ${pct.toFixed(1)}%` : c < 0 ? `▼ ${Math.abs(pct).toFixed(1)}%` : '— 0%'}</span>
    </li>`;
  }).join('');
  let el = $('#reveal');
  if (!el) { el = document.createElement('div'); el.id = 'reveal'; document.body.appendChild(el); }
  el.innerHTML = `<div class="rv-bd" data-act="reveal-close"></div>
    <div class="rv-card" role="dialog" aria-label="라운드 결과">
      <div class="rv-k">ROUND ${t} 결과</div>
      <div class="rv-pl"><span>이번 라운드 내 손익</span><b class="${plUnknown ? 'unk' : chgCls(pl)}">${plUnknown ? '???' : signed(pl) + '원'}</b>
        ${meRank >= 0 ? `<span class="rv-rank">현재 ${meRank + 1}위 ${deltaHtml(meDelta)}</span>` : ''}</div>
      <ul class="rv-list">${items}</ul>
      ${stageUp ? `<div class="rv-stage">규칙 공개 ${st.room.stage}단계${st.room.stage >= 4 ? ' · 모든 규칙 공개!' : ''}</div>` : ''}
      ${opened.length ? `<div class="rv-open"><h4>새로 열린 단어</h4>${opened.map(o => `<div class="rv-o"><b style="color:${STOCK_COLORS[o.name]}">${o.name}</b> ${o.words.map(w => `<span class="tk peek">${esc(w)}</span>`).join(' ')}</div>`).join('')}</div>` : ''}
      <button class="btn primary big" data-act="reveal-close">${st.room.status === 'finished' ? '최종 결과 보기' : `R${st.room.round} 거래 시작`}</button>
    </div>`;
  el.classList.add('open');
  clearTimeout(S.revealTimer);
  S.revealTimer = setTimeout(closeReveal, opened.length ? 9000 : 6000);
}
function closeReveal() { const el = $('#reveal'); if (el) el.classList.remove('open'); clearTimeout(S.revealTimer); }

// ───────── 결과 화면 ─────────
function renderResult(st) {
  const rk = st.ranking;
  const top = [rk[1], rk[0], rk[2]];
  const assets = (st.final?.assets || []).map((a, i) => ({ name: a.name, color: PLAYER_COLORS[i % PLAYER_COLORS.length], values: a.series }));
  const prices = STOCKS.map(name => ({ name, color: STOCK_COLORS[name], values: st.history.map(h => h.prices?.[name]) }));
  $app.innerHTML = `${topbar(st)}
  <main class="result">
    <h2>최종 결과</h2>
    <div class="podium">${top.map((r, j) => r ? `
      <div class="pod p${[2, 1, 3][j]}"><div class="medal">${[2, 1, 3][j]}</div><div class="nm">${esc(r.name)}</div><div class="as">${won(r.asset)}</div></div>` : '<div></div>').join('')}
    </div>
    <div class="card">
      <h3>전체 순위</h3>
      <ol class="rank">${rk.map((r, i) => `
        <li class="${r.me ? 'me' : ''}"><span class="rk">${i + 1}</span><span class="nm">${esc(r.name)}</span>
        <span class="as">${won(r.asset)} <small class="${chgCls(r.asset - START_CASH)}">(${r.asset >= START_CASH ? '+' : ''}${(((r.asset - START_CASH) / START_CASH) * 100).toFixed(1)}%)</small></span></li>`).join('')}
      </ol>
    </div>
    <div class="card"><h3>자산 변화</h3>${lineChart(assets)}</div>
    <div class="card"><h3>주가 변화</h3>${lineChart(prices)}</div>
    <div class="card">
      <h3>규칙 정답</h3>
      <div class="answers">${st.stocks.map(s => `
        <div style="--c:${STOCK_COLORS[s.name]}"><div class="sname"><i class="dot"></i>${s.name}</div><div class="rule full"><p>${esc(s.rule)}</p></div></div>`).join('')}
      </div>
    </div>
    <button class="btn primary big" data-act="leave-confirmed">새 게임 하러 가기</button>
  </main>`;
}

function updateLive() {
  const el = document.getElementById('live');
  if (!el) return;
  const st = S.state;
  if (S.connErr) { el.innerHTML = '<span class="hurry">연결 끊김 · 재시도 중…</span>'; return; }
  if (!st || st.room.status !== 'playing') { el.textContent = ''; return; }
  if (st.room.countdown) { el.innerHTML = '<span class="hurry">곧 마감됩니다!</span>'; return; }
  const left = st.room.round_started_at + AUTO_END_MS - serverNow();
  if (left <= 0) { el.textContent = '마감 대기 중…'; return; }
  const sec = Math.ceil(left / 1000);
  el.innerHTML = `${I.clock}<span>${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}</span>`;
}
setInterval(updateLive, 250);

// ───────── 모달 ─────────
function openModal(html) {
  $modal.innerHTML = `<div class="backdrop" data-act="close"></div><div class="sheet"><button class="close" data-act="close" aria-label="닫기">${I.close}</button>${html}</div>`;
  $modal.classList.add('open');
}
function closeModal() { $modal.classList.remove('open'); $modal.innerHTML = ''; }

function openBlind() {
  const st = S.state;
  openModal(`<h2>${I.eyeOff} 시크릿 <small class="muted">×${secretsOf(st.me)}</small></h2>
    <p class="desc">고른 종목의 가격·매매 현황·보유 총량이 <b>다음 라운드부터 2라운드 동안</b> 모두에게(나 포함) 가려집니다. 1개를 쓰면 1개가 줄어들고, 누가 썼는지는 공개되지 않아요.</p>
    <div class="pick">${st.stocks.map(s => `<button class="btn" data-act="blind-pick" data-s="${s.name}" ${s.hidden ? 'disabled' : ''} style="--c:${STOCK_COLORS[s.name]}"><span><i class="dot"></i>${s.name}</span><small>${s.hidden ? `이미 가려짐 · ${s.secret_left}R 남음` : '선택'}</small></button>`).join('')}</div>`);
}

function openToken() {
  const st = S.state;
  openModal(`<h2>${I.search} 정보 토큰 <small class="muted">×${st.me.tokens}</small></h2>
    <p class="desc">토큰 1개로 한 종목에서 <span class="tk next">점선 □</span>를 지금 바로 열 수 있어요. 19라운드까지 사용 가능.</p>
    <button class="btn cash-btn" data-act="token-cash"><span>현금으로 환전</span><b>+10,000원</b></button>
    <div class="pick-h">엿볼 종목 고르기</div>
    <div class="peek-list">${st.stocks.map(s => `
      <button class="btn peek-item" data-act="token-peek" data-s="${s.name}" ${s.level >= 4 ? 'disabled' : ''} style="--c:${STOCK_COLORS[s.name]}">
        <span class="pi-h"><b><i class="dot"></i>${s.name}</b><small>${s.level >= 4 ? '전부 보임' : `□ ${nextCount(s)}개 미리 열기`}</small></span>
        <span class="pi-r">${ruleHtml(s)}</span>
      </button>`).join('')}</div>`);
}

function openRules() {
  openModal(`<h2>게임 규칙</h2>
  <div class="rules-doc">
    <h4>기본</h4>
    <ul>
      <li>3~12명, <b>24라운드</b>. 시작 현금 <b>100,000원</b>, 7개 종목 모두 <b>10,000원</b>에서 시작 (최저가 100원).</li>
      <li>라운드 중에는 현재가로 자유롭게 사고팔 수 있어요. 가격은 라운드가 끝날 때 한꺼번에 바뀝니다.</li>
      <li>라운드가 시작되면 지난 라운드의 <b>주가 · 매매 현황 · 보유 총량 · 보유자 수 · 순위</b>가 공개됩니다.</li>
      <li>24라운드 종료 시 <b>총자산(현금 + 주식 평가액)</b>이 가장 많은 사람이 승리!</li>
    </ul>
    <h4>라운드 종료</h4>
    <ul>
      <li>접속자 <b>70% 이상</b>이 [종료 투표]를 누르면 <b>5~10초 뒤</b>(정확한 시간은 비밀) 마감돼요.</li>
      <li>라운드 시작 후 3분이 지나면 자동으로 마감이 시작됩니다. 방장은 강제 종료할 수 있어요.</li>
    </ul>
    <h4>숨겨진 규칙</h4>
    <ul>
      <li>각 종목은 숨겨진 규칙으로 움직여요. 규칙 문장은 <b>□□</b>로 가려져 있다가 <b>5 · 10 · 15라운드</b>에 조금씩, <b>20라운드</b>에 전부 공개됩니다.</li>
      <li><b>영향력이 작은 단어부터</b> 열리고, 결정적인 단어(참조 종목·오르면/내리면·기준값)는 가장 늦게 열려요.</li>
      <li>매 판 <b>10가지 규칙 중 7개</b>가 뽑혀 종목에 <b>랜덤 배정</b>돼요. 수치와 참조 종목도 매번 달라요. 지난 판 정답은 소용없어요!</li>
      <li>보유 총량 = 모든 플레이어가 가진 주식 수 합계 · 매수량/매도량 = 이번 라운드에 사고판 주식 수 합계 · 보유자 = 1주 이상 가진 사람 수.</li>
    </ul>
    <h4>아이템</h4>
    <table>
      <tr><td>시크릿</td><td>한 종목의 정보를 다음 라운드부터 2라운드 동안 모두에게 가림. 누가 썼는지는 비밀.</td></tr>
      <tr><td>정보 토큰</td><td>한 종목의 점선 □(다음 공개분)를 미리 열기, 또는 현금 10,000원으로 환전. 19라운드까지.</td></tr>
    </table>
    <h4>인원별 아이템 개수</h4>
    <table>
      <tr><td>3~4명</td><td>정보 토큰 3개 · 시크릿 2개</td></tr>
      <tr><td>5~9명</td><td>정보 토큰 2개 · 시크릿 1개</td></tr>
      <tr><td>10~12명</td><td>정보 토큰 1개 · 시크릿 1개</td></tr>
    </table>
  </div>`);
}

// ───────── 액션 ─────────
async function act(name, ds) {
  const st = S.state;
  switch (name) {
    case 'close': return closeModal();
    case 'rules': return openRules();
    case 'reveal-close': return closeReveal();
    case 'home-clear': history.replaceState(null, '', location.pathname); return renderHome();
    case 'select':
      S.sel = ds.s;
      if (isNarrow()) S.sheetOpen = true;
      return render(true);
    case 'sheet-close':
      S.sheetOpen = false;
      return render(true);
    case 'mode':
      S.mode = ds.m;
      return updateTicket();
    case 'q-step': {
      const inp = $('#q-in');
      inp.value = Math.max(1, (Math.floor(Number(inp.value)) || 0) + Number(ds.d));
      return updateTicket();
    }
    case 'q-frac': {
      const s = stockOf(st, S.sel);
      const max = ticketMax(st, s);
      if (!max) return;
      $('#q-in').value = Math.max(1, Math.floor(max * Number(ds.f)));
      return updateTicket();
    }
    case 'create':
    case 'join': {
      const nm = document.getElementById('in-name').value.trim();
      if (!nm) return toast('닉네임을 입력해주세요', 'err');
      store('msm_name', nm);
      let res;
      if (name === 'create') res = await rpc('create_room', { p_name: nm });
      else {
        const code = document.getElementById('in-code').value.trim().toUpperCase();
        if (code.length !== 4) return toast('4자리 방 코드를 입력해주세요', 'err');
        res = await rpc('join_room', { p_code: code, p_name: nm });
      }
      saveSession(res);
      history.replaceState(null, '', `${location.pathname}?room=${res.code}`);
      $app.innerHTML = '<div class="loading">입장 중…</div>';
      return startPolling();
    }
    case 'copy-link': {
      const url = `${location.origin}${location.pathname}?room=${st.room.code}`;
      try { await navigator.clipboard.writeText(url); toast('초대 링크를 복사했어요', 'ok'); }
      catch { prompt('이 링크를 친구에게 보내세요', url); }
      return;
    }
    case 'leave':
      if (!confirm('방에서 나갈까요? 진행 중인 게임이면 다시 들어올 수 없어요.')) return;
      return logout();
    case 'leave-confirmed': return logout();
    case 'start': await rpc('start_game', auth()); return refresh();
    case 'vote': await rpc('set_vote', { ...auth(), p_vote: !st.me.vote }); return refresh();
    case 'force':
      if (!confirm('이번 라운드를 강제로 마감할까요?')) return;
      await rpc('force_end', auth());
      return refresh();
    case 'submit': {
      const s = stockOf(st, S.sel);
      const q = Math.floor(Number($('#q-in').value) || 0);
      if (q <= 0) return;
      await rpc('trade', { ...auth(), p_stock: s.name, p_qty: S.mode === 'buy' ? q : -q });
      toast(`${s.name} ${q}주 ${S.mode === 'buy' ? '매수' : '매도'} 완료`, 'ok');
      $('#q-in').value = 1;
      await refresh();
      return updateTicket();
    }
    case 'open-blind': return openBlind();
    case 'open-token': return openToken();
    case 'peek-this':
      if (!confirm(`정보 토큰 1개로 ${S.sel}의 점선 □를 열까요?`)) return;
      await rpc('use_token', { ...auth(), p_kind: 'peek', p_stock: S.sel });
      toast(`${S.sel} 규칙을 한 단계 더 엿봤어요`, 'ok');
      return refresh();
    case 'blind-pick':
      if (!confirm(`${ds.s}에 시크릿을 사용할까요? (남은 시크릿 ${secretsOf(st.me)}개)`)) return;
      await rpc('use_blind', { ...auth(), p_stock: ds.s });
      closeModal();
      toast(`${ds.s}에 시크릿을 걸었어요. 다음 라운드부터 적용돼요`, 'ok');
      return refresh();
    case 'token-cash':
      await rpc('use_token', { ...auth(), p_kind: 'cash', p_stock: null });
      closeModal();
      toast('현금 10,000원을 받았어요', 'ok');
      return refresh();
    case 'token-peek':
      await rpc('use_token', { ...auth(), p_kind: 'peek', p_stock: ds.s });
      closeModal();
      toast(`${ds.s} 규칙을 한 단계 더 엿봤어요`, 'ok');
      return refresh();
  }
}

const INSTANT = ['close', 'rules', 'reveal-close', 'home-clear', 'select', 'sheet-close', 'mode', 'q-step', 'q-frac'];
document.addEventListener('click', async e => {
  const b = e.target.closest('[data-act]');
  if (!b || b.disabled) return;
  const name = b.dataset.act;
  const instant = INSTANT.includes(name);
  if (!instant && S.busy) return;
  if (!instant) S.busy = true;
  try { await act(name, b.dataset); }
  catch (err) { toast(err.message || '오류가 발생했어요', 'err'); }
  finally { if (!instant) S.busy = false; }
});

document.addEventListener('input', e => {
  if (e.target.id === 'q-in') updateTicket();
  if (e.target.id === 'memo' && S.state) store(memoKey(S.state, S.ticketFor), e.target.value);
});

document.addEventListener('keydown', e => {
  if (e.key === 'Escape') {
    if ($('#reveal.open')) return closeReveal();
    if ($modal.classList.contains('open')) return closeModal();
    if (S.sheetOpen) { S.sheetOpen = false; render(true); }
  }
  if (e.key === 'Enter' && (e.target.id === 'in-code' || e.target.id === 'in-name')) {
    const hasCode = document.getElementById('in-code')?.value.trim();
    act(hasCode ? 'join' : 'create', {}).catch(err => toast(err.message, 'err'));
  }
  if (e.key === 'Enter' && e.target.id === 'q-in') {
    e.preventDefault();
    const go = $('#t-go');
    if (go && !go.disabled) go.click();
  }
});

window.addEventListener('resize', () => {
  if (S.mounted === 'game') document.body.classList.toggle('sheet-open', S.sheetOpen && isNarrow());
});

// ───────── 시작 ─────────
(function init() {
  const urlRoom = (new URLSearchParams(location.search).get('room') || '').toUpperCase();
  if (S.session && (!urlRoom || urlRoom === S.session.code)) {
    if (!urlRoom) history.replaceState(null, '', `${location.pathname}?room=${S.session.code}`);
    startPolling();
  } else {
    renderHome();
  }
})();
