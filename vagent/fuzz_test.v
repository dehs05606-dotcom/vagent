module vagent

fn always_ok(args []FuzzValue) !FuzzValue {
	return FuzzValue(i64(1))
}

// crashes on the empty string, and on nothing else
fn crashy(args []FuzzValue) !FuzzValue {
	if args.len > 0 {
		a := args[0]
		if a is string {
			if a.len == 0 {
				return error('empty!')
			}
		}
	}
	return args[0] or { FuzzValue(FuzzNone{}) }
}

// crashes on zero, and on nothing else
fn divvy(args []FuzzValue) !FuzzValue {
	if args.len > 0 {
		a := args[0]
		if a is i64 {
			if a == 0 {
				return error('division by zero')
			}
			return FuzzValue(i64(100) / a)
		}
	}
	return FuzzValue(FuzzNone{})
}

// sorts its input, except that it reverses anything longer than three
// elements — a plausible off-by-one that never raises and always returns a
// list, so only a post-condition can catch it
fn bad_sort(args []FuzzValue) !FuzzValue {
	a := args[0] or { return FuzzValue([]FuzzValue{}) }
	if a is []FuzzValue {
		mut keys := a.map(it.repr())
		keys.sort()
		if keys.len > 3 {
			keys.reverse_in_place()
		}
		return FuzzValue(keys.map(FuzzValue(it)))
	}
	return FuzzValue([]FuzzValue{})
}

fn is_sorted(result FuzzValue, args []FuzzValue) !bool {
	if result is []FuzzValue {
		for i in 1 .. result.len {
			prev := result[i - 1]
			cur := result[i]
			if prev is string && cur is string {
				if prev > cur {
					return false
				}
			}
		}
		return true
	}
	return false
}

fn exploding_invariant(result FuzzValue, args []FuzzValue) !bool {
	return error('the invariant itself is broken')
}

fn test_a_robust_function_survives_the_whole_run() {
	mut log := new_event_log(tmp_log_path('fuz1'), 'main', 'test')
	mut f := new_fuzzer(log, 42)
	r := f.fuzz(always_ok, FuzzOpts{ iterations: 100, name: 'always_ok' })
	assert r.ok
	assert r.crashes == 0
	assert r.invariant_failures == 0
	assert r.iterations == 100
	assert r.first_crash == none
}

fn test_a_string_crash_is_found_and_shrunk_to_the_empty_string() {
	mut log := new_event_log(tmp_log_path('fuz2'), 'main', 'test')
	mut f := new_fuzzer(log, 42)
	r := f.fuzz(crashy, FuzzOpts{ iterations: 300, name: 'crashy' })
	assert r.crashes >= 1, r.to_json().str()
	assert !r.ok

	fc := r.first_crash or { panic('a crash was counted but not recorded') }
	assert fc.error.contains('empty'), fc.error
	// the reproducer is minimal, not merely smaller
	assert fc.shrunk_args.len == 1
	assert fc.shrunk_args[0].repr() == "''", fc.shrunk_args[0].repr()
	assert fc.shrunk_error.contains('empty'), fc.shrunk_error
	assert fc.iterations > 0
}

fn test_an_integer_crash_is_shrunk_to_zero() {
	mut log := new_event_log(tmp_log_path('fuz3'), 'main', 'test')
	mut f := new_fuzzer(log, 7)
	r := f.fuzz(divvy, FuzzOpts{ iterations: 300, name: 'divvy' })
	assert r.crashes >= 1, r.to_json().str()
	fc := r.first_crash or { panic('a crash was counted but not recorded') }
	assert fc.shrunk_args[0].repr() == '0', fc.shrunk_args[0].repr()
}

fn test_an_invariant_violation_is_caught_without_a_crash() {
	mut log := new_event_log(tmp_log_path('fuz4'), 'main', 'test')
	mut f := new_fuzzer(log, 3)
	r := f.fuzz(bad_sort, FuzzOpts{
		iterations: 400
		name:       'bad_sort'
		invariant:  is_sorted
	})
	// nothing raised: the function returned a wrong answer, politely
	assert r.invariant_failures >= 1, r.to_json().str()
	assert r.crashes == 0
	assert !r.ok
	fc := r.first_crash or { panic('a violation was counted but not recorded') }
	assert fc.error == 'invariant returned False'
}

fn test_an_invariant_that_itself_fails_is_reported_as_such() {
	mut log := new_event_log(tmp_log_path('fuz5'), 'main', 'test')
	mut f := new_fuzzer(log, 1)
	r := f.fuzz(always_ok, FuzzOpts{
		iterations: 5
		name:       'ok_but_bad_check'
		invariant:  exploding_invariant
	})
	assert r.crashes == 5
	fc := r.first_crash or { panic('nothing recorded') }
	// the blame lands on the invariant, not on the target
	assert fc.error.starts_with('invariant raised'), fc.error
}

fn test_the_same_seed_produces_the_same_run() {
	mut a := new_fuzzer(new_event_log(tmp_log_path('fuz6a'), 'main', 'test'), 42)
	mut b := new_fuzzer(new_event_log(tmp_log_path('fuz6b'), 'main', 'test'), 42)
	r1 := a.fuzz(crashy, FuzzOpts{ iterations: 50, name: 'crashy' })
	r2 := b.fuzz(crashy, FuzzOpts{ iterations: 50, name: 'crashy' })
	assert r1.crashes == r2.crashes
	assert r1.iterations == r2.iterations

	// and a different seed explores a different stream
	mut c := new_fuzzer(new_event_log(tmp_log_path('fuz6c'), 'main', 'test'), 43)
	c.fuzz(crashy, FuzzOpts{ iterations: 50, name: 'crashy' })
	mut g1 := new_fuzz_generator(42)
	mut g2 := new_fuzz_generator(43)
	assert g1.args_for(4).map(it.repr()) != g2.args_for(4).map(it.repr())
}

fn test_shrinking_stops_when_it_can_go_no_smaller() {
	// every simpler variant is offered emptiest-first, so a shrink
	// converges rather than wandering
	str_variants := simpler_variants(FuzzValue('abcd')).map(it.repr())
	assert str_variants[0] == "''"
	assert simpler_variants(FuzzValue('')).len == 0

	int_variants := simpler_variants(FuzzValue(i64(-8))).map(it.repr())
	assert int_variants == ['0', '-1', '-4'], int_variants.str()
	assert simpler_variants(FuzzValue(i64(0))).len == 0

	list_variants := simpler_variants(FuzzValue([FuzzValue(i64(1)), FuzzValue(i64(2))]))
	assert list_variants[0].repr() == '[]'
	assert simpler_variants(FuzzValue([]FuzzValue{})).len == 0

	assert simpler_variants(FuzzValue(FuzzNone{})).len == 0
	assert simpler_variants(FuzzValue(FuzzBlob{})).len == 0
}

fn test_generated_values_stay_bounded_in_depth() {
	mut g := new_fuzz_generator(11)
	// past depth two a value flattens to an integer, so generation
	// terminates however the dice fall
	for _ in 0 .. 50 {
		v := g.any(3)
		assert v is i64
	}
}

fn test_every_run_is_sealed_and_projected() {
	mut log := new_event_log(tmp_log_path('fuz7'), 'main', 'test')
	mut f := new_fuzzer(log, 42)
	f.fuzz(crashy, FuzzOpts{ iterations: 300, name: 'crashy' })

	mut types := map[string]bool{}
	for e in f.runs() {
		types[jstr(e, 'type')] = true
	}
	for want in ['fuzz.run', 'fuzz.crash', 'fuzz.shrunk'] {
		assert types[want], want
	}
	status := f.format_status()
	assert status.contains('FUZZ')
	assert status.contains('runs 1')
	assert status.contains('⚠')
}
