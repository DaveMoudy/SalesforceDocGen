/**
 * Converts processed DOCX XML (post-merge) to HTML suitable for Blob.toPdf().
 * Uses string-based XML parsing for DOCX-specific namespace handling.
 */
public with sharing class DocGenHtmlRenderer {

    private static final String HTML_PREFIX =
        '<html><head><style>' +
        '@page { size: letter; margin: 1in; }' +
        'body { font-family: Arial, sans-serif; font-size: 11pt; line-height: 1.15; }' +
        'table { border-collapse: collapse; width: 100%; }' +
        'td, th { padding: 4pt; vertical-align: top; }' +
        'p { margin: 0 0 8pt 0; }' +
        'img { max-width: 100%; }' +
        '</style></head><body>';

    private static final String HTML_SUFFIX = '</body></html>';

    // Unit conversions
    private static final Decimal HALF_POINTS_TO_PT = 0.5;     // half-points → pt (÷2)
    private static final Decimal TWIPS_TO_PT = 0.05;           // twips → pt (÷20)
    private static final Decimal EMU_TO_PX = 0.000104987;      // EMU → px (÷9525)

    /**
     * Converts processed DOCX XML content and associated images into an HTML string
     * suitable for Blob.toPdf().
     * @param documentXml The processed word/document.xml content (post-merge)
     * @param images Map of relationship IDs to base64-encoded image data
     * @return HTML string ready for Blob.toPdf()
     */
    public static String convertToHtml(String documentXml, Map<String, String> images) {
        if (String.isBlank(documentXml)) {
            return HTML_PREFIX + HTML_SUFFIX;
        }
        if (images == null) {
            images = new Map<String, String>();
        }

        String bodyContent = extractBodyContent(documentXml);
        String html = processBodyContent(bodyContent, images);

        return HTML_PREFIX + html + HTML_SUFFIX;
    }

    /**
     * Overload for when no images are present.
     */
    public static String convertToHtml(String documentXml) {
        return convertToHtml(documentXml, new Map<String, String>());
    }

    /**
     * Extracts content between <w:body> and </w:body> tags.
     */
    private static String extractBodyContent(String xml) {
        Integer bodyStart = xml.indexOf('<w:body');
        if (bodyStart == -1) return xml;

        Integer bodyContentStart = xml.indexOf('>', bodyStart) + 1;
        Integer bodyEnd = xml.lastIndexOf('</w:body>');
        if (bodyEnd == -1) return xml.substring(bodyContentStart);

        // Strip <w:sectPr> (section properties) from end of body
        String content = xml.substring(bodyContentStart, bodyEnd);
        Integer sectStart = content.lastIndexOf('<w:sectPr');
        if (sectStart != -1) {
            content = content.substring(0, sectStart);
        }
        return content;
    }

    /**
     * Processes body-level DOCX XML elements into HTML.
     */
    private static String processBodyContent(String xml, Map<String, String> images) {
        String result = '';
        Integer cursor = 0;

        while (cursor < xml.length()) {
            Integer nextTag = xml.indexOf('<', cursor);
            if (nextTag == -1) {
                break;
            }

            // Skip text between tags
            cursor = nextTag;

            if (xml.substring(cursor).startsWith('<w:tbl')) {
                Integer tblEnd = findClosingTag(xml, cursor, 'w:tbl');
                if (tblEnd != -1) {
                    result += processTable(xml.substring(cursor, tblEnd), images);
                    cursor = tblEnd;
                } else {
                    cursor++;
                }
            } else if (xml.substring(cursor).startsWith('<w:p ') || xml.substring(cursor).startsWith('<w:p>') || xml.substring(cursor).startsWith('<w:p/>')) {
                Integer pEnd = findClosingTag(xml, cursor, 'w:p');
                if (pEnd != -1) {
                    result += processParagraph(xml.substring(cursor, pEnd), images);
                    cursor = pEnd;
                } else {
                    cursor++;
                }
            } else {
                // Skip unknown tags
                Integer tagEnd = xml.indexOf('>', cursor);
                if (tagEnd != -1) {
                    cursor = tagEnd + 1;
                } else {
                    break;
                }
            }
        }

        return result;
    }

    /**
     * Processes a <w:p> element into an HTML <p> or <br> tag.
     */
    private static String processParagraph(String pXml, Map<String, String> images) {
        String style = '';

        // Extract paragraph properties
        String pPr = extractElement(pXml, 'w:pPr');
        if (String.isNotBlank(pPr)) {
            style = parseParagraphStyle(pPr);
        }

        // Process runs
        String content = processRuns(pXml, images);

        // Empty paragraph = line break
        if (String.isBlank(content)) {
            return '<p' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>&nbsp;</p>';
        }

        return '<p' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>' + content + '</p>';
    }

    /**
     * Parses <w:pPr> into CSS style string.
     */
    private static String parseParagraphStyle(String pPr) {
        List<String> styles = new List<String>();

        // Alignment: <w:jc w:val="center"/>
        String jcVal = extractAttr(pPr, 'w:jc', 'w:val');
        if (jcVal != null) {
            if (jcVal == 'center') styles.add('text-align:center');
            else if (jcVal == 'right' || jcVal == 'end') styles.add('text-align:right');
            else if (jcVal == 'both' || jcVal == 'distribute') styles.add('text-align:justify');
        }

        // Spacing: <w:spacing w:before="120" w:after="120" w:line="240"/>
        String spacingBefore = extractAttr(pPr, 'w:spacing', 'w:before');
        if (spacingBefore != null && spacingBefore.isNumeric()) {
            styles.add('margin-top:' + twipsToPt(Integer.valueOf(spacingBefore)) + 'pt');
        }
        String spacingAfter = extractAttr(pPr, 'w:spacing', 'w:after');
        if (spacingAfter != null && spacingAfter.isNumeric()) {
            styles.add('margin-bottom:' + twipsToPt(Integer.valueOf(spacingAfter)) + 'pt');
        }

        // Indent: <w:ind w:left="720" w:right="0" w:firstLine="360"/>
        String indLeft = extractAttr(pPr, 'w:ind', 'w:left');
        if (indLeft != null && indLeft.isNumeric()) {
            styles.add('margin-left:' + twipsToPt(Integer.valueOf(indLeft)) + 'pt');
        }
        String indRight = extractAttr(pPr, 'w:ind', 'w:right');
        if (indRight != null && indRight.isNumeric()) {
            styles.add('margin-right:' + twipsToPt(Integer.valueOf(indRight)) + 'pt');
        }
        String indFirst = extractAttr(pPr, 'w:ind', 'w:firstLine');
        if (indFirst != null && indFirst.isNumeric()) {
            styles.add('text-indent:' + twipsToPt(Integer.valueOf(indFirst)) + 'pt');
        }

        return String.join(styles, ';');
    }

    /**
     * Processes all <w:r> (run) elements within a paragraph.
     */
    private static String processRuns(String pXml, Map<String, String> images) {
        String result = '';
        Integer cursor = 0;

        while (cursor < pXml.length()) {
            Integer runStart = pXml.indexOf('<w:r>', cursor);
            Integer runStart2 = pXml.indexOf('<w:r ', cursor);

            // Also check for drawing elements outside runs
            Integer drawingStart = pXml.indexOf('<w:drawing>', cursor);
            Integer drawingStart2 = pXml.indexOf('<w:drawing ', cursor);

            // Find the earliest element
            Integer nextRun = -1;
            if (runStart != -1 && runStart2 != -1) nextRun = Math.min(runStart, runStart2);
            else if (runStart != -1) nextRun = runStart;
            else if (runStart2 != -1) nextRun = runStart2;

            Integer nextDrawing = -1;
            if (drawingStart != -1 && drawingStart2 != -1) nextDrawing = Math.min(drawingStart, drawingStart2);
            else if (drawingStart != -1) nextDrawing = drawingStart;
            else if (drawingStart2 != -1) nextDrawing = drawingStart2;

            if (nextRun == -1 && nextDrawing == -1) break;

            // Process whichever comes first
            if (nextRun != -1 && (nextDrawing == -1 || nextRun < nextDrawing)) {
                Integer runEnd = findClosingTag(pXml, nextRun, 'w:r');
                if (runEnd != -1) {
                    result += processRun(pXml.substring(nextRun, runEnd), images);
                    cursor = runEnd;
                } else {
                    cursor = nextRun + 1;
                }
            } else if (nextDrawing != -1) {
                Integer drawEnd = findClosingTag(pXml, nextDrawing, 'w:drawing');
                if (drawEnd != -1) {
                    result += processDrawing(pXml.substring(nextDrawing, drawEnd), images);
                    cursor = drawEnd;
                } else {
                    cursor = nextDrawing + 1;
                }
            }
        }

        return result;
    }

    /**
     * Processes a single <w:r> (run) element into an HTML <span>.
     */
    private static String processRun(String rXml, Map<String, String> images) {
        // Check for break
        if (rXml.contains('<w:br')) {
            return '<br/>';
        }

        // Check for drawing (image)
        if (rXml.contains('<w:drawing')) {
            Integer drawStart = rXml.indexOf('<w:drawing');
            Integer drawEnd = findClosingTag(rXml, drawStart, 'w:drawing');
            if (drawEnd != -1) {
                return processDrawing(rXml.substring(drawStart, drawEnd), images);
            }
        }

        // Extract text
        String text = extractTextContent(rXml);
        if (String.isBlank(text)) return '';

        // Extract run properties
        String rPr = extractElement(rXml, 'w:rPr');
        if (String.isBlank(rPr)) {
            return text.escapeHtml4();
        }

        String style = parseRunStyle(rPr);
        String openTags = '';
        String closeTags = '';

        // Bold
        if (rPr.contains('<w:b/>') || rPr.contains('<w:b ')) {
            openTags += '<b>';
            closeTags = '</b>' + closeTags;
        }
        // Italic
        if (rPr.contains('<w:i/>') || rPr.contains('<w:i ')) {
            openTags += '<i>';
            closeTags = '</i>' + closeTags;
        }
        // Underline
        if (rPr.contains('<w:u ')) {
            openTags += '<u>';
            closeTags = '</u>' + closeTags;
        }
        // Strikethrough
        if (rPr.contains('<w:strike/>') || rPr.contains('<w:strike ')) {
            openTags += '<s>';
            closeTags = '</s>' + closeTags;
        }

        if (String.isNotBlank(style)) {
            return '<span style="' + style + '">' + openTags + text.escapeHtml4() + closeTags + '</span>';
        }
        return openTags + text.escapeHtml4() + closeTags;
    }

    /**
     * Parses <w:rPr> into CSS style string.
     */
    private static String parseRunStyle(String rPr) {
        List<String> styles = new List<String>();

        // Font: <w:rFonts w:ascii="Calibri"/>
        String font = extractAttr(rPr, 'w:rFonts', 'w:ascii');
        if (font == null) font = extractAttr(rPr, 'w:rFonts', 'w:hAnsi');
        if (font != null) {
            styles.add('font-family:\'' + font.escapeHtml4() + '\',sans-serif');
        }

        // Font size: <w:sz w:val="24"/> (half-points)
        String sz = extractAttr(rPr, 'w:sz', 'w:val');
        if (sz != null && sz.isNumeric()) {
            Decimal ptSize = Integer.valueOf(sz) * HALF_POINTS_TO_PT;
            styles.add('font-size:' + ptSize + 'pt');
        }

        // Color: <w:color w:val="FF0000"/>
        String color = extractAttr(rPr, 'w:color', 'w:val');
        if (color != null && color != 'auto') {
            styles.add('color:#' + color);
        }

        // Highlight: <w:highlight w:val="yellow"/>
        String highlight = extractAttr(rPr, 'w:highlight', 'w:val');
        if (highlight != null) {
            styles.add('background-color:' + highlight);
        }

        return String.join(styles, ';');
    }

    /**
     * Processes a <w:tbl> element into an HTML <table>.
     */
    private static String processTable(String tblXml, Map<String, String> images) {
        String tableStyle = 'border-collapse:collapse;width:100%';

        // Parse table properties
        String tblPr = extractElement(tblXml, 'w:tblPr');
        if (String.isNotBlank(tblPr)) {
            // Table width
            String tblW = extractAttr(tblPr, 'w:tblW', 'w:w');
            String tblWType = extractAttr(tblPr, 'w:tblW', 'w:type');
            if (tblW != null && tblWType == 'pct') {
                Decimal pct = Integer.valueOf(tblW) / 50.0; // OOXML pct is in 50ths of a percent
                tableStyle = 'border-collapse:collapse;width:' + pct + '%';
            }

            // Table borders
            if (tblPr.contains('<w:tblBorders')) {
                tableStyle += ';border:1px solid #000';
            }
        }

        // Process rows
        String rows = '';
        Integer cursor = 0;
        while (cursor < tblXml.length()) {
            Integer trStart = tblXml.indexOf('<w:tr', cursor);
            if (trStart == -1) break;

            Integer trEnd = findClosingTag(tblXml, trStart, 'w:tr');
            if (trEnd == -1) break;

            rows += processTableRow(tblXml.substring(trStart, trEnd), images, tblPr);
            cursor = trEnd;
        }

        return '<table style="' + tableStyle + '">' + rows + '</table>';
    }

    /**
     * Processes a <w:tr> element into an HTML <tr>.
     */
    private static String processTableRow(String trXml, Map<String, String> images, String tblPr) {
        String cells = '';
        Integer cursor = 0;

        while (cursor < trXml.length()) {
            Integer tcStart = trXml.indexOf('<w:tc', cursor);
            if (tcStart == -1) break;

            Integer tcEnd = findClosingTag(trXml, tcStart, 'w:tc');
            if (tcEnd == -1) break;

            cells += processTableCell(trXml.substring(tcStart, tcEnd), images, tblPr);
            cursor = tcEnd;
        }

        return '<tr>' + cells + '</tr>';
    }

    /**
     * Processes a <w:tc> element into an HTML <td>.
     */
    private static String processTableCell(String tcXml, Map<String, String> images, String tblPr) {
        List<String> styles = new List<String>();

        // Cell properties
        String tcPr = extractElement(tcXml, 'w:tcPr');
        if (String.isNotBlank(tcPr)) {
            // Cell width: <w:tcW w:w="2880" w:type="dxa"/>
            String tcW = extractAttr(tcPr, 'w:tcW', 'w:w');
            String tcWType = extractAttr(tcPr, 'w:tcW', 'w:type');
            if (tcW != null && tcW.isNumeric()) {
                if (tcWType == 'pct') {
                    Decimal pct = Integer.valueOf(tcW) / 50.0;
                    styles.add('width:' + pct + '%');
                } else {
                    // dxa = twips
                    styles.add('width:' + twipsToPt(Integer.valueOf(tcW)) + 'pt');
                }
            }

            // Shading: <w:shd w:val="clear" w:fill="E2EFDA"/>
            String fill = extractAttr(tcPr, 'w:shd', 'w:fill');
            if (fill != null && fill != 'auto') {
                styles.add('background-color:#' + fill);
            }

            // Vertical alignment: <w:vAlign w:val="center"/>
            String vAlign = extractAttr(tcPr, 'w:vAlign', 'w:val');
            if (vAlign != null) {
                styles.add('vertical-align:' + vAlign);
            }
        }

        // Add border if table has borders
        if (String.isNotBlank(tblPr) && tblPr.contains('<w:tblBorders')) {
            styles.add('border:1px solid #000');
        }

        // Process cell content (paragraphs)
        String content = processBodyContent(tcXml, images);

        String styleStr = String.join(styles, ';');
        return '<td' + (String.isNotBlank(styleStr) ? ' style="' + styleStr + '"' : '') + '>' + content + '</td>';
    }

    /**
     * Processes a <w:drawing> element into an HTML <img> tag.
     */
    private static String processDrawing(String drawingXml, Map<String, String> images) {
        // Extract dimensions from <wp:extent cx="..." cy="..."/>
        Integer widthPx = 200; // default
        Integer heightPx = 150; // default

        String cx = extractAttr(drawingXml, 'wp:extent', 'cx');
        String cy = extractAttr(drawingXml, 'wp:extent', 'cy');
        if (cx == null) cx = extractAttr(drawingXml, 'a:ext', 'cx');
        if (cy == null) cy = extractAttr(drawingXml, 'a:ext', 'cy');

        if (cx != null && cx.isNumeric()) {
            widthPx = Math.round(Long.valueOf(cx) * EMU_TO_PX);
        }
        if (cy != null && cy.isNumeric()) {
            heightPx = Math.round(Long.valueOf(cy) * EMU_TO_PX);
        }

        // Extract relationship ID from <a:blip r:embed="rIdImg1"/>
        String relId = extractAttr(drawingXml, 'a:blip', 'r:embed');
        if (relId == null) return '';

        String base64 = images.get(relId);
        if (base64 == null) return '';

        // Determine MIME type
        String mimeType = 'image/png';
        if (base64.startsWith('/9j/') || base64.startsWith('/9J/')) {
            mimeType = 'image/jpeg';
        }

        return '<img src="data:' + mimeType + ';base64,' + base64 + '" ' +
               'width="' + widthPx + '" height="' + heightPx + '" ' +
               'style="max-width:100%" />';
    }

    // ===== XML PARSING UTILITIES =====

    /**
     * Extracts all text content from <w:t> elements within the given XML.
     */
    private static String extractTextContent(String xml) {
        String result = '';
        Integer cursor = 0;

        while (cursor < xml.length()) {
            Integer tStart = xml.indexOf('<w:t', cursor);
            if (tStart == -1) break;

            // Skip self-closing <w:t/>
            Integer tagEnd = xml.indexOf('>', tStart);
            if (tagEnd == -1) break;

            if (xml.substring(tagEnd - 1, tagEnd) == '/') {
                cursor = tagEnd + 1;
                continue;
            }

            Integer contentStart = tagEnd + 1;
            Integer tEnd = xml.indexOf('</w:t>', contentStart);
            if (tEnd == -1) break;

            result += xml.substring(contentStart, tEnd);
            cursor = tEnd + 6; // length of </w:t>
        }

        return result;
    }

    /**
     * Extracts the first occurrence of an element's content.
     * Returns the content including the element's own tags.
     */
    private static String extractElement(String xml, String tagName) {
        Integer start = xml.indexOf('<' + tagName);
        if (start == -1) return null;

        // Check for self-closing
        Integer tagEnd = xml.indexOf('>', start);
        if (tagEnd == -1) return null;
        if (xml.substring(tagEnd - 1, tagEnd) == '/') {
            return xml.substring(start, tagEnd + 1);
        }

        Integer endPos = findClosingTag(xml, start, tagName);
        if (endPos == -1) return xml.substring(start, tagEnd + 1);
        return xml.substring(start, endPos);
    }

    /**
     * Extracts an attribute value from a specific element.
     * E.g., extractAttr(xml, 'w:jc', 'w:val') from <w:jc w:val="center"/>
     */
    private static String extractAttr(String xml, String tagName, String attrName) {
        Integer tagStart = xml.indexOf('<' + tagName);
        if (tagStart == -1) return null;

        Integer tagEnd = xml.indexOf('>', tagStart);
        if (tagEnd == -1) return null;

        String tagContent = xml.substring(tagStart, tagEnd + 1);
        Integer attrStart = tagContent.indexOf(attrName + '="');
        if (attrStart == -1) return null;

        Integer valueStart = attrStart + attrName.length() + 2; // skip attr="
        Integer valueEnd = tagContent.indexOf('"', valueStart);
        if (valueEnd == -1) return null;

        return tagContent.substring(valueStart, valueEnd);
    }

    /**
     * Finds the position after the closing tag, handling nesting.
     * Returns the position after </tagName>.
     */
    private static Integer findClosingTag(String xml, Integer startPos, String tagName) {
        String openTag = '<' + tagName;
        String closeTag = '</' + tagName + '>';
        Integer depth = 0;
        Integer cursor = startPos;

        while (cursor < xml.length()) {
            Integer nextOpen = xml.indexOf(openTag, cursor);
            Integer nextClose = xml.indexOf(closeTag, cursor);

            if (nextClose == -1) return -1;

            if (nextOpen != -1 && nextOpen < nextClose) {
                // Check if it's actually the tag (not a prefix match like <w:tblPr matching <w:tbl)
                Integer afterOpen = nextOpen + openTag.length();
                if (afterOpen < xml.length()) {
                    String nextChar = xml.substring(afterOpen, afterOpen + 1);
                    if (nextChar == '>' || nextChar == ' ' || nextChar == '/') {
                        depth++;
                        cursor = afterOpen;
                        continue;
                    }
                }
                // Not a real match, skip past it
                cursor = afterOpen;
            } else {
                depth--;
                if (depth == 0) {
                    return nextClose + closeTag.length();
                }
                cursor = nextClose + closeTag.length();
            }
        }
        return -1;
    }

    /**
     * Converts twips to points.
     */
    private static Decimal twipsToPt(Integer twips) {
        return twips * TWIPS_TO_PT;
    }
}