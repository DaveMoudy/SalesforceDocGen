# Changelog

## v2.0.0 — "Apollo"
- **Single-App Experience** — One tab, three cards: Templates, Bulk Generate, How It Works. No more tab sprawl.
- **Bulk Runner Overhaul** — Typeahead template search, inline sample record picker, real PDF preview download, server-loaded job history. All in one view.
- **Zero-Heap PDF Preview** — `generatePdfBlob()` now forces PDF output format, ensuring the pre-decomposed path and relative image URLs are always used. Preview works on templates with dozens of images without hitting heap limits.
- **Query Builder Stability** — Fixed infinite re-parse loop that reset the active tab and wiped field selections on every checkbox toggle. V1 flat configs and V2 JSON configs now load correctly in the visual builder (backward compatible).
- **Self-Contained E2E Tests** — `scripts/e2e-test.apex` creates its own template, DOCX file, template version, test data, generates a real PDF, validates 13 assertions, and cleans up. Zero dependencies on pre-existing org data.
- **Report Filter Auto-Save** — Imported report WHERE clauses automatically saved as bulk queries and loaded when the template is selected.
- **Saved Query Management** — Save, load, and delete named SOQL conditions per template.
- **Recent Jobs Panel** — Completed bulk jobs load from the server with status, counts, template name, and date. Refreshes automatically when a job finishes.

## v1.6.0
- **Multi-Object Query Builder** — Tab-per-object layout with visual relationship tree. Build templates spanning Account → Opportunities → Line Items → Contacts in one view. Each object gets its own tab with field selection, parent field picker, and WHERE/ORDER BY/LIMIT.
- **V3 Query Tree Engine** — New JSON v3 config format. One SOQL query per object node, stitched together in Apex. Supports any depth with zero SOQL nesting limits. Backward compatible with v1/v2 configs.
- **Report Import** — Import field selections from ANY Salesforce Report. Dynamic base object resolution using plural label matching — works for standard, cross-object, and custom report types. Auto-detects parent lookups, child relationships, and junction objects. Report date filters extracted as bulk WHERE clauses.
- **Junction Object Support** — Contact via OpportunityContactRole, Campaign Members, and other junction objects detected and handled automatically. Two-hop queries stitch junction targets into the data map.
- **Click-to-Copy Merge Tags** — Click any tag in the builder to copy it to clipboard with a toast confirmation.
- **Bulk Runner Refresh** — Refresh button on template picker. Report filters auto-populate the WHERE clause when selecting a template built from a report import.
- **Backward-Compatible Upgrade** — Stub methods for removed signature classes allow v1.6.0 to install cleanly over v1.4.0 orgs.
- **E2E Test Suite** — `scripts/e2e-test.apex` validates 13 tests: V3 tree walker, parent fields, grandchild stitching, image CV creation, junction stitching, legacy backward compat, document generation. Self-cleaning. One click.
- **Stress Test** — `scripts/stress-test-data.apex` creates a Quote with 15 products, each with a product image. Validates zero-heap image rendering at scale.
- **Amanda-Friendly Naming** — All labels use plain English: "Opportunity Products" not "OpportunityLineItems", "Your Document Structure" not "Relationship Map", "Include parent fields" not "Add parent above".

## v1.5.0
- **Command Hub** — Single-tab UX replacing 7 tabs. Wizard-first onboarding, embedded bulk generator, contextual help.
- **Deep Grandchild Relationships** — Multi-level query stitching: Account → Opportunities → Line Items → Schedules. One SOQL per level, stitched in Apex. Query builder UI supports "Add Related List" inside child cards.
- **Signature Feature Removed** — E-signatures carry legal requirements a doc gen tool should not implement. Use dedicated providers (DocuSign, Adobe Sign).
- **Custom Font Upload Removed** — `Blob.toPdf()` does not support CSS `@font-face` (confirmed via data URIs, static resources, and ContentVersion URLs). PDF supports Helvetica, Times, Courier, Arial Unicode MS. DOCX preserves template fonts.
- **Font Documentation** — PDF font limitations documented. DOCX recommended for custom fonts.
- **DOCX Download Only** — Save to Record removed for DOCX output (Aura 4MB payload limit). Download works for any size.

## v1.3.4
- **Zero-Heap PDF Images** — `{%ImageField}` tags skip blob loading for PDF; images resolved by URL with zero heap cost
- **Pre-Decomposed Templates** — Template XML stored as ContentVersions on save; PDF generation skips ZIP decompression (~75% heap reduction)
- **PDF Image Fix** — Relative Salesforce URLs for `Blob.toPdf()` compatibility
- **Bold Space Fix** — Preserved whitespace between adjacent bold merge fields
- **Encoding Fix** — `&` no longer double-encoded in PDF output
- **Documentation Overhaul** — Release Update visibility, query builder limits, troubleshooting, known limitations table
- **Rich Text Fields** — Bold, italic, paragraph structure, and embedded images preserved in Word and PDF output

## v1.2.2
- **Admin Guide** — Data Model section with object reference tables
- **Page Layouts** — Added layouts for all custom objects

## v1.2.0
- **Unified PDF Generation** — Single code path for single and bulk PDF. -766 lines of duplicated logic.
- **Spring '26 Blob.toPdf() Compatibility** — Native rendering with Release Update, VF fallback without
- **Page Break Fix** — `page-break-inside: avoid` on paragraphs and list items

## v1.1.1
- **PDF Renderer** — Full DOCX style conversion: headings, lists, line spacing, page breaks, borders, shading, hyperlinks, superscript/subscript, tables
- **Merge Fields** — `{!Field}` Salesforce-style syntax and base object prefix stripping
- **Query Parser** — Auto-splits fields from adjacent subqueries

## v1.1.0
- **Admin Guide** — In-app guide covering all features
- **Version Preview** — Query display, template download, sample generation
- **Security** — `Security.stripInaccessible()`, sanitization hardening, error genericization

## v1.0.0
- **Server-Side PDF** — All generation via `DocGenHtmlRenderer` + `Blob.toPdf()`. Zero client-side JavaScript.
- **Security** — API v66.0, CRUD/FLS enforcement

## v0.9.x
- PKCE Auth Fix, wizard UX improvements, credential provisioning

## v0.8.0
- Fixed package uninstall blockers, updated terminology

## v0.7.0 and earlier
- Bulk PDF generation, transaction finalizers, security hardening, compression API migration, rich text support, 2GP package
