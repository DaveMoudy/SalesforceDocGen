/**
 * Converts processed DOCX XML (post-merge) to HTML suitable for Blob.toPdf().
 * Uses string-based XML parsing for DOCX-specific namespace handling.
 */
public with sharing class DocGenHtmlRenderer {

    private static final String HTML_PREFIX =
        '<html><head><style>' +
        '@page { size: letter; margin: 1in; }' +
        'body { font-family: Arial, sans-serif; font-size: 11pt; line-height: 1.15; color: #000; }' +
        'h1 { font-size: 20pt; font-weight: bold; margin: 0 0 6pt 0; }' +
        'h2 { font-size: 16pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h3 { font-size: 14pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h4 { font-size: 12pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h5 { font-size: 11pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h6 { font-size: 10pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h1, h2, h3, h4, h5, h6 { page-break-after: avoid; }' +
        'table { border-collapse: collapse; width: 100%; page-break-inside: auto; }' +
        'tr { page-break-inside: avoid; page-break-after: auto; }' +
        'td, th { padding: 4pt; vertical-align: top; }' +
        'p { margin: 0 0 8pt 0; orphans: 2; widows: 2; page-break-inside: avoid; }' +
        'img { max-width: 100%; }' +
        'ul, ol { margin: 0 0 8pt 0; padding-left: 36pt; }' +
        'li { margin: 0 0 2pt 0; page-break-inside: avoid; }' +
        'hr { border: none; border-top: 1px solid #000; margin: 6pt 0; }' +
        'sub { vertical-align: sub; font-size: 0.8em; }' +
        'sup { vertical-align: super; font-size: 0.8em; }' +
        '</style></head><body>';

    private static final String HTML_SUFFIX = '</body></html>';

    // Unit conversions
    private static final Decimal HALF_POINTS_TO_PT = 0.5;     // half-points → pt (÷2)
    private static final Decimal TWIPS_TO_PT = 0.05;           // twips → pt (÷20)
    private static final Decimal EMU_TO_PX = 0.000104987;      // EMU → px (÷9525)

    // Standard Word heading style IDs → HTML heading levels
    private static final Map<String, Integer> HEADING_STYLE_MAP = new Map<String, Integer>{
        'Heading1' => 1, 'heading1' => 1, 'Heading 1' => 1,
        'Heading2' => 2, 'heading2' => 2, 'Heading 2' => 2,
        'Heading3' => 3, 'heading3' => 3, 'Heading 3' => 3,
        'Heading4' => 4, 'heading4' => 4, 'Heading 4' => 4,
        'Heading5' => 5, 'heading5' => 5, 'Heading 5' => 5,
        'Heading6' => 6, 'heading6' => 6, 'Heading 6' => 6
    };

    // Word style IDs that imply a list item
    private static final Set<String> LIST_STYLE_IDS = new Set<String>{
        'ListParagraph', 'listparagraph', 'ListBullet', 'ListNumber',
        'List Paragraph', 'List Bullet', 'List Number'
    };

    /**
     * Converts processed DOCX XML content and associated images into an HTML string
     * suitable for Blob.toPdf().
     * @param documentXml The processed word/document.xml content (post-merge)
     * @param images Map of relationship IDs to base64-encoded image data
     * @return HTML string ready for Blob.toPdf()
     */
    public static String convertToHtml(String documentXml, Map<String, String> images) {
        return convertToHtml(documentXml, images, null);
    }

    /**
     * Converts document XML to HTML with custom font CSS injected into the style block.
     * @param documentXml The processed word/document.xml content (post-merge)
     * @param images Map of relationship IDs to image URLs or base64 data
     * @param fontFaceCss @font-face CSS declarations to inject (null = no custom fonts)
     * @return HTML string ready for Blob.toPdf()
     */
    public static String convertToHtml(String documentXml, Map<String, String> images, String fontFaceCss) {
        if (String.isBlank(documentXml)) {
            return HTML_PREFIX + HTML_SUFFIX;
        }
        if (images == null) {
            images = new Map<String, String>();
        }

        String bodyContent = extractBodyContent(documentXml);
        String html = processBodyContent(bodyContent, images);

        // Inject custom @font-face declarations before the base styles
        if (String.isNotBlank(fontFaceCss)) {
            String prefix = '<html><head><style>' + fontFaceCss +
                '@page { size: letter; margin: 1in; }' +
                'body { font-family: Arial, sans-serif; font-size: 11pt; line-height: 1.15; color: #000; }' +
                'h1 { font-size: 20pt; font-weight: bold; margin: 0 0 6pt 0; }' +
                'h2 { font-size: 16pt; font-weight: bold; margin: 0 0 4pt 0; }' +
                'h3 { font-size: 14pt; font-weight: bold; margin: 0 0 4pt 0; }' +
                'h4 { font-size: 12pt; font-weight: bold; margin: 0 0 4pt 0; }' +
                'h5 { font-size: 11pt; font-weight: bold; margin: 0 0 4pt 0; }' +
                'h6 { font-size: 10pt; font-weight: bold; margin: 0 0 4pt 0; }' +
                'h1, h2, h3, h4, h5, h6 { page-break-after: avoid; }' +
                'table { border-collapse: collapse; width: 100%; page-break-inside: auto; }' +
                'tr { page-break-inside: avoid; page-break-after: auto; }' +
                'td, th { padding: 4pt; vertical-align: top; }' +
                'p { margin: 0 0 8pt 0; orphans: 2; widows: 2; page-break-inside: avoid; }' +
                'img { max-width: 100%; }' +
                'ul, ol { margin: 0 0 8pt 0; padding-left: 36pt; }' +
                'li { margin: 0 0 2pt 0; page-break-inside: avoid; }' +
                'hr { border: none; border-top: 1px solid #000; margin: 6pt 0; }' +
                'sub { vertical-align: sub; font-size: 0.8em; }' +
                'sup { vertical-align: super; font-size: 0.8em; }' +
                '</style></head><body>';
            return prefix + html + HTML_SUFFIX;
        }

        return HTML_PREFIX + html + HTML_SUFFIX;
    }

    /**
     * Overload for when no images are present.
     * @param documentXml The processed word/document.xml content (post-merge)
     * @return HTML string ready for Blob.toPdf()
     */
    public static String convertToHtml(String documentXml) {
        return convertToHtml(documentXml, new Map<String, String>(), null);
    }

    /**
     * Converts DOCX XML to an HTML fragment (no html/head/body wrapper).
     * Used for rendering header/footer content separately.
     */
    public static String convertToHtmlFragment(String xml, Map<String, String> images) {
        if (String.isBlank(xml)) { return ''; }
        if (images == null) { images = new Map<String, String>(); }
        String bodyContent = extractBodyContent(xml);
        if (String.isBlank(bodyContent)) {
            bodyContent = xml;
        }
        return processBodyContent(bodyContent, images);
    }

    /**
     * Converts DOCX XML to HTML with header/footer positioned via CSS running elements.
     * Flying Saucer (Blob.toPdf engine) supports position:running() and @page margin boxes.
     */
    public static String convertToHtmlWithHeaderFooter(String documentXml, Map<String, String> images, String headerHtml, String footerHtml) {
        if (String.isBlank(documentXml)) {
            return HTML_PREFIX + HTML_SUFFIX;
        }
        if (images == null) { images = new Map<String, String>(); }

        String bodyContent = extractBodyContent(documentXml);
        String html = processBodyContent(bodyContent, images);

        // Build CSS with fixed-position header/footer for Flying Saucer
        String headerHeight = String.isNotBlank(headerHtml) ? '0.75in' : '0';
        String footerHeight = String.isNotBlank(footerHtml) ? '0.75in' : '0';

        String css = '@page { size: letter; margin: 1in; margin-top: ' + (String.isNotBlank(headerHtml) ? '1.75in' : '1in') + '; margin-bottom: ' + (String.isNotBlank(footerHtml) ? '1.75in' : '1in') + '; }';
        css += 'body { font-family: Arial, sans-serif; font-size: 11pt; line-height: 1.15; color: #000; }';
        css += 'h1 { font-size: 20pt; font-weight: bold; margin: 0 0 6pt 0; }';
        css += 'h2 { font-size: 16pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h3 { font-size: 14pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h4 { font-size: 12pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h5 { font-size: 11pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h6 { font-size: 10pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h1, h2, h3, h4, h5, h6 { page-break-after: avoid; }';
        css += 'table { border-collapse: collapse; width: 100%; page-break-inside: auto; }';
        css += 'tr { page-break-inside: avoid; page-break-after: auto; }';
        css += 'td, th { padding: 4pt; vertical-align: top; }';
        css += 'p { margin: 0 0 8pt 0; orphans: 2; widows: 2; page-break-inside: avoid; }';
        css += 'img { max-width: 100%; }';
        css += 'ul, ol { margin: 0 0 8pt 0; padding-left: 36pt; }';
        css += 'li { margin: 0 0 2pt 0; page-break-inside: avoid; }';
        css += 'hr { border: none; border-top: 1px solid #000; margin: 6pt 0; }';
        css += 'sub { vertical-align: sub; font-size: 0.8em; }';
        css += 'sup { vertical-align: super; font-size: 0.8em; }';
        css += '.docgen-header { border-bottom: 1px solid #ccc; padding-bottom: 6pt; margin-bottom: 12pt; font-size: 9pt; }';
        css += '.docgen-footer { border-top: 1px solid #ccc; padding-top: 6pt; margin-top: 12pt; font-size: 9pt; }';
        css += '.docgen-header table, .docgen-footer table { border-collapse: collapse; width: 100%; }';
        css += '.docgen-header td, .docgen-footer td { padding: 2pt; vertical-align: middle; }';

        String result = '<html><head><style>' + css + '</style></head><body>';

        if (String.isNotBlank(headerHtml)) {
            result += '<div class="docgen-header">' + headerHtml + '</div>';
        }

        result += html;

        if (String.isNotBlank(footerHtml)) {
            result += '<div class="docgen-footer">' + footerHtml + '</div>';
        }

        result += HTML_SUFFIX;
        return result;
    }

    /**
     * Extracts content from <w:hdr>, <w:body>, and <w:ftr> tags.
     */
    private static String extractBodyContent(String xml) {
        String combinedContent = '';
        
        // 1. Extract all headers
        Integer cursor = 0;
        while ((cursor = xml.indexOf('<w:hdr', cursor)) != -1) {
            Integer tagEnd = xml.indexOf('>', cursor);
            if (tagEnd == -1) { break; }
            Integer hdrEnd = findClosingTag(xml, cursor, 'w:hdr');
            if (hdrEnd != -1) {
                combinedContent += xml.substring(tagEnd + 1, hdrEnd);
                cursor = hdrEnd;
            } else { cursor = tagEnd + 1; }
        }
        
        // 2. Extract main body
        Integer bodyStart = xml.indexOf('<w:body');
        if (bodyStart != -1) {
            Integer bodyContentStart = xml.indexOf('>', bodyStart) + 1;
            Integer bodyEnd = xml.lastIndexOf('</w:body>');
            if (bodyEnd != -1) {
                String content = xml.substring(bodyContentStart, bodyEnd);
                // Strip <w:sectPr> (section properties) from end of body
                Integer sectStart = content.lastIndexOf('<w:sectPr');
                if (sectStart != -1) {
                    content = content.substring(0, sectStart);
                }
                combinedContent += content;
            } else {
                combinedContent += xml.substring(bodyContentStart);
            }
        } else if (!xml.contains('<w:hdr') && !xml.contains('<w:ftr')) {
            // Fallback for raw content
            combinedContent = xml;
        }
        
        // 3. Extract all footers
        cursor = 0;
        while ((cursor = xml.indexOf('<w:ftr', cursor)) != -1) {
            Integer tagEnd = xml.indexOf('>', cursor);
            if (tagEnd == -1) { break; }
            Integer ftrEnd = findClosingTag(xml, cursor, 'w:ftr');
            if (ftrEnd != -1) {
                combinedContent += xml.substring(tagEnd + 1, ftrEnd);
                cursor = ftrEnd;
            } else { cursor = tagEnd + 1; }
        }
        
        return combinedContent;
    }

    /**
     * Processes body-level DOCX XML elements into HTML.
     * Handles consecutive list paragraphs by wrapping them in <ul>/<ol>.
     */
    private static String processBodyContent(String xml, Map<String, String> images) {
        // First pass: collect all paragraphs and tables in order
        List<String> elements = new List<String>();
        List<String> elementTypes = new List<String>(); // 'p' or 'tbl'
        Integer cursor = 0;

        while (cursor < xml.length()) {
            Integer nextTag = xml.indexOf('<', cursor);
                        if (nextTag == -1) { break; }
            cursor = nextTag;

            if (xml.substring(cursor).startsWith('<w:tbl')) {
                Integer tblEnd = findClosingTag(xml, cursor, 'w:tbl');
                if (tblEnd != -1) {
                    elements.add(xml.substring(cursor, tblEnd));
                    elementTypes.add('tbl');
                    cursor = tblEnd;
                } else {
                    cursor++;
                }
            } else if (xml.substring(cursor).startsWith('<w:p ') || xml.substring(cursor).startsWith('<w:p>') || xml.substring(cursor).startsWith('<w:p/>')) {
                Integer pEnd = findClosingTag(xml, cursor, 'w:p');
                if (pEnd != -1) {
                    elements.add(xml.substring(cursor, pEnd));
                    elementTypes.add('p');
                    cursor = pEnd;
                } else {
                    cursor++;
                }
            } else {
                Integer tagEnd = xml.indexOf('>', cursor);
                if (tagEnd != -1) {
                    cursor = tagEnd + 1;
                } else {
                    break;
                }
            }
        }

        // Second pass: render elements, grouping consecutive list paragraphs
        String result = '';
        Integer i = 0;
        while (i < elements.size()) {
            if (elementTypes[i] == 'tbl') {
                result += processTable(elements[i], images);
                i++;
            } else {
                // Check if this paragraph is a list item
                ListInfo li = getListInfo(elements[i]);
                if (li.isList) {
                    // Collect consecutive list paragraphs
                    List<String> listItems = new List<String>();
                    Boolean isNumbered = li.isNumbered;
                    listItems.add(elements[i]);
                    Integer j = i + 1;
                    while (j < elements.size() && elementTypes[j] == 'p') {
                        ListInfo nextLi = getListInfo(elements[j]);
                                                if (!nextLi.isList) { break; }
                        listItems.add(elements[j]);
                        j++;
                    }
                    result += renderList(listItems, isNumbered, images);
                    i = j;
                } else {
                    result += processParagraph(elements[i], images);
                    i++;
                }
            }
        }

        return result;
    }

    /**
     * Detects if a paragraph is a list item by checking for w:numPr or list-style pStyle.
     */
    private static ListInfo getListInfo(String pXml) {
        ListInfo li = new ListInfo();
        li.isList = false;
        li.isNumbered = false;

        String pPr = extractElement(pXml, 'w:pPr');
                if (String.isBlank(pPr)) { return li; }

        // Check for explicit numbering properties
        if (pPr.contains('<w:numPr')) {
            li.isList = true;
            // numId 0 means "no list" in OOXML
            String numId = extractAttr(pPr, 'w:numId', 'w:val');
            if (numId == '0') {
                li.isList = false;
                return li;
            }
            // Heuristic: odd numId = bullet, even = numbered (Word's common pattern)
            // Also check for ilvl to detect nested lists (not handled as nested HTML for simplicity)
            if (numId != null && numId.isNumeric()) {
                Integer nId = Integer.valueOf(numId);
                li.isNumbered = (Math.mod(nId, 2) == 0);
            }
            return li;
        }

        // Check for list paragraph style
        String pStyleVal = extractAttr(pPr, 'w:pStyle', 'w:val');
        if (pStyleVal != null && LIST_STYLE_IDS.contains(pStyleVal)) {
            li.isList = true;
            li.isNumbered = pStyleVal.containsIgnoreCase('Number');
        }

        return li;
    }

    /**
     * Renders a group of consecutive list paragraphs as <ul> or <ol>.
     */
    private static String renderList(List<String> listItems, Boolean isNumbered, Map<String, String> images) {
        String tag = isNumbered ? 'ol' : 'ul';
        String result = '<' + tag + '>';
        for (String pXml : listItems) {
            String content = processRuns(pXml, images);
                        if (String.isBlank(content)) { content = '&nbsp;'; }

            // Extract paragraph-level styles for the <li>
            String pPr = extractElement(pXml, 'w:pPr');
            String style = '';
            if (String.isNotBlank(pPr)) {
                style = parseParagraphStyle(pPr);
            }

            result += '<li' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>' + content + '</li>';
        }
        result += '</' + tag + '>';
        return result;
    }

    /**
     * Processes a <w:p> element into an HTML paragraph, heading, or horizontal rule.
     */
    private static String processParagraph(String pXml, Map<String, String> images) {
        String style = '';
        Integer headingLevel = 0;
        Boolean pageBreakBefore = false;
        Boolean isTitle = false;

        // Extract paragraph properties
        String pPr = extractElement(pXml, 'w:pPr');
        if (String.isNotBlank(pPr)) {
            style = parseParagraphStyle(pPr);

            // Check for heading style
            String pStyleVal = extractAttr(pPr, 'w:pStyle', 'w:val');
            if (pStyleVal != null) {
                if (HEADING_STYLE_MAP.containsKey(pStyleVal)) {
                    headingLevel = HEADING_STYLE_MAP.get(pStyleVal);
                } else if (pStyleVal == 'Title' || pStyleVal == 'title') {
                    isTitle = true;
                } else if (pStyleVal == 'Subtitle' || pStyleVal == 'subtitle') {
                    // Render subtitle as styled paragraph
                    style += (String.isNotBlank(style) ? ';' : '') + 'font-size:14pt;color:#595959';
                }
            }

            // Check for page break before
            if (pPr.contains('<w:pageBreakBefore/>') || pPr.contains('<w:pageBreakBefore ')) {
                pageBreakBefore = true;
            }
        }

        // Process runs
        String content = processRuns(pXml, images);

        // Check for page break in runs (w:br w:type="page")
        if (pXml.contains('w:type="page"') || pXml.contains('w:type=\'page\'')) {
            pageBreakBefore = true;
        }

        // Empty paragraph with bottom border = horizontal rule
        if (String.isBlank(content) && String.isNotBlank(pPr) && pPr.contains('<w:pBdr')) {
            String bottomBdr = extractElement(pPr, 'w:bottom');
            String bdrVal = extractAttr(bottomBdr, 'w:bottom', 'w:val');
            if (String.isNotBlank(bottomBdr) && bdrVal != 'nil' && bdrVal != 'none') {
                return (pageBreakBefore ? '<div style="page-break-before:always"></div>' : '') + '<hr/>';
            }
        }

        String pageBreakDiv = pageBreakBefore ? '<div style="page-break-before:always"></div>' : '';

        // Empty paragraph = line break
        if (String.isBlank(content)) {
            return pageBreakDiv + '<p' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>&nbsp;</p>';
        }

        // Heading
        if (headingLevel > 0) {
            String tag = 'h' + headingLevel;
            return pageBreakDiv + '<' + tag + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>' + content + '</' + tag + '>';
        }

        // Title style
        if (isTitle) {
            return pageBreakDiv + '<h1 style="font-size:26pt;font-weight:normal' +
                (String.isNotBlank(style) ? ';' + style : '') + '">' + content + '</h1>';
        }

        return pageBreakDiv + '<p' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>' + content + '</p>';
    }

    /**
     * Parses <w:pPr> into CSS style string.
     */
    private static String parseParagraphStyle(String pPr) {
        List<String> styles = new List<String>();

        // Alignment: <w:jc w:val="center"/>
        String jcVal = extractAttr(pPr, 'w:jc', 'w:val');
        if (jcVal != null) {
                        if (jcVal == 'center') { styles.add('text-align:center'); }
                        else if (jcVal == 'right' || jcVal == 'end') { styles.add('text-align:right'); }
                        else if (jcVal == 'both' || jcVal == 'distribute') { styles.add('text-align:justify'); }
        }

        // Spacing: <w:spacing w:before="120" w:after="120" w:line="240" w:lineRule="auto"/>
        String spacingBefore = extractAttr(pPr, 'w:spacing', 'w:before');
        if (spacingBefore != null && spacingBefore.isNumeric()) {
            styles.add('margin-top:' + twipsToPt(Integer.valueOf(spacingBefore)) + 'pt');
        }
        String spacingAfter = extractAttr(pPr, 'w:spacing', 'w:after');
        if (spacingAfter != null && spacingAfter.isNumeric()) {
            styles.add('margin-bottom:' + twipsToPt(Integer.valueOf(spacingAfter)) + 'pt');
        }

        // Line spacing: <w:spacing w:line="360" w:lineRule="auto"/>
        // In "auto" mode: 240 = single, 360 = 1.5, 480 = double
        // In "exact"/"atLeast" mode: value is in twips
        String lineSpacing = extractAttr(pPr, 'w:spacing', 'w:line');
        String lineRule = extractAttr(pPr, 'w:spacing', 'w:lineRule');
        if (lineSpacing != null && lineSpacing.isNumeric()) {
            Integer lineVal = Integer.valueOf(lineSpacing);
            if (lineRule == 'exact' || lineRule == 'atLeast') {
                styles.add('line-height:' + twipsToPt(lineVal) + 'pt');
            } else {
                // "auto" or default — value/240 gives the multiplier
                Decimal multiplier = lineVal / 240.0;
                styles.add('line-height:' + multiplier);
            }
        }

        // Indent: <w:ind w:left="720" w:right="0" w:firstLine="360" w:hanging="360"/>
        String indLeft = extractAttr(pPr, 'w:ind', 'w:left');
        String indHanging = extractAttr(pPr, 'w:ind', 'w:hanging');
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
        // Hanging indent: negative text-indent
        if (indHanging != null && indHanging.isNumeric()) {
            Decimal hangPt = twipsToPt(Integer.valueOf(indHanging));
            styles.add('text-indent:-' + hangPt + 'pt');
            // If no explicit left indent, add padding to compensate
            if (indLeft == null) {
                styles.add('padding-left:' + hangPt + 'pt');
            }
        }

        // Paragraph shading: <w:shd w:val="clear" w:fill="FFFF00"/>
        String pFill = extractAttr(pPr, 'w:shd', 'w:fill');
        if (pFill != null && pFill != 'auto') {
            styles.add('background-color:#' + pFill);
        }

        // Paragraph borders: <w:pBdr><w:top w:val="single" w:sz="4" w:color="000000"/>...
        if (pPr.contains('<w:pBdr')) {
            String pBdr = extractElement(pPr, 'w:pBdr');
            if (String.isNotBlank(pBdr)) {
                String topBdr = parseBorderSide(pBdr, 'w:top');
                String bottomBdr = parseBorderSide(pBdr, 'w:bottom');
                String leftBdr = parseBorderSide(pBdr, 'w:left');
                String rightBdr = parseBorderSide(pBdr, 'w:right');
                
                if (String.isNotBlank(topBdr) && topBdr != 'none' && topBdr != 'nil') { styles.add('border-top:' + topBdr); }
                if (String.isNotBlank(bottomBdr) && bottomBdr != 'none' && bottomBdr != 'nil') { styles.add('border-bottom:' + bottomBdr); }
                if (String.isNotBlank(leftBdr) && leftBdr != 'none' && leftBdr != 'nil') { styles.add('border-left:' + leftBdr); }
                if (String.isNotBlank(rightBdr) && rightBdr != 'none' && rightBdr != 'nil') { styles.add('border-right:' + rightBdr); }
                
                if ((String.isNotBlank(topBdr) && topBdr != 'none' && topBdr != 'nil') || 
                    (String.isNotBlank(bottomBdr) && bottomBdr != 'none' && bottomBdr != 'nil') || 
                    (String.isNotBlank(leftBdr) && leftBdr != 'none' && leftBdr != 'nil') || 
                    (String.isNotBlank(rightBdr) && rightBdr != 'none' && rightBdr != 'nil')) {
                    styles.add('padding:4pt');
                }
            }
        }

        // Keep with next (avoid page break after this paragraph)
        if (pPr.contains('<w:keepNext/>') || pPr.contains('<w:keepNext ')) {
            styles.add('page-break-after:avoid');
        }

        // Keep lines together (avoid page break inside this paragraph)
        if (pPr.contains('<w:keepLines/>') || pPr.contains('<w:keepLines ')) {
            styles.add('page-break-inside:avoid');
        }

        return String.join(styles, ';');
    }

    /**
     * Parses a single border shorthand from a tcBorders element.
     * E.g., <w:top w:val="single" w:sz="4" w:color="000000"/> → "1pt solid #000000"
     */
    private static String parseBorderSide(String bdrXml, String side) {
        String val = extractAttr(bdrXml, side, 'w:val');
                if (val == null || val == 'none' || val == 'nil') { return null; }

        String sz = extractAttr(bdrXml, side, 'w:sz');
        String color = extractAttr(bdrXml, side, 'w:color');

        // sz is in 8ths of a point
        Decimal widthPt = 1;
        if (sz != null && sz.isNumeric()) {
            widthPt = Integer.valueOf(sz) / 8.0;
                        if (widthPt < 0.5) { widthPt = 0.5; }
        }

        String cssColor = '#000000';
        if (color != null && color != 'auto') {
            cssColor = '#' + color;
        }

        // Map common Word border styles to CSS
        String cssStyle = 'solid';
                if (val == 'dashed' || val == 'dashSmallGap') { cssStyle = 'dashed'; }
                else if (val == 'dotted') { cssStyle = 'dotted'; }
                else if (val == 'double') { cssStyle = 'double'; }

        return widthPt + 'pt ' + cssStyle + ' ' + cssColor;
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

            // Also check for hyperlinks
            Integer hyperlinkStart = pXml.indexOf('<w:hyperlink', cursor);

            // Find the earliest element
            Integer nextRun = -1;
                        if (runStart != -1 && runStart2 != -1) { nextRun = Math.min(runStart, runStart2); }
                        else if (runStart != -1) { nextRun = runStart; }
                        else if (runStart2 != -1) { nextRun = runStart2; }

            Integer nextDrawing = -1;
                        if (drawingStart != -1 && drawingStart2 != -1) { nextDrawing = Math.min(drawingStart, drawingStart2); }
                        else if (drawingStart != -1) { nextDrawing = drawingStart; }
                        else if (drawingStart2 != -1) { nextDrawing = drawingStart2; }

            // Find earliest of run, drawing, hyperlink
            Integer nextElement = -1;
            String elementType = '';

            if (nextRun != -1) { nextElement = nextRun; elementType = 'run'; }
            if (nextDrawing != -1 && (nextElement == -1 || nextDrawing < nextElement)) {
                nextElement = nextDrawing; elementType = 'drawing';
            }
            if (hyperlinkStart != -1 && (nextElement == -1 || hyperlinkStart < nextElement)) {
                nextElement = hyperlinkStart; elementType = 'hyperlink';
            }

                        if (nextElement == -1) { break; }

            if (elementType == 'run') {
                Integer runEnd = findClosingTag(pXml, nextRun, 'w:r');
                if (runEnd != -1) {
                    result += processRun(pXml.substring(nextRun, runEnd), images);
                    cursor = runEnd;
                } else {
                    cursor = nextRun + 1;
                }
            } else if (elementType == 'drawing') {
                Integer drawEnd = findClosingTag(pXml, nextDrawing, 'w:drawing');
                if (drawEnd != -1) {
                    result += processDrawing(pXml.substring(nextDrawing, drawEnd), images);
                    cursor = drawEnd;
                } else {
                    cursor = nextDrawing + 1;
                }
            } else if (elementType == 'hyperlink') {
                Integer hlEnd = findClosingTag(pXml, hyperlinkStart, 'w:hyperlink');
                if (hlEnd != -1) {
                    result += processHyperlink(pXml.substring(hyperlinkStart, hlEnd), images);
                    cursor = hlEnd;
                } else {
                    cursor = hyperlinkStart + 1;
                }
            }
        }

        return result;
    }

    /**
     * Processes a <w:hyperlink> element — extracts inner runs and wraps in <a> if possible.
     */
    private static String processHyperlink(String hlXml, Map<String, String> images) {
        // Hyperlinks may have an anchor (bookmark) or r:id (external link).
        // We can't resolve r:id without the .rels file, so render the text with underline styling.
        String innerContent = '';
        Integer cursor = 0;
        while (cursor < hlXml.length()) {
            Integer runStart = hlXml.indexOf('<w:r>', cursor);
            Integer runStart2 = hlXml.indexOf('<w:r ', cursor);
            Integer nextRun = -1;
                        if (runStart != -1 && runStart2 != -1) { nextRun = Math.min(runStart, runStart2); }
                        else if (runStart != -1) { nextRun = runStart; }
                        else if (runStart2 != -1) { nextRun = runStart2; }
                        if (nextRun == -1) { break; }

            Integer runEnd = findClosingTag(hlXml, nextRun, 'w:r');
            if (runEnd != -1) {
                innerContent += processRun(hlXml.substring(nextRun, runEnd), images);
                cursor = runEnd;
            } else {
                cursor = nextRun + 1;
            }
        }

                if (String.isBlank(innerContent)) { return ''; }

        // Wrap in styled span to indicate link (blue + underline)
        return '<span style="color:#0563C1;text-decoration:underline">' + innerContent + '</span>';
    }

    /**
     * Processes a single <w:r> (run) element into an HTML <span>.
     */
    private static String processRun(String rXml, Map<String, String> images) {
        // Extract run properties
        String rPr = extractElement(rXml, 'w:rPr');
        String style = (String.isNotBlank(rPr)) ? parseRunStyle(rPr) : '';
        
        String openTags = '';
        String closeTags = '';
        if (String.isNotBlank(rPr)) {
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
            // Superscript / Subscript
            String vertAlign = extractAttr(rPr, 'w:vertAlign', 'w:val');
            if (vertAlign == 'superscript') {
                openTags += '<sup>';
                closeTags = '</sup>' + closeTags;
            } else if (vertAlign == 'subscript') {
                openTags += '<sub>';
                closeTags = '</sub>' + closeTags;
            }
        }

        String runContent = '';
        Integer cursor = 0;
        
        // Walk through the run elements in order
        while (cursor < rXml.length()) {
            Integer nextBr = rXml.indexOf('<w:br', cursor);
            Integer nextTab = rXml.indexOf('<w:tab', cursor);
            Integer nextDrawing = rXml.indexOf('<w:drawing', cursor);
            // Find <w:t> or <w:t  but NOT <w:tab — indexOf('<w:t') false-matches <w:tab
            Integer nextT = -1;
            Integer tSearch = cursor;
            while (tSearch < rXml.length()) {
                Integer candidate = rXml.indexOf('<w:t', tSearch);
                if (candidate == -1) { break; }
                Integer afterTag = candidate + 4;
                if (afterTag < rXml.length()) {
                    String ch = rXml.substring(afterTag, afterTag + 1);
                    if (ch == '>' || ch == ' ') { nextT = candidate; break; }
                }
                tSearch = afterTag;
            }

            // Find the earliest element
            Integer nextPos = -1;
            String type = '';

            if (nextT != -1 && (nextPos == -1 || nextT < nextPos)) { nextPos = nextT; type = 't'; }
            if (nextBr != -1 && (nextPos == -1 || nextBr < nextPos)) { nextPos = nextBr; type = 'br'; }
            if (nextTab != -1 && (nextPos == -1 || nextTab < nextPos)) { nextPos = nextTab; type = 'tab'; }
            if (nextDrawing != -1 && (nextPos == -1 || nextDrawing < nextPos)) { nextPos = nextDrawing; type = 'drawing'; }
            
            if (nextPos == -1) { break; }
            
            if (type == 't') {
                Integer tagEnd = rXml.indexOf('>', nextPos);
                if (tagEnd != -1 && rXml.substring(tagEnd - 1, tagEnd) != '/') {
                    Integer tEnd = rXml.indexOf('</w:t>', tagEnd);
                    if (tEnd != -1) {
                        String text = rXml.substring(tagEnd + 1, tEnd);
                        if (text.contains('##BARCODE:')) {
                            runContent += renderBarcodeHtml(text);
                        } else {
                            // Check for caps in rPr
                            if (String.isNotBlank(rPr)) {
                                if (rPr.contains('<w:caps/>') || rPr.contains('<w:caps ')) { text = text.toUpperCase(); }
                                if (rPr.contains('<w:smallCaps/>') || rPr.contains('<w:smallCaps ')) {
                                    text = text.toUpperCase();
                                    if (!style.contains('font-variant:small-caps')) {
                                        style += (String.isNotBlank(style) ? ';' : '') + 'font-variant:small-caps';
                                    }
                                }
                            }
                            runContent += text.escapeHtml4();
                        }
                        cursor = tEnd + 6;
                    } else { cursor = tagEnd + 1; }
                } else { cursor = (tagEnd != -1) ? tagEnd + 1 : nextPos + 1; }
            } else if (type == 'br') {
                if (rXml.substring(nextPos).contains('w:type="page"')) {
                    runContent += '<div style="page-break-before:always"></div>';
                } else if (rXml.substring(nextPos).contains('w:type="column"')) {
                    runContent += '<br/>';
                } else {
                    runContent += '<br/>';
                }
                Integer tagEnd = rXml.indexOf('>', nextPos);
                cursor = (tagEnd != -1) ? tagEnd + 1 : nextPos + 1;
            } else if (type == 'tab') {
                runContent += '<span style="display:inline-block;width:36pt"></span>';
                Integer tagEnd = rXml.indexOf('>', nextPos);
                cursor = (tagEnd != -1) ? tagEnd + 1 : nextPos + 1;
            } else if (type == 'drawing') {
                Integer drawEnd = findClosingTag(rXml, nextDrawing, 'w:drawing');
                if (drawEnd != -1) {
                    runContent += processDrawing(rXml.substring(nextDrawing, drawEnd), images);
                    cursor = drawEnd;
                } else { cursor = nextDrawing + 1; }
            }
        }

        if (String.isBlank(runContent)) { return ''; }

        if (String.isNotBlank(style)) {
            return '<span style="' + style + '">' + openTags + runContent + closeTags + '</span>';
        }
        return openTags + runContent + closeTags;
    }

    /**
     * Processes a run containing a tab character into HTML.
     * Renders the tab as a fixed-width space and appends any styled text.
     */
    private static String processTabRun(String rXml) {
        String tabResult = '<span style="display:inline-block;width:36pt"></span>';
        String text = extractTextContent(rXml);
        if (String.isBlank(text)) { return tabResult; }

        String rPr = extractElement(rXml, 'w:rPr');
        if (String.isNotBlank(rPr)) {
            String style = parseRunStyle(rPr);
            tabResult += '<span style="' + style + '">' + text.escapeHtml4() + '</span>';
        } else {
            tabResult += text.escapeHtml4();
        }
        return tabResult;
    }

    /**
     * Parses <w:rPr> into CSS style string.
     */
    private static String parseRunStyle(String rPr) {
        List<String> styles = new List<String>();

        // Font: <w:rFonts w:ascii="Calibri"/>
        String font = extractAttr(rPr, 'w:rFonts', 'w:ascii');
                if (font == null) { font = extractAttr(rPr, 'w:rFonts', 'w:hAnsi'); }
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

        // Shading (different from highlight): <w:shd w:val="clear" w:fill="FFFF00"/>
        String shdFill = extractAttr(rPr, 'w:shd', 'w:fill');
        if (shdFill != null && shdFill != 'auto' && highlight == null) {
            styles.add('background-color:#' + shdFill);
        }

        // Letter spacing: <w:spacing w:val="20"/> (in twips)
        String letterSpacing = extractAttr(rPr, 'w:spacing', 'w:val');
        if (letterSpacing != null && letterSpacing.isNumeric()) {
            Integer lsVal = Integer.valueOf(letterSpacing);
            if (lsVal != 0) {
                styles.add('letter-spacing:' + twipsToPt(lsVal) + 'pt');
            }
        }

        return String.join(styles, ';');
    }

    /**
     * Processes a <w:tbl> element into an HTML <table>.
     */
    private static String processTable(String tblXml, Map<String, String> images) {
        String tableStyle = 'border-collapse:collapse;width:100%';
        Boolean hasBorders = false;

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
                hasBorders = true;
                tableStyle += ';border:1px solid #000';
            }

            // Table alignment
            String tblJc = extractAttr(tblPr, 'w:jc', 'w:val');
            if (tblJc == 'center') {
                tableStyle += ';margin-left:auto;margin-right:auto';
            } else if (tblJc == 'right' || tblJc == 'end') {
                tableStyle += ';margin-left:auto';
            }

            // Table cell margins (default padding for all cells)
            String tblCellMar = extractElement(tblPr, 'w:tblCellMar');
            if (String.isNotBlank(tblCellMar)) {
                String topMar = extractAttr(tblCellMar, 'w:top', 'w:w');
                String bottomMar = extractAttr(tblCellMar, 'w:bottom', 'w:w');
                String leftMar = extractAttr(tblCellMar, 'w:left', 'w:w');
                                if (leftMar == null) { leftMar = extractAttr(tblCellMar, 'w:start', 'w:w'); }
                String rightMar = extractAttr(tblCellMar, 'w:right', 'w:w');
                                if (rightMar == null) { rightMar = extractAttr(tblCellMar, 'w:end', 'w:w'); }
                // These values will be used on cells; for now they affect the table-level default
            }
        }

        // Process rows
        String rows = '';
        Integer cursor = 0;
        while (cursor < tblXml.length()) {
            Integer trStart = tblXml.indexOf('<w:tr', cursor);
                        if (trStart == -1) { break; }

            Integer trEnd = findClosingTag(tblXml, trStart, 'w:tr');
                        if (trEnd == -1) { break; }

            rows += processTableRow(tblXml.substring(trStart, trEnd), images, tblPr, hasBorders);
            cursor = trEnd;
        }

        return '<table style="' + tableStyle + '">' + rows + '</table>';
    }

    /**
     * Processes a <w:tr> element into an HTML <tr>.
     */
    private static String processTableRow(String trXml, Map<String, String> images, String tblPr, Boolean hasBorders) {
        String cells = '';
        Integer cursor = 0;

        // Check for header row
        String trPr = extractElement(trXml, 'w:trPr');
        Boolean isHeader = (String.isNotBlank(trPr) && (trPr.contains('<w:tblHeader/>') || trPr.contains('<w:tblHeader ')));

        while (cursor < trXml.length()) {
            Integer tcStart = trXml.indexOf('<w:tc', cursor);
                        if (tcStart == -1) { break; }

            Integer tcEnd = findClosingTag(trXml, tcStart, 'w:tc');
                        if (tcEnd == -1) { break; }

            cells += processTableCell(trXml.substring(tcStart, tcEnd), images, tblPr, hasBorders, isHeader);
            cursor = tcEnd;
        }

        return '<tr>' + cells + '</tr>';
    }

    /**
     * Processes a <w:tc> element into an HTML <td> or <th>.
     */
    private static String processTableCell(String tcXml, Map<String, String> images, String tblPr, Boolean hasBorders, Boolean isHeader) {
        List<String> styles = new List<String>();
        Integer colspan = 0;

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

            // Cell-specific borders: <w:tcBorders>
            String tcBdr = tcPr.contains('<w:tcBorders') ? extractElement(tcPr, 'w:tcBorders') : null;
            if (String.isNotBlank(tcBdr)) {
                addBorderStyles(styles, tcBdr);
            } else if (hasBorders) {
                styles.add('border:1px solid #000');
            }

            // Column span: <w:gridSpan w:val="2"/>
            String gridSpan = extractAttr(tcPr, 'w:gridSpan', 'w:val');
            if (gridSpan != null && gridSpan.isNumeric()) {
                colspan = Integer.valueOf(gridSpan);
            }

            // Cell padding: <w:tcMar>
            // Cell padding: <w:tcMar>
            String tcMar = tcPr.contains('<w:tcMar') ? extractElement(tcPr, 'w:tcMar') : null;
            if (String.isNotBlank(tcMar)) {
                addCellPaddingStyles(styles, tcMar);
            }
        } else if (hasBorders) {
            styles.add('border:1px solid #000');
        }

        // Process cell content (paragraphs)
        String content = processBodyContent(tcXml, images);

        String styleStr = String.join(styles, ';');
        String tag = isHeader ? 'th' : 'td';
        String attrs = '';
                if (String.isNotBlank(styleStr)) { attrs += ' style="' + styleStr + '"'; }
                if (colspan > 1) { attrs += ' colspan="' + colspan + '"'; }

        return '<' + tag + attrs + '>' + content + '</' + tag + '>';
    }

    /**
     * Adds border CSS styles from a tcBorders element.
     */
    private static void addBorderStyles(List<String> styles, String bdrXml) {
        String topBdr = parseBorderSide(bdrXml, 'w:top');
        String bottomBdr = parseBorderSide(bdrXml, 'w:bottom');
        String leftBdr = parseBorderSide(bdrXml, 'w:left');
        if (leftBdr == null) { leftBdr = parseBorderSide(bdrXml, 'w:start'); }
        String rightBdr = parseBorderSide(bdrXml, 'w:right');
        if (rightBdr == null) { rightBdr = parseBorderSide(bdrXml, 'w:end'); }
        if (topBdr != null) { styles.add('border-top:' + topBdr); }
        if (bottomBdr != null) { styles.add('border-bottom:' + bottomBdr); }
        if (leftBdr != null) { styles.add('border-left:' + leftBdr); }
        if (rightBdr != null) { styles.add('border-right:' + rightBdr); }
    }

    /**
     * Adds cell padding CSS from a tcMar element.
     */
    private static void addCellPaddingStyles(List<String> styles, String tcMar) {
        String cellPadTop = extractAttr(tcMar, 'w:top', 'w:w');
        String cellPadBottom = extractAttr(tcMar, 'w:bottom', 'w:w');
        String cellPadLeft = extractAttr(tcMar, 'w:left', 'w:w');
        if (cellPadLeft == null) { cellPadLeft = extractAttr(tcMar, 'w:start', 'w:w'); }
        String cellPadRight = extractAttr(tcMar, 'w:right', 'w:w');
        if (cellPadRight == null) { cellPadRight = extractAttr(tcMar, 'w:end', 'w:w'); }

        List<String> padParts = new List<String>();
        padParts.add((cellPadTop != null && cellPadTop.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadTop)) + 'pt' : '4pt');
        padParts.add((cellPadRight != null && cellPadRight.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadRight)) + 'pt' : '4pt');
        padParts.add((cellPadBottom != null && cellPadBottom.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadBottom)) + 'pt' : '4pt');
        padParts.add((cellPadLeft != null && cellPadLeft.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadLeft)) + 'pt' : '4pt');
        styles.add('padding:' + String.join(padParts, ' '));
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
                if (cx == null) { cx = extractAttr(drawingXml, 'a:ext', 'cx'); }
                if (cy == null) { cy = extractAttr(drawingXml, 'a:ext', 'cy'); }

        if (cx != null && cx.isNumeric()) {
            widthPx = Math.round(Long.valueOf(cx) * EMU_TO_PX);
        }
        if (cy != null && cy.isNumeric()) {
            heightPx = Math.round(Long.valueOf(cy) * EMU_TO_PX);
        }

        // Extract relationship ID from <a:blip r:embed="rIdImg1"/>
        String relId = extractAttr(drawingXml, 'a:blip', 'r:embed');
                if (relId == null) { return ''; }

        String imageValue = images.get(relId);
                if (imageValue == null) { return ''; }

        // If the value is a URL (Salesforce content path or absolute URL), use directly as img src
        if (imageValue.startsWith('/sfc/') || imageValue.startsWith('/servlet/') ||
            imageValue.startsWith('/apex/') || imageValue.startsWithIgnoreCase('http')) {
            return '<img src="' + imageValue + '" ' +
                   'width="' + widthPx + '" height="' + heightPx + '" ' +
                   'style="max-width:100%" />';
        }

        // Otherwise treat as base64 — determine MIME type and create data URI
        String mimeType = 'image/png';
        if (imageValue.startsWith('/9j/') || imageValue.startsWith('/9J/')) {
            mimeType = 'image/jpeg';
        }

        return '<img src="data:' + mimeType + ';base64,' + imageValue + '" ' +
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
                        if (tStart == -1) { break; }

            // Skip self-closing <w:t/>
            Integer tagEnd = xml.indexOf('>', tStart);
                        if (tagEnd == -1) { break; }

            if (xml.substring(tagEnd - 1, tagEnd) == '/') {
                cursor = tagEnd + 1;
                continue;
            }

            Integer contentStart = tagEnd + 1;
            Integer tEnd = xml.indexOf('</w:t>', contentStart);
                        if (tEnd == -1) { break; }

            result += xml.substring(contentStart, tEnd);
            cursor = tEnd + 6; // length of </w:t>
        }

        // Unescape XML entities so downstream escapeHtml4() doesn't double-encode
        result = result.replace('&amp;', '&');
        result = result.replace('&lt;', '<');
        result = result.replace('&gt;', '>');
        result = result.replace('&apos;', '\'');
        result = result.replace('&quot;', '"');

        return result;
    }

    /**
     * Extracts the first occurrence of an element's content.
     * Returns the content including the element's own tags.
     */
    private static String extractElement(String xml, String tagName) {
        Integer start = xml.indexOf('<' + tagName);
                if (start == -1) { return null; }

        // Check for self-closing
        Integer tagEnd = xml.indexOf('>', start);
                if (tagEnd == -1) { return null; }
        if (xml.substring(tagEnd - 1, tagEnd) == '/') {
            return xml.substring(start, tagEnd + 1);
        }

        Integer endPos = findClosingTag(xml, start, tagName);
                if (endPos == -1) { return xml.substring(start, tagEnd + 1); }
        return xml.substring(start, endPos);
    }

    /**
     * Extracts an attribute value from a specific element.
     * E.g., extractAttr(xml, 'w:jc', 'w:val') from <w:jc w:val="center"/>
     */
    private static String extractAttr(String xml, String tagName, String attrName) {
        Integer tagStart = xml.indexOf('<' + tagName);
        if (tagStart == -1) { return null; }

        Integer tagEnd = xml.indexOf('>', tagStart);
        if (tagEnd == -1) { return null; }

        String tagContent = xml.substring(tagStart, tagEnd + 1);
        
        // Try double quotes
        String searchDouble = attrName + '="';
        Integer attrStart = tagContent.indexOf(searchDouble);
        String quoteUsed = '"';
        
        if (attrStart == -1) {
            // Try single quotes
            String searchSingle = attrName + '=\'';
            attrStart = tagContent.indexOf(searchSingle);
            quoteUsed = '\'';
        }
        
        if (attrStart == -1) { return null; }

        Integer valueStart = attrStart + attrName.length() + 2; // skip attr=" or attr='
        Integer valueEnd = tagContent.indexOf(quoteUsed, valueStart);
        if (valueEnd == -1) { return null; }

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

                        if (nextClose == -1) { return -1; }

            if (nextOpen != -1 && nextOpen < nextClose) {
                // Check if it's actually the tag (not a prefix match like <w:tblPr matching <w:tbl)
                Integer afterOpen = nextOpen + openTag.length();
                Boolean isRealTag = afterOpen < xml.length() &&
                    (xml.substring(afterOpen, afterOpen + 1) == '>' ||
                     xml.substring(afterOpen, afterOpen + 1) == ' ' ||
                     xml.substring(afterOpen, afterOpen + 1) == '/');
                if (isRealTag) {
                    depth++;
                    cursor = afterOpen;
                    continue;
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

    // Inner class for list detection
    private class ListInfo {
        Boolean isList;
        Boolean isNumbered;
    }

    // ---------------------------------------------------------------------------
    // Barcode rendering — CSS bars for Blob.toPdf()
    // ---------------------------------------------------------------------------

    /**
     * Detects ##BARCODE:type:value## markers in text and renders as HTML/CSS bars.
     * No images needed — Blob.toPdf() renders CSS perfectly.
     */
    private static String renderBarcodeHtml(String text) {
        // Extract marker: ##BARCODE:type:size:VALUE##
        Integer startIdx = text.indexOf('##BARCODE:');
                if (startIdx == -1) { return text.escapeHtml4(); }
        Integer endIdx = text.indexOf('##', startIdx + 10);
                if (endIdx == -1) { return text.escapeHtml4(); }

        String marker = text.substring(startIdx + 10, endIdx);
        List<String> parts = marker.split(':', 3);
        String barcodeType = parts[0];
        String sizeSpec = parts.size() > 1 ? parts[1] : '';
        String value = parts.size() > 2 ? parts[2] : '';

        // Unescape XML entities
        value = value.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>');

        String pattern = BarcodeGenerator.getPattern(value, barcodeType);
                if (pattern == null) { return value.escapeHtml4(); }

        String html;
        if (barcodeType == 'qr') {
            html = renderQrHtml(pattern, sizeSpec);
        } else {
            html = renderCode128Html(pattern, sizeSpec);
        }

        String before = text.substring(0, startIdx);
        String after = text.substring(endIdx + 2);
        return (String.isNotBlank(before) ? before.escapeHtml4() : '') +
               html +
               (String.isNotBlank(after) ? after.escapeHtml4() : '');
    }

    /** Renders Code 128 as inline CSS bars. */
    private static String renderCode128Html(String pattern, String sizeSpec) {
        // Parse size: "300x80" or default
        Integer barWidth = 1;
        Integer barHeight = 50;
        if (String.isNotBlank(sizeSpec) && sizeSpec.contains('x')) {
            List<String> dims = sizeSpec.split('x');
            if (dims.size() == 2 && dims[0].trim().isNumeric() && dims[1].trim().isNumeric()) {
                barWidth = Math.max(1, Integer.valueOf(dims[0].trim()) / pattern.length());
                barHeight = Integer.valueOf(dims[1].trim());
            }
        }

        String html = '<div style="display:inline-block;white-space:nowrap;line-height:0;">';
        for (Integer i = 0; i < pattern.length(); i++) {
            String color = pattern.substring(i, i + 1) == '1' ? '#000' : '#fff';
            html += '<span style="display:inline-block;width:' + barWidth + 'px;height:' + barHeight + 'px;background:' + color + ';"></span>';
        }
        html += '</div>';
        return html;
    }

    /** Renders QR code with absolute positioning — zero-gap guarantee in Flying Saucer. */
    private static String renderQrHtml(String pattern, String sizeSpec) {
        List<String> rows = pattern.split('\n');
        Integer modules = rows.size();

        // Parse size: single number = total px, default 250 (square)
        Integer totalPx = 250;
        if (String.isNotBlank(sizeSpec) && sizeSpec.trim().isNumeric()) {
            totalPx = Integer.valueOf(sizeSpec.trim());
        }

        // QR spec requires 4-module quiet zone on each side
        Integer quietZone = 4;
        Integer totalModules = modules + (quietZone * 2);
        Integer cellPx = Math.max(3, totalPx / totalModules);
        Integer quietPx = cellPx * quietZone;
        Integer totalSizePx = cellPx * totalModules;

        // Relative container with white background; only black modules are emitted
        // as absolutely positioned spans. No layout engine gaps possible.
        String html = '<div style="position:relative;display:inline-block;width:' + totalSizePx
            + 'px;height:' + totalSizePx + 'px;background:#fff;">';

        Integer yPx = quietPx;
        for (Integer r = 0; r < rows.size(); r++) {
            String row = rows[r];
            Integer c = 0;
            while (c < row.length()) {
                String bit = row.substring(c, c + 1);
                Integer run = 1;
                while (c + run < row.length() && row.substring(c + run, c + run + 1) == bit) {
                    run++;
                }
                // Only emit black modules; white is the container background
                if (bit == '1') {
                    Integer xPx = quietPx + (c * cellPx);
                    html += '<span style="position:absolute;left:' + xPx + 'px;top:' + yPx
                        + 'px;width:' + (cellPx * run) + 'px;height:' + cellPx + 'px;background:#000;"></span>';
                }
                c += run;
            }
            yPx += cellPx;
        }

        html += '</div>';
        return html;
    }
}