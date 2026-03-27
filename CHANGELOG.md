# Changelog

## v1.1.3 — "Clickable Hyperlinks in Rich Text PDFs" (Portwood DocGen)

- **Clickable Hyperlinks in PDF** — Rich text `<a href="...">` tags now render as real clickable links in PDF output. Previously, hyperlinks from rich text fields were rendered as styled text (blue + underline) but were not clickable. Now they generate proper `<a>` tags in the HTML passed to `Blob.toPdf()`.
- **Anchor Tag Parsing** — New `extractAttribute()` helper parses `href` from rich text anchor tags. Handles quoted and unquoted attributes, `&amp;` decoding.
- **Custom URL Attribute for DOCX→PDF Bridge** — Rich text links embed a `w:docgen-url` attribute on `w:hyperlink` elements during XML processing, which the HTML renderer reads to produce clickable `<a>` tags without needing relationship file lookups.

## v1.1.2 — "Image Sizing, Error Diagnostics & Multiline Text" (Portwood DocGen)

Huge thanks to **@Henk3000** for PR #47 — ImageRenderSpec, ahe() helper, multiline text preservation, error diagnostics for malformed tags, and smart container expansion for numbered lists.

- **ImageRenderSpec** — Percentage-based image sizing (`{%Logo:100%x}`), max constraints (`{%Logo:m100%x}`), intrinsic dimension detection from PNG/JPEG headers, aspect ratio preservation. Credit: @Henk3000 PR #47.
- **Error Diagnostics** — Malformed merge tags and unclosed loop tags now throw `DocGenException` with descriptive messages instead of silently producing broken output.
- **Multiline Text Preservation** — Newlines in Long Text Area and Text Area fields now render as proper Word line breaks (`<w:br/>`) with correct run element handling.
- **Smart Container Expansion** — Loop tags inside numbered/bulleted lists now repeat the list paragraph formatting. Previously only table rows were detected.
- **`ahe()` Helper** — Consistent `AuraHandledException` creation with original exception logging. All 38 throw sites migrated.
- **Universal File Save** — `saveContentVersion()` gracefully handles objects that don't support `FirstPublishLocationId` or `ContentDocumentLink` (e.g., Pricebook2).
- **507/507 Apex tests**, 79% coverage, 0 Critical/High. E2E 22/22.

## v1.1.0 — "Pixel-Perfect PDF" (Portwood DocGen)

Huge thanks to **@josephedwards-png** for PR #46 — his analysis of the relId collision bug and namespacing approach was the key insight that unlocked header/footer image rendering.

- **Header/Footer Rendering in PDF** — Full formatting, borders, merge tags, images. Headers at top, footers pinned to bottom.
- **Namespaced Image RelIds** — `header1_rId1`, `footer1_rId1` prevent collisions. Credit: @josephedwards-png PR #46.
- **Dynamic Style Resolution** — Table borders, cell padding, page size/margins all read from `styles.xml` and `w:sectPr` at render time.
- **PDF Merger Restored** — Generate+merge, merge-only, document packets with client-side PDF merging.
- **Client-Side DOCX Assembly** — Zero heap ZIP. Per-image Apex calls with fresh 6MB heap each.
- **507/507 Apex tests**, 81% coverage, 0 Critical/High. E2E 22/22.
- Templates with headers/footers must be re-saved to pick up the fix.

## v1.0.8 — "Full Release" (Portwood DocGen)

**IMPORTANT: If upgrading from the old unnamespaced "Document Generation" package, you MUST uninstall it first.** The new package uses the `portwoodglobal` namespace — the two cannot coexist. Go to Setup > Installed Packages > Document Generation > Uninstall, then install this version.

- **Website Live** — [portwoodglobalsolutions.com](https://portwoodglobalsolutions.com) — landing page with install links and live demo
- **DocGenDataProvider Interface** — Custom Apex data sources for templates. Implement `getData(Id recordId)` and `getFieldNames()` to supply data from any source — external APIs, computed fields, cross-object aggregations. V4 query config: `{"v":4,"provider":"ClassName"}`
- **Apex Provider in Query Builder** — Toggle between Standard Object and Apex Provider. Searchable class picker finds all `DocGenDataProvider` implementations. Tags preview from `getFieldNames()`
- **Flow Actions Expanded** — Single generation: Save to Record, Document Title override, Content Version ID output. Bulk generation: Combined PDF Only, Keep Individual Files, Batch Size, Job Label
- **Mobile Support** — Responsive CSS, utility bar target, flow screen compatible
- **Bulk Runner UX** — "Combined PDF Only" / "Combined + Individual PDFs" replaces confusing merge toggles
- **Sample Record Picker** — Persistent bar above all tabs in edit modal
- **507 Apex Tests Passing** — 83% code coverage, 0 Critical, 0 High on Code Analyzer
- **E2E: 22/22** — includes V4 provider tests, image rendering, junction stitching, aggregates
- **Package Install Tracker** — DevHub dashboard with version history, install notifications, auto-refresh

## v1.0.4 — "Namespace Release" (Portwood DocGen)
- **Namespaced Package** — DocGen is now distributed as `portwoodglobal` namespaced unlocked 2GP package via Portwood Global Solutions. Existing unnamespaced installs must uninstall and reinstall.
- **Namespace-Aware LWC** — All Lightning Web Components now use `@salesforce/schema` imports for field access, ensuring correct field resolution in namespaced subscriber orgs. Fixes "undefined" and "field does not exist" errors.
- **Visual Query Builder Fixes** — Tag copy now works in all Lightning contexts (clipboard fallback). "Change Object" button added to tree header. Parent field search preserves selections when filtering.
- **Manual Query Mode** — Toggling to Manual now converts V3 JSON to readable V1 SOQL format. Editable and saveable as V1.
- **Sample Templates Fixed** — Sample templates now create proper version snapshots with metadata headers and image extraction. No more "undefined" in template lists.
- **Bulk Runner UX** — "Combined PDF Only" and "Combined + Individual PDFs" replace confusing "Merge PDFs" / "Merge Only" toggles. Combined-only is now the default (saves heap).
- **Sample Record Promoted** — Record picker moved to persistent bar above all tabs in the edit modal. Accessible from any tab.
- **Permission Sets Updated** — All custom fields, Apex classes, VF pages, and tabs audited and corrected for both Admin and User permission sets.
- **Dead Code Removed** — Removed vestigial DocGenVerify VF page (e-signature leftover).
- **Code Quality** — 161 assertion messages added, 64 missing braces fixed, 11 parseInt radix fixes. Code Analyzer: 0 Critical, 0 High.
- **E2E Tests** — 20 tests (added doc generation size check). All 495 Apex tests passing, 83% coverage.
- **Support** — hello@portwoodglobalsolutions.com

## v2.7.0.7 — "Beacon"
- **Header/Footer Images in PDF** — Fixed: images in Word headers and footers now render in PDF output. The template image extraction now parses `word/_rels/header*.xml.rels` and `word/_rels/footer*.xml.rels` in addition to the main document rels. All image relationship IDs are combined so `buildPdfImageMap()` can resolve them. Templates with header/footer images must be re-saved to pick up the fix.
- **Add Related Records UI Refresh** — Fixed: clicking "Add Related Records" now immediately updates the document structure tree and tabs without requiring navigation away and back.
- **All 495 Apex tests passing** (100% pass rate). E2E 19/19. Code Analyzer: 0 Critical, 0 High, 0 Medium.

## v2.7.0.6 — "Beacon"
- **Pre-flight Job Analysis** — The Bulk Runner now runs a comprehensive governor limit analysis on "Validate Filter". Checks SOQL queries per batch, DML statements, record count limits, and heap usage (merge mode). The Run button is disabled until the filter is validated and all checks pass.
- **Dynamic Junction Target ID** — Report import now dynamically resolves the lookup field on junction objects (e.g., `ContactId` on `OpportunityContactRole`) instead of hardcoding. Works for any junction relationship, not just Contact.
- **View Job Button Fix** — The "View Job" button on the batch status card is now clearly visible (uses `variant="inverse"` for white-on-blue).
- **All 495 Apex tests passing** (100% pass rate). E2E 19/19. Code Analyzer: 0 Critical, 0 High, 0 Medium.

## v2.7.0.5 — "Beacon"
- **Default Template Auto-Select** — Fixed: templates marked as "Default Template for this Object" now auto-select in the document runner when opening a record page. Previously the dropdown always started on "Choose a template..." regardless of the default setting.
- **One Default Per Object Enforcement** — Setting a template as default now automatically unsets any other default for the same object. Previously multiple templates could be toggled as default simultaneously.
- **Tab Character Rendering** — Fixed: Word tab characters (`<w:tab/>`) are now correctly rendered as fixed-width spaces in PDF output. A parsing bug caused `<w:tab` to be misidentified as `<w:t>` (text), silently dropping all tab stops.
- **HeapEstimate Null Safety** — `HeapEstimate.isRisk` now initializes to `false` instead of `null`, preventing null-check failures when heap estimation encounters an exception.
- **Test Coverage** — All 491 Apex tests passing (100% pass rate). E2E 19/19. New test for default template enforcement.

## v2.7.0.4 — "Beacon"
- **Proactive Heap Estimator** — The Bulk Runner now automatically estimates the final heap usage before you start a merge job. It simulates a single document generation and projects the total memory requirement, warning you if the job is likely to exceed the 12MB limit.
- **Word Header/Footer Support for PDF** — Content in Word headers and footers (like company addresses and logos) is now correctly included when generating PDFs.
- **Fixed Run Data Loss** — Resolved an issue where text or merge tags in a Docx run were lost if the run also contained a line break (`<w:br/>`).
- **Query Sanitization Graceful Failure** — Invalid clauses in query configurations no longer fail the entire generation.
- **Improved Parent Object Detection** — Fixed self-referential lookup detection.

## v2.6.0 — "Apollo+"
- **Bulk Data Pre-Cache** — All record data queried in a single SOQL with an IN clause during batch `start()`, cached as a JSON ContentVersion on the Job record. Each `execute()` reads from cache instead of re-querying. Eliminates 500+ individual SOQL queries for V3 configs. Graceful fallback to per-record queries for V1/V2 or if cache exceeds 4MB.
- **Template Static Cache** — Template metadata, file content, and pre-decomposed XML parts are cached statically across batch executions. First record queries the template; remaining records reuse it. Zero redundant template SOQL.
- **Merge PDFs Mode** — New "Merge PDFs" checkbox in bulk runner. Generates individual PDFs per record AND produces a single merged PDF at the end. HTML captured as a byproduct of `renderPdf()` — zero extra processing per record.
- **Merge Only Mode** — New "Merge Only" checkbox. Skips `Blob.toPdf()` and ContentVersion saves per record entirely. Only generates HTML snippets, assembles once in a Queueable, renders one merged PDF. ~5-8x faster than individual PDF generation for large batches.
- **Server-Side PDF Assembly** — `DocGenMergeJob` Queueable reads HTML snippets by title prefix, concatenates with page breaks, calls `Blob.toPdf()` once, saves merged PDF linked to the Job record. Accessible anytime via `Merged_PDF_CV__c`.
- **Custom Notifications** — Bell icon + Salesforce mobile push notification on all bulk job completions. Merge jobs notify with page count; normal jobs notify with success/fail count. Tapping navigates to the Job record. Uses `DocGen_Job_Complete` custom notification type.
- **Configurable Batch Size** — New "Batch Size" input in bulk runner UI (1-200, default 1). Simple text-only templates can use 10-50 for faster throughput. Complex templates with images stay at 1 for max heap.
- **lookupField Bug Fix** — Query tree builder now uses the actual lookup field API name from schema describe (`opt.lookupField`) instead of guessing from the parent object name. Fixes incorrect SOQL for custom objects where the lookup field name doesn't match the object name (e.g., `abc__Purchase_Order__c` vs `abc__PurchaseOrder__c`).
- **DateTime Filter Fix** — `getObjectFields()` now returns field type metadata. Filter builder appends `T00:00:00Z` to date-only values on datetime fields. Report filter import applies the same fix for standard datetime fields like CreatedDate.
- **Image Deduplication Confirmed** — Tested `Blob.toPdf()` image handling: same image URL repeated across pages is stored once in the PDF (confirmed via size analysis). Template logos on 500 pages = one embedded image, not 500.
- **New Custom Objects/Fields** — `Data_Cache_CV__c` (bulk data cache), `Merged_PDF_CV__c` (merged PDF link), `Merge_Only__c` (merge-only flag) on DocGen_Job__c. "Merging" status added to Status picklist. `DocGen_Job_Complete` custom notification type.
- **New Apex Classes** — `DocGenMergeJob` (Queueable for server-side PDF assembly).
- **E2E Tests** — 19/19 passing. No regressions from bulk caching or merge changes.

## v2.5.0 — "Apollo+"
- **Child Record PDF Merge** — New "Child Record PDFs" mode in the document generator. Pick a child relationship (e.g., Opportunities from Account), optionally filter with a WHERE clause, browse PDFs attached to each child record with grouped checkboxes and Select All, merge selected PDFs into one document. Download or save to parent record.
- **Bulk Generate + Merge** — After a bulk PDF job completes, merge all generated PDFs into a single downloadable document. Merge icon button on each completed job in the Recent Jobs list for easy access later.
- **Named Bulk Jobs** — Give bulk jobs a custom name (e.g., "March Receipts") for easy identification. Search bar filters the Recent Jobs list by name, template, or status.
- **Aggregate Format Specifiers** — Aggregate tags now support format suffixes: `{SUM:LineItems.TotalPrice:currency}` → $55,000.00. Works with `:currency`, `:percent`, `:number`, and custom patterns like `:#,##0.00`.
- **Aggregate Bug Fix** — Fixed silent failure when format specifiers (`:currency`, etc.) were appended to aggregate tags. The format suffix was being included in the field name lookup, causing the tag to resolve to "0" or disappear.
- **VF Fallback Removed** — Removed `DocGenPdfRenderer` VF page and `DocGenPdfRendererController`. `Blob.toPdf()` with the Spring '26 Release Update handles all PDF rendering. Eliminates the last security scan violation and reduces attack surface.
- **Security Hardening** — Zero PMD security violations. All 22 findings resolved: SOQL injection (validated inputs + NOPMD), CRUD (package-internal objects with permission sets), XSS (ID validation + escaping).
- **Page Breaks in Loops** — README now documents how to use Word page breaks inside child loops for one-page-per-record output (receipts, invoices, certificates).
- **E2E Test Coverage** — 6 new aggregate tests (T14-T19): COUNT, SUM, SUM:currency, AVG, MIN, MAX. Total: 19 tests.

## v2.4.0 — "Apollo+"
- **QR Codes** — `{*Field:qr}` generates QR codes in PDF output. Supports up to 255 characters (full text field). Custom sizing: `{*Field:qr:200}` for 200px square. Version 1-14 with Level M error correction and Reed-Solomon.
- **Barcode Sizing** — `{*Field:code128:300x80}` for custom barcode dimensions.
- **Number & Currency Formatting** — `{Amount:currency}` → $500,000.00. Also `:percent`, `:number`, and custom patterns like `{Price:#,##0.00}`.
- All 13 barcode/QR tests passing, E2E 13/13.

## v2.3.0 — "Apollo+"
- **PDF Merger** — Generate a document and merge it with existing PDFs on the record in one step. Client-side merge engine (`docGenPdfMerger.js`) — pure JS, no external dependencies, zero heap.
- **Merge-Only Mode** — Combine existing PDFs without generating a template. Dual-listbox for reordering. Select 2+ PDFs, merge, download or save.
- **Document Packets** — Select multiple PDF templates, generate each for the same record, merge into one combined document. Optionally append existing PDFs.
- **Aggregate Tags** — `{SUM:QuoteLineItems.TotalPrice}`, `{COUNT:Contacts}`, `{AVG:...}`, `{MIN:...}`, `{MAX:...}`. Computed from child record data already in memory — zero extra SOQL.
- **Barcode Tags** — `{*FieldName}` renders Code 128 barcodes as CSS bars in PDF output. No images, no fonts — pure HTML/CSS rendered by `Blob.toPdf()`.
- **Excel (XLSX) Output** — Upload an Excel template with merge tags in cells. Engine parses shared strings table, inlines references, merges tags, and assembles via client-side ZIP. Same pattern as DOCX.
- **Save to Record for All Formats** — DOCX, XLSX, and PDF can all be saved back to the record. Previously PDF-only.
- **Query Builder Fix** — Selecting fields, changing the search filter, and selecting more fields no longer loses previous selections. Hidden selections are preserved across filter changes.
- **Show Selected Toggle** — New button in the query builder to filter the field list to only selected fields. Works alongside search.
- **Robust PDF Parsing** — Root catalog detection follows `startxref` spec path with nested `<<>>` dictionary handling. Works with PDF 1.5+ cross-reference streams.
- **Page Ordering Fix** — Merged PDFs preserve correct reading order from each document's page tree.

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
