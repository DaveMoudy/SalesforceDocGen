# Client-Side Document Generation (LWC)

**Date:** 2026-03-18
**Status:** Design approved
**Scope:** DOCX only (v1)

---

## Problem

The existing server-side Apex engine hits Salesforce governor limits during document assembly:

- Synchronous heap limit: 6 MB
- Asynchronous heap limit: 12 MB

Documents with multiple images or large templates can exceed these limits because Apex holds the entire ZIP (template + merged XML + images) in memory simultaneously during assembly.

---

## Solution

Move ZIP assembly to the browser. Apex continues to handle template retrieval and XML processing (reusing all existing logic), but stops before building the ZIP. The LWC receives the processed XML strings and image Content IDs, fetches images directly from Salesforce Files, and assembles the final DOCX ZIP in pure JavaScript.

Images flow: **Salesforce Files → Browser → ZIP** — never touching Apex heap.

---

## Opt-In Behavior

Client-side generation is opt-in. Server-side remains the default. Admins enable client-side by setting a property when placing `docGenRunner` on a Lightning record page, or via an org-wide `DocGen_Settings__c` field.

This is intentional — client-side generation is currently limited to DOCX output and represents a new code path. Users should consciously choose it.

---

## Architecture

### New Flow

```
User clicks "Generate Document" (client-side mode enabled)
  ↓
[Apex] DocGenController.generateDocumentDataForClient(templateId, recordId)
  ├─ DocGenTemplateManager    → reads + unzips template        (existing)
  ├─ DocGenDataRetriever      → fetches record data            (existing)
  └─ DocGenService            → processes XML, loops, conditionals (existing, refactored to expose pre-zip state)
  Returns: { xmlFiles, imagePaths, otherParts, fileName }
  ↓
[LWC] receives payload (no images ever in Apex heap)
  ↓
[LWC] fetches images in parallel via:
  fetch('/sfc/servlet.shepherd/version/download/{contentVersionId}')
  → ArrayBuffer (binary, no Base64 round-trip)
  ↓
[LWC] docGenZipWriter.js assembles DOCX ZIP in store mode (no compression)
  ↓
[LWC] triggers browser download or saves to record via ContentVersion REST API
```

### Apex Return Payload

```json
{
  "xmlFiles": {
    "word/document.xml": "<xml...>",
    "word/styles.xml": "<xml...>",
    "word/_rels/document.xml.rels": "<xml...>"
  },
  "imagePaths": {
    "word/media/image1.png": "068xx000001234AAA"
  },
  "otherParts": {
    "[Content_Types].xml": "<xml...>",
    "_rels/.rels": "<xml...>"
  },
  "fileName": "Contract_Acme.docx"
}
```

---

## Components

### 1. `DocGenController` — new `@AuraEnabled` method

```apex
@AuraEnabled
public static Map<String, Object> generateDocumentDataForClient(
    String templateId, String recordId
)
```

Internally delegates to existing classes. Returns the pre-zip payload above.

### 2. `DocGenService` — small refactor

Extract the post-merge, pre-zip state into a return value rather than immediately calling `assembleZip()`. The existing `assembleZip()` call path is preserved — this is additive, not a rewrite.

### 3. `DocGen_Settings__c` — new optional field

`Enable_Client_Side_Generation__c` (Checkbox, default `false`) — org-wide toggle so admins can enable client-side without updating every page layout.

### 4. `docGenRunner` — new component property + code path

New property:
```html
<c-doc-gen-runner enable-client-side-generation="true" record-id={recordId} />
```

Logic:
- If `enableClientSideGeneration = false` (default): existing server-side path, zero behavior change
- If `enableClientSideGeneration = true`:
  - DOCX templates → client-side path
  - PDF output type → show clear message: *"Client-side generation doesn't support PDF. Switch to server-side generation."*
  - On failure → show error toast + explicit *"Try server-side generation"* button (no silent fallback)

UI additions:
- Small badge: *"Client-side generation enabled"* when opt-in is active
- Spinner with *"Generating document..."* during assembly

### 5. `docGenZipWriter.js` — new pure JS ZIP utility

Location: `lwc/docGenRunner/docGenZipWriter.js`

Implements ZIP store mode (no DEFLATE compression required for valid DOCX):

```
For each file entry:
  1. Local File Header  (30 bytes + filename)
  2. Raw file data      (UTF-8 for XML, ArrayBuffer for images)

Then:
  3. Central Directory entries
  4. End of Central Directory Record

Output: Uint8Array → Blob → <a> download trigger
```

Pure function — no imports, no side effects. Reusable for PPTX if added later.

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Apex error (template not found, data failure) | Toast message, same pattern as existing `docGenRunner` |
| Image fetch failure | Skip image, continue with rest of document |
| PDF output requested in client-side mode | Clear user message, no generation attempted |
| ZIP assembly failure | Error toast + explicit "Try server-side generation" button |

---

## Testing

| Layer | Approach |
|-------|----------|
| `DocGenController` new method | New Apex test class, reuses `DocGenTestDataFactory` |
| `DocGenService` refactor | Existing tests must still pass; new test for pre-zip return value |
| `docGenZipWriter.js` | Jest unit tests — pure function, easy to validate byte output |
| `docGenRunner` | New Jest cases for opt-in property, PDF fallback message, error states |

---

## Limitations (v1)

- DOCX output only — PDF not supported client-side
- No offline support (requires Salesforce session for image fetch)
- Very large documents may hit browser memory limits (replaces Apex limits, not eliminates them)

---

## Out of Scope (v1)

- PPTX client-side generation
- PDF client-side generation
- Bulk generation via client-side path
