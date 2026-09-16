module vagent

import net
import x.json2

// tower.v — the web control tower: mission control in a browser tab.
//
// A real HTTP server streaming the whole agent's world to a dark,
// self-contained single-page dashboard:
//
//     /api/state      the live snapshot — cost, tokens, tool calls, errors,
//                     crew roster, brain, branches — one JSON, one poll
//     /api/events     the event river: every kernel event since a seq, so
//                     the page paints them as they seal
//     /api/timeline   the scrubber strip, from the theater's frames
//     /api/frame      one frame's reconstructed state
//     /api/command    POST {"text": "..."} launches a REAL agent turn in
//                     the background, and its events light up the river.
//                     {"sleep": true} runs the brain's consolidation pass.
//
// The page is genuinely self-contained: no CDN, no build step, vanilla JS
// and CSS grid. A dashboard that needs the network to render is not a
// dashboard you can open when the network is the thing that broke.
//
// The server is written directly on TCP rather than through a framework, for
// the same reason the mesh is: the protocol is small enough to read in one
// sitting, and one fewer dependency between the operator and their agent.

const tower_page = '<!doctype html>
<html><head><meta charset="utf-8"><title>FullAgent Control Tower</title>
<style>
:root{--bg:#0d1117;--card:#161b22;--line:#21262d;--fg:#c9d1d9;--dim:#8b949e;
--acc:#58a6ff;--ok:#3fb950;--warn:#d29922;--bad:#f85149;--pink:#bc8cff}
*{box-sizing:border-box;margin:0}
body{background:var(--bg);color:var(--fg);font:14px/1.45 ui-monospace,
Consolas,monospace;padding:18px}
h1{font-size:17px;color:var(--acc);letter-spacing:.5px}
h1 .pulse{display:inline-block;width:9px;height:9px;border-radius:50%;
background:var(--ok);margin-right:8px;animation:p 1.6s infinite}
@keyframes p{0%,100%{opacity:1}50%{opacity:.25}}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
gap:10px;margin:14px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:9px;
padding:10px 12px}
.card .v{font-size:21px;color:var(--fg)}
.card .l{font-size:11px;color:var(--dim);text-transform:uppercase;
letter-spacing:.6px}
.cols{display:grid;grid-template-columns:1.4fr 1fr;gap:12px}
@media(max-width:900px){.cols{grid-template-columns:1fr}}
.panel{background:var(--card);border:1px solid var(--line);border-radius:9px;
padding:12px;min-height:220px;overflow:auto;max-height:46vh}
.panel h2{font-size:12px;color:var(--dim);text-transform:uppercase;
letter-spacing:.6px;margin-bottom:8px}
#river div{padding:2px 6px;border-left:2px solid var(--line);margin:3px 0;
animation:in .4s ease}
@keyframes in{from{background:#1c2432}to{background:transparent}}
#river .seq{color:var(--dim);margin-right:8px}
#river .t{color:var(--acc)}
#river .u{color:var(--fg)}
#river .err{border-left-color:var(--bad)}
#river .ok{border-left-color:var(--ok)}
#tl{display:flex;gap:3px;flex-wrap:wrap;margin-top:8px}
#tl i{width:9px;height:16px;border-radius:2px;background:var(--acc);
cursor:pointer;opacity:.75}
#tl i:hover{opacity:1;outline:1px solid var(--pink)}
form{display:flex;gap:8px;margin-top:12px}
input{flex:1;background:var(--card);border:1px solid var(--line);
border-radius:7px;color:var(--fg);padding:9px 12px;font:inherit}
button{background:#1f6feb;border:none;border-radius:7px;color:#fff;
padding:9px 16px;font:inherit;cursor:pointer}
button:hover{background:#388bfd}
.muted{color:var(--dim)} .ok{color:var(--ok)} .bad{color:var(--bad)}
.pink{color:var(--pink)}
</style></head><body>
<h1><span class="pulse"></span>FULLAGENT CONTROL TOWER
<span class="muted" id="branch"></span></h1>
<div class="grid" id="cards"></div>
<div class="cols">
 <div class="panel"><h2>Event river — live</h2><div id="river"></div></div>
  <div><div class="panel"><h2>Crew / brain</h2><div id="crew"
  class="muted">—</div></div>
 <div class="panel" style="margin-top:12px"><h2>Timeline scrubber</h2>
  <div id="tl"></div><div id="frame" class="muted" style="margin-top:8px">
  click a bar to inspect the frame</div></div></div>
</div>
<form id="cmd"><input id="txt" placeholder="command the agent… (real turn)">
<button>SEND</button></form>
<script>
let lastSeq=-1;
const \$=id=>document.getElementById(id);
const esc=s=>String(s).replace(/[&<>"]/g,c=>({\x27&\x27:\x27&amp;\x27,\x27<\x27:\x27&lt;\x27,
\x27>\x27:\x27&gt;\x27,\x27"\x27:\x27&quot;\x27}[c]));
async function pollState(){try{const r=await fetch(\x27/api/state\x27);
const s=await r.json();const c=s.cards||{};
\$(\x27cards\x27).innerHTML=[[\x27cost\x27,s.cost],[\x27tokens\x27,s.tokens],
[\x27tool calls\x27,s.tool_calls],[\x27errors\x27,s.errors],[\x27messages\x27,s.messages],
[\x27files\x27,s.files],[\x27crew agents\x27,s.crew_agents],[\x27branches\x27,s.branches]]
.map(([l,v])=>`<div class="card"><div class="v">\${esc(v)}</div>
<div class="l">\${l}</div></div>`).join(\x27\x27);
\$(\x27branch\x27).textContent=\x27 · \x27+s.branch;
\$(\x27crew\x27).innerHTML=(s.crew||[]).map(a=>`\${a.icon} <b>\${esc(a.nickname)}
</b> <span class="muted">(\${a.role})</span> \${a.state===\x27done\x27?
\x27<span class=ok>✓</span>\x27:a.state===\x27error\x27?\x27<span class=bad>✗</span>\x27:
a.state}</>`).join(\x27<br>\x27)||\x27crew is idle\x27;
if(s.brain)\$(\x27crew\x27).innerHTML+=`<br><span class="pink">brain:</span>
\${s.brain}`;}catch(e){}}
async function pollEvents(){try{const r=await fetch(
\x27/api/events?since=\x27+lastSeq);const evs=await r.json();
for(const e of evs){lastSeq=Math.max(lastSeq,e.seq);
const d=document.createElement(\x27div\x27);
d.className=e.type.includes(\x27error\x27)||e.type.includes(\x27fail\x27)?\x27err\x27:
(e.type.includes(\x27done\x27)||e.type.includes(\x27pass\x27))?\x27ok\x27:\x27\x27;
d.innerHTML=`<span class="seq">\${e.seq}</span><span class="t">
\${esc(e.type)}</span> <span class="u">\${esc(e.summary||\x27\x27)}</span>`;
\$(\x27river\x27).prepend(d);}
if(evs.length)drawTimeline();}catch(e){}}
async function drawTimeline(){try{const r=await fetch(\x27/api/timeline\x27);
const f=await r.json();\$(\x27tl\x27).innerHTML=f.frames.slice(-120).map(x=>
`<i title="\${x.seq} \${esc(x.type)}" data-s="\${x.seq}"></i>`).join(\x27\x27);
[...\$(\x27tl\x27).children].forEach(i=>i.onclick=async()=>{const r=await fetch(
\x27/api/frame?seq=\x27+i.dataset.s);const fr=await r.json();
\$(\x27frame\x27).innerHTML=`<b class="pink">seq \${fr.seq}</b> \${esc(fr.type)}
<br><span class="muted">\${esc(fr.summary||\x27\x27)}</span><br>msgs
\${fr.messages} · tools \${fr.tool_calls} · cost \$\${fr.cost}`;});}
catch(e){}}
\$(\x27cmd\x27).onsubmit=async ev=>{ev.preventDefault();const t=\$(\x27txt\x27).value.
trim();if(!t)return;\$(\x27txt\x27).value=\x27\x27;await fetch(\x27/api/command\x27,
{method:\x27POST\x27,headers:{\x27Content-Type\x27:\x27application/json\x27},
body:JSON.stringify({text:t})});};
pollState();pollEvents();drawTimeline();
setInterval(pollState,2000);setInterval(pollEvents,1200);
</script></body></html>'

// the HTTP request ceiling: a dashboard command is a sentence, not a payload
const tower_request_limit = 1 << 20

// TurnRunner launches a real agent turn. It is injectable so the tower can
// be stood up — and tested — before an agent is attached to it.
pub type TurnRunner = fn (text string)

@[heap]
pub struct Tower {
pub mut:
	log    &EventLog
	host   string = '127.0.0.1'
	port   int
	url    string
	crew   &Crew      = unsafe { nil }
	brain  &Brain     = unsafe { nil }
	runner TurnRunner = unsafe { nil }
mut:
	listener &net.TcpListener = unsafe { nil }
	serving  bool
}

pub fn new_tower(log &EventLog) &Tower {
	return &Tower{
		log: unsafe { log }
	}
}

// -- state assembly ---------------------------------------------------------------

pub fn (mut t Tower) state() map[string]json2.Any {
	st := fold(mut t.log, t.log.branch)
	mut crew_rows := []json2.Any{}
	if t.crew != unsafe { nil } {
		mut agents := t.crew.list()
		if agents.len > 12 {
			agents = agents[..12].clone()
		}
		for a in agents {
			mut row := a.to_json()
			row['icon'] = json2.Any(a.icon())
			crew_rows << json2.Any(row)
		}
	}
	mut brain_txt := ''
	if t.brain != unsafe { nil } {
		s := t.brain.stats()
		brain_txt = '${s.total} memories · ${s.alive} alive · retention ' + '${round_to(s.avg_retention, 3)}'
	}
	return {
		'branch':      json2.Any(t.log.branch)
		'cost':        json2.Any('\$${st.cost_usd:.4f}')
		'tokens':      json2.Any(thousands(st.tokens_in + st.tokens_out))
		'tool_calls':  json2.Any(st.tool_calls)
		'errors':      json2.Any(st.tool_errors)
		'messages':    json2.Any(st.messages.len)
		'files':       json2.Any(st.files_touched.len)
		'crew_agents': json2.Any(crew_rows.len)
		'branches':    json2.Any(t.log.branches().len)
		'crew':        json2.Any(crew_rows)
		'brain':       json2.Any(brain_txt)
	}
}

// -- commands -------------------------------------------------------------------------

// command runs a REAL agent turn in the background, so its events light up
// the river while the request returns at once.
pub fn (mut t Tower) command(payload map[string]json2.Any) map[string]json2.Any {
	if jbool(payload, 'sleep') {
		if t.brain == unsafe { nil } {
			return {
				'ok':    json2.Any(false)
				'error': json2.Any('no brain attached')
			}
		}
		stats := t.brain.sleep()
		return {
			'ok':    json2.Any(true)
			'slept': json2.Any({
				'merged':    json2.Any(stats.merged)
				'distilled': json2.Any(stats.distilled)
				'promoted':  json2.Any(stats.promoted)
				'forgotten': json2.Any(stats.forgotten)
			})
		}
	}
	text := jstr(payload, 'text').trim_space()
	if text == '' {
		return {
			'ok':    json2.Any(false)
			'error': json2.Any('empty command')
		}
	}
	if t.runner == unsafe { nil } {
		return {
			'ok':    json2.Any(false)
			'error': json2.Any('no agent attached')
		}
	}
	spawn t.runner(text)
	return {
		'ok':       json2.Any(true)
		'launched': json2.Any(clip_plain(text, 100))
	}
}

// -- routing --------------------------------------------------------------------------

struct HttpReply {
	status       int    = 200
	content_type string = 'application/json'
	body         string
}

fn json_reply(obj map[string]json2.Any, status int) HttpReply {
	return HttpReply{
		status: status
		body:   json2.encode(json2.Any(obj.clone()))
	}
}

// route answers one request. It is a pure-ish function of the path and body,
// so the whole API can be exercised without a socket.
pub fn (mut t Tower) route(method string, path string, body string) HttpReply {
	if method == 'POST' {
		if path != '/api/command' {
			return json_reply({
				'error': json2.Any('not found')
			}, 404)
		}
		parsed := json2.decode[json2.Any](if body != '' { body } else { '{}' }) or {
			return json_reply({
				'error': json2.Any('bad json')
			}, 400)
		}
		if parsed !is map[string]json2.Any {
			// command() reads keys off the payload; an array or a string
			// body would fail inside the handler and close the connection
			// with no response at all
			return json_reply({
				'error': json2.Any('payload must be a JSON object')
			}, 400)
		}
		return json_reply(t.command(parsed.as_map()), 200)
	}
	if method != 'GET' {
		return json_reply({
			'error': json2.Any('not found')
		}, 404)
	}

	if path == '/' || path.starts_with('/index') {
		return HttpReply{
			content_type: 'text/html; charset=utf-8'
			body:         tower_page
		}
	}
	if path == '/api/state' {
		return json_reply(t.state(), 200)
	}
	if path.starts_with('/api/events') {
		since := query_int(path, 'since', -1)
		mut evs := []json2.Any{}
		for ev in t.log.events(t.log.branch) {
			if ev.seq <= since {
				continue
			}
			evs << json2.Any({
				'seq':     json2.Any(ev.seq)
				'type':    json2.Any(ev.typ)
				'actor':   json2.Any(ev.actor)
				'summary': json2.Any(frame_summary(&ev))
			})
		}
		if evs.len > 200 {
			evs = evs[evs.len - 200..].clone()
		}
		return json_reply({
			'events': json2.Any(evs)
		}, 200)
	}
	if path.starts_with('/api/timeline') {
		mut theater := new_theater(t.log)
		mut frames := theater.frames(t.log.branch)
		if frames.len > 120 {
			frames = frames[frames.len - 120..].clone()
		}
		return json_reply({
			'frames': json2.Any(frames.map(json2.Any(it.to_json())))
		}, 200)
	}
	if path.starts_with('/api/frame') {
		seq := query_int(path, 'seq', -999)
		if seq == -999 {
			return json_reply({
				'error': json2.Any('bad seq')
			}, 400)
		}
		mut theater := new_theater(t.log)
		f := theater.frame(seq) or {
			return json_reply({
				'error': json2.Any('no such frame')
			}, 404)
		}
		return json_reply({
			'seq':        json2.Any(f.seq)
			'type':       json2.Any(f.typ)
			'summary':    json2.Any(f.summary)
			'messages':   json2.Any(f.state.messages)
			'tool_calls': json2.Any(f.state.tool_calls)
			'cost':       json2.Any(f.state.cost_usd)
		}, 200)
	}
	return json_reply({
		'error': json2.Any('not found')
	}, 404)
}

// query_int reads one integer query parameter, falling back when it is
// absent or not a number.
fn query_int(path string, key string, fallback int) int {
	marker := '${key}='
	idx := path.index(marker) or { return fallback }
	mut raw := path[idx + marker.len..]
	if amp := raw.index('&') {
		raw = raw[..amp]
	}
	if !is_int_text(raw) {
		return fallback
	}
	return raw.int()
}

// -- the server -------------------------------------------------------------------------

// start binds the port and serves on a background thread, returning the URL.
// Port 0 asks the OS for a free one.
pub fn (mut t Tower) start(port int) !string {
	if t.serving {
		return t.url
	}
	mut listener := net.listen_tcp(.ip, '${t.host}:${port}')!
	addr := listener.addr()!
	t.listener = listener
	t.port = int(addr.port()!)
	t.url = 'http://${t.host}:${t.port}'
	t.serving = true
	// The tower writes nothing of its own. It is an observer, and an
	// observer that seals its own arrival has already shifted every seq
	// the page is about to display.
	spawn t.accept_loop()
	return t.url
}

fn (mut t Tower) accept_loop() {
	for {
		if !t.serving {
			return
		}
		mut conn := t.listener.accept() or { return }
		spawn t.serve_conn(mut conn)
	}
}

fn (mut t Tower) serve_conn(mut conn net.TcpConn) {
	defer {
		conn.close() or {}
	}
	request_line := conn.read_line_max(tower_request_limit).trim_right('\r\n')
	if request_line == '' {
		return
	}
	parts := request_line.split(' ')
	if parts.len < 2 {
		return
	}
	method := parts[0].to_upper()
	path := parts[1]

	// headers, to the blank line; only the length matters here
	mut content_length := 0
	for {
		header := conn.read_line_max(tower_request_limit).trim_right('\r\n')
		if header == '' {
			break
		}
		lower := header.to_lower()
		if lower.starts_with('content-length:') {
			raw := header.all_after_first(':').trim_space()
			if is_int_text(raw) {
				content_length = raw.int()
			}
		}
	}

	mut body := ''
	if content_length > 0 && content_length <= tower_request_limit {
		mut buf := []u8{len: content_length}
		mut read := 0
		for read < content_length {
			n := conn.read(mut buf[read..]) or { break }
			if n <= 0 {
				break
			}
			read += n
		}
		body = buf[..read].bytestr()
	}

	reply := t.route(method, path, body)
	conn.write_string(render_http(reply)) or {}
}

fn render_http(reply &HttpReply) string {
	return 'HTTP/1.1 ${reply.status} ${http_status_text(reply.status)}\r\n' + 'Content-Type: ${reply.content_type}\r\n' + 'Content-Length: ${reply.body.len}\r\n' + 'Connection: close\r\n\r\n' + reply.body
}

fn http_status_text(code int) string {
	return match code {
		200 { 'OK' }
		400 { 'Bad Request' }
		404 { 'Not Found' }
		else { 'OK' }
	}
}

pub fn (mut t Tower) stop() {
	if !t.serving {
		return
	}
	t.serving = false
	t.listener.close() or {}
}
