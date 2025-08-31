TODO

1. Functional Behavior

A. Make sure --scan and --dezombify behave as expected in context.
B. Block zombie scans when dezombify=0.

2. Code Structure & Maintainability

A. Pull repeated patterns (e.g., cache handling) into Utils.pm.
B. Centralize timestamp generation into a single helper.

3. Future Additions

A. Create a scripts/tools folder for dev helpers (e.g., TODO auto-updater).
B. Keep TODO.md in the repo root and auto-update during dev work.
C. Add optional color palettes for Logger output.
D. Add command-line switches for debug modes:
	1.	--debug → enable sprinkles + Dumper.
	2.	--verbose → show more Logger detail.

4. Normalization & Collisions

A. Review normalize_filename — simplify where possible.
B. Consider making it a general “no-clobber” utility for reuse later.
C. Build normalize_collision_groups to handle grouped normalization from collected metadata.
D. Decide if translation should hook into collisions/normalization or just remain separate.

5. Translation

A. Translation hook exists — currently TODO.
B. When enabled, append translations to the comment field (prepend with \nEN:).
C. Ensure tracker/comment values like ...torrents.php?id=... are not broken.

6. Reporting & Logging

A. Line up bucket output in columns for readability.
B. Keep collision group reporting (only 2+ entries) clean and separate from summary.
C. Allow Logger to output clean \n lines without [INFO] prefix.
D. Make placement of collision reporting flexible (before summary, not buried inside).
