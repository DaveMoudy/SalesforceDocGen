# DocGen — Free Document Generation for Salesforce

Generate PDFs, Word docs, Excel spreadsheets, and PowerPoint presentations from any Salesforce record. Merge PDFs, add barcodes and QR codes, compute totals — 100% native, zero external dependencies, completely free.

[![Version](https://img.shields.io/badge/version-2.7.0.7_Beacon-blue.svg)](#install)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Salesforce-00A1E0.svg)](https://www.salesforce.com)
[![Code Analyzer](https://img.shields.io/badge/Critical-0-brightgreen)](#code-quality)
[![Code Analyzer](https://img.shields.io/badge/High-0-brightgreen)](#code-quality)

---

## Install

```bash
sf package install --package 04tdL000000S3arQAC --wait 10 --installation-key-bypass
```

[Install in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000S3arQAC) | [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000S3arQAC)

**Then:** Assign **DocGen Admin** permission set | Enable **Blob.toPdf() Release Update** | Open the **DocGen** app

---

## Quick Start

1. **Create a template** — pick Word, Excel, or PowerPoint. Choose your Salesforce object.
2. **Select your fields** — use the visual query builder to pick fields, parent lookups, and child records.
3. **Add tags and upload** — type `{Name}` where you want data. Upload the file.
4. **Generate** — from any record page, in bulk, or from a Flow.

---

## Merge Tags

| Tag | What It Does | Example |
|-----|-------------|---------|
| `{FieldName}` | Insert a field value | `{Name}`, `{Email}`, `{Phone}` |
| `{Parent.Field}` | Pull from a related record | `{Account.Name}`, `{Owner.Email}` |
| `{#ChildList}...{/ChildList}` | Repeat for each child record | `{#Contacts}{FirstName}{/Contacts}` |
| `{#BoolField}...{/BoolField}` | Show/hide based on field value | `{#IsActive}Active member{/IsActive}` |
| `{RichTextField}` | Rich text with formatting and images | `{Description}` on a Rich Text Area |

### Formatting

| Tag | Output | Works In |
|-----|--------|----------|
| `{CloseDate:MM/dd/yyyy}` | 03/18/2026 | All formats |
| `{Amount:currency}` | $500,000.00 | All formats |
| `{Rate:percent}` | 15.5% | All formats |
| `{Quantity:number}` | 1,234 | All formats |
| `{Price:#,##0.00}` | 1,234.56 | All formats |

### Aggregates

Place these **outside** the loop to compute totals from child records:

| Tag | Example |
|-----|---------|
| `{SUM:List.Field}` | `{SUM:QuoteLineItems.TotalPrice}` |
| `{COUNT:List}` | `{COUNT:Contacts}` |
| `{AVG:List.Field}` | `{AVG:OpportunityLineItems.UnitPrice}` |
| `{MIN:List.Field}` / `{MAX:List.Field}` | `{MIN:QuoteLineItems.Quantity}` |

Zero extra SOQL — computed from child data already in memory.

### Barcodes & QR Codes

Rendered as CSS in PDF output. No fonts, no images, no external services.

| Tag | What You Get |
|-----|-------------|
| `{*ProductCode}` | Code 128 barcode |
| `{*ProductCode:code128:300x80}` | Barcode at 300px wide, 80px tall |
| `{*Website:qr}` | QR code at 150px (default) |
| `{*TrackingUrl:qr:200}` | QR code at 200px square |

QR codes support up to **255 characters** — enough for a full Salesforce text field or URL.

### Images

| Tag | What It Does |
|-----|-------------|
| `{%Logo__c:200x60}` | Insert image at 200x60px from ContentVersion ID |
| `{%Photo__c}` | Insert image at default size (4" x 3") |

Store a ContentVersion ID (starts with `068`) in a text field. Works in Word templates — PDF and DOCX output.

### Page Breaks in Loops

Child loops repeat whatever content is between the opening and closing tags — **including page breaks**. This means you can put each child record on its own page just by adding a page break inside the loop.

**Example: One receipt per Opportunity**

Say you have an Account with multiple Opportunities and you want each Opportunity printed as a separate receipt page. In your Word template:

```
{#Opportunities}
                    RECEIPT
Customer:   {Account.Name}
Date:       {CloseDate:MM/dd/yyyy}
Amount:     {Amount:currency}
Rep:        {Owner.Name}

Thank you for your business!
                                        ← page break here
{/Opportunities}
```

Insert the page break in Word (Insert → Page Break, or Ctrl+Enter) right before the closing `{/Opportunities}` tag. Each Opportunity gets its own full page.

**How to set it up:**
1. Open your `.docx` template in Word
2. Place your opening loop tag (`{#Opportunities}`) at the top
3. Design one page of content using merge tags
4. At the bottom, insert a **Page Break** (Insert → Page Break)
5. Place the closing tag (`{/Opportunities}`) right after the page break
6. Upload the template — each child record gets its own page

This works with any child loop — Contacts, Line Items, Cases, custom objects. Anything you can loop over, you can page-break over. Combine it with images, barcodes, QR codes, and formatting tags to build invoices, packing slips, certificates, or anything that needs one page per record.

---

## Template Formats

| Format | Template | Output | Images | Barcodes/QR | Rich Text | Best For |
|--------|----------|--------|--------|-------------|-----------|----------|
| **Word** | `.docx` | PDF or DOCX | Yes | Yes (PDF) | Yes | Contracts, proposals, letters, invoices |
| **Excel** | `.xlsx` | XLSX | No | No | No | Data exports, reports, financial summaries |
| **PowerPoint** | `.pptx` | PPTX | No | No | No | Presentations, slide decks |

All formats support: field tags, parent lookups, child loops, aggregates, conditionals, date formatting, number/currency formatting.

**Word** is the most capable — it's the only format that supports images, barcodes, QR codes, rich text, and PDF output.

---

## PDF Merger

Five ways to combine PDFs, all running client-side in the browser:

| Mode | How It Works |
|------|-------------|
| **Generate & Merge** | Generate from a template, then append existing PDFs from the record |
| **Document Packets** | Select multiple templates, generate them all, merge into one PDF |
| **Merge Only** | Combine existing PDFs on the record with drag-and-drop ordering |
| **Child Record PDFs** | Pick a child relationship (e.g., Opportunities), filter, select PDFs from child records, merge |
| **Bulk Merge** | After bulk generation, merge all generated PDFs into one downloadable document |

Each PDF is fetched in its own Apex call (fresh 6 MB heap). The merge engine (`docGenPdfMerger.js`) handles the binary work — parsing object graphs, renumbering references, flattening page trees, writing cross-reference tables. No size limits on download. Save to record up to ~3 MB.

**Child Record PDFs** — From a parent record (e.g., Account), select a child relationship, optionally filter with a WHERE clause (e.g., `StageName = 'Closed Won' AND CloseDate = THIS_MONTH`), browse PDFs grouped by child record with Select All, and merge into one document.

**Bulk Merge** — After running bulk generation, each completed job shows a merge icon in the Recent Jobs list. Click it to download all generated PDFs merged into a single file. Name your jobs for easy searching later.

---

## How It Stays Under Salesforce Limits

| Technique | What It Does | Impact |
|-----------|-------------|--------|
| **Pre-decomposition** | Templates unzipped on save; generation loads only XML, never the full ZIP | ~75% heap reduction |
| **Zero-heap images** | PDF images referenced by URL, not loaded into memory | Unlimited images |
| **Client-side assembly** | Browser builds DOCX/XLSX files; each image gets its own request | No size limit |
| **Client-side PDF merge** | PDFs fetched one at a time, merged in browser via pure JS engine | Unlimited merge |
| **Multi-level queries** | One SOQL per relationship depth, stitched in Apex | 3 levels = 3 queries |

---

## Automation

### Flow Actions

| Action | Inputs | Output |
|--------|--------|--------|
| `DocGenFlowAction` | templateId, recordId | contentDocumentId |
| `DocGenBulkFlowAction` | templateId, queryCondition | jobId |

Both work in Record-Triggered Flows, Screen Flows, and Subflows.

### Bulk Generation

Generate documents for hundreds of records at once. Enter a filter condition, click Submit. Real-time progress tracking via the Bulk Generate tab.

### Record Page Component

Drop `docGenRunner` onto any Lightning Record Page via App Builder. Full UI with template selection, output mode, PDF merging, and document packets.

---

## Limitations

| Limitation | Details | Workaround |
|-----------|---------|------------|
| **PDF fonts** | Helvetica, Times, Courier, Arial Unicode MS only | Generate as DOCX for custom fonts |
| **PDF file size** | ~3 MB per individual PDF for merge/save | Download has no limit |
| **Barcodes/QR** | PDF output only | Not available in DOCX/XLSX/PPTX |
| **Images** | Word templates only | Place static images directly in Excel/PPTX |
| **Excel/PPTX output** | Native format only, no PDF conversion | Use Word template for PDF |
| **Heap (sync)** | 6 MB per transaction | Use DOCX output for large docs (client-side assembly) |
| **Heap (async)** | 12 MB per batch execute | Batch size 1 gives fresh heap per record |
| **No e-signatures** | Intentionally excluded | Use DocuSign, Adobe Sign, etc. after generation |

---

## Architecture

```
Template (.docx/.xlsx/.pptx)
    ↓
Decompress → Merge XML tags → Recompress
    ↓                              ↓
  DOCX/XLSX/PPTX              PDF path:
  (client-side ZIP)     DocGenHtmlRenderer → Blob.toPdf()
```

| Class | Role |
|-------|------|
| `DocGenService` | Core merge engine — tags, loops, images, aggregates, barcodes |
| `DocGenHtmlRenderer` | DOCX XML → HTML for PDF rendering, barcode/QR CSS |
| `DocGenDataRetriever` | Multi-level SOQL with query tree stitching |
| `BarcodeGenerator` | Code 128 + QR code generation (pure Apex, Reed-Solomon) |
| `DocGenController` | LWC controller — template CRUD, generation endpoints |
| `DocGenBatch` | Batch Apex for bulk document generation |
| `docGenPdfMerger.js` | Client-side PDF merge engine (pure JS) |
| `docGenZipWriter.js` | Client-side Office Open XML assembly (pure JS) |

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full version history.

---

## Code Quality

Scanned with [Salesforce Code Analyzer](https://developer.salesforce.com/docs/platform/salesforce-code-analyzer/overview) v5.9.0 (engines: PMD, ESLint, RetireJS, CPD, Flow Scanner).

### Security & Severity Scorecard

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | Passed |
| High | 0 | Passed |
| Moderate | 413 | Style / complexity |
| Low | 511 | Informational |
| Info | 26 | Duplicate detection |

### E2E Test Results

```
sf apex run --target-org <org> -f scripts/e2e-test.apex

PASS: 19  FAIL: 0  ALL TESTS PASSED
```

| # | Test | Result |
|---|------|--------|
| T1 | Account Name field merge | PASS |
| T2 | Owner.Name parent field lookup | PASS |
| T3 | Contacts child loop (2 records) | PASS |
| T4 | Opportunities child loop (1 record) | PASS |
| T5 | Product2.Name on Line Items (parent field through child) | PASS |
| T6 | Line Items count (2 records) | PASS |
| T7 | Description ContentVersion ID (image field) | PASS |
| T8 | Legacy V1 backward compatibility | PASS |
| T9 | Image CV ID format validation | PASS |
| T10 | Image CV file accessibility | PASS |
| T11 | PDF document generation (Blob.toPdf) | PASS |
| T12 | Generated file not empty | PASS |
| T13 | Junction stitching (OCR -> Contact) | PASS |
| T14 | COUNT:Contacts aggregate | PASS |
| T15 | SUM:LineItems.TotalPrice aggregate | PASS |
| T16 | SUM with :currency formatting | PASS |
| T17 | AVG:UnitPrice aggregate | PASS |
| T18 | MIN:Quantity aggregate | PASS |
| T19 | MAX:Quantity aggregate | PASS |

### QR Code Verification

QR encoding verified module-by-module against [qrcode-generator](https://www.npmjs.com/package/qrcode-generator) reference library for versions 1 (21x21), 3 (29x29), and 6 (41x41). All modules match. See `scripts/qr-verify.js`.

---

## Contributing

Open-source under Apache 2.0. Contributions welcome:

1. Fork the repo
2. Create a feature branch
3. Submit a PR with a clear description

Report bugs via [GitHub Issues](https://github.com/DaveMoudy/SalesforceDocGen/issues).

---

## License

Apache License, Version 2.0. See [LICENSE](LICENSE).
