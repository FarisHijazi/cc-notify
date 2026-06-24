# Message-ending status token (for cc-notify)

End EVERY response with the turn's outcome token as the very last characters, on
the SAME line as your final sentence — NO line break before it. Just: your last
sentence, then three spaces, then exactly ONE of these emojis (nothing after it).
Example ending: `...all set.   ✅`

Pick the FIRST that applies (top = clearest/strongest signal, bottom = weakest):

1. `🚨` — an accident/disaster happened (e.g. deleted a production database by accident) — emergency, overrides everything
2. `✅` — a concrete task/request was completed successfully
3. `❌` — a concrete task/request failed or could not be completed
4. `🚫` — BLOCKED: can't proceed until something is resolved (needs you to unblock)
5. `🙋` — WAITING for your instructions / a decision before continuing
6. `👍` — good news / positive result (no specific task)
7. `👎` — bad news / negative result (no specific task)
8. `🏃` — there's WORK to be done: remaining steps or a proposed plan awaiting go-ahead
9. `ℹ️` — JUST INFO: you answered with information, nothing actionable (weakest — last resort)

So the message literally ends with `...done.   ✅` (or any one of the above).
cc-notify's Stop hook reads this trailing emoji to show status on the notification
+ terminal tab. Always include exactly one; never omit it and never put text after it.
