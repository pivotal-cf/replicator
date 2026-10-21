## Commit message requirements

Every commit message MUST contain both of the following, or the PR is blocked by the org's commit-message ruleset:

1. A Jira ticket key (e.g. `TNZ-12345`) anywhere in the message.
2. An `ai-assisted=yes` or `ai-assisted=no` trailer. Commits written by Claude use `ai-assisted=yes`. The value must be followed by whitespace, punctuation, or end of message (not a letter, digit, or `/`).

Use the ticket from the branch name (e.g. `feat/TNZ-75265` -> `TNZ-75265`). If the branch has no ticket, ask the user rather than guessing.

Example:

```
Fix lease timeout handling

TNZ-12345
ai-assisted=yes
```

Exempt from the check: messages containing `[skip-ci]` or `[skip-commit-ruleset]`, and messages starting with `Merge branch`, `Merge pull request`, `Merge remote-tracking branch`, or `Revert`. Don't use the skip markers unless the user asks.

Before pushing, verify with `git log -1 --format=%B`. Fix a non-conforming unpushed commit with `git commit --amend`.
