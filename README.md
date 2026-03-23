# DocGen — Free Document Generation for Salesforce

Turn any Word template into a merged PDF or DOCX, straight from your Salesforce records.

[![Version](https://img.shields.io/badge/version-2.0.0_Apollo-blue.svg)](#install)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Salesforce-00A1E0.svg)](https://www.salesforce.com)
[![Buy Amanda a Coffee](https://img.shields.io/badge/Buy_Amanda_a_Coffee-%E2%98%95-FFDD00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/davemoudya)

---

## Install (2 minutes)

**Package Version ID**: `04tdL000000RnavQAC`

```bash
sf package install --package 04tdL000000RnavQAC --wait 10 --installation-key-bypass
```

Or click: [Install in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000RnavQAC) | [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000RnavQAC)

**After install:**
1. Assign the **DocGen Admin** permission set to yourself (Setup > Permission Sets)
2. Enable the **Blob.toPdf() Release Update** (Setup > Release Updates > "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations")
3. Open the **DocGen** app — the getting started guide walks you from there

---

## How It Works

1. **Name your template** — pick a name, output type (PDF or Word), and the Salesforce object
2. **Pick your data** — use the visual query builder to select fields, parent lookups, and child lists (supports deep nesting: Account → Opportunities → Line Items)
3. **Upload your Word file** — add merge tags like `{Name}`, `{Account.Name}`, or `{#Contacts}...{/Contacts}` where you want data
4. **Generate** — from any record page, or in bulk, or from a Flow

That's it. DocGen handles the rest — merging data, injecting images, rendering PDFs, all server-side.

---

## What You Can Put in Your Templates

| Tag | What It Does | Example |
|-----|-------------|---------|
| `{FieldName}` | Inserts a field value | `{Name}`, `{Email}`, `{Phone}` |
| `{Parent.Field}` | Pulls from a related record | `{Account.Name}`, `{Owner.Email}` |
| `{#ChildList}...{/ChildList}` | Repeats for each child record | `{#Contacts}{FirstName}{/Contacts}` |
| `{#Child}{#Grandchild}...` | Nested loops (deep relationships) | `{#Opportunities}{#OpportunityLineItems}{Name}{/OpportunityLineItems}{/Opportunities}` |
| `{Field:format}` | Formatted date | `{CloseDate:MM/dd/yyyy}` |
| `{%ImageField:WxH}` | Dynamic image from ContentVersion | `{%Logo__c:200x60}` |
| `{#BoolField}...{/BoolField}` | Show/hide based on field value | `{#IsActive}Active member{/IsActive}` |
| `{RichTextField}` | Full rich text (bold, italic, images) | `{Description}` on a Rich Text Area |

Tags inherit the formatting from your Word template — whatever font, color, and size the tag has in Word is what the output gets.

---

## Why No Signatures?

DocGen generates documents. That's it.

Electronic signatures carry legal requirements (ESIGN Act, eIDAS) that change by jurisdiction. Getting it wrong exposes you to liability. Dedicated providers like DocuSign and Adobe Sign carry their own compliance certifications. We don't, and we won't pretend to.

Generate your document with DocGen. Send it to a signature provider. Best tool for each job.

---

## Features

| Feature | Description |
|---------|-------------|
| **Command Hub** | One-tab experience: create templates, generate in bulk, get help — all in one place |
| **Visual Query Builder** | Point-and-click field selection with parent lookups and nested child lists |
| **Deep Relationships** | Account → Opportunities → Line Items → Schedules. No depth limit in templates. |
| **PDF Generation** | Server-side via `Blob.toPdf()` with zero-heap image rendering |
| **DOCX Output** | Client-side assembly for unlimited file sizes. Custom fonts carry through. |
| **Bulk Generation** | Hundreds of records with real-time progress tracking |
| **Flow Integration** | `DocGenFlowAction` (single) and `DocGenBulkFlowAction` (bulk) invocable actions |
| **Image Injection** | Dynamic images from ContentVersion IDs, rich text fields, or template-embedded graphics |
| **Template Versioning** | Full history with preview, download, restore, and sample generation |
| **PDF Merger** | Merge generated PDFs with existing PDFs on the record — client-side, no heap limits |
| **Zero External Dependencies** | No HTTP callouts, no JavaScript libraries, no external services |

---

## How DocGen Stays Under Salesforce Limits

Salesforce gives each transaction 6 MB of memory. DocGen uses three techniques to stay well under that:

| Technique | What It Does | Impact |
|-----------|-------------|--------|
| **Pre-decomposition** | When you save a template, DocGen unzips the .docx and stores each piece separately. At generation time, it loads only the XML — never the full ZIP. | ~75% heap reduction |
| **Zero-heap images** | Images are passed to the PDF engine by URL, not loaded into memory. 20+ large images render without using any of your 6 MB. | Unlimited images in PDFs |
| **Client-side DOCX** | For Word output, the browser assembles the final file. Each image gets its own request with fresh memory. | No size limit on DOCX |
| **Client-side PDF merge** | Existing PDFs are fetched one at a time (fresh heap each call), merged in the browser via a pure JS PDF engine. | Unlimited merge size |
| **Multi-level queries** | Deep relationships (grandchildren) use one SOQL query per level, not per record. Results are stitched together in Apex. | 3 levels = 3 queries |

---

## For Developers

### Permission Sets

| Permission Set | Who | What |
|---------------|-----|------|
| **DocGen Admin** | Template managers | Full CRUD, template sharing, setup |
| **DocGen User** | End users | Generate documents, view templates |

### Flow Actions

| Action | Inputs | Output |
|--------|--------|--------|
| `DocGenFlowAction` | templateId, recordId | contentDocumentId |
| `DocGenBulkFlowAction` | templateId, queryCondition | jobId |

### Architecture

```
Template (.docx) → Decompress → Merge XML tags → Recompress → DOCX/PDF
                                                    ↓
                              PDF: DocGenHtmlRenderer → Blob.toPdf()
```

| Class | Role |
|-------|------|
| `DocGenService` | Core merge engine — tags, images, ZIP |
| `DocGenHtmlRenderer` | XML → HTML for PDF rendering |
| `DocGenDataRetriever` | Dynamic SOQL with multi-level stitching |
| `DocGenController` | LWC controller — template CRUD, generation |
| `DocGenBatch` | Batch Apex for bulk jobs |

### PDF Merger

Generate a document from your template and merge it with existing PDFs already attached to the record — all in one step.

1. Select a PDF template from the record page
2. Check **Merge with existing PDFs on this record**
3. Pick which PDFs to append
4. Click **Generate & Merge** — downloads or saves a single combined PDF

The merge runs entirely client-side using `docGenPdfMerger.js` (pure JS, no external libraries). Each source PDF is fetched via its own Apex call with fresh 6 MB heap, then the browser handles the binary merge — no server-side size constraints.

### PDF Font Support

PDF output supports **Helvetica**, **Times**, **Courier**, and **Arial Unicode MS** only — this is a Salesforce platform limitation (`Blob.toPdf()` does not support `@font-face`). For custom fonts, generate as DOCX.

### Known Limits

| Limit | Value | Notes |
|-------|-------|-------|
| Heap (synchronous) | 6 MB | Single record generation from UI or Flow |
| Heap (asynchronous) | 12 MB | Bulk generation via Batch Apex |
| SOQL queries | 100 | ~3 used per relationship depth level |
| Query rows | 50,000 | Watch child loops with thousands of records |

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full version history.

---

## Contributing

Open-source under Apache 2.0. We welcome contributions:

1. Fork the repo
2. Create a feature branch
3. Submit a PR with a clear description

Report bugs via [GitHub Issues](https://github.com/DaveMoudy/SalesforceDocGen/issues).

[![Buy Amanda a Coffee](https://img.shields.io/badge/Buy_Amanda_a_Coffee-%E2%98%95-FFDD00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/davemoudya)

---

## License

Apache License, Version 2.0. See [LICENSE](LICENSE).
