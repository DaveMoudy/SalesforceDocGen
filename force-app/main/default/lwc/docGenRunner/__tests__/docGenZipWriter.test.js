import { buildDocx } from "../docGenZipWriter";

describe("buildDocx", () => {
  it("returns a Uint8Array", () => {
    const result = buildDocx({ "word/document.xml": "<xml/>" }, {});
    expect(result).toBeInstanceOf(Uint8Array);
  });

  it("starts with PK ZIP signature", () => {
    const result = buildDocx({ "word/document.xml": "<xml/>" }, {});
    // Local file header signature: 0x04034b50 (little-endian: 50 4B 03 04)
    expect(result[0]).toBe(0x50);
    expect(result[1]).toBe(0x4b);
    expect(result[2]).toBe(0x03);
    expect(result[3]).toBe(0x04);
  });

  it("ends with end-of-central-directory signature", () => {
    const result = buildDocx({ "word/document.xml": "<xml/>" }, {});
    // EOCD signature: 0x06054b50 (little-endian: 50 4B 05 06)
    const len = result.length;
    expect(result[len - 22]).toBe(0x50);
    expect(result[len - 21]).toBe(0x4b);
    expect(result[len - 20]).toBe(0x05);
    expect(result[len - 19]).toBe(0x06);
  });

  it("includes xml file content in output", () => {
    const xmlContent = "<root><child>hello</child></root>";
    const result = buildDocx({ "word/document.xml": xmlContent }, {});
    // Convert to string and check content appears somewhere in the output
    const str = new TextDecoder().decode(result);
    expect(str).toContain(xmlContent);
  });

  it("handles media files (base64 input)", () => {
    // A 1x1 pixel PNG in base64
    const tiny1x1png =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    const result = buildDocx(
      { "[Content_Types].xml": "<Types/>" },
      { "word/media/image1.png": tiny1x1png }
    );
    expect(result).toBeInstanceOf(Uint8Array);
    expect(result.length).toBeGreaterThan(100);
  });

  it("includes all provided xml files", () => {
    const xmlParts = {
      "word/document.xml": "<document/>",
      "word/styles.xml": "<styles/>",
      "[Content_Types].xml": "<Types/>"
    };
    const result = buildDocx(xmlParts, {});
    const str = new TextDecoder().decode(result);
    expect(str).toContain("word/document.xml");
    expect(str).toContain("word/styles.xml");
    expect(str).toContain("[Content_Types].xml");
  });

  it("returns empty-ish zip for no files", () => {
    const result = buildDocx({}, {});
    // At minimum: EOCD record (22 bytes)
    expect(result.length).toBeGreaterThanOrEqual(22);
  });
});
