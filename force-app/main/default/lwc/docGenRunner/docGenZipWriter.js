/**
 * Pure JavaScript ZIP writer (store mode — no compression).
 * No external dependencies. Produces valid DOCX/ZIP archives.
 *
 * Public API:
 *   buildDocx(xmlParts, mediaParts) → Uint8Array
 *
 * @param {Object} xmlParts   - { 'path/file.xml': '<string content>', ... }
 * @param {Object} mediaParts - { 'path/image.png': '<base64 string>', ... }
 * @returns {Uint8Array} ZIP archive bytes
 */

// ---------------------------------------------------------------------------
// CRC-32 Table (standard polynomial 0xEDB88320)
// ---------------------------------------------------------------------------
const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let j = 0; j < 8; j++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c;
  }
  return table;
})();

function crc32(bytes) {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Encode a string as UTF-8 bytes */
function utf8Bytes(str) {
  return new TextEncoder().encode(str);
}

/** Decode a base64 string to Uint8Array */
function base64ToBytes(b64) {
  const binaryStr = atob(b64);
  const bytes = new Uint8Array(binaryStr.length);
  for (let i = 0; i < binaryStr.length; i++) {
    bytes[i] = binaryStr.charCodeAt(i);
  }
  return bytes;
}

/** Write a 16-bit little-endian value into a DataView */
function writeUint16LE(view, offset, value) {
  view.setUint16(offset, value, true);
}

/** Write a 32-bit little-endian value into a DataView */
function writeUint32LE(view, offset, value) {
  view.setUint32(offset, value, true);
}

/** Concatenate an array of Uint8Arrays into one */
function concat(arrays) {
  const totalLength = arrays.reduce((sum, a) => sum + a.length, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const arr of arrays) {
    result.set(arr, offset);
    offset += arr.length;
  }
  return result;
}

// ---------------------------------------------------------------------------
// ZIP Record Builders
// ---------------------------------------------------------------------------

/**
 * Builds a Local File Header + file data block.
 * Returns { bytes: Uint8Array, crc: number, size: number }
 */
function buildLocalEntry(nameBytes, fileBytes) {
  const crc = crc32(fileBytes);
  const size = fileBytes.length;

  // Local file header: 30 bytes fixed + filename
  const header = new Uint8Array(30 + nameBytes.length);
  const view = new DataView(header.buffer);

  writeUint32LE(view, 0, 0x04034b50); // Local file header signature
  writeUint16LE(view, 4, 20); // Version needed: 2.0
  writeUint16LE(view, 6, 0); // General purpose bit flag
  writeUint16LE(view, 8, 0); // Compression method: STORE
  writeUint16LE(view, 10, 0); // Last mod time
  writeUint16LE(view, 12, 0); // Last mod date
  writeUint32LE(view, 14, crc); // CRC-32
  writeUint32LE(view, 18, size); // Compressed size
  writeUint32LE(view, 22, size); // Uncompressed size
  writeUint16LE(view, 26, nameBytes.length); // File name length
  writeUint16LE(view, 28, 0); // Extra field length

  header.set(nameBytes, 30);

  return {
    bytes: concat([header, fileBytes]),
    crc,
    size
  };
}

/**
 * Builds a Central Directory Entry for a given file.
 */
function buildCentralEntry(nameBytes, crc, size, localOffset) {
  // Central directory entry: 46 bytes fixed + filename
  const entry = new Uint8Array(46 + nameBytes.length);
  const view = new DataView(entry.buffer);

  writeUint32LE(view, 0, 0x02014b50); // Central directory signature
  writeUint16LE(view, 4, 20); // Version made by
  writeUint16LE(view, 6, 20); // Version needed
  writeUint16LE(view, 8, 0); // General purpose bit flag
  writeUint16LE(view, 10, 0); // Compression method: STORE
  writeUint16LE(view, 12, 0); // Last mod time
  writeUint16LE(view, 14, 0); // Last mod date
  writeUint32LE(view, 16, crc); // CRC-32
  writeUint32LE(view, 20, size); // Compressed size
  writeUint32LE(view, 24, size); // Uncompressed size
  writeUint16LE(view, 28, nameBytes.length); // File name length
  writeUint16LE(view, 30, 0); // Extra field length
  writeUint16LE(view, 32, 0); // File comment length
  writeUint16LE(view, 34, 0); // Disk number start
  writeUint16LE(view, 36, 0); // Internal file attributes
  writeUint32LE(view, 38, 0); // External file attributes
  writeUint32LE(view, 42, localOffset); // Offset of local header

  entry.set(nameBytes, 46);

  return entry;
}

/**
 * Builds the End of Central Directory record.
 */
function buildEOCD(entryCount, cdSize, cdOffset) {
  const eocd = new Uint8Array(22);
  const view = new DataView(eocd.buffer);

  writeUint32LE(view, 0, 0x06054b50); // EOCD signature
  writeUint16LE(view, 4, 0); // Disk number
  writeUint16LE(view, 6, 0); // Disk with central directory
  writeUint16LE(view, 8, entryCount); // Entries on this disk
  writeUint16LE(view, 10, entryCount); // Total entries
  writeUint32LE(view, 12, cdSize); // Central directory size
  writeUint32LE(view, 16, cdOffset); // Central directory offset
  writeUint16LE(view, 20, 0); // Comment length

  return eocd;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Assembles a DOCX ZIP from processed XML strings and base64-encoded media files.
 *
 * @param {Object} xmlParts   - { 'word/document.xml': '<xml string>', ... }
 * @param {Object} mediaParts - { 'word/media/img.png': '<base64>', ... }
 * @returns {Uint8Array}
 */
export function buildDocx(xmlParts, mediaParts) {
  const localEntries = []; // Uint8Arrays of local header + data
  const centralEntries = []; // Uint8Arrays of central directory entries
  let offset = 0;

  // Process XML files
  for (const [path, content] of Object.entries(xmlParts)) {
    const nameBytes = utf8Bytes(path);
    const fileBytes = utf8Bytes(content);
    const { bytes, crc, size } = buildLocalEntry(nameBytes, fileBytes);

    centralEntries.push(buildCentralEntry(nameBytes, crc, size, offset));
    localEntries.push(bytes);
    offset += bytes.length;
  }

  // Process media files (base64 → binary)
  for (const [path, b64] of Object.entries(mediaParts)) {
    const nameBytes = utf8Bytes(path);
    const fileBytes = base64ToBytes(b64);
    const { bytes, crc, size } = buildLocalEntry(nameBytes, fileBytes);

    centralEntries.push(buildCentralEntry(nameBytes, crc, size, offset));
    localEntries.push(bytes);
    offset += bytes.length;
  }

  const centralDir = concat(centralEntries);
  const eocd = buildEOCD(localEntries.length, centralDir.length, offset);

  return concat([...localEntries, centralDir, eocd]);
}
