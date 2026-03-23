/**
 * Pure JavaScript PDF merger. No external dependencies.
 * Combines multiple PDF documents into a single PDF.
 *
 * Public API:
 *   mergePdfs(pdfBytesArray) → Uint8Array
 *
 * Takes an array of PDF files as Uint8Arrays (or ArrayBuffers),
 * parses their object graphs, renumbers to avoid collisions,
 * flattens the page trees, and writes a single merged PDF.
 *
 * Same philosophy as docGenZipWriter.js — raw binary manipulation,
 * zero dependencies, runs entirely client-side to avoid Apex heap.
 */

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

/** latin1 gives 1:1 byte↔char mapping — byte offsets = string offsets */
function latin1Decode(bytes) {
    return new TextDecoder('latin1').decode(bytes);
}

function latin1Encode(str) {
    const bytes = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) {
        bytes[i] = str.charCodeAt(i) & 0xff;
    }
    return bytes;
}

function concat(arrays) {
    let total = 0;
    for (const a of arrays) total += a.length;
    const result = new Uint8Array(total);
    let off = 0;
    for (const a of arrays) {
        result.set(a, off);
        off += a.length;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Reference renumbering
// ---------------------------------------------------------------------------

/**
 * Extracts a full dictionary (<< ... >>) from the string starting at or after pos.
 * Handles nested << >> correctly so we don't stop at an inner >>.
 */
function extractDict(str, pos) {
    const start = str.indexOf('<<', pos);
    if (start === -1) return '';
    let depth = 0;
    let i = start;
    while (i < str.length - 1) {
        if (str[i] === '<' && str[i + 1] === '<') { depth++; i += 2; }
        else if (str[i] === '>' && str[i + 1] === '>') {
            depth--;
            if (depth === 0) return str.substring(start, i + 2);
            i += 2;
        }
        else { i++; }
    }
    return str.substring(start); // unterminated — return what we have
}

/**
 * Replaces all indirect references (N 0 R) in dictionary text.
 * Only call on dictionary text, never on stream binary data.
 */
function renumberRefs(text, numMap) {
    return text.replace(/\b(\d+)(\s+0\s+R)\b/g, (match, numStr, rest) => {
        const num = parseInt(numStr);
        return numMap.has(num) ? numMap.get(num) + rest : match;
    });
}

// ---------------------------------------------------------------------------
// PDF Parser
// ---------------------------------------------------------------------------

/**
 * Parses a PDF file into its object graph and page tree.
 *
 * Returns:
 *   objects  — Map<number, {num, dictText, streamBytes}>
 *   pageNums — ordered array of leaf page object numbers
 *   rootNum  — catalog object number
 */
function parsePdf(bytes) {
    if (!(bytes instanceof Uint8Array)) bytes = new Uint8Array(bytes);
    const str = latin1Decode(bytes);

    if (!str.startsWith('%PDF-')) {
        throw new Error('Not a valid PDF file');
    }

    // --- Find all indirect objects: "N 0 obj" ... "endobj" ---
    const objects = new Map();
    const objRe = /\b(\d+)\s+0\s+obj\b/g;
    let m;

    while ((m = objRe.exec(str)) !== null) {
        const num = parseInt(m[1]);
        const headerEnd = m.index + m[0].length;
        const endIdx = str.indexOf('endobj', headerEnd);
        if (endIdx === -1) continue;

        const body = str.substring(headerEnd, endIdx);
        const si = body.indexOf('stream');
        let dictText;
        let streamBytes = null;

        if (si !== -1 && body.indexOf('endstream') > si) {
            // Object has a stream — split dict from binary data
            dictText = body.substring(0, si);

            // Stream data starts after "stream" + EOL
            let dStart = headerEnd + si + 6; // 'stream'.length
            if (bytes[dStart] === 0x0d) dStart++;
            if (bytes[dStart] === 0x0a) dStart++;

            // Use /Length (direct value) when available for precise extraction
            const lenMatch = dictText.match(/\/Length\s+(\d+)(?!\s+\d+\s+R)/);
            if (lenMatch) {
                const len = parseInt(lenMatch[1]);
                streamBytes = bytes.slice(dStart, dStart + len);
            } else {
                // Fallback: scan to endstream, trim trailing EOL
                const esIdx = str.indexOf('endstream', dStart);
                let dEnd = esIdx;
                if (bytes[dEnd - 1] === 0x0a) dEnd--;
                if (bytes[dEnd - 1] === 0x0d) dEnd--;
                streamBytes = bytes.slice(dStart, dEnd);
            }
        } else {
            dictText = body;
        }

        // Last occurrence wins (handles incremental updates)
        objects.set(num, { num, dictText, streamBytes });
    }

    // --- Find root catalog ---
    // Follow the spec: startxref → xref location → trailer/root
    let rootNum = null;

    // Primary: use startxref to find xref, then extract /Root
    const startxrefIdx = str.lastIndexOf('startxref');
    if (startxrefIdx !== -1) {
        const xrefOffsetMatch = str.substring(startxrefIdx + 9).match(/\s*(\d+)/);
        if (xrefOffsetMatch) {
            const xrefOffset = parseInt(xrefOffsetMatch[1]);
            const atOffset = str.substring(xrefOffset, xrefOffset + 10).trimStart();

            if (atOffset.startsWith('xref')) {
                // Traditional xref table — trailer dict follows
                const trailerIdx = str.indexOf('trailer', xrefOffset);
                if (trailerIdx !== -1) {
                    // Extract full trailer dict (handle nested << >>)
                    const trailerDict = extractDict(str, trailerIdx);
                    if (trailerDict.includes('/Encrypt')) {
                        throw new Error('Encrypted PDFs cannot be merged');
                    }
                    const rm = trailerDict.match(/\/Root\s+(\d+)\s+0\s+R/);
                    if (rm) rootNum = parseInt(rm[1]);
                }
            } else {
                // Cross-reference stream (PDF 1.5+) — the object dict IS the trailer
                const objMatch = str.substring(xrefOffset).match(/(\d+)\s+0\s+obj/);
                if (objMatch) {
                    const dictStart = xrefOffset + objMatch.index + objMatch[0].length;
                    const streamIdx = str.indexOf('stream', dictStart);
                    const endIdx = str.indexOf('endobj', dictStart);
                    const dictEnd = (streamIdx !== -1 && streamIdx < endIdx) ? streamIdx : endIdx;
                    const dictText = str.substring(dictStart, dictEnd);
                    if (dictText.includes('/Encrypt')) {
                        throw new Error('Encrypted PDFs cannot be merged');
                    }
                    const rm = dictText.match(/\/Root\s+(\d+)\s+0\s+R/);
                    if (rm) rootNum = parseInt(rm[1]);
                }
            }
        }
    }

    // Fallback: scan for traditional trailer keyword anywhere
    if (rootNum === null) {
        const tidx = str.lastIndexOf('trailer');
        if (tidx !== -1) {
            const trailerDict = extractDict(str, tidx);
            if (trailerDict.includes('/Encrypt')) {
                throw new Error('Encrypted PDFs cannot be merged');
            }
            const rm = trailerDict.match(/\/Root\s+(\d+)\s+0\s+R/);
            if (rm) rootNum = parseInt(rm[1]);
        }
    }

    // Fallback: scan all objects for xref stream with /Root
    if (rootNum === null) {
        for (const [, obj] of objects) {
            if (obj.dictText.includes('/Root')) {
                const rm = obj.dictText.match(/\/Root\s+(\d+)\s+0\s+R/);
                if (rm) {
                    rootNum = parseInt(rm[1]);
                    break;
                }
            }
        }
    }

    if (rootNum === null) throw new Error('PDF root catalog not found');

    // --- Resolve catalog → /Pages tree ---
    const catalog = objects.get(rootNum);
    if (!catalog) throw new Error('Catalog object ' + rootNum + ' missing');
    const pm = catalog.dictText.match(/\/Pages\s+(\d+)\s+0\s+R/);
    if (!pm) throw new Error('/Pages reference not found in catalog');

    // Walk page tree — /Pages nodes have /Kids, /Page leaves do not
    function walkPages(objNum, visited) {
        if (visited.has(objNum)) return [];
        visited.add(objNum);
        const obj = objects.get(objNum);
        if (!obj) return [];

        const km = obj.dictText.match(/\/Kids\s*\[([\s\S]*?)\]/);
        if (km) {
            // Intermediate /Pages node — recurse into children
            const refs = [...km[1].matchAll(/(\d+)\s+0\s+R/g)];
            const pages = [];
            for (const r of refs) pages.push(...walkPages(parseInt(r[1]), visited));
            return pages;
        }
        // Leaf /Page object
        return [objNum];
    }

    const pageNums = walkPages(parseInt(pm[1]), new Set());

    return { objects, rootNum, pageNums };
}

// ---------------------------------------------------------------------------
// Inheritable attribute resolution
// ---------------------------------------------------------------------------

/**
 * Walks up the page tree to find /MediaBox.
 * Must be called BEFORE renumbering (uses original /Parent refs).
 */
function resolveMediaBox(objects, pageNum) {
    const visited = new Set();
    let num = pageNum;
    while (num != null && !visited.has(num)) {
        visited.add(num);
        const obj = objects.get(num);
        if (!obj) break;
        const mb = obj.dictText.match(/\/MediaBox\s*\[([^\]]+)\]/);
        if (mb) return mb[0];
        const pr = obj.dictText.match(/\/Parent\s+(\d+)\s+0\s+R/);
        num = pr ? parseInt(pr[1]) : null;
    }
    return '/MediaBox [0 0 612 792]'; // US Letter fallback
}

// ---------------------------------------------------------------------------
// PDF Writer
// ---------------------------------------------------------------------------

/** Serializes one indirect object to bytes. */
function writeObject(num, dictText, streamBytes) {
    const hdr = num + ' 0 obj';
    if (streamBytes) {
        // Ensure /Length matches actual stream size
        let dict = dictText;
        if (/\/Length\s+\d+(?!\s+\d+\s+R)/.test(dict)) {
            dict = dict.replace(/\/Length\s+\d+(?!\s+\d+\s+R)/, '/Length ' + streamBytes.length);
        }
        const pre = latin1Encode(hdr + dict + 'stream\n');
        const post = latin1Encode('\nendstream\nendobj\n');
        return concat([pre, streamBytes, post]);
    }
    return latin1Encode(hdr + dictText + 'endobj\n');
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Merges multiple PDFs into a single document.
 *
 * @param {Array<Uint8Array|ArrayBuffer>} pdfBytesArray - PDFs to merge, in order
 * @returns {Uint8Array} Merged PDF bytes
 */
export function mergePdfs(pdfBytesArray) {
    if (!pdfBytesArray || pdfBytesArray.length === 0) {
        throw new Error('No PDFs provided');
    }
    if (pdfBytesArray.length === 1) {
        const b = pdfBytesArray[0];
        return b instanceof Uint8Array ? b : new Uint8Array(b);
    }

    // 1. Parse all input PDFs
    const parsed = pdfBytesArray.map(b => parsePdf(b));

    // 2. Resolve inherited /MediaBox BEFORE renumbering
    //    Pages can inherit /MediaBox from ancestor /Pages nodes.
    //    Since we flatten the tree, we must attach it explicitly.
    for (const pdf of parsed) {
        for (const pageNum of pdf.pageNums) {
            const obj = pdf.objects.get(pageNum);
            if (obj && !obj.dictText.includes('/MediaBox')) {
                const mb = resolveMediaBox(pdf.objects, pageNum);
                obj.dictText = obj.dictText.replace(/<</, '<< ' + mb);
            }
        }
    }

    // 3. Renumber objects across all PDFs (sequential, no gaps)
    let nextNum = 1;
    const allObjs = [];
    const allPages = [];

    for (const pdf of parsed) {
        const numMap = new Map();
        for (const oldNum of pdf.objects.keys()) {
            numMap.set(oldNum, nextNum++);
        }

        for (const [oldNum, obj] of pdf.objects) {
            const newNum = numMap.get(oldNum);
            const isPage = pdf.pageNums.includes(oldNum);

            allObjs.push({
                newNum,
                dictText: renumberRefs(obj.dictText, numMap),
                streamBytes: obj.streamBytes,
                isPage
            });

        }

        // Collect pages in tree order (not object scan order)
        for (const pageNum of pdf.pageNums) {
            allPages.push(numMap.get(pageNum));
        }
    }

    // 4. Allocate new structural objects
    const newPagesNum = nextNum++;
    const newCatalogNum = nextNum++;

    // 5. Point all pages to the new /Pages parent
    for (const obj of allObjs) {
        if (obj.isPage) {
            obj.dictText = obj.dictText.replace(
                /\/Parent\s+\d+\s+0\s+R/,
                '/Parent ' + newPagesNum + ' 0 R'
            );
        }
    }

    // 6. Write the merged PDF
    const parts = [];
    const offsets = new Map();
    let off = 0;

    // Header + binary comment (tells readers this isn't plain text)
    const hdr = latin1Encode('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n');
    parts.push(hdr);
    off += hdr.length;

    // All objects from all input PDFs
    for (const obj of allObjs) {
        offsets.set(obj.newNum, off);
        const b = writeObject(obj.newNum, obj.dictText, obj.streamBytes);
        parts.push(b);
        off += b.length;
    }

    // New /Pages — flat tree with all pages as direct children
    const kids = allPages.map(n => n + ' 0 R').join(' ');
    offsets.set(newPagesNum, off);
    const pagesBytes = latin1Encode(
        newPagesNum + ' 0 obj\n<< /Type /Pages /Kids [' + kids +
        '] /Count ' + allPages.length + ' >>\nendobj\n'
    );
    parts.push(pagesBytes);
    off += pagesBytes.length;

    // New /Catalog
    offsets.set(newCatalogNum, off);
    const catBytes = latin1Encode(
        newCatalogNum + ' 0 obj\n<< /Type /Catalog /Pages ' +
        newPagesNum + ' 0 R >>\nendobj\n'
    );
    parts.push(catBytes);
    off += catBytes.length;

    // Cross-reference table
    const xrefStart = off;
    let xref = 'xref\n0 ' + nextNum + '\n';
    // Object 0: head of free list (always present)
    xref += '0000000000 65535 f \n';
    for (let i = 1; i < nextNum; i++) {
        const o = offsets.get(i);
        xref += String(o).padStart(10, '0') + ' 00000 n \n';
    }

    // Trailer
    xref += 'trailer\n<< /Size ' + nextNum +
            ' /Root ' + newCatalogNum + ' 0 R >>\n' +
            'startxref\n' + xrefStart + '\n%%EOF\n';

    parts.push(latin1Encode(xref));

    return concat(parts);
}
