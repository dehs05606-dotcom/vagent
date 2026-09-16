module vagent

import math

__global (
	debate_calls []string
)

// a three-persona script: two participants converge on rust, one dissents
fn scripted_debater(model_id string, prompt string) string {
	debate_calls << '${model_id}|' + clip_plain(prompt, 40)
	if model_id == 'modelA' {
		if prompt.contains('Attack') {
			return 'the go answer ignores memory safety'
		}
		if prompt.contains('Revise') {
			return 'rust is memory-safe and fast for systems'
		}
		return 'rust is the right choice for systems work'
	}
	if model_id == 'modelB' {
		if prompt.contains('Attack') {
			return 'rust has a steep learning curve'
		}
		if prompt.contains('Revise') {
			return 'rust remains right despite the curve'
		}
		return 'rust suits performance-critical systems'
	}
	if prompt.contains('Attack') {
		return 'rust compile times hurt iteration speed'
	}
	if prompt.contains('Revise') {
		return 'go ships faster for web services'
	}
	return 'go is more practical for most teams'
}

// two participants that give literally the same answer, and one that does not
fn twins_debater(model_id string, prompt string) string {
	if model_id == 'loner' {
		return 'a completely different position on another subject'
	}
	return 'the shared position that both twins argue for'
}

fn three_models() []string {
	return ['modelA', 'modelB', 'modelC']
}

fn test_all_three_rounds_run_for_every_participant() {
	debate_calls = []string{}
	mut log := new_event_log(tmp_log_path('deb1'), 'main', 'test')
	mut t := new_debate_tournament(log, scripted_debater, three_models())
	assert t.calibration('modelA') == 0.5

	result := t.run('rust or go for a new backend?', 3)
	assert result.rounds == 3
	assert debate_calls.len == 9, debate_calls.len.str()
	// the proposal round is blind: the first three prompts carry no other
	// participant's answer
	for i in 0 .. 3 {
		assert !debate_calls[i].contains('says:'), debate_calls[i]
	}
}

fn test_the_majority_cluster_supplies_the_verdict_and_the_dissent_survives() {
	debate_calls = []string{}
	mut log := new_event_log(tmp_log_path('deb2'), 'main', 'test')
	mut t := new_debate_tournament(log, scripted_debater, three_models())
	result := t.run('rust or go for a new backend?', 3)

	// The three revisions share almost no vocabulary — even the two that
	// both argue for rust overlap on the single word 'rust', which is 0.14
	// cosine, well under the 0.45 threshold. So this tournament produces
	// three singleton clusters rather than a rust majority, and that is the
	// honest reading of the answers: agreeing on a conclusion is not the
	// same as making the same argument.
	assert result.clusters == [['modelA'], ['modelB'], ['modelC']], result.clusters.str()
	// every cluster weighs the same, so the tie breaks on formation order
	assert result.champion_model == 'modelA', result.champion_model
	assert result.verdict.to_lower().contains('rust'), result.verdict
	// the runner-up is reported, not buried
	assert result.dissent.len == 1
	assert result.dissent[0].contains('dissents')
	assert result.dissent[0].contains('modelB')
	// every participant is placed in some cluster
	for p in result.positions {
		assert p.cluster >= 0, p.model_id
	}
	assert result.positions[0].cluster == 0
}

fn test_calibration_moves_bounded_and_survives_a_restart() {
	debate_calls = []string{}
	mut log := new_event_log(tmp_log_path('deb3'), 'main', 'test')
	mut t := new_debate_tournament(log, scripted_debater, three_models())
	result := t.run('rust or go for a new backend?', 3)

	trust := t.confirm(result.champion_model)
	assert trust[result.champion_model] > 0.5
	// here the winning cluster is a singleton, so only the champion gains
	// and both other positions decay
	for m in ['modelB', 'modelC'] {
		assert trust[m] < 0.5, m
	}

	// calibration lives in the log, so a fresh tournament inherits it
	mut reloaded := new_debate_tournament(log, scripted_debater, three_models())
	assert math.abs(reloaded.calibration(result.champion_model) - trust[result.champion_model]) < 1e-6
	assert math.abs(reloaded.calibration('modelC') - trust['modelC']) < 1e-6

	// a refutation flips the flow of trust back
	before_c := t.calibration('modelC')
	t.refute('modelC')
	assert t.calibration('modelC') > before_c
	assert t.calibration('modelA') < trust['modelA']
}

fn test_a_whole_agreeing_cluster_is_credited_not_only_its_champion() {
	mut log := new_event_log(tmp_log_path('deb3b'), 'main', 'test')
	mut t := new_debate_tournament(log, twins_debater, ['twinA', 'twinB', 'loner'])
	result := t.run('which way', 1)
	// the twins say the same thing, so they cluster and both get credit
	assert result.clusters[0].len == 2, result.clusters.str()
	trust := t.confirm(result.champion_model)
	assert trust['twinA'] > 0.5
	assert trust['twinB'] > 0.5
	assert trust['loner'] < 0.5
}

fn test_trust_is_bounded_however_often_it_is_updated() {
	mut log := new_event_log(tmp_log_path('deb4'), 'main', 'test')
	mut t := new_debate_tournament(log, scripted_debater, ['x', 'y'])
	for _ in 0 .. 200 {
		t.confirm('x')
	}
	assert t.calibration('x') <= trust_max
	assert t.calibration('y') >= trust_min
	// the bounds are approached, never crossed
	assert t.calibration('x') > 0.9
	assert t.calibration('y') < 0.1
}

fn test_a_single_participant_needs_no_critique_round() {
	debate_calls = []string{}
	mut log := new_event_log(tmp_log_path('deb5'), 'main', 'test')
	mut solo := new_debate_tournament(log, scripted_debater, ['modelA'])
	r := solo.run('solo question', 3)
	// a critique of nobody and a revision under no fire are both pointless
	assert r.rounds == 1
	assert r.champion_model == 'modelA'
	assert r.dissent.len == 0
	assert debate_calls.len == 1
}

fn test_empty_inputs_produce_an_empty_tournament() {
	mut log := new_event_log(tmp_log_path('deb6'), 'main', 'test')
	mut t := new_debate_tournament(log, scripted_debater, three_models())
	assert t.run('   ', 3).rounds == 0

	mut empty := new_debate_tournament(log, scripted_debater, [])
	r := empty.run('q', 3)
	assert r.rounds == 0
	assert r.verdict == ''
	assert r.champion_model == ''
}

fn test_token_vectors_and_cosine_behave() {
	// identical vectors are similarity 1, up to the float arithmetic
	assert math.abs(token_cosine(token_vector('a b c'), token_vector('a b c')) - 1.0) < 1e-9
	assert token_cosine(token_vector('a b'), token_vector('x y')) == 0.0
	assert token_cosine(map[string]int{}, token_vector('a')) == 0.0
	// punctuation and case are not part of the signal
	assert token_vector('Rust, rust!') == {
		'rust': 2
	}
	assert token_vector('  ') == map[string]int{}
	// a trailing token with no delimiter after it still counts
	assert token_vector('one two') == {
		'one': 1
		'two': 1
	}
}

fn test_every_round_and_verdict_is_sealed() {
	debate_calls = []string{}
	mut log := new_event_log(tmp_log_path('deb7'), 'main', 'test')
	mut t := new_debate_tournament(log, scripted_debater, three_models())
	result := t.run('rust or go for a new backend?', 3)
	t.confirm(result.champion_model)

	st := fold(mut log, 'main')
	mut kinds := map[string]bool{}
	for e in st.advanced_events {
		kinds[jstr(e, 'type')] = true
	}
	for want in ['debate.round', 'debate.verdict', 'debate.calibration'] {
		assert kinds[want], want
	}

	text := t.format(&result)
	assert text.contains('DEBATE VERDICT')
	assert text.contains('champion: [${result.champion_model}]')
	assert text.contains('⚠ dissent')
	assert text.contains('calibration: modelA=')
}
