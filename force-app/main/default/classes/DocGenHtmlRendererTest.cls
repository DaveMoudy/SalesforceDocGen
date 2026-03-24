@IsTest
private class DocGenHtmlRendererTest {

    @IsTest
    static void testBasicParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>Hello World</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<body>'), 'Should contain body tag');
            System.assert(html.contains('Hello World'), 'Should contain text');
            System.assert(html.contains('<p>'), 'Should contain paragraph tag');
        }
    }

    @IsTest
    static void testBoldItalicUnderline() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:b/><w:i/><w:u w:val="single"/></w:rPr><w:t>Styled</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<b>'), 'Should contain bold');
            System.assert(html.contains('<i>'), 'Should contain italic');
            System.assert(html.contains('<u>'), 'Should contain underline');
            System.assert(html.contains('Styled'), 'Should contain text');
        }
    }

    @IsTest
    static void testParagraphAlignment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>Centered</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('text-align:center'), 'Should have center alignment');
        }
    }

    @IsTest
    static void testFontSizeAndColor() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:sz w:val="28"/><w:color w:val="FF0000"/></w:rPr><w:t>Big Red</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('font-size:14'), 'Should have 14pt font (28/2)');
            System.assert(html.contains('#FF0000'), 'Should have red color');
        }
    }

    @IsTest
    static void testTable() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl>' +
                '<w:tblPr><w:tblBorders><w:top w:val="single"/></w:tblBorders></w:tblPr>' +
                '<w:tr>' +
                '<w:tc><w:p><w:r><w:t>Cell 1</w:t></w:r></w:p></w:tc>' +
                '<w:tc><w:p><w:r><w:t>Cell 2</w:t></w:r></w:p></w:tc>' +
                '</w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<table'), 'Should contain table');
            System.assert(html.contains('<tr>'), 'Should contain row');
            System.assert(html.contains('<td'), 'Should contain cell');
            System.assert(html.contains('Cell 1'), 'Should contain cell text');
            System.assert(html.contains('Cell 2'), 'Should contain cell text');
        }
    }

    @IsTest
    static void testTableCellShading() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr><w:shd w:val="clear" w:fill="E2EFDA"/></w:tcPr>' +
                '<w:p><w:r><w:t>Shaded</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('#E2EFDA'), 'Should contain shading color');
        }
    }

    @IsTest
    static void testLineBreak() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>Before</w:t></w:r><w:r><w:br/></w:r><w:r><w:t>After</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<br/>'), 'Should contain line break');
            System.assert(html.contains('Before'), 'Should contain text before break');
            System.assert(html.contains('After'), 'Should contain text after break');
        }
    }

    @IsTest
    static void testImageWithBase64() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake image data'));
            Map<String, String> images = new Map<String, String>{
                'rIdImg1' => fakeBase64
            };

            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="1905000" cy="952500"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdImg1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);

            System.assert(html.contains('<img'), 'Should contain image tag');
            System.assert(html.contains('data:image/png;base64,'), 'Should contain base64 data URI');
        }
    }

    @IsTest
    static void testEmptyDocument() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String html = DocGenHtmlRenderer.convertToHtml('');
            System.assert(html.contains('<body>'), 'Should return valid HTML for empty input');
            System.assert(html.contains('</body>'), 'Should close body tag');
        }
    }

    @IsTest
    static void testNullDocument() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String html = DocGenHtmlRenderer.convertToHtml(null);
            System.assert(html.contains('<body>'), 'Should return valid HTML for null input');
        }
    }

    @IsTest
    static void testNoImagesOverload() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>Test</w:t></w:r></w:p></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Test'), 'Should handle no-image overload');
        }
    }

    @IsTest
    static void testMultipleRuns() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p>' +
                '<w:r><w:t>Hello </w:t></w:r>' +
                '<w:r><w:rPr><w:b/></w:rPr><w:t>World</w:t></w:r>' +
                '</w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('Hello '), 'Should contain first run text');
            System.assert(html.contains('<b>'), 'Should contain bold tag');
            System.assert(html.contains('World'), 'Should contain second run text');
        }
    }

    @IsTest
    static void testSpacingAndIndent() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:spacing w:before="120" w:after="240"/><w:ind w:left="720"/></w:pPr>' +
                '<w:r><w:t>Indented</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('margin-top:'), 'Should have top margin');
            System.assert(html.contains('margin-bottom:'), 'Should have bottom margin');
            System.assert(html.contains('margin-left:'), 'Should have left indent');
        }
    }

    // =========================================================================
    // Additional coverage tests
    // =========================================================================

    @IsTest
    static void testNullImagesMap() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Exercises the images == null guard in convertToHtml
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>Text</w:t></w:r></w:p></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, null);
            System.assert(html.contains('Text'), 'Should handle null images map');
        }
    }

    @IsTest
    static void testParagraphAlignmentRightAndJustify() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers right/end and both/distribute alignment branches
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>Right</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:jc w:val="end"/></w:pPr><w:r><w:t>End</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:jc w:val="both"/></w:pPr><w:r><w:t>Justify</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:jc w:val="distribute"/></w:pPr><w:r><w:t>Distribute</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('text-align:right'), 'Should have right alignment');
            System.assert(html.contains('text-align:justify'), 'Should have justify alignment');
        }
    }

    @IsTest
    static void testIndentRightAndFirstLine() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:ind w:right and w:firstLine branches
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:ind w:left="360" w:right="360" w:firstLine="720"/></w:pPr>' +
                '<w:r><w:t>Indented</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('margin-right:'), 'Should have right indent');
            System.assert(html.contains('text-indent:'), 'Should have first line indent');
        }
    }

    @IsTest
    static void testStrikethrough() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:strike branch
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:strike/></w:rPr><w:t>Struck</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<s>'), 'Should contain strikethrough');
            System.assert(html.contains('Struck'), 'Should contain text');
        }
    }

    @IsTest
    static void testFontFamilyAndHighlight() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:rFonts (hAnsi fallback) and w:highlight branches
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:rFonts w:hAnsi="Times New Roman"/><w:highlight w:val="yellow"/></w:rPr><w:t>Highlighted</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Times New Roman'), 'Should contain font family from hAnsi');
            System.assert(html.contains('background-color:yellow'), 'Should contain highlight');
        }
    }

    @IsTest
    static void testColorAuto() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers the color == 'auto' skip branch
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:color w:val="auto"/></w:rPr><w:t>Auto</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(!html.contains('color:#auto'), 'Should not include auto color');
            System.assert(html.contains('Auto'), 'Should contain text');
        }
    }

    @IsTest
    static void testTableWidthPercent() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers tblW with type=pct branch
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/></w:tblPr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('width:') && html.contains('%'), 'Should have percentage width from pct type');
        }
    }

    @IsTest
    static void testTableCellWidthTypes() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers tcW with pct type and dxa type branches
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr><w:tblBorders><w:top w:val="single"/></w:tblBorders></w:tblPr>' +
                '<w:tr>' +
                '<w:tc><w:tcPr><w:tcW w:w="2500" w:type="pct"/></w:tcPr><w:p><w:r><w:t>Pct</w:t></w:r></w:p></w:tc>' +
                '<w:tc><w:tcPr><w:tcW w:w="2880" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Dxa</w:t></w:r></w:p></w:tc>' +
                '</w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('border:1px solid #000'), 'Should have cell borders');
            System.assert(html.contains('Pct'), 'Should contain pct cell text');
            System.assert(html.contains('Dxa'), 'Should contain dxa cell text');
        }
    }

    @IsTest
    static void testCellVerticalAlignment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:vAlign branch
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr><w:vAlign w:val="center"/></w:tcPr>' +
                '<w:p><w:r><w:t>Centered</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('vertical-align:center'), 'Should have vertical alignment');
        }
    }

    @IsTest
    static void testImageJpegDetection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers JPEG detection branch (base64 starting with /9j/)
            String jpegBase64 = '/9j/4AAQSkZJRgABAQEASABIAAD';
            Map<String, String> images = new Map<String, String>{ 'rIdImg1' => jpegBase64 };

            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="952500" cy="476250"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdImg1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(html.contains('image/jpeg'), 'Should detect JPEG MIME type');
        }
    }

    @IsTest
    static void testImageMissingRelId() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers relId == null return '' branch
            Map<String, String> images = new Map<String, String>();

            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="952500" cy="476250"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(!html.contains('<img'), 'Should not produce img tag when no blip embed');
        }
    }

    @IsTest
    static void testImageMissingBase64() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers base64 == null return '' branch (relId exists but not in images map)
            Map<String, String> images = new Map<String, String>();

            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="952500" cy="476250"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdMissing" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(!html.contains('<img'), 'Should not produce img tag when base64 not in map');
        }
    }

    @IsTest
    static void testImageDimensionFallbackFromAExt() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers the fallback to a:ext for cx/cy when wp:extent is absent
            String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake image'));
            Map<String, String> images = new Map<String, String>{ 'rIdImg2' => fakeBase64 };

            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdImg2" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '<pic:spPr><a:xfrm><a:ext cx="1905000" cy="952500"/></a:xfrm></pic:spPr>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(html.contains('<img'), 'Should contain image tag');
        }
    }

    @IsTest
    static void testEmptyParagraphRendersNbsp() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers blank content branch in processParagraph
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:jc w:val="center"/></w:pPr></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('&nbsp;'), 'Empty paragraph should render nbsp');
        }
    }

    @IsTest
    static void testSelfClosingParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers <w:p/> self-closing paragraph handling
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p/>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<body>'), 'Should produce valid HTML');
        }
    }

    @IsTest
    static void testSelfClosingTextElement() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers self-closing <w:t/> skip in extractTextContent
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t/><w:t>After</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('After'), 'Should skip self-closing w:t and continue');
        }
    }

    @IsTest
    static void testNoBodyTag() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers extractBodyContent when no w:body tag exists
            String xml = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:p><w:r><w:t>NoBody</w:t></w:r></w:p></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<body>'), 'Should still produce valid HTML');
        }
    }

    @IsTest
    static void testBodyWithoutClosingTag() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers extractBodyContent when no </w:body> close tag
            String xml = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>Open</w:t></w:r></w:p></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Open'), 'Should handle missing close body tag');
        }
    }

    @IsTest
    static void testDrawingOutsideRun() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers standalone w:drawing outside of w:r in processRuns
            String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake'));
            Map<String, String> images = new Map<String, String>{ 'rIdStandalone' => fakeBase64 };

            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="952500" cy="476250"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdStandalone" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(html.contains('<img'), 'Should process drawing outside of w:r');
        }
    }

    @IsTest
    static void testSectPrStripping() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers sectPr stripping from body content
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>Before</w:t></w:r></w:p>' +
                '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Before'), 'Should contain text');
            System.assert(!html.contains('pgSz'), 'Should strip section properties');
        }
    }

    @IsTest
    static void testRunWithAttributeStart() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers <w:r ...> with attributes (runStart2 branch)
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r w:rsidR="00112233"><w:t>WithAttr</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('WithAttr'), 'Should handle runs with attributes');
        }
    }

    @IsTest
    static void testParagraphWithAttributes() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers <w:p ...> with attributes
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p w:rsidR="00112233"><w:r><w:t>ParaAttr</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('ParaAttr'), 'Should handle paragraphs with attributes');
        }
    }

    @IsTest
    static void testExtractElementSelfClosing() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers self-closing element in extractElement
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:jc w:val="left"/></w:pPr><w:r><w:t>Left</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Left'), 'Should handle self-closing elements in pPr');
        }
    }

    @IsTest
    static void testFontWithAsciiAttr() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:rFonts w:ascii path (primary path)
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:rFonts w:ascii="Courier New"/></w:rPr><w:t>Mono</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Courier New'), 'Should contain ascii font');
        }
    }

    @IsTest
    static void testCellShadingAutoFill() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers fill == 'auto' skip branch in cell shading
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr><w:shd w:val="clear" w:fill="auto"/></w:tcPr>' +
                '<w:p><w:r><w:t>AutoFill</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(!html.contains('background-color:#auto'), 'Should not include auto fill');
            System.assert(html.contains('AutoFill'), 'Should contain text');
        }
    }

    // =========================================================================
    // Barcode rendering — renderBarcodeHtml, renderCode128Html
    // =========================================================================

    @IsTest
    static void testRenderBarcodeCode128() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Build XML with a barcode marker in the text content
            String barcodeMarker = '##BARCODE:code128::ABC-123##';
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' + barcodeMarker + '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            // Should render CSS bars, not the raw marker text
            System.assert(html.contains('display:inline-block'), 'Should render as CSS bars');
            System.assert(html.contains('background:'), 'Should contain bar colors');
            System.assert(!html.contains('##BARCODE:'), 'Should not contain raw marker');
        }
    }

    @IsTest
    static void testRenderBarcodeCode128WithSize() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String barcodeMarker = '##BARCODE:code128:300x80:TEST##';
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' + barcodeMarker + '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('height:80px'), 'Should use custom height 80px');
            System.assert(html.contains('display:inline-block'), 'Should render as bars');
        }
    }

    // =========================================================================
    // QR code rendering — renderQrHtml
    // =========================================================================

    @IsTest
    static void testRenderBarcodeQr() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String barcodeMarker = '##BARCODE:qr::Hello##';
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' + barcodeMarker + '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            // QR renders as position:relative container with absolute spans
            System.assert(html.contains('position:relative'), 'Should render QR with position:relative container');
            System.assert(html.contains('position:absolute'), 'Should render QR modules as absolute spans');
            System.assert(!html.contains('##BARCODE:'), 'Should not contain raw marker');
        }
    }

    @IsTest
    static void testRenderBarcodeQrWithSize() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String barcodeMarker = '##BARCODE:qr:200:TestQR##';
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' + barcodeMarker + '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('position:relative'), 'Should render QR container');
        }
    }

    @IsTest
    static void testRenderBarcodeSurroundingText() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Text before and after barcode marker
            String barcodeMarker = 'Before##BARCODE:code128::VAL##After';
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' + barcodeMarker + '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('Before'), 'Should preserve text before barcode');
            System.assert(html.contains('After'), 'Should preserve text after barcode');
        }
    }

    // =========================================================================
    // List rendering — <w:numPr> for bulleted/numbered lists
    // =========================================================================

    @IsTest
    static void testBulletedList() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // w:numPr with odd numId = bullet list
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Bullet One</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Bullet Two</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<ul>'), 'Should contain unordered list');
            System.assert(html.contains('<li'), 'Should contain list items');
            System.assert(html.contains('Bullet One'), 'Should contain first item');
            System.assert(html.contains('Bullet Two'), 'Should contain second item');
            System.assert(html.contains('</ul>'), 'Should close list');
        }
    }

    @IsTest
    static void testNumberedList() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // w:numPr with even numId = numbered list
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Step One</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Step Two</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<ol>'), 'Should contain ordered list');
            System.assert(html.contains('<li'), 'Should contain list items');
            System.assert(html.contains('Step One'), 'Should contain first item');
            System.assert(html.contains('</ol>'), 'Should close ordered list');
        }
    }

    @IsTest
    static void testListStyleParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // ListParagraph style without numPr
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="ListParagraph"/></w:pPr>' +
                '<w:r><w:t>List Item</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<ul>') || html.contains('<ol>'), 'Should render as list');
            System.assert(html.contains('List Item'), 'Should contain list text');
        }
    }

    @IsTest
    static void testListNumIdZero() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // numId 0 means "no list" in OOXML
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="0"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Not a list</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(!html.contains('<ul>') && !html.contains('<ol>'), 'numId 0 should not produce a list');
            System.assert(html.contains('Not a list'), 'Should contain text');
        }
    }

    // =========================================================================
    // Tab stops — processTabRun
    // =========================================================================

    @IsTest
    static void testTabStop() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:tab/></w:r><w:r><w:t>After tab</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('width:36pt'), 'Should render tab as fixed-width space');
            System.assert(html.contains('After tab'), 'Should contain text after tab');
        }
    }

    @IsTest
    static void testTabStopWithStyledText() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Tab run that also contains text with run properties
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:b/></w:rPr><w:tab/><w:t>TabText</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('width:36pt'), 'Should render tab space');
            System.assert(html.contains('TabText'), 'Should contain text after tab');
        }
    }

    // =========================================================================
    // Subscript/Superscript — w:vertAlign
    // =========================================================================

    @IsTest
    static void testSubscript() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:vertAlign w:val="subscript"/></w:rPr><w:t>2</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<sub>'), 'Should contain subscript tag');
            System.assert(html.contains('</sub>'), 'Should close subscript tag');
        }
    }

    @IsTest
    static void testSuperscript() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:t>TM</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<sup>'), 'Should contain superscript tag');
            System.assert(html.contains('</sup>'), 'Should close superscript tag');
        }
    }

    // =========================================================================
    // Cell borders — addBorderStyles with <w:tcBorders>
    // =========================================================================

    @IsTest
    static void testCellBorders() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr>' +
                '<w:tcBorders>' +
                '<w:top w:val="single" w:sz="8" w:color="FF0000"/>' +
                '<w:bottom w:val="dashed" w:sz="4" w:color="00FF00"/>' +
                '<w:left w:val="dotted" w:sz="4" w:color="0000FF"/>' +
                '<w:right w:val="double" w:sz="12" w:color="000000"/>' +
                '</w:tcBorders>' +
                '</w:tcPr>' +
                '<w:p><w:r><w:t>Bordered</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('border-top:'), 'Should have top border');
            System.assert(html.contains('border-bottom:'), 'Should have bottom border');
            System.assert(html.contains('border-left:'), 'Should have left border');
            System.assert(html.contains('border-right:'), 'Should have right border');
            System.assert(html.contains('#FF0000'), 'Should have red top border');
            System.assert(html.contains('dashed'), 'Should have dashed bottom border');
            System.assert(html.contains('dotted'), 'Should have dotted left border');
            System.assert(html.contains('double'), 'Should have double right border');
        }
    }

    @IsTest
    static void testCellBordersStartEnd() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // w:start and w:end instead of w:left and w:right
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr>' +
                '<w:tcBorders>' +
                '<w:start w:val="single" w:sz="4" w:color="111111"/>' +
                '<w:end w:val="single" w:sz="4" w:color="222222"/>' +
                '</w:tcBorders>' +
                '</w:tcPr>' +
                '<w:p><w:r><w:t>StartEnd</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('border-left:'), 'Should have left border from w:start');
            System.assert(html.contains('border-right:'), 'Should have right border from w:end');
        }
    }

    // =========================================================================
    // Cell padding — addCellPaddingStyles with <w:tcMar>
    // =========================================================================

    @IsTest
    static void testCellPadding() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr>' +
                '<w:tcMar>' +
                '<w:top w:w="100" w:type="dxa"/>' +
                '<w:bottom w:w="200" w:type="dxa"/>' +
                '<w:left w:w="150" w:type="dxa"/>' +
                '<w:right w:w="150" w:type="dxa"/>' +
                '</w:tcMar>' +
                '</w:tcPr>' +
                '<w:p><w:r><w:t>Padded</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('padding:'), 'Should have padding style');
            System.assert(html.contains('Padded'), 'Should contain text');
        }
    }

    @IsTest
    static void testCellPaddingStartEnd() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // w:start and w:end instead of w:left and w:right
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr>' +
                '<w:tcMar>' +
                '<w:top w:w="80" w:type="dxa"/>' +
                '<w:bottom w:w="80" w:type="dxa"/>' +
                '<w:start w:w="120" w:type="dxa"/>' +
                '<w:end w:w="120" w:type="dxa"/>' +
                '</w:tcMar>' +
                '</w:tcPr>' +
                '<w:p><w:r><w:t>StartEndPad</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('padding:'), 'Should have padding using start/end');
        }
    }

    // =========================================================================
    // Cell merge — <w:gridSpan> (column span)
    // =========================================================================

    @IsTest
    static void testCellGridSpan() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr>' +
                '<w:tc><w:tcPr><w:gridSpan w:val="3"/></w:tcPr>' +
                '<w:p><w:r><w:t>Spanning 3 columns</w:t></w:r></w:p></w:tc>' +
                '</w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('colspan="3"'), 'Should have colspan=3');
            System.assert(html.contains('Spanning 3 columns'), 'Should contain spanned text');
        }
    }

    // =========================================================================
    // fontFaceCss parameter — custom font CSS injection
    // =========================================================================

    @IsTest
    static void testFontFaceCssInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>Custom Font</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String fontCss = '@font-face { font-family: "CustomFont"; src: url("data:font/woff2;base64,ABC"); }';
            String html = DocGenHtmlRenderer.convertToHtml(xml, new Map<String, String>(), fontCss);

            System.assert(html.contains('@font-face'), 'Should contain custom font-face CSS');
            System.assert(html.contains('CustomFont'), 'Should contain custom font name');
            System.assert(html.contains('Custom Font'), 'Should contain body text');
            // The custom CSS should come before the base styles
            Integer fontFacePos = html.indexOf('@font-face');
            Integer baseStylePos = html.indexOf('@page');
            System.assert(fontFacePos < baseStylePos, 'Font-face CSS should come before base styles');
        }
    }

    @IsTest
    static void testFontFaceCssNull() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>No Custom Font</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            // Null fontFaceCss should use default prefix
            String html = DocGenHtmlRenderer.convertToHtml(xml, new Map<String, String>(), null);

            System.assert(!html.contains('@font-face'), 'Should not contain font-face when null');
            System.assert(html.contains('No Custom Font'), 'Should contain body text');
        }
    }

    // =========================================================================
    // Image with Salesforce URL — exercises URL-based img rendering
    // =========================================================================

    @IsTest
    static void testImageWithSfcUrl() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, String> images = new Map<String, String>{
                'rIdSfc1' => '/sfc/servlet.shepherd/version/download/068000000000001'
            };

            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="1905000" cy="952500"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdSfc1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);

            System.assert(html.contains('<img'), 'Should contain img tag');
            System.assert(html.contains('/sfc/servlet.shepherd'), 'Should use Salesforce URL directly');
            System.assert(!html.contains('data:image'), 'Should not use data URI for SF URLs');
        }
    }

    // =========================================================================
    // Heading styles
    // =========================================================================

    @IsTest
    static void testHeadingStyles() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Section</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<h1'), 'Should contain h1 tag');
            System.assert(html.contains('<h2'), 'Should contain h2 tag');
            System.assert(html.contains('Title'), 'Should contain heading text');
        }
    }

    @IsTest
    static void testTitleStyle() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Doc Title</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<h1'), 'Title style should render as h1');
            System.assert(html.contains('26pt'), 'Title should have 26pt font size');
            System.assert(html.contains('Doc Title'), 'Should contain title text');
        }
    }

    // =========================================================================
    // All caps and small caps
    // =========================================================================

    @IsTest
    static void testAllCaps() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:caps/></w:rPr><w:t>lowercase text</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('LOWERCASE TEXT'), 'Should uppercase text with w:caps');
        }
    }

    @IsTest
    static void testSmallCaps() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:smallCaps/></w:rPr><w:t>small caps</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('SMALL CAPS'), 'Should uppercase text with smallCaps');
            System.assert(html.contains('font-variant:small-caps'), 'Should add small-caps font variant');
        }
    }

    // =========================================================================
    // Page break rendering
    // =========================================================================

    @IsTest
    static void testPageBreakInParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pageBreakBefore/></w:pPr><w:r><w:t>After Break</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('page-break-before:always'), 'Should contain page break');
            System.assert(html.contains('After Break'), 'Should contain text after break');
        }
    }

    @IsTest
    static void testPageBreakInRun() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:br w:type="page"/></w:r><w:r><w:t>Next Page</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('page-break-before:always'), 'Should contain page break from run');
        }
    }

    // =========================================================================
    // Hyperlink rendering
    // =========================================================================

    @IsTest
    static void testHyperlink() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:hyperlink r:id="rId5" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
                '<w:r><w:t>Click Here</w:t></w:r>' +
                '</w:hyperlink></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('Click Here'), 'Should contain link text');
            System.assert(html.contains('color:#0563C1'), 'Should have link color');
            System.assert(html.contains('text-decoration:underline'), 'Should have underline');
        }
    }

    // =========================================================================
    // Horizontal rule (empty paragraph with bottom border)
    // =========================================================================

    @IsTest
    static void testHorizontalRule() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:color="000000"/></w:pBdr></w:pPr></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<hr/>'), 'Should render horizontal rule');
        }
    }

    // =========================================================================
    // Letter spacing
    // =========================================================================

    @IsTest
    static void testLetterSpacing() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:spacing w:val="40"/></w:rPr><w:t>Spaced</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('letter-spacing:'), 'Should contain letter-spacing style');
        }
    }

    // =========================================================================
    // Header row (th)
    // =========================================================================

    @IsTest
    static void testTableHeaderRow() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:trPr><w:tblHeader/></w:trPr>' +
                '<w:tc><w:p><w:r><w:t>Header</w:t></w:r></w:p></w:tc></w:tr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>Data</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<th'), 'Should render header cell as th');
            System.assert(html.contains('<td'), 'Should render data cell as td');
        }
    }

    // =========================================================================
    // Hyperlink rendering
    // =========================================================================

    @IsTest
    static void testHyperlinkExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:hyperlink r:id="rId5" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
                '<w:r><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr><w:t>Click here</w:t></w:r>' +
                '</w:hyperlink></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('Click here'), 'Should contain hyperlink text');
            System.assert(html.contains('text-decoration:underline'), 'Should have underline styling');
        }
    }

    @IsTest
    static void testHyperlinkEmptyContent() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Hyperlink with no inner runs — should render empty
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:hyperlink></w:hyperlink></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<body>'), 'Should produce valid HTML');
        }
    }

    // =========================================================================
    // convertToHtml with fontFaceCss
    // =========================================================================

    @IsTest
    static void testConvertToHtmlWithFontFaceCss() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>FontTest</w:t></w:r></w:p></w:body></w:document>';

            String fontCss = '@font-face { font-family: "Custom"; src: url("data:;base64,abc"); }';
            String html = DocGenHtmlRenderer.convertToHtml(xml, new Map<String, String>(), fontCss);

            System.assert(html.contains('@font-face'), 'Should inject font-face CSS');
            System.assert(html.contains('FontTest'), 'Should contain text');
        }
    }

    // =========================================================================
    // Page break in run (w:br type="page")
    // =========================================================================

    @IsTest
    static void testPageBreakInRunExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('page-break-before:always'), 'Should contain page break');
        }
    }

    // =========================================================================
    // Column break in run
    // =========================================================================

    @IsTest
    static void testColumnBreakInRun() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:br w:type="column"/></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<br/>'), 'Column break should render as br');
        }
    }

    // =========================================================================
    // Paragraph with page break before (w:pageBreakBefore)
    // =========================================================================

    @IsTest
    static void testPageBreakBeforeParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pageBreakBefore/></w:pPr><w:r><w:t>After break</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('page-break-before:always'), 'Should have page break before');
            System.assert(html.contains('After break'), 'Should contain text after break');
        }
    }

    // =========================================================================
    // Horizontal rule (empty paragraph with bottom border)
    // =========================================================================

    @IsTest
    static void testHorizontalRuleExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:color="000000"/></w:pBdr></w:pPr></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<hr/>'), 'Should render as horizontal rule');
        }
    }

    // =========================================================================
    // Heading styles (h1-h6) and Title/Subtitle
    // =========================================================================

    @IsTest
    static void testHeadingStylesExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>H1</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:pStyle w:val="Subtitle"/></w:pPr><w:r><w:t>Sub</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<h1'), 'Should contain h1 for Heading1');
            System.assert(html.contains('26pt'), 'Should contain Title style with 26pt');
            System.assert(html.contains('14pt'), 'Should contain Subtitle style with 14pt');
        }
    }

    // =========================================================================
    // Paragraph shading
    // =========================================================================

    @IsTest
    static void testParagraphShading() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:shd w:val="clear" w:fill="FFFF00"/></w:pPr>' +
                '<w:r><w:t>Highlighted</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('background-color:#FFFF00'), 'Should have paragraph shading');
        }
    }

    // =========================================================================
    // Paragraph borders
    // =========================================================================

    @IsTest
    static void testParagraphBorders() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pBdr>' +
                '<w:top w:val="single" w:sz="4" w:color="FF0000"/>' +
                '<w:bottom w:val="dashed" w:sz="4" w:color="00FF00"/>' +
                '<w:left w:val="dotted" w:sz="4" w:color="0000FF"/>' +
                '<w:right w:val="double" w:sz="4" w:color="000000"/>' +
                '</w:pBdr></w:pPr>' +
                '<w:r><w:t>Bordered</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('border-top:'), 'Should have top border');
            System.assert(html.contains('border-bottom:'), 'Should have bottom border');
            System.assert(html.contains('padding:4pt'), 'Should have padding when borders exist');
        }
    }

    // =========================================================================
    // Keep with next / Keep lines together
    // =========================================================================

    @IsTest
    static void testKeepWithNextAndKeepLines() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:keepNext/><w:keepLines/></w:pPr>' +
                '<w:r><w:t>Keep</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('page-break-after:avoid'), 'Should have keepNext CSS');
            System.assert(html.contains('page-break-inside:avoid'), 'Should have keepLines CSS');
        }
    }

    // =========================================================================
    // Line spacing — exact and auto modes
    // =========================================================================

    @IsTest
    static void testLineSpacingExact() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:spacing w:line="360" w:lineRule="exact"/></w:pPr>' +
                '<w:r><w:t>Exact spacing</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('line-height:'), 'Should have line-height for exact spacing');
        }
    }

    @IsTest
    static void testLineSpacingAuto() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr>' +
                '<w:r><w:t>Auto spacing</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('line-height:1.5'), 'Should have 1.5x line-height for 360/240');
        }
    }

    // =========================================================================
    // Hanging indent
    // =========================================================================

    @IsTest
    static void testHangingIndent() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:ind w:hanging="360"/></w:pPr>' +
                '<w:r><w:t>Hanging</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('text-indent:-'), 'Should have negative text-indent for hanging');
            System.assert(html.contains('padding-left:'), 'Should have compensating padding-left');
        }
    }

    // =========================================================================
    // All caps and small caps
    // =========================================================================

    @IsTest
    static void testAllCapsExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:caps/></w:rPr><w:t>hello</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('HELLO'), 'Should uppercase text for caps');
        }
    }

    @IsTest
    static void testSmallCapsExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:smallCaps/></w:rPr><w:t>test</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('font-variant:small-caps'), 'Should have small-caps style');
        }
    }

    // =========================================================================
    // Run shading (w:shd in rPr)
    // =========================================================================

    @IsTest
    static void testRunShading() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:shd w:val="clear" w:fill="00FF00"/></w:rPr><w:t>Shaded</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('background-color:#00FF00'), 'Should have run shading color');
        }
    }

    // =========================================================================
    // Letter spacing
    // =========================================================================

    @IsTest
    static void testLetterSpacingExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:spacing w:val="40"/></w:rPr><w:t>Spaced</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('letter-spacing:'), 'Should have letter spacing');
        }
    }

    // =========================================================================
    // Table alignment (center and right)
    // =========================================================================

    @IsTest
    static void testTableAlignmentCenter() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr><w:jc w:val="center"/></w:tblPr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>Centered Table</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('margin-left:auto'), 'Should center table with auto margins');
            System.assert(html.contains('margin-right:auto'), 'Should center table with auto margins');
        }
    }

    @IsTest
    static void testTableAlignmentRight() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr><w:jc w:val="right"/></w:tblPr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>Right Table</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('margin-left:auto'), 'Should right-align table with margin-left:auto');
        }
    }

    // =========================================================================
    // Cell colspan (w:gridSpan)
    // =========================================================================

    @IsTest
    static void testCellColspan() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr><w:gridSpan w:val="3"/></w:tcPr>' +
                '<w:p><w:r><w:t>Spanning</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('colspan="3"'), 'Should have colspan attribute');
        }
    }

    // =========================================================================
    // Image with URL path (not base64)
    // =========================================================================

    @IsTest
    static void testImageWithRelativeUrl() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, String> images = new Map<String, String>{
                'rIdUrl' => '/sfc/servlet.shepherd/version/download/068000000000001'
            };

            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="1905000" cy="952500"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdUrl" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(html.contains('<img'), 'Should contain img tag');
            System.assert(html.contains('/sfc/servlet.shepherd'), 'Should use relative URL directly');
        }
    }

    // =========================================================================
    // ListNumber style detection
    // =========================================================================

    @IsTest
    static void testListNumberStyle() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="ListNumber"/></w:pPr>' +
                '<w:r><w:t>Numbered Item</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<ol>'), 'ListNumber should render as ordered list');
            System.assert(html.contains('Numbered Item'), 'Should contain list text');
        }
    }

    // =========================================================================
    // Border style nil/none renders no border
    // =========================================================================

    @IsTest
    static void testBorderNilRendersNoBorder() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pBdr>' +
                '<w:top w:val="nil"/>' +
                '</w:pBdr></w:pPr>' +
                '<w:r><w:t>NoBorder</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(!html.contains('border-top:'), 'nil border should not render');
            System.assert(html.contains('NoBorder'), 'Should contain text');
        }
    }
}
