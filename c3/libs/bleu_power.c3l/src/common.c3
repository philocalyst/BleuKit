<*
 Which capability each action and each inhibitor kind needs. Pure: no I/O, so
 every mechanism shares one mapping.
*>
module bleu::power;

<* The capability that performing `action` requires. *>
fn Cap action_cap(Action action)
{
	switch (action)
	{
		case SUSPEND: return Cap.SUSPEND;
		case HIBERNATE: return Cap.HIBERNATE;
		case HYBRID_SLEEP: return Cap.HYBRID_SLEEP;
		case POWER_OFF: return Cap.POWER_OFF;
		case REBOOT: return Cap.REBOOT;
		case LOCK: return Cap.LOCK;
		case LOGOUT: return Cap.LOGOUT;
	}
}

<* The capability that taking an inhibitor of `kind` requires. *>
fn Cap inhibit_cap(InhibitKind kind)
{
	switch (kind)
	{
		case KEEP_AWAKE_IDLE: return Cap.KEEP_AWAKE_IDLE;
		case KEEP_AWAKE_DISPLAY: return Cap.KEEP_AWAKE_DISPLAY;
		case KEEP_AWAKE_SYSTEM: return Cap.KEEP_AWAKE_SYSTEM;
		case SLEEP_DELAY: return Cap.DELAY_SLEEP_HOOK;
		case SHUTDOWN_BLOCK: return Cap.BLOCK_SHUTDOWN;
	}
}