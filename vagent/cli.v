module vagent

// cli.v — the headless subcommands (Appendix A).
//
// These operate on the persistent event log without launching the UI. They
// exist because the log is the product: an integrity check, a replay, a
// rewind and a causal chain are all things you want from a script, a CI
// step or a postmortem, not only from a session you happen to have open.
//
// As with the slash router, nothing here prints. run_headless returns the
// lines, the diagnostics and the exit code, and the entry point is the only
// place that writes to a stream — so the whole surface is testable, and a
// command's exit code is asserted rather than eyeballed.

pub const cli_usage = 'Entry point: vagent

Interactive TUI by default; headless subcommands (Appendix A) operate on
the persistent event log without launching the UI:

    vagent                     launch the interactive TUI
    vagent verify-log          Merkle integrity check of the log
    vagent replay              replay the session log as a text film
    vagent rewind <seq>        time travel: files + agent state
    vagent revert <seq>        files only; agent keeps the memory
    vagent cost                spend breakdown from the fold
    vagent why <seq>           causal chain back to the instruction
    vagent goal status         the Goal Compass
    vagent stats               Oracle post-run analysis
    vagent forge               environment digest'

// CliResult is what a headless command produced: normal output, diagnostics
// that belong on stderr, and the process exit code.
pub struct CliResult {
pub mut:
	out  []string
	errs []string
	code int
}

fn cli_ok(lines []string) CliResult {
	return CliResult{
		out: lines
	}
}

fn cli_fail(code int, lines []string) CliResult {
	return CliResult{
		errs: lines
		code: code
	}
}

pub fn (mut a Agent) run_headless(argv []string) CliResult {
	if argv.len == 0 {
		return cli_fail(2, [cli_usage])
	}
	cmd := argv[0]

	match cmd {
		'verify-log' {
			ok, msg := a.log.verify(a.log.branch)
			line := '${if ok { 'OK' } else { 'FAIL' }}: ${msg}'
			// a corrupt log is a non-zero exit: this command exists to be
			// wired into something that checks the exit code
			return if ok { cli_ok([line]) } else { cli_fail(1, [line]) }
		}
		'replay' {
			mut out := []string{}
			for ev in replay(mut a.log, a.log.branch) {
				d := ev.data.clone()
				match ev.typ {
					'user.message', 'assistant.message' {
						who := if ev.typ == 'user.message' { '❯' } else { '◆' }
						out << '[${ev.seq}] ${who} ${cap_at(jstr(d, 'text'), 70)}'
					}
					'tool.call' {
						out << '[${ev.seq}] ⚙ ${jstr(d, 'name')}'
					}
					'tool.result' {
						icon := if jstr(d, 'status') == 'done' { '✓' } else { '✗' }
						out << '[${ev.seq}] ${icon} ${jstr(d, 'name')} (${jstr(d, 'status')})'
					}
					'snapshot.taken' {
						out << '[${ev.seq}] 📸 snapshot ${cap_at(jstr(d, 'tree'), 10)}'
					}
					'clause.proven' {
						out << '[${ev.seq}] ★ clause ${jstr(d, 'clause')} PROVEN'
					}
					'goal.closed' {
						out << '[${ev.seq}] ■ GOAL ${jstr(d, 'state')}'
					}
					else {}
				}
			}
			return cli_ok(out)
		}
		'rewind' {
			if argv.len < 2 {
				return cli_fail(2, ['usage: rewind <seq>'])
			}
			seq := parse_int_strict(argv[1]) or { return cli_fail(2, [
				'usage: rewind <seq>',
			]) }
			new_head, kept := a.rewind_to(seq)
			return cli_ok(['rewound to seq ${new_head} — ${kept} message(s) kept'])
		}
		'revert' {
			if argv.len < 2 {
				return cli_fail(2, ['usage: revert <seq>'])
			}
			seq := parse_int_strict(argv[1]) or { return cli_fail(2, [
				'usage: revert <seq>',
			]) }
			result := a.revert_files_to(seq)
			if 'error' in result {
				return cli_fail(1, ['error: ${jstr(result, 'error')}'])
			}
			return cli_ok([
				'files reverted — ${jint(result, 'restored')} restored, ${jint(result, 'removed')} removed (agent memory kept)',
			])
		}
		'cost' {
			st := a.state()
			mut out := [
				'cost: ${st.cost_summary()}',
				'tool calls: ${st.tool_calls}   errors: ${st.tool_errors}   commands: ${st.commands_run}',
			]
			if st.files_touched.len > 0 {
				out << 'files touched: ' + st.touched_files().join(', ')
			}
			return cli_ok(out)
		}
		'why' {
			if argv.len < 2 {
				return cli_fail(2, ['usage: why <seq>'])
			}
			seq := parse_int_strict(argv[1]) or { return cli_fail(2, [
				'usage: why <seq>',
			]) }
			evs := a.log.events(a.log.branch)
			mut target := Event{}
			mut found := false
			for e in evs {
				if e.seq == seq {
					target = e
					found = true
					break
				}
			}
			if !found {
				return cli_fail(1, ['no event at seq ${seq}'])
			}
			mut out := []string{}
			for i, ev in a.log.why(target.id, 50) {
				indent := '  '.repeat(i)
				clause := if cid := ev.correlation_id { '  [clause ${cid}]' } else { '' }
				out << '${indent}← seq ${ev.seq} ${ev.typ} (${ev.actor}) ${event_preview(ev, 50)}${clause}'
			}
			return cli_ok(out)
		}
		'goal' {
			sub := if argv.len > 1 { argv[1] } else { 'status' }
			if sub == 'status' {
				return cli_ok([a.goal.format()])
			}
			if sub == 'prove' {
				if argv.len < 3 {
					return cli_fail(2, ['usage: goal prove <clause-id>'])
				}
				ok, detail := a.goal.prove_by_predicate(argv[2])
				line := '${if ok { 'PROVEN' } else { 'FAILED' }}: ${detail}'
				return if ok {
					cli_ok([line])
				} else {
					CliResult{
						out:  [line]
						code: 1
					}
				}
			}
			if sub == 'close' {
				result := a.goal.close(true)
				mut out := ['GOAL CLOSED: ${result.state}']
				for r in result.reasons {
					out << '  - ${r}'
				}
				out << result.bundle
				return CliResult{
					out:  out
					code: if result.state == 'ACHIEVED' { 0 } else { 1 }
				}
			}
			return cli_fail(2, ['unknown goal subcommand: ${sub}'])
		}
		'stats' {
			return cli_ok([a.oracle.format_report()])
		}
		'forge' {
			d := a.forge.probe()
			lock_hash := jstr(d, 'lockfile_hash')
			return cli_ok([
				'environment digest: ${jstr(d, 'digest')}',
				'  os ${jstr(d, 'os')} ${jstr(d, 'arch')}   runtime ${jstr(d, 'runtime')}',
				'  cwd ${jstr(d, 'cwd')}',
				'  lockfile ${if lock_hash != '' { lock_hash } else { 'none' }}',
			])
		}
		else {
			return cli_fail(2, ['unknown command: ${cmd}', cli_usage])
		}
	}
}
