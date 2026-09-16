module vagent

fn test_the_context_bucket_reads_the_dominant_signature() {
	assert context_of('fix the parser bug') == 'code'
	assert context_of('write a README for the api') == 'write'
	assert context_of('research the latest flask release') == 'research'
	assert context_of('run the test suite') == 'run'
	assert context_of('hii') == 'chat'

	// an execution verb outranks a noun: this is a run, not a test
	assert context_of('run the test suite') != 'code'
	assert context_of('build the docs') == 'run'
	// and bucketing is case-insensitive
	assert context_of('FIX THE BUG') == 'code'
	assert context_of('') == 'chat'
}

fn test_the_beta_sampler_covers_the_space_under_a_uniform_prior() {
	mut low := false
	mut high := false
	for i in 0 .. 50 {
		mut r := new_rng(u64(i) + 1)
		d := beta_draw(1.0, 1.0, mut r)
		assert d >= 0.0 && d <= 1.0
		if d < 0.3 {
			low = true
		}
		if d > 0.7 {
			high = true
		}
	}
	assert low && high

	// a sharply-shaped posterior concentrates where the evidence is
	mut r := new_rng(4)
	mut total := 0.0
	for _ in 0 .. 400 {
		total += beta_draw(90.0, 10.0, mut r)
	}
	mean := total / 400.0
	assert mean > 0.85 && mean < 0.95, '${mean}'

	// the shape < 1 branch is the one with the boost, so exercise it
	mut s := new_rng(77)
	for _ in 0 .. 200 {
		v := gamma_draw(0.4, mut s)
		assert v >= 0.0
	}
}

fn test_the_router_converges_on_a_planted_best_arm() {
	arms := ['fast-model', 'smart-model', 'huge-model']
	mut log := new_event_log(tmp_log_path('bandit1'), 'main', 'test')
	mut b := new_bandit_router(log, arms, 9)

	// the planted world: smart-model is best at code, fast-model at chat
	mut env := new_rng(3)
	mut picks := [][]string{}
	for i in 0 .. 400 {
		ctx := if i % 2 == 0 { 'code' } else { 'chat' }
		task := if ctx == 'code' { 'fix the bug' } else { 'hello there' }
		rec := b.recommend(task)
		assert rec.context == ctx
		p := true_reward_p(rec.arm, ctx)
		reward := if env.f64() < p { 1.0 } else { 0.0 }
		b.update(rec.arm, reward, ctx)
		picks << [ctx, rec.arm]
	}

	late := picks[300..]
	mut code_best := 0
	mut code_total := 0
	mut chat_best := 0
	mut chat_total := 0
	for row in late {
		if row[0] == 'code' {
			code_total++
			if row[1] == 'smart-model' {
				code_best++
			}
		} else {
			chat_total++
			if row[1] == 'fast-model' {
				chat_best++
			}
		}
	}
	assert f64(code_best) > f64(code_total) * 0.75, '${code_best}/${code_total}'
	assert f64(chat_best) > f64(chat_total) * 0.6, '${chat_best}/${chat_total}'

	// and everything was explored early — convergence without exploration is
	// just a hardcoded answer
	mut tried := map[string]bool{}
	for row in picks[..80] {
		tried[row[1]] = true
	}
	assert tried.len == arms.len, '${tried.keys()}'

	// the learned policy survives a restart, because it lives in the log
	mut b2 := new_bandit_router(log, arms, 1)
	pol := b2.policy()
	assert pol['code']['smart-model'] > 0.7, '${pol["code"]}'
	assert pol['code']['huge-model'] < pol['code']['smart-model']
	assert pol['chat']['fast-model'] > 0.5, '${pol["chat"]}'

	// a context nobody has played keeps the uniform prior
	assert pol['research']['fast-model'] == 0.5

	assert b2.format().contains('BANDIT ROUTER')
	assert b2.format().contains('smart-model')

	kinds := log.events('main').map(it.typ)
	assert 'bandit.pull' in kinds
	assert 'bandit.update' in kinds
}

fn true_reward_p(arm string, ctx string) f64 {
	if arm == 'smart-model' && ctx == 'code' {
		return 0.9
	}
	if arm == 'fast-model' && ctx == 'chat' {
		return 0.8
	}
	if arm == 'huge-model' && ctx == 'code' {
		return 0.5
	}
	return 0.3
}

fn test_rewards_are_clamped_and_contexts_default() {
	mut log := new_event_log(tmp_log_path('bandit2'), 'main', 'test')
	mut b := new_bandit_router(log, ['a'], 2)
	b.update('a', 7.0, '')
	a1, b1 := b.posterior('chat', 'a')
	assert a1 == 2.0 && b1 == 1.0
	b.update('a', -3.0, '')
	a2, b2 := b.posterior('chat', 'a')
	assert a2 == 2.0 && b2 == 2.0
	// a fractional reward is half evidence each way
	b.update('a', 0.5, 'code')
	a3, b3 := b.posterior('code', 'a')
	assert a3 == 1.5 && b3 == 1.5
}

fn test_an_empty_arm_list_still_routes() {
	mut log := new_event_log(tmp_log_path('bandit3'), 'main', 'test')
	mut b := new_bandit_router(log, [], 1)
	assert b.arms == ['default']
	rec := b.recommend('anything at all')
	assert rec.arm == 'default'
	assert rec.expected['default'] == 0.5
}
