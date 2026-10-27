{
	# Every owned application starts at the same version it ships as. This is
	# the first baseline: no upgrade transitions exist yet, so the appup is an
	# empty list on both sides. `task live:update` adds an entry per
	# hot-upgradeable change (see AGENTS.md); releases before 0.0.1 are not
	# upgrade sources.
	~c"0.0.1",
	[],
	[]
}
