## Summary

<!-- What does this PR do? Keep it brief — 1-3 sentences. -->

## Changes

<!-- Bullet list of what changed and why. -->

-

## Testing

<!-- How did you verify this works? -->

- [ ] Ran E2E tests (`sf apex run --target-org <org> -f scripts/e2e-test.apex`) — all passing
- [ ] Ran Apex unit tests (`sf apex run test --synchronous --code-coverage`) — all passing
- [ ] Tested manually in a scratch org
- [ ] Added/updated E2E test assertions for new behavior

## Related Issues

<!-- Link issues: "Fixes #123" or "Closes #123" to auto-close, "Related to #123" for reference -->

## Screenshots

<!-- If UI changes, before/after screenshots help reviewers. Delete this section if not applicable. -->

## Checklist

- [ ] No hardcoded IDs, URLs, or credentials
- [ ] No `VersionData` in PDF image queries (see CLAUDE.md)
- [ ] SOQL uses `WITH USER_MODE` or `Security.stripInaccessible()` where appropriate
- [ ] No new external dependencies introduced
