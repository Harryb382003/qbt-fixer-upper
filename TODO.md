TODO

1. Functional Behavior
	a.	Ensure --scan and --dezombify have contextual behavior.
	b.	Prevent zombie scan if dezombify=0.

2. Code Structure & Maintainability
	a.	Extract repeated patterns (e.g., cache handling) into Utils.pm.
	b.	Move timestamp generation to a common helper.

3. Future Additions
	a.	Create a scripts/tools directory for dev utilities (e.g., TODO auto-updater).
	b.	Store TODO.md in repo root and auto-update during dev cycles.
	c.	Add optional color palettes for Logger output.
	d.	Consider command-line switches for debug modes:
	e.	--debug → enable sprinkles + Dumper.
	f	--verbose → extra Logger detail.
