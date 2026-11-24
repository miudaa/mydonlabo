// ===== お知らせ（上のベル） =====
// 読むのは誰でも、書けるのは管理者だけ、リアクションはログインした人（依頼ページと同じアカウント）
(() => {
const SB_URL = 'https://txwslwspvfmptzmlbbzx.supabase.co';
const SB_KEY = 'sb_publishable_yxad4Hzn3GzZT6vB3LtteQ_ogZbIovH';   // 公開してよいキー（中身はデータベース側の鍵で守っています）
const SB_JS = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/dist/umd/supabase.js';
const CHANNELS = ['notice', 'progress', 'off-topic', 'admins-throughs'];
const QUICK = ['👍', '❤️', '😂', '🎉', '😮', '😢', '🔥', '🥁'];
const MAIL_DOMAINS = ['mydonlabo.app', 'users.noreply.github.com'];
const COLORS = ['#1fa3d6', '#e0742c', '#3aa55d', '#9b59b6', '#d6466f', '#c9a227', '#2c8c99'];

const q = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const linkify = t => esc(t).replace(/https?:\/\/[^\s<>"']+/g, u => `<a href="${u}" target="_blank" rel="noopener noreferrer">${u}</a>`);
const colorOf = s => COLORS[[...String(s)].reduce((a, c) => a + c.charCodeAt(0), 0) % COLORS.length];
function say(t){ const el = q('#toast'); if (!el) return; el.textContent = t; el.classList.add('show'); clearTimeout(say.t); say.t = setTimeout(() => el.classList.remove('show'), 2600); }
const getSeen = () => { try { return JSON.parse(localStorage.getItem('mydon-nt-seen') || '{}'); } catch { return {}; } };
const setSeen = (ch, id) => { const s = getSeen(); if ((s[ch] || 0) >= id) return; s[ch] = id; try { localStorage.setItem('mydon-nt-seen', JSON.stringify(s)); } catch {} };

const N = { sb: null, me: null, admin: false, ch: 'notice', rows: [], latest: {}, open: false, timer: null, editing: null, signup: false };

// ---- 部品を置く ----
const bell = document.createElement('button');
bell.className = 'btn icon ntbell'; bell.id = 'ntBell'; bell.type = 'button';
bell.title = 'お知らせ'; bell.setAttribute('aria-label', 'お知らせ'); bell.setAttribute('aria-expanded', 'false'); bell.setAttribute('aria-haspopup', 'dialog');
bell.innerHTML = '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.6 2.2H4.4z"/><path d="M10 20.5a2.2 2.2 0 0 0 4 0"/></svg><span class="dot" hidden></span>';
(q('#sushiBtn') || q('#bmBtn')).after(bell);

document.body.insertAdjacentHTML('beforeend', `
<div id="ntPop" role="dialog" aria-label="お知らせ" hidden>
  <div class="nt-head"><h2>お知らせ</h2><div class="nt-me" id="ntMe"></div><button class="nt-x" type="button" id="ntClose" aria-label="閉じる">×</button></div>
  <div class="nt-tabs" role="tablist">${CHANNELS.map(c => `<button type="button" role="tab" data-ch="${c}" aria-selected="${c === 'notice'}">${c}</button>`).join('')}</div>
  <div class="nt-list" id="ntList" aria-live="polite"></div>
  <form class="nt-compose" id="ntCompose" hidden><div class="nt-cbox"><textarea id="ntText" rows="1" placeholder="notice に書く" aria-label="お知らせを書く"></textarea><button class="btn primary" type="submit">投稿</button></div></form>
</div>
<div id="ntLogin" hidden>
  <form class="nt-card" id="ntLoginForm" autocomplete="on" role="dialog" aria-modal="true" aria-labelledby="ntLoginH">
    <h2 id="ntLoginH">ログイン</h2>
    <p>リアクションするにはログインして下さい。</p>
    <div class="nt-seg"><button type="button" id="ntTabIn" aria-pressed="true">ログイン</button><button type="button" id="ntTabUp" aria-pressed="false">新規登録</button></div>
    <label>ユーザー名<input id="ntName" autocomplete="username" maxlength="20" required></label>
    <label>パスワード<input id="ntPass" type="password" autocomplete="current-password" minlength="8" required></label>
    <label id="ntPass2Row" hidden>パスワード（もう一度）<input id="ntPass2" type="password" autocomplete="new-password" minlength="8"></label>
    <p id="ntNote">ユーザー名に空白は使えません。パスワードは8文字以上です。</p>
    <p class="err" id="ntErr" role="alert"></p>
    <div class="row"><button class="btn" type="button" id="ntLoginNo">やめる</button><button class="btn primary" type="submit" id="ntLoginGo">ログイン</button></div>
  </form>
</div>`);

// ---- Supabase（ログインする時・ログイン中だけ読み込む） ----
function loadSb(){
  if (N.sb) return Promise.resolve(N.sb);
  return loadSb.p || (loadSb.p = new Promise((ok, ng) => {
    const s = document.createElement('script'); s.src = SB_JS;
    s.onload = () => { N.sb = window.supabase.createClient(SB_URL, SB_KEY, { auth: { persistSession: true, storageKey: 'mydon-notice-auth' } }); ok(N.sb); };
    s.onerror = () => { loadSb.p = null; ng(new Error('読み込みに失敗しました')); };
    document.head.appendChild(s);
  }));
}
const hasSession = () => { try { return !!localStorage.getItem('mydon-notice-auth'); } catch { return false; } };
// ログインしていない時は、ふつうの通信だけで読む
async function rpc(fn, args){
  if (N.sb) { const { data, error } = await N.sb.rpc(fn, args); if (error) throw error; return data; }
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: SB_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(args || {}) });
  if (!r.ok) throw new Error('読み込めませんでした（' + r.status + '）');
  return r.json();
}
async function refreshMe(){
  if (!N.sb) { N.me = null; N.admin = false; renderMe(); return; }
  const { data: { session } } = await N.sb.auth.getSession();
  if (!session) { N.me = null; N.admin = false; renderMe(); return; }
  const { data: p } = await N.sb.from('profiles').select('id, username, avatar, avatar_color').eq('id', session.user.id).maybeSingle();
  N.me = p || null;
  N.admin = !!(p && await N.sb.rpc('am_admin').then(r => r.data).catch(() => false));
  renderMe();
}
function renderMe(){
  q('#ntMe').innerHTML = N.me
    ? `${avatar(N.me.username, N.me.avatar_color, N.me.avatar)}<b>${esc(N.me.username)}</b><button class="nt-link" type="button" id="ntOut">ログアウト</button>`
    : `<button class="nt-link" type="button" id="ntIn">ログイン</button>`;
  q('#ntCompose').hidden = !N.admin;
}

// ---- 未読（ベルの赤い点） ----
async function checkLatest(){
  try {
    const rows = await rpc('notice_latest');
    N.latest = Object.fromEntries((rows || []).map(r => [r.channel, Number(r.last_id)]));
    renderDots();
  } catch {}
}
function renderDots(){
  const seen = getSeen();
  const unread = c => (N.latest[c] || 0) > (seen[c] || 0);
  bell.querySelector('.dot').hidden = !CHANNELS.some(unread);
  document.querySelectorAll('.nt-tabs [data-ch]').forEach(b => b.classList.toggle('new', b.dataset.ch !== N.ch && unread(b.dataset.ch)));
}

// ---- 一覧 ----
async function loadFeed(keep){
  const ch = N.ch;
  try {
    const rows = await rpc('notice_feed', { p_channel: ch, p_before: null, p_limit: 50 });
    if (ch !== N.ch) return;
    N.rows = (rows || []).reverse(); N.more = (rows || []).length === 50;
    render(keep);
    if (N.rows.length) { setSeen(ch, Math.max(...N.rows.map(r => Number(r.id)))); renderDots(); }
  } catch (e) { q('#ntList').innerHTML = `<p class="nt-empty">${esc(e.message || '読み込めませんでした')}</p>`; }
}
async function loadOlder(){
  const first = N.rows[0]; if (!first) return;
  const rows = await rpc('notice_feed', { p_channel: N.ch, p_before: first.id, p_limit: 50 }).catch(() => []);
  const box = q('#ntList'), h = box.scrollHeight;
  N.rows = [...(rows || []).reverse(), ...N.rows]; N.more = (rows || []).length === 50;
  render(true); box.scrollTop = box.scrollHeight - h;
}
const z = n => String(n).padStart(2, '0');
const avatar = (name, color, img) => `<span class="nt-av" style="background:${esc(color || colorOf(name || ''))}">${img ? `<img src="${esc(img)}" alt="">` : esc([...(name || '?')][0])}</span>`;
function render(keep){
  const box = q('#ntList'), atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 60, top = box.scrollTop;
  if (!N.rows.length) { box.innerHTML = `<p class="nt-empty">${esc(N.ch)} には、まだ何もありません。</p>`; return; }
  let h = N.more ? '<button class="btn nt-more" type="button" id="ntOlder">前のお知らせを見る</button>' : '';
  let prev = null, prevDay = '';
  const tools = N.admin ? '<span class="nt-tools"><button type="button" data-edit>編集</button><button type="button" class="del" data-del>削除</button></span>' : '';
  for (const m of N.rows) {
    const d = new Date(m.created_at), day = `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
    if (day !== prevDay) { h += `<div class="nt-day"><span>${day}</span></div>`; prev = null; prevDay = day; }
    const cont = prev && prev.author_name === m.author_name && d - new Date(prev.created_at) < 10 * 60 * 1000;
    const rs = (m.reactions || []).map(r => `<button class="nt-r${r.me ? ' me' : ''}" type="button" data-e="${esc(r.e)}" aria-pressed="${!!r.me}" aria-label="${esc(r.e)} ${r.n}人">${esc(r.e)}<small>${r.n}</small></button>`).join('');
    const body = N.editing === m.id
      ? `<div class="nt-edit"><textarea aria-label="編集">${esc(m.body)}</textarea><div class="row"><button class="btn" type="button" data-ecancel>やめる</button><button class="btn primary" type="button" data-esave>保存</button></div></div>`
      : `<div class="nt-body">${linkify(m.body)}</div>`;
    h += `<div class="nt-msg${cont ? ' cont' : ''}" data-id="${m.id}">${tools}
      ${cont ? '' : `<div class="nt-who">${avatar(m.author_name, m.author_color, m.author_avatar)}<b>${esc(m.author_name)}</b><time>${d.getMonth() + 1}/${d.getDate()} ${z(d.getHours())}:${z(d.getMinutes())}</time>${m.edited_at ? '<span class="ed">編集済み</span>' : ''}</div>`}
      <div class="nt-bub">${body}</div>
      <div class="nt-rs">${rs}<button class="nt-add${rs ? '' : ' only'}" type="button" data-add aria-label="リアクションを付ける" title="リアクション"><svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="12" r="8"/><path d="M7.8 13.8c.8 1.3 1.9 2 3.2 2s2.4-.7 3.2-2"/><circle cx="8.4" cy="10" r=".6" fill="currentColor"/><circle cx="13.6" cy="10" r=".6" fill="currentColor"/><path d="M19.5 2.5v5M17 5h5"/></svg></button></div></div>`;
    prev = m;
  }
  box.innerHTML = h;
  box.scrollTop = keep && !atBottom ? top : box.scrollHeight;
}

// ---- 開く・閉じる ----
function place(){
  const p = q('#ntPop'), r = bell.getBoundingClientRect();
  if (innerWidth <= 560) { p.style.left = ''; p.style.top = (r.bottom + 8) + 'px'; return; }
  p.style.top = (r.bottom + 8) + 'px';
  p.style.left = Math.max(8, Math.min(r.left - 12, innerWidth - p.offsetWidth - 8)) + 'px';
}
async function openPop(){
  N.open = true; q('#ntPop').hidden = false; bell.setAttribute('aria-expanded', 'true'); place();
  q('#ntList').innerHTML = '<p class="nt-empty">読み込み中…</p>';
  if (hasSession()) { try { await loadSb(); } catch {} }
  await refreshMe();
  await loadFeed();
  clearInterval(N.timer); N.timer = setInterval(() => { if (!document.hidden && !N.editing && !q('.nt-pick')) { loadFeed(true); checkLatest(); } }, 30000);
}
function closePop(){
  N.open = false; q('#ntPop').hidden = true; bell.setAttribute('aria-expanded', 'false');
  clearInterval(N.timer); closePick(); N.editing = null;
}
bell.addEventListener('click', e => { e.stopPropagation(); N.open ? closePop() : openPop(); });
q('#ntClose').onclick = closePop;
addEventListener('resize', () => { if (N.open) place(); });
document.addEventListener('pointerdown', e => {
  if (!N.open || q('#ntLogin').contains(e.target) || e.target.closest('.nt-pick')) return;
  if (!q('#ntPop').contains(e.target) && e.target !== bell && !bell.contains(e.target)) closePop();
});
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape') return;
  if (!q('#ntLogin').hidden) { q('#ntLogin').hidden = true; return; }
  if (q('.nt-pick')) { closePick(); return; }
  if (N.open) closePop();
});
q('.nt-tabs').addEventListener('click', e => {
  const b = e.target.closest('[data-ch]'); if (!b || b.dataset.ch === N.ch) return;
  N.ch = b.dataset.ch; N.editing = null; closePick();
  document.querySelectorAll('.nt-tabs [data-ch]').forEach(x => x.setAttribute('aria-selected', x === b));
  q('#ntText').placeholder = `${N.ch} に書く`;
  q('#ntList').innerHTML = '<p class="nt-empty">読み込み中…</p>';
  renderDots(); loadFeed();
});
q('#ntMe').addEventListener('click', async e => {
  if (e.target.id === 'ntIn') showLogin();
  if (e.target.id === 'ntOut') { await N.sb.auth.signOut(); await refreshMe(); await loadFeed(true); say('ログアウトしました'); }
});

// ---- リアクション ----
async function needLogin(){
  if (N.me) return true;
  showLogin(); return false;
}
const okEmoji = s => s && [...s].length <= 8 && s.length <= 16 && !/[A-Za-z0-9\s<>"'&\\/]/.test(s) && /\p{Extended_Pictographic}|\p{Regional_Indicator}|[☀-➿]/u.test(s);
async function toggle(id, emoji, on){
  if (!await needLogin()) return;
  const m = N.rows.find(x => String(x.id) === String(id)); if (!m) return;
  // 先に見た目を変えてから送る
  const list = m.reactions || (m.reactions = []);
  let r = list.find(x => x.e === emoji);
  if (on === undefined) on = !(r && r.me);
  if (on) { if (r && r.me) return; if (r) { r.n++; r.me = true; } else list.push({ e: emoji, n: 1, me: true }); }
  else { if (!r || !r.me) return; r.n--; r.me = false; if (r.n <= 0) list.splice(list.indexOf(r), 1); }
  render(true);
  const { error } = on
    ? await N.sb.from('notice_reactions').insert({ notice_id: m.id, emoji })
    : await N.sb.from('notice_reactions').delete().eq('notice_id', m.id).eq('emoji', emoji).eq('user_id', N.me.id);
  if (error && !/duplicate/i.test(error.message)) say('リアクションできませんでした');
  loadFeed(true);
}
function closePick(){ q('.nt-pick')?.remove(); }
// 絵文字の一覧（大きいので、初めて開いた時に読み込む）
function loadEmoji(){
  if (window.NT_EMOJI) return Promise.resolve(window.NT_EMOJI);
  return loadEmoji.p || (loadEmoji.p = new Promise((ok, ng) => {
    const s = document.createElement('script'); s.src = 'notice-emoji.js';
    s.onload = () => ok(window.NT_EMOJI); s.onerror = () => { loadEmoji.p = null; ng(new Error('絵文字を読み込めませんでした')); };
    document.head.appendChild(s);
  }));
}
const getRecent = () => { try { const r = JSON.parse(localStorage.getItem('mydon-nt-recent') || '[]'); return r.length ? r : QUICK; } catch { return QUICK; } };
const addRecent = e => { const r = [e, ...getRecent().filter(x => x !== e)].slice(0, 16); try { localStorage.setItem('mydon-nt-recent', JSON.stringify(r)); } catch {} };
let GROUPS = null;   // [[アイコン, 名前, [[絵文字, 名前・タグ], …]], …]
async function openPick(btn, id){
  closePick();
  const el = document.createElement('div'); el.className = 'nt-pick'; el.dataset.id = id;
  el.setAttribute('role', 'dialog'); el.setAttribute('aria-label', '絵文字を選ぶ');
  el.innerHTML = `<div class="pk-top"><input type="search" placeholder="絵文字を探す（例：すし、ハート）" aria-label="絵文字を探す" autocomplete="off"></div>
    <div class="pk-cats"></div><div class="pk-grid"><p class="pk-none">読み込み中…</p></div>
    <div class="pk-foot"><span class="e"></span><span class="l">絵文字を選んで下さい</span></div>`;
  document.body.appendChild(el);
  if (innerWidth > 560) {
    const r = btn.getBoundingClientRect();
    el.style.left = Math.max(8, Math.min(r.left, innerWidth - el.offsetWidth - 8)) + 'px';
    const h = el.offsetHeight;
    el.style.top = (r.bottom + 6 + h <= innerHeight - 8 ? r.bottom + 6 : r.top - h - 6 >= 8 ? r.top - h - 6 : Math.max(8, innerHeight - h - 8)) + 'px';
  }
  const grid = el.querySelector('.pk-grid'), inp = el.querySelector('input'), foot = el.querySelector('.pk-foot');
  const btns = list => `<div class="pk-g">${list.map(([e, l]) => `<button type="button" data-q="${esc(e)}" data-l="${esc(l.split(' ')[0])}" aria-label="${esc(l.split(' ')[0])}">${esc(e)}</button>`).join('')}</div>`;
  const pick = e => { addRecent(e); closePick(); toggle(id, e, true); };
  el.addEventListener('click', e => {
    const b = e.target.closest('[data-q]'); if (b) { pick(b.dataset.q); return; }
    const c = e.target.closest('[data-cat]'); if (c) { const h = grid.querySelector(`[data-h="${c.dataset.cat}"]`); if (h) grid.scrollTop = h.offsetTop - 2; }
  });
  el.addEventListener('pointerover', e => { const b = e.target.closest('[data-q]'); if (b) { foot.querySelector('.e').textContent = b.dataset.q; foot.querySelector('.l').textContent = b.dataset.l || ''; } });
  inp.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); const first = grid.querySelector('[data-q]'); if (first) pick(first.dataset.q); } });
  try {
    const raw = await loadEmoji();
    GROUPS = GROUPS || raw.map(([icon, name, s]) => [icon, name, s.split(';').map(x => x.split('|'))]);
  } catch (ex) { grid.innerHTML = `<p class="pk-none">${esc(ex.message)}</p>`; return; }
  if (!el.isConnected) return;
  const recent = getRecent().map(e => [e, GROUPS.flatMap(g => g[2]).find(x => x[0] === e)?.[1] || e]);
  el.querySelector('.pk-cats').innerHTML = `<button type="button" data-cat="r" title="よく使う" aria-label="よく使う">🕘</button>` + GROUPS.map((g, i) => `<button type="button" data-cat="${i}" title="${esc(g[1])}" aria-label="${esc(g[1])}">${g[0]}</button>`).join('');
  const all = () => `<h4 data-h="r">よく使う</h4>${btns(recent)}` + GROUPS.map((g, i) => `<h4 data-h="${i}">${esc(g[1])}</h4>${btns(g[2])}`).join('');
  grid.innerHTML = all();
  // 探す：名前・タグで。絵文字そのものを入れた時は、それを出す
  inp.addEventListener('input', () => {
    const v = inp.value.trim().normalize('NFKC').toLowerCase();
    if (!v) { grid.innerHTML = all(); return; }
    const hit = GROUPS.flatMap(g => g[2]).filter(([e, l]) => e === v || l.toLowerCase().includes(v)).slice(0, 200);
    if (!hit.length && okEmoji(inp.value.trim())) hit.push([inp.value.trim(), 'この絵文字']);
    grid.innerHTML = hit.length ? btns(hit) : '<p class="pk-none">見つかりません。<br>絵文字キーボードで入れることもできます</p>';
  });
  if (innerWidth > 560) inp.focus();
}
document.addEventListener('pointerdown', e => { if (q('.nt-pick') && !e.target.closest('.nt-pick') && !e.target.closest('[data-add]')) closePick(); }, true);
q('#ntList').addEventListener('click', async e => {
  if (e.target.id === 'ntOlder') { loadOlder(); return; }
  const msg = e.target.closest('.nt-msg'); if (!msg) return;
  const id = msg.dataset.id;
  const r = e.target.closest('.nt-r'); if (r) { toggle(id, r.dataset.e); return; }
  const add = e.target.closest('[data-add]'); if (add) { if (q('.nt-pick')?.dataset.id === id) { closePick(); return; } if (await needLogin()) openPick(add, id); return; }
  if (e.target.closest('[data-edit]')) { N.editing = Number(id); render(true); q('.nt-edit textarea')?.focus(); return; }
  if (e.target.closest('[data-ecancel]')) { N.editing = null; render(true); return; }
  if (e.target.closest('[data-esave]')) {
    const v = msg.querySelector('.nt-edit textarea').value.trim(); if (!v) return;
    const { error } = await N.sb.from('notices').update({ body: v }).eq('id', id);
    if (error) { say('編集できませんでした'); return; }
    N.editing = null; await loadFeed(true); return;
  }
  if (e.target.closest('[data-del]')) {
    if (!confirm('このお知らせを削除しますか？（元に戻せません）')) return;
    const { error } = await N.sb.from('notices').delete().eq('id', id);
    if (error) { say('削除できませんでした'); return; }
    await loadFeed(true); checkLatest(); return;
  }
  if (e.target.closest('a,textarea,button')) return;
  // スマホ：押すと「編集・削除」や ☺︎+ が出る
  document.querySelectorAll('.nt-msg.sel').forEach(x => { if (x !== msg) x.classList.remove('sel'); });
  msg.classList.toggle('sel');
});

// ---- 管理者：書く ----
const grow = t => { t.style.height = 'auto'; t.style.height = Math.min(t.scrollHeight, 140) + 'px'; };
q('#ntText').addEventListener('input', e => grow(e.target));
q('#ntText').addEventListener('keydown', e => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); q('#ntCompose').requestSubmit(); } });
q('#ntCompose').addEventListener('submit', async e => {
  e.preventDefault();
  const v = q('#ntText').value.trim(); if (!v || !N.admin) return;
  const { error } = await N.sb.from('notices').insert({ channel: N.ch, body: v });
  if (error) { say('投稿できませんでした：' + error.message); return; }
  q('#ntText').value = ''; grow(q('#ntText'));
  await loadFeed(); checkLatest();
});

// ---- ログイン・新規登録（依頼ページと同じアカウント） ----
const enc = new TextEncoder();
const b64 = u8 => { let s = ''; for (const c of new Uint8Array(u8)) s += String.fromCharCode(c); return btoa(s); };
async function nameHash(name){ return [...new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(name)))].map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 40); }
const cleanName = s => String(s || '').normalize('NFKC').trim();
// 依頼ページで使う暗号の鍵も、ここで一緒に作っておく
async function newIdentity(password){
  const ECDH = { name: 'ECDH', namedCurve: 'P-256' };
  const kp = await crypto.subtle.generateKey(ECDH, true, ['deriveKey']);
  const pub = await crypto.subtle.exportKey('jwk', kp.publicKey);
  const pkcs8 = await crypto.subtle.exportKey('pkcs8', kp.privateKey);
  const salt = crypto.getRandomValues(new Uint8Array(16)), iv = crypto.getRandomValues(new Uint8Array(12));
  const base = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveKey']);
  const wk = await crypto.subtle.deriveKey({ name: 'PBKDF2', salt, iterations: 310000, hash: 'SHA-256' }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, wk, pkcs8);
  return { pubkey: { kty: pub.kty, crv: pub.crv, x: pub.x, y: pub.y }, privkey_enc: { salt: b64(salt), iv: b64(iv), ct: b64(ct) } };
}
function setLoginTab(up){
  N.signup = up;
  q('#ntTabIn').setAttribute('aria-pressed', !up); q('#ntTabUp').setAttribute('aria-pressed', up);
  q('#ntPass2Row').hidden = !up; q('#ntPass2').required = up;
  q('#ntPass').autocomplete = up ? 'new-password' : 'current-password';
  q('#ntLoginH').textContent = up ? '新規登録' : 'ログイン'; q('#ntLoginGo').textContent = up ? '登録する' : 'ログイン';
  q('#ntErr').textContent = '';
}
function showLogin(){ setLoginTab(false); q('#ntLogin').hidden = false; q('#ntName').focus(); }
q('#ntTabIn').onclick = () => setLoginTab(false);
q('#ntTabUp').onclick = () => setLoginTab(true);
q('#ntLoginNo').onclick = () => { q('#ntLogin').hidden = true; };
q('#ntLogin').addEventListener('click', e => { if (e.target.id === 'ntLogin') q('#ntLogin').hidden = true; });
q('#ntLoginForm').addEventListener('submit', async e => {
  e.preventDefault();
  const name = cleanName(q('#ntName').value), pass = q('#ntPass').value, err = q('#ntErr');
  if (!name || /\s/.test(name)) { err.textContent = 'ユーザー名に空白は使えません。'; return; }
  if ([...name].length > 20) { err.textContent = 'ユーザー名は20文字までです。'; return; }
  if (pass.length < 8) { err.textContent = 'パスワードは8文字以上にして下さい。'; return; }
  const form = q('#ntLoginForm'); form.style.opacity = '.6'; form.style.pointerEvents = 'none';
  try {
    const sb = await loadSb();
    if (N.signup) {
      if (pass !== q('#ntPass2').value) throw new Error('パスワードが一致しません。');
      const { data: taken } = await sb.rpc('username_taken', { name });
      if (taken) throw new Error('そのユーザー名はもう使われています。');
      const h = await nameHash(name);
      let res;
      for (const d of MAIL_DOMAINS) { res = await sb.auth.signUp({ email: `u${h}@${d}`, password: pass }); if (!res.error || !/invalid/i.test(res.error.message)) break; }
      if (res.error) throw new Error(/registered|exists/i.test(res.error.message) ? 'そのユーザー名はもう使われています。' : '登録できませんでした：' + res.error.message);
      if (!res.data.session) throw new Error('登録できましたが、ログインできませんでした。');
      const idn = await newIdentity(pass);
      const { error } = await sb.from('profiles').insert({ id: res.data.user.id, username: name, pubkey: idn.pubkey, privkey_enc: idn.privkey_enc });
      if (error) throw new Error('登録できませんでした：' + error.message);
    } else {
      let h = null;
      try { const { data } = await sb.rpc('login_hash_for', { name }); h = data; } catch {}
      h = h || await nameHash(name);
      let res;
      for (const d of MAIL_DOMAINS) { res = await sb.auth.signInWithPassword({ email: `u${h}@${d}`, password: pass }); if (!res.error) break; }
      if (res.error) throw new Error('ユーザー名かパスワードが違います。');
    }
    q('#ntPass').value = ''; q('#ntPass2').value = ''; q('#ntLogin').hidden = true;
    await refreshMe(); await loadFeed(true);
    say(N.signup ? '登録しました' : 'ログインしました');
  } catch (ex) { err.textContent = ex.message; }
  finally { form.style.opacity = ''; form.style.pointerEvents = ''; }
});

// ---- はじめ ----
// 今は試験中なので、#admin で開いた時だけベルを出す
const ON = () => location.hash === '#admin';
function sync(){ bell.hidden = !ON(); if (!ON() && N.open) closePop(); if (ON()) checkLatest(); }
addEventListener('hashchange', sync);
sync();
setInterval(() => { if (ON() && !document.hidden && !N.open) checkLatest(); }, 120000);
})();
