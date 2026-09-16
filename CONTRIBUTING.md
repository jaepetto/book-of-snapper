# Contributing

- Every page ends with a "Further reading" section linking real upstream
  documentation (official manuals, project docs, upstream wikis). Verify
  each link resolves before citing it — never guess a URL.
- No employer, vendor, or org-identifying detail: no real hostnames,
  internal IP ranges, or internal-only tool/product names. Use generic
  placeholders instead.
- Every commit must pass `./scripts/check-sanitization.sh` (also runnable
  as `mise run check`). The pre-commit hook enforces this automatically for
  local commits.
