# Overlord Activity

A static dashboard for world PvP activity recorded by the Overlord Activity addon:
top zones and fronts by estimated HKs (7 days, 30 days, all time), a weekday × hour heatmap,
zone trends, this week vs last week, sessions, coverage, and Overlord's weekly network data
(W/F/G/M/L/V records).

- `index.html`, `assets/` - the page (no trackers, no external requests, no frameworks).
- `data/activity.json` - your data, uploaded by the Windows uploader. Until it exists the page
  shows `data/sample.json` with a "Sample data" banner.
- `data/schema.json` - JSON Schema of the data file (`overlord-activity/1`).
- `uploader/` - Windows upload script; see [uploader/README.md](uploader/README.md). For now
  the recommended use is a manual one-off upload after the token is set. The launcher wrapper
  and the Task Scheduler auto-run are included but **not enabled yet, pending the owner's
  decision** (each automatic upload would add a commit to main).
- `tools/oa1_to_json.py` - converts an in-game `/oa export web` text into the same JSON.

Estimated HKs = Overlord's "last 5 min" kill counts summed over 30-second samples ÷ 10.
They describe fighting around you while you were online. Times are shown in the viewer's
local time zone. Missing 15-minute slots mean "not recorded", never zero.

Privacy: the weekly best player's name is never stored in the published data; character
names are aliased by default. Guild names come from Overlord's weekly ranking.

World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of
Blizzard Entertainment, Inc. This fan project is not affiliated with or endorsed by Blizzard.
