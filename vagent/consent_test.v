module vagent

fn a_violation(clause string, path string) Violation {
	return Violation{
		clause: clause
		kind:   'confine_paths'
		detail: 'test'
		path:   path
	}
}

fn test_a_grant_is_scoped_expiring_and_single_use_by_default() {
	mut c := new_consent(new_event_log(tmp_log_path('con1'), 'main', 'test'))
	g := c.grant('1', GrantOpts{
		path:   '/etc/hosts'
		reason: 'one-time migration'
	}) or { panic(err) }
	assert g.uses == 1
	assert g.used == 0
	assert g.live_now()
	assert g.expires_at > now_ts()
	assert g.granted_by == 'human'

	// it speaks only to its own clause and its own path
	assert g.covers('1', '/etc/hosts', '')
	assert !g.covers('2', '/etc/hosts', '')
	assert !g.covers('1', '/etc/passwd', '')
}

fn test_spending_consumes_the_grant() {
	mut c := new_consent(new_event_log(tmp_log_path('con2'), 'main', 'test'))
	c.grant('1', GrantOpts{
		path: '/etc/hosts'
	}) or { panic(err) }

	first := c.spend('1', '/etc/hosts', '') or { panic('the grant did not cover it') }
	assert first.used == 1
	assert c.spent == 1
	// a used single-use grant is gone
	assert c.spend('1', '/etc/hosts', '') == none
	assert c.live().len == 0
}

fn test_a_grant_with_several_uses_runs_out_after_them() {
	mut c := new_consent(new_event_log(tmp_log_path('con3'), 'main', 'test'))
	c.grant('1', GrantOpts{
		path: 'src/a.py'
		uses: 3
	}) or { panic(err) }
	for i in 0 .. 3 {
		assert c.spend('1', 'src/a.py', '') != none, '${i}'
	}
	assert c.spend('1', 'src/a.py', '') == none
	assert c.report().contains('exhausted')
}

fn test_an_unbounded_grant_is_refused_at_creation() {
	mut c := new_consent(new_event_log(tmp_log_path('con4'), 'main', 'test'))
	c.grant('', GrantOpts{}) or {
		assert err.msg().contains('must name the clause')
		c.grant('1', GrantOpts{ ttl: 0.0 }) or {
			assert err.msg().contains('does not expire')
			c.grant('1', GrantOpts{ ttl: max_grant_ttl + 1.0 }) or {
				c.grant('1', GrantOpts{ uses: 0 }) or {
					c.grant('1', GrantOpts{ uses: max_grant_uses + 1 }) or {
						assert err.msg().contains('uses must be between')
						assert c.grants.len == 0
						return
					}
					assert false, 'too many uses must be refused'
					return
				}
				assert false, 'zero uses must be refused'
				return
			}
			assert false, 'a ttl past the ceiling must be refused'
			return
		}
		assert false, 'a ttl of zero must be refused'
		return
	}
	assert false, 'a grant with no clause must be refused'
}

fn test_an_expired_grant_covers_nothing() {
	mut c := new_consent(new_event_log(tmp_log_path('con5'), 'main', 'test'))
	c.grant('1', GrantOpts{
		path: 'src/a.py'
		ttl:  60.0
	}) or { panic(err) }
	// wind the clock past it
	c.grants[0].expires_at = now_ts() - 1.0
	assert c.spend('1', 'src/a.py', '') == none
	assert c.live().len == 0
	assert c.report().contains('expired')
}

fn test_a_command_grant_matches_the_exact_command() {
	mut c := new_consent(new_event_log(tmp_log_path('con6'), 'main', 'test'))
	c.grant('3', GrantOpts{
		command: 'rm -rf build'
		uses:    2
	}) or { panic(err) }
	assert c.spend('3', '', 'rm -rf build') != none
	// whitespace around it does not change the command
	assert c.spend('3', '', '  rm -rf build  ') != none
	assert c.spend('3', '', 'rm -rf src') == none
}

fn test_a_clause_wide_grant_covers_any_path_in_that_clause() {
	mut c := new_consent(new_event_log(tmp_log_path('con7'), 'main', 'test'))
	c.grant('1', GrantOpts{ uses: 2 }) or { panic(err) }
	assert c.spend('1', '/anywhere/at/all', '') != none
	assert c.spend('1', '/somewhere/else', '') != none
	// but never another clause
	assert c.spend('2', '/anywhere/at/all', '') == none
}

fn test_revoking_ends_a_grant_without_rewriting_how_others_ended() {
	mut c := new_consent(new_event_log(tmp_log_path('con8'), 'main', 'test'))
	live_grant := c.grant('1', GrantOpts{
		path: 'a'
		uses: 2
	}) or { panic(err) }
	spent_grant := c.grant('2', GrantOpts{
		path: 'b'
	}) or { panic(err) }
	c.spend('2', 'b', '')

	assert c.revoke(live_grant.id)
	assert !c.revoke(live_grant.id), 'revoking twice must not report success'
	assert c.spend('1', 'a', '') == none
	// the spent grant is still recorded as exhausted, not as revoked
	for g in c.grants {
		if g.id == spent_grant.id {
			assert !g.revoked
		}
	}

	// revoke_all only touches what is live
	mut c2 := new_consent(new_event_log(tmp_log_path('con9'), 'main', 'test'))
	c2.grant('1', GrantOpts{ path: 'a' }) or { panic(err) }
	c2.grant('1', GrantOpts{ path: 'b' }) or { panic(err) }
	c2.spend('1', 'a', '')
	assert c2.revoke_all() == 1
}

fn test_narrowing_never_creates_permission() {
	mut c := new_consent(new_event_log(tmp_log_path('con10'), 'main', 'test'))
	// with nothing refused there is nothing to forgive
	assert c.narrow([], 'write_file', '').len == 0
	c.grant('1', GrantOpts{
		path: 'src/a.py'
	}) or { panic(err) }
	assert c.narrow([], 'write_file', '').len == 0

	kept := c.narrow([a_violation('1', 'src/a.py'), a_violation('2', 'src/a.py')],
		'write_file', '')
	assert kept.len == 1
	assert kept[0].clause == '2'
}

fn test_a_relative_path_is_not_the_same_as_an_absolute_one() {
	assert same_path('/etc/hosts', '/etc/hosts')
	assert same_path('/etc/./hosts', '/etc/sub/../hosts')
	assert same_path('src/a.py', 'src/a.py')
	assert !same_path('src/a.py', '/src/a.py')
	assert !same_path('', '')
}

fn test_every_step_is_sealed_and_the_report_reads() {
	mut log := new_event_log(tmp_log_path('con11'), 'main', 'test')
	mut c := new_consent(log)
	assert c.report() == 'consent: no grants have been given'
	g := c.grant('1', GrantOpts{
		path:   '/etc/hosts'
		reason: 'migration'
	}) or { panic(err) }
	c.spend('1', '/etc/hosts', '')
	c.revoke(g.id)
	kinds := log.events('main').map(it.typ)
	assert 'consent.granted' in kinds
	assert 'consent.spent' in kinds
	assert 'consent.exhausted' in kinds
	text := c.report()
	assert text.contains('1 total')
	assert text.contains('1 spent')
	assert text.contains('/etc/hosts')
	assert text.contains('migration')
}
