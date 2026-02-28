public with sharing class DocGenService {
    

    public static Id generateDocument(Id templateId, Id recordId) {
        System.debug('Starting DocGen for Template: ' + templateId + ' Record: ' + recordId);
        Map<String, Object> dataMap;
        try {
            dataMap = DocGenController.generateDocumentData(templateId, recordId);
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String outputFormat = (String) dataMap.get('outputFormat'); 
        String templateType = (String) dataMap.get('templateType');

        if (base64File == null) throw new DocGenException('Template file content is missing.');

        if (templateType == 'HTML') {
            throw new DocGenException('HTML templates are only supported when generating from a single record. Use the record page generator for this template.');
        }
        
        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject)dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            Boolean isTargetXml = false;
            if (templateType == 'Word') {
                isTargetXml = name == 'word/document.xml' || 
                              (name.startsWith('word/header') && name.endsWith('.xml')) || 
                              (name.startsWith('word/footer') && name.endsWith('.xml'));
            } else if (templateType == 'PowerPoint') {
                isTargetXml = name.startsWith('ppt/slides/slide') && name.endsWith('.xml');
            }

            if (isTargetXml) { 
                Blob content = reader.extract(name);
                String xml = content.toString();
                xml = processXml(xml, recordDataMap);
                writer.addEntry(name, Blob.valueOf(xml));
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }
        
        Blob resultBlob = writer.getArchive();
        String titleFormat = (String) dataMap.get('titleFormat');
        String recordName = (String) resolveValue(recordDataMap, 'Name');
        
        String docTitle = generateDocTitle(titleFormat, recordDataMap);
        if (docTitle == null) docTitle = recordName;
        
        return saveFile(resultBlob, docTitle, recordId, outputFormat, templateType);
    }

    // ... (processXml etc omitted, assuming unchanged relative position) ...
    // Wait, replacing lines 49-52 and 255-264
    // Using multi_replace or separate calls?
    // I can do it in two calls.

    
    private static String processXml(String xml, Map<String, Object> data) {
        String output = '';
        Integer len = xml.length();
        Integer cursor = 0;
        
        while (cursor < len) {
            Integer nextTag = xml.indexOf('{', cursor);
            if (nextTag == -1) {
                output += xml.substring(cursor);
                break; 
            }
            output += xml.substring(cursor, nextTag);
            cursor = nextTag;
            
            Integer tagClose = xml.indexOf('}', cursor);
            if (tagClose == -1) {
                output += xml.substring(cursor);
                break;
            }
            
            String rawTag = xml.substring(cursor + 1, tagClose); 
            String tagContent = rawTag.trim();
            
            if (tagContent.startsWith('#')) {
                String key = tagContent.substring(1).trim();
                Integer sectionEnd = findBalancedEnd(xml, tagClose + 1, key);
                
                if (sectionEnd == -1) {
                    output += '{' + rawTag + '}';
                    cursor = tagClose + 1;
                } else {
                    // Default: Content between tags
                    Integer contentStart = tagClose + 1;
                    Integer contentEnd = sectionEnd;
                    String innerXml = xml.substring(contentStart, contentEnd);
                    
                    // Smart Table Row Expansion
                    // Check if we are inside a TR and if the loop is fully contained in it
                    Integer trStart = xml.lastIndexOf('<w:tr ', cursor); // Try with space
                    if (trStart == -1) trStart = xml.lastIndexOf('<w:tr>', cursor);
                    
                    // Find matching TR End
                    Integer trEnd = -1;
                    if (trStart != -1) {
                         trEnd = xml.indexOf('</w:tr>', trStart);
                         // Check if our loop is INSIDE this TR
                         // sectionEnd is index of start of {/Key}
                         Integer closeTagEnd = xml.indexOf('}', sectionEnd);
                         
                         if (trEnd > closeTagEnd) {
                             // Yes, the loop is fully inside this TR.
                             // Now, checking if we should expand.
                             // Expand if the start tag and end tag are in the SAME TR (implied by above)
                             // AND if we think it's intended (always true for better UX?)
                             
                             // CAUTION: If user meant cell-repetition, valid, but rare.
                             // We assume Row Repetition is preferred.
                             
                             // Redefine Inner XML to include the TR
                             // And strip the tags from it.
                             
                             contentStart = trStart;
                             contentEnd = trEnd + 7; // Length of </w:tr>
                             innerXml = xml.substring(contentStart, contentEnd);
                             
                             // Strip placeholders to prevent infinite recursion
                             // We must remove EXACTLY the tags found at `cursor` and `sectionEnd`
                             // To be safe, we reconstruct:
                             // Prefix (Before #Tag) + Suffix (After #Tag) ...
                             // Actually, simpler: replace first occurrence of those tags in the substring.
                             
                             String startTagFull = '{' + rawTag + '}';
                             innerXml = innerXml.replace(startTagFull, '');
                             
                             // Needed regex for end tag? No, construct it.
                             // We know the key.
                             // But strict replacement might fail if spaces differ.
                             // We can use the actual string from xml
                             String endTagFull = xml.substring(sectionEnd, closeTagEnd + 1);
                             innerXml = innerXml.replace(endTagFull, '');
                             
                             // Clean up output buffer: we added up to `cursor` (start of tag).
                             // We need to backtrack output to remove the prefix of the TR that we just added!
                             // output currently = ...<w:tr>...<w:tc>...
                             // We want to remove that part because `innerXml` now contains the WHOLE TR.
                             
                             // Calculate fallback amount
                             Integer overlap = cursor - contentStart; // Distance from TR Start to Tag Start
                             if (overlap > 0) {
                                  output = output.substring(0, output.length() - overlap);
                             }
                             
                             // Move cursor to end of TR
                             // Next iteration should start AFTER the </w:tr>
                             cursor = contentEnd; 

                             // NOTE: We set cursor for the loop.
                             // But we must NOT execute the default `cursor = closeTagEnd + 1` logic below.
                        } else {
                            // Loop spans across TRs or is outside TR?
                            // Default behavior (keep tags inside, repeat content)
                             cursor = xml.indexOf('}', sectionEnd) + 1;
                        }
                    } else {
                        cursor = xml.indexOf('}', sectionEnd) + 1;
                    }

                    // Process Data
                    Object val = resolveValue(data, key);
                    String sectionResult = '';
                    
                    if (val instanceof Boolean && (Boolean)val) {
                         sectionResult = processXml(innerXml, data);
                    } else if (val instanceof Map<String, Object>) {
                        Map<String, Object> mapVal = (Map<String, Object>) val;
                         if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                            for (Object item : (List<Object>) mapVal.get('records')) {
                                if (item instanceof Map<String, Object>) sectionResult += processXml(innerXml, (Map<String, Object>) item);
                            }
                        } else {
                             sectionResult = processXml(innerXml, mapVal);
                        }
                    } else if (val instanceof List<Object>) {
                         for (Object item : (List<Object>) val) {
                              if (item instanceof Map<String, Object>) sectionResult += processXml(innerXml, (Map<String, Object>) item);
                         }
                    } else if (val != null) {
                         sectionResult = processXml(innerXml, data);
                    }
                    output += sectionResult;
                }
                
            } else if (tagContent.startsWith('/')) {
                output += '{' + rawTag + '}';
                cursor = tagClose + 1;
            } else {
                Object val = resolveValue(data, tagContent);
                if (val != null) output += String.valueOf(val).escapeXml();
                cursor = tagClose + 1;
            }
        }
        return output;
    }
    
    private static Integer findBalancedEnd(String xml, Integer startSearch, String key) {
        Integer depth = 1;
        Integer cursor = startSearch;
        while (cursor < xml.length()) {
            Integer nextStart = xml.indexOf('{', cursor);
            if (nextStart == -1) return -1;
            Integer nextClose = xml.indexOf('}', nextStart);
            if (nextClose == -1) return -1;
            String content = xml.substring(nextStart + 1, nextClose).trim();
            if (content.equals('#' + key)) depth++;
            else if (content.equals('/' + key)) {
                depth--;
                if (depth == 0) return nextStart;
            }
            cursor = nextClose + 1;
        }
        return -1;
    }
    
    private static Object resolveValue(Map<String, Object> data, String path) {
        if (data == null) return null;
        List<String> parts = path.split('\\.');
        Object current = data;
        
        for (String part : parts) {
            if (current instanceof Map<String, Object>) {
                Map<String, Object> currentMap = (Map<String, Object>) current;
                if (currentMap.containsKey(part)) {
                    current = currentMap.get(part);
                } else {
                    // Try case-insensitive comparison
                    Boolean found = false;
                    for (String key : currentMap.keySet()) {
                        if (key.equalsIgnoreCase(part)) {
                            current = currentMap.get(key);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        System.debug('DocGen Debug: Key "' + part + '" not found in Map. Keys: ' + currentMap.keySet());
                        return null;
                    }
                }
            } else if (current instanceof SObject) {
                 SObject sobj = (SObject) current;
                 try {
                     current = sobj.get(part);
                 } catch(Exception e) { 
                     System.debug('DocGen Debug: Error retrieving field "' + part + '" from SObject ' + sobj + ': ' + e.getMessage());
                     return null; 
                 }
            } else {
                return null;
            }
            if (current == null) return null;
        }
        return current;
    }
    
    private static Id saveFile(Blob fileBlob, String title, Id recordId, String format, String type) {
        ContentVersion cv = new ContentVersion();
        String baseName = (title != null ? title : 'Generated_Document');
        if (!baseName.startsWith('Generated_') && title == null) baseName = 'Generated_' + baseName; 
        // Logic: specific requirements? 
        // User wants "create a title". 
        // If title provided via format, use it exactly.
        // If not, revert to old behavior: 'Generated_' + recordName.
        
        // Revised Logic:
        if (title != null) baseName = title;
        else baseName = 'Generated_' + (recordId != null ? 'Document' : 'File'); // Fallback fallback
        
        String ext = (type == 'PowerPoint') ? '.pptx' : '.docx';
        cv.Title = baseName;
        cv.PathOnClient = baseName + ext;
        cv.VersionData = fileBlob;
        cv.FirstPublishLocationId = recordId; 
        insert cv;

        // EXPERIMENT: Background PDF Rendition Hack
        // If the requested format is PDF, add to the collector for delayed background capture
        if (format == 'PDF') {
            System.debug('DocGen: Collecting Rendition Capture for ' + cv.Id);
            DocGenRenditionService.addPendingRendition(cv.Id, recordId);
        }
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE].ContentDocumentId;
    }
    private static String generateDocTitle(String format, Map<String, Object> data) {
        if (String.isBlank(format)) return null;
        String result = format;
        Pattern p = Pattern.compile('\\{([^}]+)\\}');
        Matcher m = p.matcher(format);
        while(m.find()) {
            String key = m.group(1);
            Object val = resolveValue(data, key);
            if (val != null) {
                 result = result.replace('{' + key + '}', String.valueOf(val));
            } else {
                result = result.replace('{' + key + '}', '');
            }
        }
        return result;
    }
}