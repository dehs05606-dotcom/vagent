module vagent

import net.http
import net.urllib
import time

// web.v — the two real-time tools: fetch a URL, and search the web.

const web_user_agent = 'Mozilla/5.0 (X11; Linux x86_64) FullAgent/1.0'
const web_timeout = 30 * time.second

fn web_get(url string) !http.Response {
	mut req := http.Request{
		url:            url
		method:         .get
		read_timeout:   web_timeout
		write_timeout:  web_timeout
		user_agent:     web_user_agent
		allow_redirect: true
	}
	req.add_header(.user_agent, web_user_agent)
	return req.do()
}

fn web_post_form(url string, form map[string]string, user_agent string) !http.Response {
	mut body := []string{}
	for k, v in form {
		body << '${urllib.query_escape(k)}=${urllib.query_escape(v)}'
	}
	mut req := http.Request{
		url:            url
		method:         .post
		data:           body.join('&')
		read_timeout:   web_timeout
		write_timeout:  web_timeout
		user_agent:     user_agent
		allow_redirect: true
	}
	req.add_header(.content_type, 'application/x-www-form-urlencoded')
	req.add_header(.user_agent, user_agent)
	return req.do()
}

// strip_html turns a page into readable text: scripts and styles go
// entirely, tags collapse to a space, and runs of blank space collapse.
fn strip_html(html string) string {
	script_style := compile_regex_flags(r'<script[\s\S]*?</script>|<style[\s\S]*?</style>',
		RxFlags{ ignore_case: true, dotall: true }) or { return html }
	tags := compile_regex('<[^>]+>') or { return html }
	spaces := compile_regex('[ \t]+') or { return html }
	blanks := compile_regex_flags(r'\n\s*\n+', RxFlags{ dotall: true }) or { return html }
	mut text := script_style.replace_all(html, '')
	text = tags.replace_all(text, ' ')
	text = spaces.replace_all(text, ' ')
	text = blanks.replace_all(text, '\n')
	return text
}

// unescape_entities decodes the handful of HTML entities that show up in
// search-result titles and snippets. Leaving them raw puts `&amp;` in front
// of the model as if it were content.
fn unescape_entities(s string) string {
	mut out := s.replace('&quot;', '"').replace('&#x27;', "'").replace('&#39;', "'")
	out = out.replace('&lt;', '<').replace('&gt;', '>').replace('&nbsp;', ' ')
	// `&amp;` last, so `&amp;lt;` does not become `<`
	return out.replace('&amp;', '&')
}

// tool_web_fetch fetches a URL and returns its text content.
pub fn tool_web_fetch(url string) string {
	if url.trim_space() == '' {
		return 'ERROR: url is required'
	}
	resp := web_get(url) or { return 'ERROR: ${err.msg()}' }
	if resp.status_code >= 400 {
		return 'ERROR: HTTP ${resp.status_code} ${resp.status_msg}'
	}
	ctype := resp.header.get(.content_type) or { '' }
	mut text := resp.body
	if ctype.to_lower().contains('html') {
		text = strip_html(text)
	}
	return clip_middle(unescape_entities(text).trim_space(), 16_000)
}

struct SearchHit {
	title   string
	url     string
	snippet string
}

// ddg_search runs a DuckDuckGo HTML search.
fn ddg_search(query string) ![]SearchHit {
	resp := web_post_form('https://html.duckduckgo.com/html/', {
		'q': query
	}, web_user_agent)!
	if resp.status_code >= 400 {
		return error('HTTP ${resp.status_code}')
	}
	link_re := compile_regex_flags(r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
		RxFlags{ dotall: true })!
	snip_re := compile_regex_flags(r'class="result__snippet"[^>]*>([\s\S]*?)</a>',
		RxFlags{ dotall: true })!
	tag_re := compile_regex('<[^>]+>')!
	uddg_re := compile_regex('uddg=([^&]+)')!

	links := link_re.find_all(resp.body)
	snips := snip_re.find_all(resp.body)
	mut out := []SearchHit{}
	for i, m in links {
		mut href := group_text(resp.body, &m, 1)
		title := unescape_entities(tag_re.replace_all(group_text(resp.body, &m, 2),
			'').trim_space())
		snippet := if i < snips.len {
			unescape_entities(tag_re.replace_all(group_text(resp.body, &snips[i], 1),
				'').trim_space())
		} else {
			''
		}
		// DuckDuckGo wraps every result in a redirector; the real URL is the
		// percent-encoded `uddg` parameter
		if um := uddg_re.search(href) {
			href = urllib.query_unescape(group_text(href, &um, 1)) or { href }
		}
		out << SearchHit{
			title:   title
			url:     unescape_entities(href)
			snippet: snippet
		}
	}
	return out
}

// bing_search is the HTML fallback when DuckDuckGo returns nothing.
fn bing_search(query string) ![]SearchHit {
	url := 'https://www.bing.com/search?q=${urllib.query_escape(query)}&count=10'
	ua := 'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0'
	mut req := http.Request{
		url:            url
		method:         .get
		read_timeout:   web_timeout
		write_timeout:  web_timeout
		user_agent:     ua
		allow_redirect: true
	}
	req.add_header(.user_agent, ua)
	resp := req.do()!
	if resp.status_code >= 400 {
		return error('HTTP ${resp.status_code}')
	}
	block_re := compile_regex_flags(r'<li class="b_algo"[\s\S]*?</li>',
		RxFlags{ dotall: true })!
	head_re := compile_regex_flags(r'<h2><a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
		RxFlags{ dotall: true })!
	para_re := compile_regex_flags(r'<p[^>]*>([\s\S]*?)</p>', RxFlags{ dotall: true })!
	tag_re := compile_regex('<[^>]+>')!

	mut out := []SearchHit{}
	for block in block_re.find_all(resp.body) {
		body := block.text
		hm := head_re.search(body) or { continue }
		url_hit := group_text(body, &hm, 1)
		title := unescape_entities(tag_re.replace_all(group_text(body, &hm, 2), '').trim_space())
		mut snippet := ''
		if pm := para_re.search(body) {
			snippet = unescape_entities(tag_re.replace_all(group_text(body, &pm, 1),
				'').trim_space())
		}
		out << SearchHit{
			title:   title
			url:     unescape_entities(url_hit)
			snippet: snippet
		}
	}
	return out
}

// tool_web_search is a real-time web search. Tries DuckDuckGo, then Bing;
// returns the top results with titles, URLs and snippets, stamped with the
// retrieval time so the data's freshness is explicit.
pub fn tool_web_search(query string) string {
	if query.trim_space() == '' {
		return 'ERROR: query is required'
	}
	mut errors := []string{}
	mut results := []SearchHit{}

	if hits := ddg_search(query) {
		results = hits.clone()
	} else {
		errors << 'DuckDuckGo: ${err.msg()}'
	}
	if results.len == 0 {
		if hits := bing_search(query) {
			results = hits.clone()
		} else {
			errors << 'Bing: ${err.msg()}'
		}
	}
	if results.len == 0 {
		detail := if errors.len > 0 { errors.join('; ') } else { 'no results' }
		return 'ERROR: all search engines failed — ${detail}'
	}

	now := time.now()
	stamp := '${now.year:04}-${now.month:02}-${now.day:02} ' +
		'${now.hour:02}:${now.minute:02}:${now.second:02}'
	mut lines := ["web search: '${query}'  (retrieved ${stamp}, live results)"]
	mut n := 0
	for hit in results {
		if n >= 8 {
			break
		}
		n++
		lines << '${n}. ${hit.title}\n   ${hit.url}\n   ${clip_plain(hit.snippet, 220)}'
	}
	return lines.join('\n')
}
