# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.1.x   | Yes       |
| 1.0.x   | Security fixes only |
| < 1.0   | No        |

## Reporting a Vulnerability

If you discover a security vulnerability in Portwood DocGen, **please do not open a public issue.**

Instead, report it privately:

1. **Email:** dave@portwoodglobalsolutions.com
2. **Subject:** `[SECURITY] <brief description>`
3. **Include:** Steps to reproduce, affected versions, and potential impact

You will receive an acknowledgment within 48 hours. We will work with you to understand the issue and coordinate a fix before any public disclosure.

## Security Design

DocGen is designed with Salesforce security best practices:

- **No external callouts.** All processing happens within the Salesforce platform. No data leaves the org.
- **CRUD/FLS enforcement.** All user-facing queries use `WITH USER_MODE` or `Security.stripInaccessible()`.
- **No session ID exposure.** The package never accesses or transmits `UserInfo.getSessionId()`.
- **No guest user access.** The package does not include Salesforce Sites, guest user profiles, or public endpoints.
- **Permission-gated access.** All functionality requires the DocGen Admin or DocGen User permission set.
- **Code Analyzer clean.** Scanned with `sf code-analyzer run --rule-selector "recommended"` — 0 Critical, 0 High violations.

## Responsible Disclosure

We follow responsible disclosure practices. If you report a vulnerability:

- We will not take legal action against you for the report
- We will work with you to understand and resolve the issue
- We will credit you in the release notes (unless you prefer to remain anonymous)
