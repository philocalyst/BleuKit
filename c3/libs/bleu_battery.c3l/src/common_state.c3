<*
 Rules shared by every platform backend: how a battery's charge state is named,
 how health and time-at-rate are computed. Pure (no I/O), so every host runs the
 tests in `common_test.c3`.
*>
module bleu::battery;
import std::collections::maybe, std::time, bleu::unit;

<*
 The charge state of one battery from its mains connection and its flags.

 On mains: CHARGING, FULL, or NOT_CHARGING (plugged in and held, by a charge limit or
 heat). On battery: EMPTY at zero charge, otherwise DISCHARGING. The on-battery rule
 follows starship-battery 0.10.0 `darwin/device.rs`; the on-mains split is the same
 reading applied to the IOPowerSources and Windows flags.
*>
fn ChargeState charge_state(bool on_mains, bool charging, bool fully_charged, bool charge_is_zero)
{
	if (!on_mains) return charge_is_zero ? EMPTY : DISCHARGING;
	if (charging) return CHARGING;
	return fully_charged ? FULL : NOT_CHARGING;
}

<*
 Health as full capacity over design capacity, both in mWh. Empty when the design
 capacity is not reported.
*>
fn Maybe{Level} health_from(MilliWattHour full, MilliWattHour design)
{
	if (design <= (MilliWattHour)0) return { };
	return maybe::value(unit::from_ratio((double)full, (double)design));
}

<*
 Time to empty (discharging) or to full (charging) for `energy` mWh at a flow of
 `rate` mW in either direction. Empty when the flow is zero.
*>
fn Maybe{Duration} time_at_rate(MilliWattHour energy, MilliWatt rate)
{
	if (rate == (MilliWatt)0) return { };
	double magnitude = rate < (MilliWatt)0 ? -(double)rate : (double)rate;
	// mWh / mW = hours; the result is in microseconds.
	return maybe::value((Duration)((double)energy / magnitude * 3600.0 * 1.0e6));
}