# Salesforce Document Generation Platform

**A free, native, production-ready document engine for Salesforce.**

[![Version](https://img.shields.io/badge/version-1.3.2-blue.svg)](#quick-install)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Salesforce-00A1E0.svg)](https://www.salesforce.com)
[![API Version](https://img.shields.io/badge/API-v66.0-orange.svg)](#)
[![Dependencies](https://img.shields.io/badge/JS%20dependencies-zero-brightgreen.svg)](#)
[![Buy Amanda a Coffee](https://img.shields.io/badge/Buy_Amanda_a_Coffee-%E2%98%95-FFDD00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/davemoudya)

Generate DOCX, PPTX, and PDF documents from any Salesforce record. Merge fields, loop over child records, inject images, collect legally-binding electronic signatures, and render PDFs -- all 100% server-side, without leaving Salesforce, and without paying a dime.

---

## Table of Contents

- [Why This Exists](#why-this-exists)
- [Quick Install](#quick-install)
- [What's New in v1.2.2](#whats-new-in-v122)
- [What's New in v1.2.0](#whats-new-in-v120)
- [What's New in v1.1.1](#whats-new-in-v111)
- [What's New in v1.1.0](#whats-new-in-v110)
- [Features at a Glance](#features-at-a-glance)
- [Getting Started](#getting-started)
  - [Permission Sets](#permission-sets)
  - [Adding Components to Record Pages](#adding-components-to-record-pages)
  - [E-Signature Site Setup](#e-signature-site-setup)
  - [Email Branding](#email-branding)
- [Template Authoring Guide](#template-authoring-guide)
  - [How Merge Tags Work](#how-merge-tags-work)
  - [Tag Syntax Reference](#tag-syntax-reference)
  - [Working with Child Records](#working-with-child-records)
  - [Image Injection](#image-injection)
  - [Date Formatting](#date-formatting)
  - [Conditional Sections](#conditional-sections)
  - [Signature Placeholders](#signature-placeholders)
- [E-Signatures](#e-signatures)
  - [Signature Roles](#signature-roles)
  - [Signer Templates](#signer-templates)
- [Bulk Generation](#bulk-generation)
- [Flow Integration](#flow-integration)
- [Architecture](#architecture)
- [In-App Admin Guide](#in-app-admin-guide)
- [Changelog](#changelog)
- [Contributing](#contributing)
- [License](#license)

---

## Why This Exists

Document generation in Salesforce is expensive. The market leaders charge per-user, per-month fees that quickly add up across an organization. We believe basic document needs should be accessible to everyone.

This project gives you a professional-grade document engine -- template management, bulk generation, flow integration, server-side PDF rendering, image injection, and multi-signer electronic signatures -- entirely for free and fully open-source.

---

## Quick Install

**Package Version ID**: `04tdL000000Rd0TQAS`

**CLI:**
```bash
sf package install --package 04tdL000000Rd0TQAS --wait 10 --installation-key-bypass
```

**Browser:**
- [Install in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000Rd0TQAS)
- [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000Rd0TQAS)

> Select **Install for Admins Only** during installation, then assign permission sets to your users.

> **Required after install:** You must enable the Spring '26 Release Update **"Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations"** for PDF generation to work correctly. Without it, PDFs will render raw CSS as visible text and images will not appear. Go to [Setup > Release Updates](/lightning/setup/ReleaseUpdates/home) and enable it. This is opt-in until Summer '26 when Salesforce enforces it for all orgs. See [Required: Enable Updated Blob.toPdf()](#required-enable-updated-blobtopdf-spring-26) for full details.

## Known Limitations

DocGen runs 100% on the Salesforce platform, which means it operates within [Apex Governor Limits](https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_gov_limits.htm). Here's what that means in practice:

| Limit | Value | What It Means |
|-------|-------|---------------|
| **Heap size (synchronous)** | 6 MB | The maximum memory available for a single document generation from a record page or Flow. This includes the template file, merged data, images, and the output document — all held in memory at once. |
| **Heap size (asynchronous)** | 12 MB | The limit for bulk generation jobs, which run as Batch Apex. Each record gets its own 12 MB transaction. |
| **SOQL queries** | 100 per transaction | Each document generation uses queries to fetch the record, parent fields, and child lists. The [Query Builder](#getting-started) limits parent fields to **10** and child relationships to **5** to keep well within this budget. |
| **SOQL subqueries** | 20 per transaction | Salesforce limits the number of child relationship subqueries in a single SOQL statement. The Query Builder's 5-relationship cap provides a safe margin. |
| **Total query rows** | 50,000 per transaction | All records returned across all queries count toward this limit. Child loops with thousands of records (e.g., 500 line items per Opportunity) can approach this. |

**Large Documents & Images** — Because PDF rendering and image injection happen server-side, memory usage climbs with each image. If your documents include multiple images, use optimized/low-resolution versions to avoid `LimitException: Apex heap size too large`.

**Is this right for you?** — If your use case consistently requires documents or image data larger than these limits, this tool may not be the right fit in its current state. For very large documents, consider the [client-side generation option](https://github.com/DaveMoudy/SalesforceDocGen/issues/23) which offloads assembly to the browser.

## What's New in v1.3.2

### Bug Fix: PDF Images Broken in Single-Record Generation
- Template images in PDFs were rendering as broken placeholders since v1.2.0
- Root cause: `buildPdfImageMap()` was prepending the org domain to ContentVersion URLs, creating absolute URLs. `Blob.toPdf()` only resolves **relative** Salesforce paths (`/sfc/servlet.shepherd/version/download/...`)
- Fix: Use relative ContentVersion download URLs, matching the original design from commit `35ea7cb`

### Bug Fix: PDF Loses Space Between Bold Merge Fields (#34)
- A space between two adjacent bold merge fields (e.g., `{FirstName} {LastName}`) was being dropped in PDF output
- Root cause: `String.isBlank(" ")` returns `true` in Apex, so whitespace-only text runs were discarded
- Fix: Changed to `String.isEmpty()` which preserves space-only content

### Bug Fix: Character Encoding (#21)
- Fixed `&` characters rendering as `&amp;` in PDF output -- the HTML renderer was double-encoding XML entities from the DOCX source

### Documentation Overhaul
- **Release Update visibility** -- Added prominent callout immediately after Quick Install explaining the required Spring '26 Blob.toPdf() Release Update. This was the #1 source of confusion for new users (Issues #27, #21, #28)
- **In-app admin guide** -- Added Release Update warning to the Overview section with a direct link to [Setup > Release Updates](/lightning/setup/ReleaseUpdates/home)
- **Query Builder limits** -- Expanded from one-word reasons to full explanations of why each limit exists, what Salesforce enforces, and links to Salesforce Governor Limits documentation
- **Troubleshooting** -- Added "PDF shows raw CSS text" as the first troubleshooting entry, pointing users directly to the Release Update
- **Known Limitations** -- Replaced terse limit descriptions with a detailed table explaining heap size, SOQL queries, subqueries, and total query rows in practical terms

### Rich Text Field Documentation
- Corrected inaccurate "plain text only" language -- DocGen already preserves bold, italic, underline, paragraph structure, and embedded images from Rich Text Area fields in Word and PDF output
- Added new **Rich Text Fields** section to README and in-app Admin Guide documenting what is and isn't preserved

### Page Layouts
- Updated all 9 custom object page layouts from DevOrg-398

---

## What's New in v1.2.2

### E-Signature PDF Fix
- Signed PDFs now save correctly to the original record after all signers complete
- Fixed `Related_Record_Id__c` lookup -- no longer relies on fragile ContentDocumentLink traversal
- Fixed base64 `data:image/...` prefix not being stripped before signature image decoding
- Signature images now render in the signed PDF via committed ContentVersion download URLs
- Added `Database.AllowsCallouts` to the Stage 2 render Queueable

### Automated Process User Compatibility
- Signature PDF generation runs entirely through `Blob.toPdf()` -- no Visualforce page access required
- Requires the Spring '26 Release Update: **"Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations"**
- Added `DocGenPdfRendererController`, `DocGenSignatureController`, and `DocGenSignatureService` class access to Admin and User permission sets
- Added VF page access (`DocGenPdfRenderer`, `DocGenSignature`) to Admin and User permission sets
- Error audit logging: signature PDF failures now create a `DocGen_Signature_Audit__c` record with the error message instead of failing silently

### Admin Guide
- New **Data Model** section with complete object reference tables, signature flow lifecycle, and relationship diagram
- Signature placeholders now recommend always using `{#Signature_RoleName}` format

### Page Layouts
- Added page layouts for all 9 custom objects

---

## What's New in v1.2.0

### Unified PDF Generation (#27, #21)
- Single and bulk PDF generation now use the **exact same code path** -- no more divergent behavior between single-doc and batch modes
- Removed 6 redundant PDF methods from `DocGenController` and 5 from `DocGenService`, replaced with a single unified pipeline: `mergeTemplate()` → `buildPdfImageMap()` → `DocGenHtmlRenderer.convertToHtml()` → PDF engine
- Removed `DocGenPdfQueueable` -- no longer needed; PDF generation is synchronous with pre-committed template image URLs
- LWC polling logic removed from both `docGenRunner` and `docGenAdmin` -- PDF calls are now simple request/response

### Spring '26 Blob.toPdf() Compatibility
- Orgs with the Spring '26 Release Update enabled get native `Blob.toPdf()` rendering with image support -- no VF page needed
- Orgs without the Release Update automatically fall back to VF `renderAs="pdf"` (Flying Saucer) for templates with images
- Text-only templates always use `Blob.toPdf()` directly for speed

### Page Break Fix (#21)
- Added `page-break-inside: avoid` to `<p>` and `<li>` CSS rules -- paragraphs and list items no longer split across page boundaries

### Net Change
- **-766 lines** of duplicated PDF logic removed across 11 files

---

## What's New in v1.1.1

### Signature Fix (#28)
- Fixed single-signer signature flow failing with "Script-thrown exception"
- The VF page now uses an `isSignerToken` flag instead of signer count to route correctly -- works whether 1 or many signers are created through the multi-signer flow

### Enhanced PDF Renderer (#27)
- Users no longer need to add CSS to templates for proper PDF output
- `DocGenHtmlRenderer` now converts Word heading styles (H1-H6), Title, and Subtitle to proper HTML tags
- Added support for: line spacing, page breaks (`pageBreakBefore`, `w:br type="page"`), paragraph borders and shading, bullet and numbered lists, hanging indents, superscript/subscript, all caps/small caps, hyperlinks, tab characters, horizontal rules, letter spacing, and `keepNext`/`keepLines` page-break controls
- Tables now support: cell-specific borders, column span (`gridSpan`), custom cell padding (`tcMar`), header rows (`<th>`), and table alignment (center/right)
- Base CSS includes orphan/widow control and `page-break-inside: avoid` on table rows

### Merge Field Compatibility
- Templates now accept Salesforce-style `{!Field}` syntax in addition to `{Field}`
- Base object prefix is automatically stripped (e.g., `{!Contact.Name}` resolves the same as `{Name}` when running on Contact)

### Query Config Parser Fix
- The field parser now handles missing commas between fields and subqueries (e.g., `Account.Name (SELECT ...)` is auto-split correctly)

---

## What's New in v1.1.0

### In-App Admin Guide
- Comprehensive admin guide accessible as the **first tab** in the DocGen app
- 14 sections covering every feature: templates, merge tags, signatures, roles, email branding, logo hosting, permissions, versioning, flow automation, and troubleshooting
- Documents the `{%ImageField:WxH}` image injection syntax with ContentVersion usage

### Template Version Preview
- Version preview modal redesigned to show the **query configuration** that was active at that time
- **Download** the exact template file from any version
- **Generate a sample document** using a previous version's template against your test record
- Active/inactive status badges on each version

### Email Branding & Copy
- Customizable **email subject line**, **footer text**, **logo**, and **brand color** for signature request emails
- All configurable from the DocGen Setup tab
- Support for merge fields in the subject: `{SignerName}`, `{DocumentTitle}`, `{SenderName}`

### Security Hardening
- All DML operations wrapped with `Security.stripInaccessible()` for CRUD/FLS enforcement
- SOQL filter sanitization strengthened with whitespace normalization
- Signature token generation upgraded from `Math.random()` to `Crypto.generateAesKey(256)`
- Error messages genericized to prevent information disclosure
- Debug logging levels reduced to prevent sensitive data exposure
- Added explicit `WITH SYSTEM_MODE` to all system-context queries
- Passed Salesforce Code Analyzer with zero actionable high-severity findings

### Bug Fixes
- Fixed setup wizard email preview typo
- Fixed duplicate `rawPreviewJson` getter in query builder
- Removed unused JavaScript imports and duplicate class members

---

## Features at a Glance

| Feature | Description |
|---------|-------------|
| **Template Manager** | Create, edit, version, and share document templates with a visual query builder |
| **Record Page Generator** | Drop-in LWC component -- users select a template and generate from any record |
| **PDF Generation** | Server-side DOCX-to-PDF via `Blob.toPdf()` with automatic VF fallback for image support |
| **Bulk Generation** | Generate documents for hundreds of records with real-time progress tracking |
| **Flow Integration** | Invocable actions for single-record and bulk generation in any Flow |
| **Electronic Signatures** | Multi-signer, role-based signatures with branded emails and audit trails |
| **Image Injection** | Embed images from ContentVersion files, rich text fields, or base64 data |
| **Template Versioning** | Full version history with preview, download, restore, and sample generation |
| **Admin Guide** | Built-in comprehensive guide as the first tab in the app |
| **Document Authenticator** | SHA-256 hash verification of signed PDFs (client-side, no upload) |

---

## Getting Started

### Permission Sets

After installing, assign these from **Setup > Permission Sets**:

| Permission Set | Who Gets It | What It Grants |
|---------------|-------------|----------------|
| **DocGen Admin** | Admins, template managers | Full CRUD on all DocGen objects, setup wizard access, template sharing |
| **DocGen User** | End users | Generate documents, view templates (read-only), manage own signature requests |
| **DocGen Guest Signature** | Site guest user only | Signature submission via public VF pages (never assign to internal users) |

### Adding Components to Record Pages

**Document Generator** -- lets users generate documents from any record:
1. Navigate to a record page > Gear icon > **Edit Page**
2. Drag the **docGenRunner** component onto the layout
3. Save and activate

**Signature Sender** -- lets users send documents for e-signature:
1. Same process, drag **docGenSignatureSender** onto the page
2. Shows recently generated documents and tracks signature status

### E-Signature Site Setup

E-signatures require a Salesforce Site (not Experience Cloud):

1. Go to **Setup > Sites** > click **New**
2. Configure:
   - Site Label: **DocGen Signatures**
   - Active Site Home Page: **DocGenSignature**
   - Check **Active**
3. Click **Public Access Settings** > add **DocGenSignature** to Enabled Visualforce Page Access
4. Assign the **DocGen Guest Signature** permission set to the Site Guest User
5. Copy the Site URL and paste it in the **DocGen Setup** tab

> Signature links are secured with SHA-256 tokens and expire after 30 days.

### Required: Enable Updated Blob.toPdf() (Spring '26)

**This Release Update is required for all PDF generation**, not just signatures. The old `Blob.toPdf()` engine does not understand `<style>` blocks or `<img>` tags in HTML — it renders them as literal visible text in your PDF. The updated engine uses the same Visualforce PDF rendering service (Flying Saucer) that powers `renderAs="pdf"`, giving you proper CSS, image, and font support.

**To enable:**
1. Go to [**Setup > Release Updates**](/lightning/setup/ReleaseUpdates/home)
2. Find **"Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations"**
3. Click **Get Started** > **Enable**

**What this does:**
- Upgrades `Blob.toPdf()` to use the same rendering engine as Visualforce `renderAs="pdf"`
- Enables CSS parsing (`<style>` tags), image rendering (`<img>` with Salesforce URLs), and modern font support
- Required for all PDF output — single-record, bulk, and signed PDFs

**Without this Release Update**, PDFs will contain raw CSS text instead of formatted content, and images will not render. This is the most common issue reported by new users.

> **Note:** This Release Update is opt-in until Summer '26 when Salesforce enforces it for all orgs.

**Why signatures are especially affected:** E-signature PDFs are generated by the Automated Process user via Platform Events and Queueable Apex. This system user cannot access Visualforce pages, so there is no fallback — `Blob.toPdf()` with the Release Update enabled is the only rendering path for signed documents.

### How the Automated Process User Works

When all signers complete their signatures, the following chain executes automatically:

1. The last signer's completion publishes a **Platform Event** (`DocGen_Signature_PDF__e`)
2. A **trigger** fires and enqueues a Queueable job (runs as the **Automated Process user**)
3. **Stage 1** stamps all signature images into the DOCX and saves the result as ContentVersion files on the Signature Request record
4. **Stage 2** (chained Queueable) reads those committed files, generates HTML with ContentVersion download URLs, and calls `Blob.toPdf()` to produce the final PDF
5. The signed PDF is saved to the **original record** (Account, Opportunity, etc.) and an audit trail is created

The Automated Process user has full data access via `SYSTEM_MODE` queries and `AccessLevel.SYSTEM_MODE` DML. It does **not** need permission sets for object access. However, it **does** require the Spring '26 `Blob.toPdf()` Release Update for proper PDF rendering since it cannot access Visualforce pages.

### Email Branding

Customize the emails sent to signers from the **DocGen Setup** tab (Step 2):

| Setting | Description | Default |
|---------|-------------|---------|
| **Company Name** | Shown in email header when no logo is set | (blank) |
| **Logo Image URL** | Company logo in email header (200x60px PNG recommended) | (blank) |
| **Brand Color** | Header bar and CTA button color | `#0176D3` |
| **Email Subject** | Supports merge fields: `{SignerName}`, `{DocumentTitle}`, `{SenderName}` | `Action Required: Please Sign {DocumentTitle}` |
| **Footer Text** | Custom text at email bottom | `Powered by DocGen` |

**Logo hosting tips:**
- For the best email experience, host your logo on a **public URL** (your company website or CDN)
- Salesforce-hosted images (ContentVersion, Static Resource) require authentication -- email clients won't render them
- If you have a Salesforce Site, you can serve a Static Resource through the Site URL for public access

---

## Template Authoring Guide

### How Merge Tags Work

DocGen uses **plain text replacement**. Each tag in your template is swapped with the corresponding field value. That's it.

**What this means:**
- Tags are replaced with **text values only** -- they won't insert images, charts, or media (use the `{%}` image tag for that)
- Tables don't dynamically expand -- use **loop tags** for repeating rows
- Formatting (bold, font, color) comes from your template, not the data -- the replaced text inherits the tag's formatting
- **Rich Text fields** preserve basic formatting in Word output (see [Rich Text Fields](#rich-text-fields) below)

### Tag Syntax Reference

| Tag | Purpose | Example |
|-----|---------|---------|
| `{FieldName}` | Simple field merge | `{Name}`, `{Email}` |
| `{Parent.Field}` | Parent record lookup | `{Account.Name}`, `{Owner.Email}` |
| `{#ChildList}...{/ChildList}` | Loop over child records | `{#Contacts}{FirstName}{/Contacts}` |
| `{#BooleanField}...{/BooleanField}` | Conditional section | `{#IsActive}Active{/IsActive}` |
| `{Field:format}` | Date with format | `{CloseDate:MM/dd/yyyy}` |
| `{%ImageField}` | Image (default 4"x3") | `{%Company_Logo__c}` |
| `{%ImageField:WxH}` | Image with pixel size | `{%Photo__c:200x150}` |
| `{#Signature}` | Single-signer placeholder | |
| `{#Signature_Role}` | Multi-signer placeholder | `{#Signature_Client}` |

### Working with Child Records

Loop tags repeat content for each child record. In tables, the entire row is duplicated:

| Product | Qty | Price |
|---------|-----|-------|
| `{#OpportunityLineItems}{Name}` | `{Quantity}` | `{TotalPrice}{/OpportunityLineItems}` |

Use the **relationship name** (not the object API name) as the loop tag. Configure child relationships and their fields in the Query Builder.

### Image Injection

Use `{%FieldName}` to dynamically insert images into Word documents. This is the one exception to the plain text rule.

```
{%Company_Logo__c}           -- Default size (4" x 3")
{%Photo__c:200x150}          -- 200px wide, 150px tall
{%Headshot__c:100x100}       -- 100px square
```

**Supported image sources** (what to store in the field):

| Source | Field Value | Example |
|--------|------------|---------|
| **ContentVersion ID** (recommended) | 18-char ID starting with `068` | `068xx0000012345AAA` |
| **Rich Text HTML** | Rich Text Area with embedded image | Any RTA field with an image |
| **Base64 data URI** | `data:image/png;base64,...` | Data URI string |
| **Salesforce file URL** | `/sfc/servlet.shepherd/...` | Salesforce file URL |

> **Best practice:** Upload your image as a Salesforce File, copy the ContentVersion ID, and store it in a text field. Then use `{%MyField__c:200x60}` in your template.

> Image tags only work in **Word (.docx)** templates. External URLs cannot be fetched (no HTTP callouts).

### Rich Text Fields

When a merge tag references a Rich Text Area field, DocGen automatically detects the HTML content and preserves formatting in Word and PDF output. No special syntax is needed -- just use the standard `{FieldName}` tag.

**What's preserved (Word & PDF):**
- **Bold**, *italic*, and underline formatting
- Paragraph structure (line breaks, paragraph breaks)
- Images embedded in the rich text field (Salesforce-hosted URLs and data URIs)

**What's NOT preserved:**
- Font colors, font sizes, and font families
- Text alignment (center, right, justify)
- Bullet and numbered lists (rendered as plain text paragraphs)
- Tables within the rich text field
- Hyperlinks (the text appears, but the link is not clickable)

**PowerPoint:** Rich text is stripped to plain text in `.pptx` output. Only Word and PDF preserve formatting.

**Images in Rich Text:** If your rich text field contains an embedded image (inserted via the Salesforce Rich Text editor), the image is automatically extracted and embedded in the output document. Salesforce-hosted image URLs are resolved to absolute paths so they render in both DOCX and PDF.

> **Tip:** For simple text fields (Name, Email, etc.), formatting comes from the template -- the merged value inherits whatever font/style the tag had in your Word file. For Rich Text Area fields, the formatting comes from the data itself and overrides the tag's template styling.

### Date Formatting

Append a format string after a colon:

| Example | Output |
|---------|--------|
| `{CloseDate:MM/dd/yyyy}` | 03/18/2026 |
| `{CreatedDate:MMMM d, yyyy}` | March 18, 2026 |
| `{CreatedDate:yyyy-MM-dd HH:mm}` | 2026-03-18 14:30 |

### Conditional Sections

Show or hide content based on field values:

```
{#HasSpecialTerms}
SPECIAL TERMS: This agreement includes special provisions...
{/HasSpecialTerms}
```

Content appears only if the field is truthy (non-null, non-empty, non-false).

### Signature Placeholders

**Single signer:** `{#Signature}`

**Multiple signers** (role-specific):
- `{#Signature_Client}`
- `{#Signature_Account_Executive}`
- `{#Signature_Witness}`

Role names use underscores for spaces. When signed, the placeholder is replaced with the drawn signature image plus a timestamp.

---

## E-Signatures

### How It Works

1. **Generate a document** with signature placeholders in the template
2. **Send for signature** from the Signature Sender component on the record page
3. **Signers receive branded emails** with secure links
4. **Signers review and sign** on a public page with a signature pad
5. **Signed PDF is generated** with all signatures stamped in place
6. **Audit trail** records signer name, email, IP, browser, timestamp, and SHA-256 hash

### Signature Roles

Roles map signers to specific locations in the document:

```
{#Signature_Client}       -- Where the client signs
{#Signature_Witness}      -- Where the witness signs
```

The Signature Sender auto-detects roles by scanning the document for `{#Signature_*}` placeholders.

### Signer Templates

Save frequently used role configurations:
1. Configure signers and roles in the Signature Sender
2. Click **Save as Template**
3. Load it next time from the dropdown -- roles are pre-populated

---

## Bulk Generation

1. Go to the **Bulk Generation** tab
2. Select a template
3. Enter a filter condition: `Industry = 'Technology'` or `StageName = 'Closed Won' AND CloseDate = THIS_YEAR`
4. Click **Count Records** to verify
5. Click **Generate** -- documents are saved as Files on each record
6. Monitor progress in the Recent Jobs section (auto-refreshes every 5s)

Save frequently used filters with **Save Query** for reuse.

---

## Flow Integration

**Generate Document (Single Record)** -- `DocGenFlowAction`:

| Parameter | Type | Description |
|-----------|------|-------------|
| `templateId` | Input | DocGen_Template__c record ID |
| `recordId` | Input | Source record ID |
| `contentDocumentId` | Output | Generated file ID |

**Generate Documents (Bulk)** -- `DocGenBulkFlowAction`:

| Parameter | Type | Description |
|-----------|------|-------------|
| `templateId` | Input | DocGen_Template__c record ID |
| `queryCondition` | Input | SOQL WHERE clause |
| `jobId` | Output | DocGen_Job__c record ID |

**Signature Actions** (for Experience Cloud flows):
- `DocGenSignatureValidator` -- Validates a signature token
- `DocGenSignatureFinalizer` -- Processes signature submission in system context
- `DocGenSignatureSubmitter` -- Handles signature from Flow context

---

## Architecture

All document generation runs **100% server-side in Apex** -- no client-side JavaScript.

```
Template (.docx/.pptx)
    → Decompress ZIP (Salesforce Compression API)
    → Pre-process XML (merge split text runs, normalize tags)
    → Tag Processing:
        {Field}           → plain text substitution
        {#List}...{/List} → row/content duplication
        {#Bool}...{/Bool} → conditional rendering
        {%Image:WxH}      → DrawingML image injection
    → Recompress ZIP → DOCX/PPTX Blob
    → PDF path: DocGenHtmlRenderer → Blob.toPdf()
    → Save as ContentVersion on record
```

### Key Classes

| Class | Responsibility |
|-------|---------------|
| `DocGenService` | Core merge engine -- tag processing, image injection, ZIP assembly |
| `DocGenHtmlRenderer` | DOCX XML to HTML conversion for `Blob.toPdf()` |
| `DocGenController` | LWC controller -- template CRUD, generation, versioning |
| `DocGenDataRetriever` | Dynamic SOQL with Schema validation |
| `DocGenSignatureService` | Signature stamping via OpenXML manipulation |
| `DocGenSignatureEmailService` | Branded HTML email generation |
| `DocGenBatch` | Batch Apex for bulk generation |

---

## In-App Admin Guide

DocGen includes a comprehensive **Admin Guide** built directly into the app as the first tab. It covers:

- Installation & setup walkthrough
- Template creation and the visual query builder
- Merge tag syntax with examples
- Dynamic image injection with `{%}` tags and ContentVersion IDs
- E-signature workflow, roles, and templates
- Email branding configuration
- Logo hosting options (external, Salesforce-hosted, Site-hosted)
- Sharing and permissions architecture
- Template versioning with preview, download, and rollback
- Flow and automation actions
- Troubleshooting common issues

Open the **DocGen Admin Guide** tab in the DocGen app to access it.

---

## Changelog

### v1.1.1
- **Signature Fix** (#28) -- Single-signer flow no longer fails; uses `isSignerToken` flag for correct routing
- **PDF Renderer** (#27) -- Full DOCX style conversion: headings, lists, line spacing, page breaks, borders, shading, hyperlinks, superscript/subscript, table enhancements
- **Merge Fields** -- `{!Field}` Salesforce-style syntax and base object prefix stripping now supported
- **Query Parser** -- Auto-splits fields from adjacent subqueries when comma is missing

### v1.1.0
- **Admin Guide** -- In-app admin guide as the first tab with 14 sections covering all features
- **Version Preview** -- Redesigned with query display, template download, and sample generation
- **Email Branding** -- Configurable subject, footer, logo, and brand color for signature emails
- **Security** -- `Security.stripInaccessible()` on all DML, `Crypto.generateAesKey()` for tokens, sanitization hardening, error message genericization
- **Image Documentation** -- `{%ImageField:WxH}` syntax with ContentVersion usage documented in-app

### v1.0.0
- **Server-Side PDF** -- All PDF generation uses `DocGenHtmlRenderer` + `Blob.toPdf()`. Zero client-side JavaScript.
- **Removed** -- All third-party JS libraries, client-side rendering pipeline
- **Security** -- API version 66.0, CRUD/FLS enforcement, verbose debug logging removed
- **Signature** -- Server-side document preview and PDF generation for the signing portal

### v0.9.x
- PKCE Auth Fix, wizard UX improvements, credential provisioning

### v0.8.0
- Fixed package uninstall blockers, updated terminology

### v0.7.0 and earlier
- Bulk PDF generation, transaction finalizer retries, security hardening, compression API migration, multi-signer roles, rich text support, 2GP package

---

## Contributing

This is an open-source project under the Apache license, Version 2.0 . We welcome contributions:

1. Fork the repository
2. Create a feature branch
3. Submit a pull request with a clear description

Report bugs and feature requests via [GitHub Issues](https://github.com/DaveMoudy/SalesforceDocGen/issues).

---

## License

This project is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.
