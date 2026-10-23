---
name: daily-plan-refresh
description: Weekdays at 09:00 and 13:00, build ~/.daily-plan/plan.json from Google Calendar, Jira and open Slack asks for the DailyPlan menu bar widget
---

<!--
Prompt for a Claude scheduled task (Claude desktop app → Scheduled, cron "0 9,13 * * 1-5").
Before using it, replace the <PLACEHOLDERS> below with your own values.
Needs the Google Calendar, Atlassian (Jira) and Slack connectors.
-->

You maintain the data file for the user's "DailyPlan" macOS menu bar widget (source: DailyPlan.swift). The widget re-reads ~/.daily-plan/plan.json every 30 seconds. Your only job is to write that file. Be read-only everywhere else: do not modify calendar events, Jira issues, or anything in git repos, and do not send messages.

User: <YOUR NAME> (<YOUR EMAIL>). Local timezone is <IANA TIMEZONE, e.g. Europe/Berlin> (<UTC OFFSET, e.g. +01:00>). Today = the current local date.

## Steps

1. Archive. If ~/.daily-plan/plan.json exists and its "date" is NOT today, copy it to ~/.daily-plan/history/plan-<thatdate>.json, and copy ~/.daily-plan/done.json (if it exists) to ~/.daily-plan/history/done-<thatdate>.json. Create the history dir if needed.

2. Midday refresh rule. If plan.json already exists with "date" == today (this is the 13:00 run), keep its existing "priorities" EXACTLY as they are (same titles, same order), because the user's checkboxes in done.json are keyed by priority title. You may only APPEND new Slack items found since the 09:00 run (step 5), at most 2. Refresh "events", "notes" and "generatedAt".

3. Calendar (Google Calendar connector, list_events on the primary calendar, today 00:00–23:59, orderBy startTime). Include timed events where the user's responseStatus is accepted, tentative or needsAction, plus events the user organizes. Skip declined events, all-day events, workingLocation and birthday events. For each event: start/end as local "HH:mm", title = summary, url = conferenceUrl (Google Meet) if present, otherwise htmlLink.
   Event kinds (the widget draws "kind" events in orange and never treats them as meetings):
   - Lunch: the user has a recurring weekday "Lunch" event (<LUNCH TIME, e.g. 14:15–14:45>) in Google Calendar. Write it as {"start", "end", "title": "Lunch", "url": null, "kind": "lunch"}. If a meeting overlaps it (starts before lunch ends and ends after lunch starts), keep lunch anyway and add the note "Lunch overlaps <meeting title> until HH:mm". If the user deleted that day's Lunch instance, don't invent one. Never create, move or modify calendar events.
   - Out-of-office events (eventType OUT_OF_OFFICE) and events the user organizes with no other attendees (e.g. "busy"): "kind": "personal", url null.
   - Focus-time events (eventType FOCUS_TIME, e.g. "No Calls Day"): do NOT add them to "events"; add a note instead, e.g. "No Calls Day".
   Everything else is a meeting: omit "kind".

4. Jira (Atlassian connector, cloudId <YOUR ATLASSIAN CLOUD ID>). JQL: `assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, updated DESC`, maxResults 20. Pick up to 4 priorities for today:
   - first, items in Review or In Progress (push them to done);
   - then P1/P2 items in the active sprint;
   - skip incident/post-mortem tickets unless they were updated in the last 3 days.
   For each priority, write a short actionable title (≤ 60 chars, starting with a verb), ref = the issue key, url = the issue's webUrl.
   Do NOT add items based on uncommitted git changes or other local repo state.

5. Slack (Slack connector, slack_search_public_and_private; the user's Slack ID is <YOUR SLACK USER ID, e.g. U0123456789>). Find open asks directed at the user since the previous working day 09:00 (on Monday: since Friday 09:00; on the 13:00 run: since today 09:00). Run these searches with sort=timestamp, include_context=false:
   - mentions: keywords ["<@YOUR SLACK USER ID>"], filters "after:<YYYY-MM-DD of the day before the window start>";
   - DMs and group DMs: filters "is:dm after:<same date>" (page through with the cursor if the first page is full);
   - bot requests: include_bots=true, filters "is:dm after:<same date>"; keep only GitLab merge-request mentions or approval requests addressed to the user.
   For each candidate, read the thread (slack_read_thread) or the DM messages after it, and keep it ONLY if it still needs the user:
   - keep: a direct question to the user with no reply from the user after it; a request to review, approve, decide or do something; something the user promised ("I'll check / I'll do X") that isn't reported done later in the thread;
   - drop: anything the user already answered or did (a later reply from the user, an :approved:/:merged:/✅ reaction or message, "done"/"deployed"), FYI and status updates, chit-chat, alerts, calendar bot digests, and Jira bot notifications (Jira is covered by step 4).
   Add up to 3 Slack priorities, ranked by urgency (blocking someone or a release > review requests > questions):
   - title: a short actionable paraphrase (≤ 60 chars, verb first), e.g. "Answer Alex: review the caching RFC or hand off". Never quote messages verbatim and never copy secrets, tokens or links with credentials;
   - ref: "Slack", or the MR id like "!1234" when the ask is a GitLab merge request;
   - url: the Slack permalink, or the merge-request URL when there is one.
   If a Slack ask is about a Jira issue already listed, don't add a second item. Order the final priorities: Jira Review/In Progress items, then Slack items, then the remaining Jira items; 6 priorities at most.
   This step is read-only: never send messages, reply, react or mark anything as read.

6. Notes (2–4 short strings):
   - free focus blocks of ≥ 60 min between 10:00 and 19:00 that don't overlap meetings or lunch, e.g. "Focus block: 12:00–13:45 (1h45m)";
   - total meeting time today (only events without "kind");
   - the lunch-overlap note, if any;
   - optionally one prep reminder for a meeting that needs preparation (retro, rollout sync, planning, 1:1).

7. Write ~/.daily-plan/plan.json atomically: write to plan.json.tmp, then mv. Use exactly this schema, valid JSON, UTF-8:
{
  "date": "YYYY-MM-DD",
  "generatedAt": "<ISO 8601 with your UTC offset>",
  "events": [{"start": "HH:mm", "end": "HH:mm", "title": "...", "url": "... or null", "kind": "omit for meetings; \"lunch\" or \"personal\""}],
  "priorities": [{"title": "...", "ref": "KEY-123 or null", "url": "... or null"}],
  "notes": ["..."]
}
Validate it with `python3 -I -m json.tool ~/.daily-plan/plan.json`.

If a connector is unavailable, still write the file with whatever you have and add a note such as "Calendar unavailable" or "Slack unavailable". Never put secrets or tokens in the file.

Final message: one line, e.g. "Plan for 2026-10-26: 4 meetings (2h30m), 5 priorities (2 from Slack), focus 10:00–12:00".
