---
name: daily-plan-refresh
description: Weekdays at 09:00 and 13:00, build ~/.daily-plan/plan.json from Google Calendar and Jira for the DailyPlan menu bar widget
---

<!--
Prompt for a Claude scheduled task (Claude desktop app → Scheduled, cron "0 9,13 * * 1-5").
Before using it, replace the <PLACEHOLDERS> below with your own values.
Needs the Google Calendar and Atlassian (Jira) connectors.
-->

You maintain the data file for the user's "DailyPlan" macOS menu bar widget (source: DailyPlan.swift). The widget re-reads ~/.daily-plan/plan.json every 30 seconds. Your only job is to write that file. Be read-only everywhere else: do not modify calendar events, Jira issues, or anything in git repos, and do not send messages.

User: <YOUR NAME> (<YOUR EMAIL>). Local timezone is <IANA TIMEZONE, e.g. Europe/Berlin> (<UTC OFFSET, e.g. +01:00>). Today = the current local date.

## Steps

1. Archive. If ~/.daily-plan/plan.json exists and its "date" is NOT today, copy it to ~/.daily-plan/history/plan-<thatdate>.json, and copy ~/.daily-plan/done.json (if it exists) to ~/.daily-plan/history/done-<thatdate>.json. Create the history dir if needed.

2. Midday refresh rule. If plan.json already exists with "date" == today (this is the 13:00 run), keep its "priorities" array EXACTLY as is, because the user's checkboxes in done.json are keyed by priority title. Only refresh "events", "notes" and "generatedAt".

3. Calendar (Google Calendar connector, list_events on the primary calendar, today 00:00–23:59, orderBy startTime). Include timed events where the user's responseStatus is accepted, tentative or needsAction, plus events the user organizes. Skip declined events, all-day events, workingLocation and birthday events. For each event: start/end as local "HH:mm", title = summary, url = conferenceUrl (Google Meet) if present, otherwise htmlLink.
   Event kinds (the widget draws "kind" events in orange and never treats them as meetings):
   - Lunch: the user has a recurring weekday "Lunch" event (<LUNCH TIME, e.g. 14:15–14:45>) in Google Calendar. Write it as {"start", "end", "title": "Lunch", "url": null, "kind": "lunch"}. If a meeting overlaps it (starts before lunch ends and ends after lunch starts), keep lunch anyway and add the note "Lunch overlaps <meeting title> until HH:mm". If the user deleted that day's Lunch instance, don't invent one. Never create, move or modify calendar events.
   - Out-of-office events (eventType OUT_OF_OFFICE) and events the user organizes with no other attendees (e.g. "busy"): "kind": "personal", url null.
   - Focus-time events (eventType FOCUS_TIME, e.g. "No Calls Day"): do NOT add them to "events"; add a note instead, e.g. "No Calls Day".
   Everything else is a meeting: omit "kind".

4. Jira (Atlassian connector, cloudId <YOUR ATLASSIAN CLOUD ID>). JQL: `assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, updated DESC`, maxResults 20. Pick the 3–5 priorities for today:
   - first, items in Review or In Progress (push them to done);
   - then P1/P2 items in the active sprint;
   - skip incident/post-mortem tickets unless they were updated in the last 3 days.
   For each priority, write a short actionable title (≤ 60 chars, starting with a verb), ref = the issue key, url = the issue's webUrl.
   Priorities come from Jira only. Do NOT add items based on uncommitted git changes or other local repo state.

5. Notes (2–4 short strings):
   - free focus blocks of ≥ 60 min between 10:00 and 19:00 that don't overlap meetings or lunch, e.g. "Focus block: 12:00–13:45 (1h45m)";
   - total meeting time today (only events without "kind");
   - the lunch-overlap note, if any;
   - optionally one prep reminder for a meeting that needs preparation (retro, rollout sync, planning, 1:1).

6. Write ~/.daily-plan/plan.json atomically: write to plan.json.tmp, then mv. Use exactly this schema, valid JSON, UTF-8:
{
  "date": "YYYY-MM-DD",
  "generatedAt": "<ISO 8601 with your UTC offset>",
  "events": [{"start": "HH:mm", "end": "HH:mm", "title": "...", "url": "... or null", "kind": "omit for meetings; \"lunch\" or \"personal\""}],
  "priorities": [{"title": "...", "ref": "KEY-123 or null", "url": "... or null"}],
  "notes": ["..."]
}
Validate it with `python3 -I -m json.tool ~/.daily-plan/plan.json`.

If a connector is unavailable, still write the file with whatever you have and add a note such as "Calendar unavailable". Never put secrets or tokens in the file.

Final message: one line, e.g. "Plan for 2026-10-26: 4 meetings (2h30m), 4 priorities, focus 10:00–12:00".
