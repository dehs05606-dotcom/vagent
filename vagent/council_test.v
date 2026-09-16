module vagent

// a scripted speaker: the thesis cites a measurement, the antithesis waves
// its hands, and the judge picks A
fn speaker_a_wins(role string, brief string) !string {
	match role {
		'thesis' {
			return 'Evidence shows the change cuts latency 40%.\n' + 'STRONGEST POINT: measured 40% latency reduction'
		}
		'antithesis' {
			return 'It might be risky maybe.\nSTRONGEST POINT: vague concern'
		}
		'synthesis' {
			// the blindness is structural, so this is checkable: the
			// synthesis brief must not carry the proposition
			if brief.contains('PROPOSITION') {
				return error('synthesis is not blind')
			}
			return 'WINNER: A\nCONFIDENCE: 82%\nREASON: A cites measurements; B is vague.'
		}
		else {
			return error('unexpected role ${role}')
		}
	}
}

fn speaker_b_wins(role string, brief string) !string {
	if role == 'synthesis' {
		return 'WINNER: B\nCONFIDENCE: 61%\nREASON: B rebuts A.'
	}
	return '${role} argues its side.\nSTRONGEST POINT: a point'
}

fn speaker_draw(role string, brief string) !string {
	if role == 'synthesis' {
		return 'WINNER: DRAW\nCONFIDENCE: 50%\nREASON: even.'
	}
	return '${role} case\nSTRONGEST POINT: p'
}

fn speaker_flaky(role string, brief string) !string {
	if role == 'antithesis' {
		return error('model timeout')
	}
	if role == 'synthesis' {
		return 'WINNER: A\nCONFIDENCE: 90%\nREASON: x'
	}
	return 'thesis stands\nSTRONGEST POINT: p'
}

fn speaker_dead(role string, brief string) !string {
	return error('api down')
}

fn speaker_mute(role string, brief string) !string {
	return '   '
}

fn speaker_sloppy(role string, brief string) !string {
	if role == 'synthesis' {
		return 'I think A was better overall.'
	}
	return '${role} case\nSTRONGEST POINT: p'
}

fn test_the_stronger_argument_wins_and_the_judge_stays_blind() {
	mut log := new_event_log(tmp_log_path('cou1'), 'main', 'test')
	mut c := new_council(log, speaker_a_wins)
	v := c.convene('should we migrate the database this week')
	assert v.ok, v.error
	assert v.winner == 'thesis', v.winner
	assert v.confidence == 82.0
	assert v.reason.contains('measurements')
	assert v.positions.len == 2
	assert 'thesis' in v.positions && 'antithesis' in v.positions
}

fn test_the_judge_can_pick_either_side_or_neither() {
	mut log := new_event_log(tmp_log_path('cou2'), 'main', 'test')
	mut b := new_council(log, speaker_b_wins)
	v2 := b.convene('adopt framework X')
	assert v2.winner == 'antithesis'
	assert v2.confidence == 61.0

	mut d := new_council(log, speaker_draw)
	assert d.convene('q').winner == 'draw'
}

fn test_one_silent_side_loses_by_default_at_low_confidence() {
	mut log := new_event_log(tmp_log_path('cou3'), 'main', 'test')
	mut c := new_council(log, speaker_flaky)
	v := c.convene('flaky debate')
	assert v.ok, v.error
	assert v.winner == 'thesis', v.winner
	assert v.confidence == 30.0
	assert v.reason.contains('failed'), v.reason
	// the surviving side is still on the record
	assert 'thesis' in v.positions
	assert 'antithesis' !in v.positions
}

fn test_two_silent_sides_are_an_honest_failure_not_a_fake_verdict() {
	mut log := new_event_log(tmp_log_path('cou4'), 'main', 'test')
	mut c := new_council(log, speaker_dead)
	v := c.convene('dead debate')
	assert !v.ok
	assert v.winner == ''
	assert v.error.contains('thesis'), v.error
	assert v.error.contains('antithesis'), v.error

	// an empty reply is silence too, not an argument
	mut m := new_council(log, speaker_mute)
	mv := m.convene('mute debate')
	assert !mv.ok
	assert mv.error.contains('empty position'), mv.error
}

fn test_a_council_with_no_speaker_says_so() {
	mut log := new_event_log(tmp_log_path('cou5'), 'main', 'test')
	mut c := new_silent_council(log)
	v := c.convene('no speaker')
	assert !v.ok
	assert v.error == 'no speaker attached'
	assert v.winner == ''
}

fn test_an_unparseable_verdict_carries_no_confidence() {
	// a judge that ignores the reply format has said nothing measurable, so
	// the confidence is 0 rather than a coin-flip 50
	winner, conf, reason := parse_synthesis('I think A was better overall.')
	assert winner == 'DRAW'
	assert conf == 0.0
	assert reason == ''

	mut log := new_event_log(tmp_log_path('cou6'), 'main', 'test')
	mut c := new_council(log, speaker_sloppy)
	v := c.convene('sloppy judge')
	assert v.ok
	assert v.winner == 'draw'
	assert v.confidence == 0.0
}

fn test_a_confidence_outside_the_range_is_clamped() {
	_, high, _ := parse_synthesis('WINNER: A\nCONFIDENCE: 480%\nREASON: r')
	assert high == 100.0
	// the winner is read case-insensitively, as the judge writes it
	lower, conf, reason := parse_synthesis('winner: b\nconfidence: 12.5%\nreason: because')
	assert lower == 'B'
	assert conf == 12.5
	assert reason == 'because'
}

fn test_the_strongest_point_line_is_lifted_out() {
	assert strongest_point('body\nSTRONGEST POINT: the measurement') == 'the measurement'
	assert strongest_point('body with no marker') == ''
}

fn test_every_debate_is_sealed_and_replayable() {
	mut log := new_event_log(tmp_log_path('cou7'), 'main', 'test')
	mut c := new_council(log, speaker_a_wins)
	c.convene('first question')
	c.convene('second question')

	vs := c.verdicts()
	assert vs.len == 2, vs.len.str()

	st := fold(mut log, 'main')
	mut types := map[string]bool{}
	for e in st.council_events {
		types[jstr(e, 'type')] = true
	}
	for want in ['council.convened', 'council.position', 'council.verdict'] {
		assert types[want], want
	}
	status := c.format_status()
	assert status.contains('COUNCIL')
	assert status.contains('debates decided: 2')
	assert status.contains('thesis')
}
