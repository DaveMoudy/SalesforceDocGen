# CLAUDE.md — SalesforceDocGen Project Guidelines

## Critical: Blob.toPdf() Image URL Rules

The Spring '26 `Blob.toPdf()` rendering engine has strict requirements for image URLs in HTML:

- **MUST use relative Salesforce paths**: `/sfc/servlet.shepherd/version/download/<ContentVersionId>`
- **NEVER use absolute URLs**: `https://domain.com/sfc/servlet.shepherd/...` — fails silently (no exception, broken image)
- **NEVER use data URIs**: `data:image/png;base64,...` — not supported, renders broken

In `DocGenService.buildPdfImageMap()`, do NOT prepend `URL.getOrgDomainUrl()` to ContentVersion download URLs. Keep them relative. The `Blob.toPdf()` engine resolves relative Salesforce paths internally.

## Critical: Zero-Heap PDF Image Rendering

For PDF output, `{%ImageField}` tags with ContentVersion IDs MUST skip blob loading. The `currentOutputFormat` static variable is set to `'PDF'` before `processXml()` calls. In `buildImageXml()`, when `currentOutputFormat == 'PDF'` and the field value is a ContentVersion ID (`068xxx`), query only `Id, FileExtension` (NOT `VersionData`) and store the relative URL. This is what enables unlimited images in PDFs without heap limits.

**NEVER** add `VersionData` to the SOQL query in the PDF path. Each image blob would consume 100KB-5MB+ of heap, and with multiple images this immediately exceeds governor limits.

## PDF Image Pipeline

### How template images are prepared (on save)

When an admin saves a template version (via `DocGenController.saveTemplate()`), the system calls `DocGenService.extractAndSaveTemplateImages(templateId, versionId)`. This method:

1. Downloads the DOCX/PPTX ZIP from the template's ContentVersion
2. Reads `word/_rels/document.xml.rels` to find all `<Relationship>` entries with `Type` containing `/image`
3. For each image relationship, extracts the image blob from `word/media/`
4. Saves each image as a new ContentVersion with `Title = docgen_tmpl_img_<versionId>_<relId>` and `FirstPublishLocationId = versionId`

This pre-extraction is essential — it creates committed ContentVersion records that `Blob.toPdf()` can reference by relative URL at generation time.

### How template images are rendered (on generate)

At PDF generation time, `buildPdfImageMap()` queries for these pre-committed CVs:
- Finds the active template version
- Queries `ContentVersion WHERE Title LIKE 'docgen_tmpl_img_<versionId>_%'`
- Builds relative URLs: `/sfc/servlet.shepherd/version/download/<cvId>`
- `DocGenHtmlRenderer.convertToHtml()` embeds these as `<img src="/sfc/...">` in the HTML
- `Blob.toPdf()` resolves the relative paths and renders the images

## Package Info

- Package type: Unlocked 2GP (no namespace)
- DevHub: `namespace-org` (davemoudy398@agentforce.com)
- Default target org: `DevOrg - 398`
- Namespace `docgensig` is registered on `DocGen - DevOrg` but linking to DevHub is blocked (OAuth redirect_uri_mismatch)

## Key Architecture

- PDF rendering has two paths in `mergeTemplate()`:
  1. **Pre-decomposed (preferred)**: Loads XML parts from ContentVersions saved during template version creation. Skips ZIP decompression entirely. ~75% heap savings. Used for PDF output when XML CVs exist.
  2. **ZIP path (fallback)**: Full base64 decode + ZIP decompression. Used for DOCX/PPTX output, or PDF when pre-decomposed parts don't exist (older templates not yet re-saved).
- After merge: `buildPdfImageMap()` → `DocGenHtmlRenderer.convertToHtml()` → `Blob.toPdf()` with VF page fallback
- The Spring '26 Release Update "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations" is REQUIRED

## Client-Side DOCX Assembly (In Progress)

DOCX generation now uses client-side ZIP assembly to avoid Apex heap limits:

### How it works
1. Server calls `generateDocumentParts()` which merges XML using `currentOutputFormat='PDF'` trick (skips blob loading)
2. Server returns: `allXmlParts` (merged XML + passthrough entries), `imageCvIdMap` (mediaPath → CV ID), `imageBase64Map` (template media)
3. Client deduplicates CV IDs and calls `getContentVersionBase64()` for each **unique** CV — each call gets fresh 6MB heap
4. Client builds ZIP from scratch via `buildDocx()` in `docGenZipWriter.js` (pure JS, no dependencies)
5. Download works for unlimited size. Save-to-record blocked by Aura 4MB payload limit (needs chunking or alternative).

### Key files
- `docGenRunner/docGenZipWriter.js` — Pure JS ZIP writer (store mode, CRC-32). Exports `buildDocx(xmlParts, mediaParts)` and `buildDocxFromShell()`
- `DocGenService.generateDocumentParts()` — Returns merged parts without ZIP assembly
- `DocGenController.getContentVersionBase64()` — Returns single CV blob as base64, each call = fresh heap
- `DocGenController.generateDocumentParts()` — AuraEnabled endpoint

### Important: rels XML must include ALL image relationships
In both `mergeTemplate()` (full ZIP path, ~line 174) and `tryMergeFromPreDecomposed()` (~line 293), the pending images loop that adds relationships to rels XML must process ALL images, not just ones with blobs. URL-only images need rels entries too for DOCX.

### LWS Constraints
- Lightning Web Security blocks `fetch()` to `/sfc/servlet.shepherd/` URLs (CORS redirect to `file.force.com`)
- All binary data must be returned via Apex, not client-side fetch
- `Blob` constructor in LWC rejects non-standard MIME types — use `application/octet-stream` for DOCX downloads

## E-Signatures: Removed (Decision Record)

E-signature functionality was **intentionally removed** from DocGen. The rationale:

1. **Legal liability** — Electronic signatures carry jurisdiction-specific legal requirements (ESIGN Act, eIDAS, etc.). A document generator shipping its own signature implementation exposes both the product and its users to legal risk if the implementation doesn't meet the relevant standard for a given use case. Dedicated e-signature providers (DocuSign, Adobe Sign, etc.) carry their own legal compliance certifications — we don't.
2. **Security surface area** — The signature flow required a public-facing Salesforce Site with guest user access, token-based authentication, image upload endpoints, and cross-context PDF generation via platform events. Each of these is an attack vector: XSS in document previews, image injection via unvalidated uploads, token interception, and DOM manipulation of the signing page. Hardening these to production-grade security is a full-time security engineering effort, not a side feature.
3. **Scope creep** — Signatures pulled focus from the core mission: being the best document generator on the platform. Every hour spent on signature audit trails, email branding, multi-signer orchestration, and PIN verification is an hour not spent on rendering fidelity, font support, template features, and output quality.
4. **Better path forward** — The architecture supports a clean integration point for third-party signature providers in the future. Generate the document with DocGen, hand it off to a dedicated provider for signing. Best tool for each job.

**What was removed:** 8 Apex classes, 7 custom objects (50+ fields), 2 VF pages, 3 LWC bundles, 2 Aura apps, 1 trigger, 1 permission set, 5 layouts, 5 settings fields, 2 tabs, 1 flow, 1 Salesforce Site config. ~9,700 lines of code.

**Do NOT re-add signature functionality.** If signature integration is needed, build an adapter pattern that delegates to an external provider.

## Font Support

### PDF output
`Blob.toPdf()` uses Salesforce's Flying Saucer rendering engine which only supports 4 built-in font families:
- **Helvetica** (`sans-serif`) — the default
- **Times** (`serif`)
- **Courier** (`monospace`)
- **Arial Unicode MS** — for CJK/multibyte characters

Custom fonts **cannot** be loaded into the PDF engine. CSS `@font-face` is not supported — not via data URIs, static resource URLs, or ContentVersion URLs. This is a Salesforce platform limitation, not a DocGen limitation. Paid tools like Nintex and Conga work around this by using their own rendering engines outside of Salesforce.

**Do NOT re-add custom font upload for PDF.** It was built, tested exhaustively (base64 data URIs, static resource URLs, ContentVersion URLs), and confirmed not possible.

### DOCX output
DOCX output preserves whatever fonts are in the template file. If users need custom fonts (branded typefaces, barcode fonts, decorative scripts), they should generate as DOCX. The fonts render correctly when opened in Word or any compatible viewer.

## Scratch Org for Testing

- Alias: `docgen-stress` (expires ~2026-03-28)
- Account: `001Ff00000MDKqsIAH` ("Stress Test Corp") — 500 Contacts, 1 Opportunity
- Template: "Stress Test - Large PDF" — programmatic DOCX with `{%Description}` image + Contact loop with `{%Title}` images
- Test image CV: `068Ff000006MHefIAG` (1.3MB PNG "Design") — stored in Account.Description and first 15 Contacts' Title field
- Release Update enabled

## E2E Test Script

**Every code change MUST be validated by the E2E test script.** If you add a feature, add a test for it in the script. If the script doesn't pass, the change doesn't ship.

Run: `sf apex run --target-org <org> -f scripts/e2e-test.apex`

The script is fully self-contained — creates its own template, DOCX file, template version, test data (Account, Contacts, Opportunity, Products, Line Items, Contact Roles, image CV), runs the V3 tree walker, validates parent fields, tests legacy backward compatibility, generates an actual PDF, validates junction stitching, and cleans up. Output: `PASS: 13  FAIL: 0  ALL TESTS PASSED`

**Requires:** Nothing. Zero dependencies on pre-existing org data. Works on any org with DocGen deployed.

**When adding features:**
1. Add test assertions to `scripts/e2e-test.apex`
2. Run the script — all tests must pass
3. If a test fails, fix before committing

Current tests (13): Account name, Owner.Name parent field, Contacts count, Opportunities count, Product2.Name on Line Items, Line Items count, Description CV ID, Legacy V1 backward compat, Image CV format, Image CV access, Document generation, Generated file not empty, Junction stitching (OCR → Contact).

## Query Config Formats

Three formats, all stored in `Query_Config__c` (32KB LongTextArea):

### V1 — Legacy flat string
```
Name, Industry, (SELECT FirstName, LastName FROM Contacts)
```
Detected by: does NOT start with `{`. Parsed by the original `getRecordData()` method.

### V2 — JSON flat (junction support)
```json
{"v":2,"baseObject":"Opportunity","baseFields":["Name"],"parentFields":["Account.Name"],
 "children":[{"rel":"OpportunityLineItems","fields":["Name"]}],
 "junctions":[{"junctionRel":"OpportunityContactRoles","targetObject":"Contact","targetIdField":"ContactId","targetFields":["FirstName"]}]}
```
Detected by: starts with `{`, `"v":2`. Parsed by `getRecordDataV2()`.

### V3 — Query tree (multi-object, any depth)
```json
{"v":3,"root":"Account","nodes":[
  {"id":"n0","object":"Account","fields":["Name"],"parentFields":["Owner.Name"],"parentNode":null,"lookupField":null,"relationshipName":null},
  {"id":"n1","object":"Contact","fields":["FirstName"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"},
  {"id":"n2","object":"Opportunity","fields":["Name","Amount"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Opportunities"},
  {"id":"n3","object":"OpportunityLineItem","fields":["Quantity"],"parentFields":["Product2.Name"],"parentNode":"n2","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}
]}
```
Detected by: starts with `{`, `"v":3`. Parsed by `getRecordDataV3()` tree walker. Each node is one SOQL query, stitched into parent's data map via `lookupField`.

**Backward compat:** All three formats work. The DataRetriever auto-detects the format and routes to the correct parser.

## Command Hub Architecture

The DocGen app has 2 tabs: "DocGen" (Command Hub) and "Job History".

The Command Hub (`docGenCommandHub` LWC) contains:
- Welcome banner (< 10 templates, dismissible)
- Quick action cards (Templates, Bulk Generate, How It Works)
- Embedded template manager (`docGenAdmin`)
- Embedded bulk runner (`docGenBulkRunner`, collapsible)
- Help section with merge tag cheat sheet, heap architecture explanation, Flow integration

The template wizard uses `docGenColumnBuilder` for the query builder step (tab-per-object layout with tree visualization). The old `docGenQueryBuilder` is still available via Manual Query toggle for legacy configs.

## Font Support

### PDF output
`Blob.toPdf()` only supports 4 built-in fonts: Helvetica (`sans-serif`), Times (`serif`), Courier (`monospace`), Arial Unicode MS. CSS `@font-face` is NOT supported. **Do NOT re-add custom font upload for PDF.**

### DOCX output
Preserves whatever fonts are in the template file.

## AppExchange

DocGen is NOT on the AppExchange. Do not reference AppExchange in user-facing documentation (admin guide, README). Code comments saying "AppExchange safe" (meaning no callouts/session IDs) are fine.
