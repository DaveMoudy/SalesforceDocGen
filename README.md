# Salesforce Document Generation Platform

**A free, native, production-ready document engine for Salesforce.**

[![Version](https://img.shields.io/badge/version-0.5.0-blue.svg)](#quick-install)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Salesforce-00A1E0.svg)](https://www.salesforce.com)

Generate DOCX, PPTX, and PDF documents from any Salesforce record. Merge fields, loop over child records, inject images from rich text fields, collect legally-binding electronic signatures, and render PDFs -- all without leaving Salesforce, and without paying a dime.

---

## Why This Exists

Document generation in Salesforce is expensive. The market leaders charge per-user, per-month fees that quickly add up across an organization. We believe basic document needs should be accessible to everyone.

This project gives you a professional-grade document engine -- template management, bulk generation, flow integration, background PDF rendering, rich text with embedded images, and multi-signer electronic signatures -- entirely for free and fully open-source.

---

## Quick Install

### v0.5.0 -- Sandbox / Developer Org

**Subscriber Package Version ID**: `04tdL000000Ooi1QAC`

**CLI:**
```bash
sf package install --package 04tdL000000Ooi1QAC --wait 10 --installation-key-bypass
```

**Browser:**
- [Install in Developer Org](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000Ooi1QAC)
- [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000Ooi1QAC)

### v0.5.0 -- Production

To promote this version for production installation:

```bash
sf package version promote --package 04tdL000000Ooi1QAC
```

> Select **Install for Admins Only** during installation, then assign permission sets to your users afterward.

---

## What's New in v0.5.0

This release represents a major evolution from the initial v0.1.0:

- **100% Server-Side Document Generation** -- Replaced client-side docxtemplater/PizZip with a native Apex engine using Salesforce's Compression API. All merge tag processing, image injection, and loop expansion now happens server-side with zero browser dependencies.
- **Multi-Signer Signature Roles** -- Define roles (Buyer, Seller, Witness, etc.) per template. Each signer receives a unique secure link and signs independently. Documents are stamped only after all parties complete.
- **Visualforce Signature Portal** -- Replaced the Experience Cloud Flow approach with a standalone VF page. Simpler setup, better mobile experience, client-side document preview with live signature rendering.
- **Rich Text & HTML Support** -- Template tags now preserve rich text formatting. Embedded `<img>` tags in rich text fields are automatically extracted and injected as DrawingML images in the DOCX output.
- **Image Size Controls** -- Use `{%ImageField:WxH}` syntax to specify exact pixel dimensions for injected images.
- **Client-Side PDF Rendering** -- VF-based PDF engine uses docx-preview.js for high-fidelity DOCX rendering, then html2pdf.js for conversion. Cross-origin postMessage communication between LWC and VF iframe.
- **Background PDF Rendition** -- Asynchronous PDF rendering via Named Credential loopback with built-in retry mechanism for Salesforce's rendition API latency.
- **Previous Signature Request Recall** -- View and copy links from past signature requests directly from the record page.
- **SLDS Mobile Accessibility** -- Updated all components to use density-aware utility classes and labeled buttons for mobile compatibility.
- **2GP Package Ready** -- Full SYSTEM_MODE query support for package-internal objects, permission set-aware test harness, and security-reviewed stripInaccessible enforcement.

---

## Features

### Template Manager

The central hub for creating, editing, and versioning document templates.

- Upload `.docx` or `.pptx` template files with merge tags
- Visual Query Builder for selecting fields, parent lookups, and child relationships -- no SOQL knowledge required
- Manual query mode for advanced users who want direct control
- Template versioning with full history, restore, and preview
- One-click test generation with sample records
- Template sharing with user/group access control

**Access:** Navigate to the **DocGen Template Manager** tab in the DocGen app.

### Record Page Generator

Drop-in Lightning Web Component for generating documents from any record page.

- Add `docGenRunner` to any Lightning Record Page via App Builder
- Users select from available templates filtered to that object
- One-click generation produces DOCX with automatic PDF rendition
- Generated documents attach to the record's Files related list

### Bulk Document Generation

Generate documents for hundreds or thousands of records in a single batch.

- Filter records with SOQL WHERE clauses (with validation)
- Real-time progress tracking with success/error counts
- Save and reload frequently-used filter queries
- Background processing via Apex Batch -- documents attach to each record automatically

**Access:** Navigate to the **DocGen Bulk Gen** tab.

### Flow Integration

Two invocable actions for embedding document generation into any Salesforce Flow.

**Single Record** (`DocGenFlowAction`):
- Inputs: `templateId`, `recordId`
- Outputs: `contentDocumentId`, `errorMessage`
- Use in Screen Flows, Record-Triggered Flows, or Autolaunched Flows

**Bulk/Batch** (`DocGenBulkFlowAction`):
- Inputs: `templateId`, `queryCondition` (optional WHERE clause)
- Outputs: `jobId`, `errorMessage`
- Ideal for Scheduled Flows -- generate monthly invoices, quarterly reports, etc.

### PDF Generation

Two rendering paths ensure PDF output works in every context:

**Client-Side (Record Page):**
- VF iframe receives the generated DOCX via postMessage
- docx-preview.js renders the document with full formatting fidelity (headers, footers, images)
- html2pdf.js converts the rendered HTML to PDF
- PDF is saved back to Salesforce as a ContentVersion

**Server-Side (Bulk & Flow):**
- Named Credential loopback calls Salesforce's Connect REST API for PDF rendition
- Built-in retry mechanism handles `202 Accepted` latency
- Wizard-driven setup on the DocGen Setup tab walks you through Connected App, Auth Provider, and Named Credential creation in 4 steps
- Platform Event or direct Queueable enqueue depending on the calling context

### Native Electronic Signatures

A zero-cost, multi-signer electronic signature system built entirely on Salesforce.

- **Role-based signing** -- define Buyer, Seller, Witness, Manager, or any custom role per template
- **Secure token links** -- each signer receives a unique URL with a cryptographic token
- **Visualforce signing portal** -- mobile-friendly signature capture with live document preview, no Experience Cloud configuration required
- **OpenXML signature stamping** -- signature PNGs are injected directly into the DOCX source at role-specific placeholders before PDF conversion
- **SHA-256 tamper evidence** -- every signed PDF is hashed, creating an immutable audit trail for non-repudiation
- **Signature templates** -- save signer configurations for reuse across documents
- **Previous request history** -- view past signature requests and copy links from the record page

### Template Tag Syntax

Tags are placed directly in your `.docx` or `.pptx` template files:

| Tag | Purpose | Example |
|-----|---------|---------|
| `{FieldName}` | Simple field merge | `{Name}`, `{Account.Industry}` |
| `{Parent.Field}` | Parent record lookup | `{Account.Name}`, `{Owner.Email}` |
| `{#ChildList}...{/ChildList}` | Loop over child records | `{#Contacts}{FirstName} {LastName}{/Contacts}` |
| `{#BooleanField}...{/BooleanField}` | Conditional section | `{#IsActive}Active{/IsActive}` |
| `{%ImageField}` | Image injection (default size) | `{%Company_Logo__c}` |
| `{%ImageField:WxH}` | Image with pixel dimensions | `{%Photo__c:400x300}` |
| `{#Signature}` | Single-signer signature placeholder | |
| `{#Signature_RoleName}` | Multi-signer placeholder | `{#Signature_Buyer}`, `{#Signature_Witness}` |

Tags inside table rows are automatically detected and expand into multiple rows during generation.

---

## Architecture

### Document Generation Pipeline

All document generation runs **100% server-side in Apex** -- no client-side JavaScript templating libraries are required for document creation.

```
Template (.docx/.pptx)
    |
    v
Decompress ZIP (Salesforce Compression API)
    |
    v
Pre-process XML
    |-- Merge split text runs (<w:r> elements)
    |-- Normalize template tags across formatting boundaries
    |
    v
Tag Processing (Server-side Apex)
    |-- Simple substitution: {Field} -> value
    |-- Loop expansion: {#List}...{/List} -> repeated content
    |-- Conditional rendering: {#Bool}...{/Bool}
    |-- Image injection: {%Image} -> DrawingML <w:drawing> elements
    |-- Rich text HTML -> extracted images + inline formatted text
    |
    v
Recompress ZIP + Save as ContentVersion
    |
    v
PDF Rendition (two paths):
    |-- Server-side: Named Credential loopback via REST API
    |   |-- GET /services/data/v63.0/connect/files/{id}/rendition?type=PDF
    |   |-- Retry on 202 (up to 3 attempts)
    |-- Client-side: VF page renders DOCX preview + html2pdf conversion
    |
    v
Save PDF as ContentVersion (attached to record)
```

### Signature Flow

```
Admin generates signature links from record page
    |
    v
Each signer receives unique URL:
    https://your-site.salesforce-sites.com/apex/DocGenSignature?token=<secure_token>
    |
    v
Signer opens link -> VF page validates token
    |-- Fetches DOCX blob for client-side preview
    |-- Renders document in browser
    |
    v
Signer draws signature on canvas -> saves PNG
    |
    v
All signers complete?
    |-- Yes -> Stamp all signature PNGs into DOCX at role placeholders
    |       -> Browser renders stamped DOCX to PDF
    |       -> Upload PDF + compute SHA-256 hash
    |       -> Create audit trail per signer
    |-- No  -> Wait for remaining signers
```

---

## Setup Guide

### 1. Install the Package

Use the install links above. Select **Install for Admins Only**.

### 2. Assign Permission Sets

| Permission Set | For | Access |
|---------------|-----|--------|
| **DocGen Admin** | Template managers, admins | Full access: create/edit/delete templates, bulk generation, sharing, setup wizard |
| **DocGen User** | End users | Generate documents from existing templates, view template tags |
| **DocGen Guest Signature** | Site guest users | Signature submission only (VF pages + signature objects) |

Go to **Setup > Permission Sets**, open the appropriate set, and click **Manage Assignments** to add users.

### 3. Add the Generator to Record Pages

1. Navigate to any record page (e.g., an Account or Opportunity)
2. Click the gear icon > **Edit Page**
3. Drag the **docGenRunner** component onto the page layout
4. Save and activate

### 4. Configure the PDF Engine (Required for PDF Output)

1. Navigate to the **DocGen Setup** tab in the DocGen app
2. Follow the 4-step wizard:
   - **Step 1:** Create a Connected App named "DocGen Loopback" with OAuth scopes `api` and `refresh_token`
   - **Step 2:** Create an Auth Provider using the Consumer Key/Secret from Step 1
   - **Step 3:** Create a Named Credential (`DocGen_Loopback`) with the External Credential, then authenticate as a named principal
   - **Step 4:** Configure your Salesforce Site URL for public signature links
3. Assign the `DocGen Admin` and `DocGen User` permission sets to the Named Credential's External Credential principal

### 5. Configure Electronic Signatures (Optional)

E-signatures require a Salesforce Site for public access to the signing VF page:

1. **Create a Salesforce Site** -- Go to **Setup > Sites**, create a new site with:
   - Site label: `DocGen Signatures` (or your preference)
   - Default page: `DocGenSignature`
   - Active: checked
2. **Configure Guest Access** -- On the site's guest user profile:
   - Add `DocGenSignature`, `DocGenSign`, and `DocGenVerify` to **Enabled Visualforce Page Access**
   - Assign the `DocGen Guest Signature` permission set to the guest user
3. **Save Site URL** -- In the **DocGen Setup** wizard (Step 4), enter your site's base URL (e.g., `https://yourorg.my.salesforce-sites.com`)
4. **Create Signature Templates** (optional) -- Pre-define signer roles for reuse across documents

No Experience Cloud site, Flow embedding, or Screen Flow configuration is needed. The VF pages handle everything natively.

---

## Project Structure

```
force-app/main/default/
  classes/              26 Apex classes (services, controllers, batch, queueable, tests)
  lwc/                  12 Lightning Web Components
  objects/              9 custom objects + 1 platform event + 1 custom setting
  pages/                4 Visualforce pages (PDF engine, signature portal, verification)
  permissionsets/       3 permission sets (Admin, User, Guest Signature)
  staticresources/      DocGenEngine bundle (docx-preview, jszip, html2pdf), mammoth, filesaver, sample templates
  triggers/             Platform event trigger for async PDF rendition
  applications/         DocGen Lightning App
  tabs/                 8 custom tabs
```

---

## Contributing

This is an open-source project under the MIT license. We welcome contributions:

1. Fork the repository
2. Create a feature branch
3. Submit a pull request with a clear description of your changes

Please report bugs and feature requests via [GitHub Issues](https://github.com/DaveMoudy/SalesforceDocGen/issues).

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
