public with sharing class DocGenController {
    
    @AuraEnabled
    public static Map<String, Object> generateDocumentData(Id templateId, Id recordId) {
        if (templateId == null) throw new DocGenException('Template ID is missing.');

        List<DocGen_Template__c> templates = [
            SELECT Base_Object_API__c, Query_Config__c, Type__c, Output_Format__c, Document_Title_Format__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (templates.isEmpty()) {
            throw new DocGenException('Unable to access template. Verify it exists and you have permission.');
        }
        DocGen_Template__c template = templates[0];

        Map<String, Object> recordData = DocGenDataRetriever.getRecordData(
            recordId,
            template.Base_Object_API__c,
            template.Query_Config__c
        );

        String fileContent = DocGenTemplateManager.getTemplateFileContent(templateId);

        if (recordData == null) {
            throw new DocGenException('Record data not found.');
        }

        // Pre-resolve Salesforce rich text image URLs to base64 data URIs
        resolveRichTextImages(recordData);

        return new Map<String, Object>{
            'data' => recordData,
            'templateFile' => fileContent,
            'templateType' => template.Type__c,
            'outputFormat' => template.Output_Format__c,
            'titleFormat' => template.Document_Title_Format__c
        };
    }

    @AuraEnabled
    public static Id saveGeneratedDocument(Id recordId, String fileName, String base64Data, String extension) {
        try {
            ContentVersion cv = new ContentVersion();
            cv.Title = fileName;
            cv.PathOnClient = fileName + (extension.startsWith('.') ? extension : '.' + extension);
            cv.VersionData = EncodingUtil.base64Decode(base64Data);
            cv.IsMajorVersion = true;
            SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
            insert cvDecision.getRecords();
            Id cvId = cvDecision.getRecords()[0].Id;

            Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cvId WITH USER_MODE].ContentDocumentId;

            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = contentDocId;
            cdl.LinkedEntityId = recordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            SObjectAccessDecision cdlDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{ cdl });
            insert cdlDecision.getRecords();

            return contentDocId;
        } catch (System.NoAccessException e) {
            throw new DocGenException('Insufficient access to save document: ' + e.getMessage());
        } catch (Exception e) {
            throw new DocGenException('Error saving document to record: ' + e.getMessage());
        }
    }

    /**
     * Processes a template server-side and returns the document as base64, along with
     * the title, output format, and template type. Used by LWC for download/preview.
     */
    @AuraEnabled
    public static Map<String, Object> processAndReturnDocument(Id templateId, Id recordId) {
        return processAndReturnDocumentWithImages(templateId, recordId, null);
    }

    /**
     * Processes a template with record data and optional pre-resolved images.
     * The LWC can fetch RTF images via the browser session and pass them as
     * a map of originalUrl → base64DataUri. This enables DOCX image embedding
     * without server-side HTTP callouts (AppExchange safe).
     */
    @AuraEnabled
    public static Map<String, Object> processAndReturnDocumentWithImages(Id templateId, Id recordId, Map<String, String> resolvedImages) {
        try {
            Map<String, Object> result = DocGenService.processDocument(templateId, recordId, resolvedImages);
            Blob docBlob = (Blob) result.get('blob');
            return new Map<String, Object>{
                'base64' => EncodingUtil.base64Encode(docBlob),
                'title' => result.get('title'),
                'outputFormat' => result.get('outputFormat'),
                'templateType' => result.get('templateType')
            };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error generating document: ' + e.getMessage());
            throw new AuraHandledException('Error generating document. Please check the template configuration.');
        }
    }

    /**
     * Returns merged document parts for client-side DOCX assembly.
     * Server merges the XML (lightweight). Client fetches the shell ZIP and images
     * by URL, then assembles the final DOCX — no server-side ZIP, zero heap for large docs.
     */
    @AuraEnabled
    public static Map<String, Object> generateDocumentParts(Id templateId, Id recordId) {
        try {
            return DocGenService.generateDocumentParts(templateId, recordId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error generating document parts: ' + e.getMessage());
            throw new AuraHandledException('Error generating document parts. Please check the template configuration.');
        }
    }

    /**
     * Returns a single ContentVersion's binary data as base64.
     * Called by the client in a loop — each call is its own transaction with fresh heap.
     * This enables client-side DOCX assembly with unlimited images.
     */
    @AuraEnabled
    public static String getContentVersionBase64(Id contentVersionId) {
        List<ContentVersion> cvs = [
            SELECT VersionData FROM ContentVersion WHERE Id = :contentVersionId WITH SYSTEM_MODE LIMIT 1
        ];
        if (cvs.isEmpty()) return null;
        return EncodingUtil.base64Encode(cvs[0].VersionData);
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> previewRecordData(Id recordId, String baseObject, String queryConfig) {
        if (recordId == null || String.isBlank(baseObject) || String.isBlank(queryConfig)) {
            return null;
        }
        
        try {
            return DocGenDataRetriever.getRecordData(recordId, baseObject, queryConfig);
        } catch (Exception e) {
            throw new DocGenException('Error fetching preview data: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getTemplatesForObject(String objectApiName) {
        return [
            SELECT Id, Name, Description__c, Type__c, Output_Format__c, Is_Default__c
            FROM DocGen_Template__c
            WHERE Base_Object_API__c = :objectApiName
            WITH SYSTEM_MODE
            ORDER BY Is_Default__c DESC, Name ASC
        ];
    }
    
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getAllTemplates() {
        return [
            SELECT Id, Name, Description__c, Type__c, Base_Object_API__c, Category__c, Query_Config__c,
                   Test_Record_Id__c, Output_Format__c, Document_Title_Format__c, Is_Default__c,
                   (SELECT ContentDocumentId FROM ContentDocumentLinks ORDER BY ContentDocument.CreatedDate DESC LIMIT 1)
            FROM DocGen_Template__c
            WITH SYSTEM_MODE
            ORDER BY Category__c ASC, Name ASC
        ];
    }

    @AuraEnabled
    public static void saveTemplate(Map<String, Object> fields, Boolean createVersion) {
        try {
            // 1. Update Template
            Id templateId = (Id) fields.get('Id');
            DocGen_Template__c template = new DocGen_Template__c(Id = templateId);
            template.Name = (String) fields.get('Name');
            template.Category__c = (String) fields.get('Category__c');
            template.Type__c = (String) fields.get('Type__c');
            template.Base_Object_API__c = (String) fields.get('Base_Object_API__c');
            template.Description__c = (String) fields.get('Description__c');
            template.Query_Config__c = (String) fields.get('Query_Config__c');
            template.Test_Record_Id__c = (String) fields.get('Test_Record_Id__c');
            template.Document_Title_Format__c = (String) fields.get('Document_Title_Format__c');
            
            // Update Output Format if provided
            if (fields.containsKey('Output_Format__c')) {
                template.Output_Format__c = (String) fields.get('Output_Format__c');
            }
            // Update Default flag if provided
            if (fields.containsKey('Is_Default__c')) {
                template.Is_Default__c = (Boolean) fields.get('Is_Default__c');
            }
            // Package-internal object — CRUD controlled by DocGen permission sets
            update template;

            // 2. Create Version if requested
            if (createVersion == true) {
                // Deactivate current active versions
                List<DocGen_Template_Version__c> activeVersions = [
                    SELECT Id FROM DocGen_Template_Version__c
                    WHERE Template__c = :templateId AND Is_Active__c = true
                    WITH SYSTEM_MODE
                ];
                for (DocGen_Template_Version__c av : activeVersions) {
                    av.Is_Active__c = false;
                }
                if (!activeVersions.isEmpty()) {
                    // Package-internal object — CRUD controlled by DocGen permission sets
                    update activeVersions;
                }

                // Get latest ContentVersionId
                List<ContentDocumentLink> links = [
                    SELECT ContentDocument.LatestPublishedVersionId
                    FROM ContentDocumentLink
                    WHERE LinkedEntityId = :templateId
                    WITH USER_MODE
                    ORDER BY ContentDocument.CreatedDate DESC
                    LIMIT 1
                ];

                String cvId = null;
                if (!links.isEmpty()) {
                    cvId = links[0].ContentDocument.LatestPublishedVersionId;
                }

                DocGen_Template_Version__c version = new DocGen_Template_Version__c();
                version.Template__c = templateId;
                version.Query_Config__c = (String) fields.get('Query_Config__c');
                version.Content_Version_Id__c = cvId;
                version.Is_Active__c = true;

                // Snapshot Headers
                version.Category__c = (String) fields.get('Category__c');
                version.Description__c = (String) fields.get('Description__c');
                version.Type__c = (String) fields.get('Type__c');
                version.Base_Object_API__c = (String) fields.get('Base_Object_API__c');

                // Package-internal object — CRUD controlled by DocGen permission sets
                insert version;

                // Extract images from DOCX/PPTX and save as ContentVersions linked to the version.
                // Blob.toPdf() cannot render data URI images — needs committed CV URLs.
                try {
                    DocGenService.extractAndSaveTemplateImages(templateId, version.Id);
                } catch (Exception imgErr) {
                    System.debug(LoggingLevel.WARN, 'DocGen: Template image extraction: ' + imgErr.getMessage());
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error saving template: ' + e.getMessage());
            throw new AuraHandledException('Error saving template. Please verify your inputs and permissions.');
        }
    }

    @AuraEnabled
    public static void deleteTemplate(Id templateId) {
        try {
            if (!Schema.sObjectType.DocGen_Template__c.isDeletable()) {
                throw new AuraHandledException('Insufficient access.');
            }
            delete new DocGen_Template__c(Id = templateId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error deleting template: ' + e.getMessage());
            throw new AuraHandledException('Error deleting template. Please check your permissions.');
        }
    }

    @AuraEnabled
    public static List<DocGen_Template_Version__c> getTemplateVersions(Id templateId) {
        return [
            SELECT Id, Name, CreatedDate, CreatedBy.Name, Query_Config__c, Content_Version_Id__c, 
                   Category__c, Description__c, Type__c, Base_Object_API__c, Is_Active__c
            FROM DocGen_Template_Version__c 
            WHERE Template__c = :templateId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    @AuraEnabled
    public static void activateVersion(Id versionId) {
        try {
            DocGen_Template_Version__c version = [
                SELECT Template__c, Query_Config__c, Content_Version_Id__c, Category__c, Description__c, Type__c, Base_Object_API__c
                FROM DocGen_Template_Version__c 
                WHERE Id = :versionId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            
            // 1. Deactivate others
            List<DocGen_Template_Version__c> others = [
                SELECT Id FROM DocGen_Template_Version__c 
                WHERE Template__c = :version.Template__c AND Is_Active__c = true
                WITH SYSTEM_MODE
            ];
            for (DocGen_Template_Version__c v : others) {
                v.Is_Active__c = false;
            }
            // Package-internal objects — CRUD controlled by DocGen permission sets
            if (!others.isEmpty()) {
                update others;
            }

            // 2. Activate this one
            version.Is_Active__c = true;
            // Package-internal object — CRUD controlled by DocGen permission sets
            update version;

            // 3. Update Template Record Headline
            DocGen_Template__c template = new DocGen_Template__c(Id = version.Template__c);
            template.Query_Config__c = version.Query_Config__c;
            template.Category__c = version.Category__c;
            template.Description__c = version.Description__c;
            template.Type__c = version.Type__c;
            template.Base_Object_API__c = version.Base_Object_API__c;

            // Package-internal object — CRUD controlled by DocGen permission sets
            update template;
            
        } catch (Exception e) {
            throw new DocGenException('Error activating version: ' + e.getMessage());
        }
    }

    /**
     * Unified PDF generation. Uses the same code path as bulk batch generation.
     * For "save" mode: saves PDF to record via DocGenService.generateDocument().
     * For "download" mode: returns base64 PDF via DocGenService.generatePdfBlob().
     */
    @AuraEnabled
    public static Map<String, Object> generatePdf(Id templateId, Id recordId, Boolean saveToRecord) {
        try {
            if (saveToRecord) {
                Id contentDocId = DocGenService.generateDocument(templateId, recordId);
                return new Map<String, Object>{
                    'saved' => true,
                    'contentDocumentId' => contentDocId
                };
            } else {
                Map<String, Object> result = DocGenService.generatePdfBlob(templateId, recordId);
                Blob pdfBlob = (Blob) result.get('blob');
                String docTitle = (String) result.get('title');
                return new Map<String, Object>{
                    'base64' => EncodingUtil.base64Encode(pdfBlob),
                    'title' => docTitle
                };
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error generating PDF: ' + e.getMessage());
            throw new AuraHandledException('Error generating PDF document. Please check the template configuration.');
        }
    }

    // --- Schema Methods for Query Builder ---

    public class Option implements Comparable {
         public String label;
         public String value;
         public String childObjectApiName;

         public Option(String label, String value) {
             this.label = label;
             this.value = value;
         }
         
         public Option(String label, String value, String childObjectApiName) {
             this.label = label;
             this.value = value;
             this.childObjectApiName = childObjectApiName;
         }

         public Integer compareTo(Object compareTo) {
             Option other = (Option) compareTo;
             if (label == other.label) return 0;
             if (label > other.label) return 1;
             return -1;
         }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectOptions() {
        List<Option> sortedOptions = new List<Option>();
        for (Schema.SObjectType sobj : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult describe = sobj.getDescribe();
            if (describe.isQueryable() && !describe.isDeprecatedAndHidden()) {
                sortedOptions.add(new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName()));
            }
        }
        sortedOptions.sort();
        
        List<Map<String, String>> options = new List<Map<String, String>>();
        for (Option opt : sortedOptions) {
            options.add(new Map<String, String>{'label' => opt.label, 'value' => opt.value});
        }
        return options;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectFields(String objectName) {
        List<Option> sortedFields = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return new List<Map<String, String>>();

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (describe.isAccessible()) {
                sortedFields.add(new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName()));
            }
        }
        sortedFields.sort();

        List<Map<String, String>> fields = new List<Map<String, String>>();
        for (Option opt : sortedFields) {
            fields.add(new Map<String, String>{'label' => opt.label, 'value' => opt.value});
        }
        return fields;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getChildRelationships(String objectName) {
        List<Option> sortedRels = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return new List<Map<String, String>>();

        for (Schema.ChildRelationship child : objType.getDescribe().getChildRelationships()) {
            if (child.getRelationshipName() != null) {
                sortedRels.add(new Option(
                    child.getRelationshipName() + ' (' + child.getChildSObject().getDescribe().getLabel() + ')',
                    child.getRelationshipName(),
                    child.getChildSObject().getDescribe().getName()
                ));
            }
        }
        sortedRels.sort();

        List<Map<String, String>> relationships = new List<Map<String, String>>();
        for (Option opt : sortedRels) {
            relationships.add(new Map<String, String>{
                'label' => opt.label, 
                'value' => opt.value,
                'childObjectApiName' => opt.childObjectApiName
            });
        }
        return relationships;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getParentRelationships(String objectName) {
        List<Option> sortedParents = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return new List<Map<String, String>>();

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
             Schema.DescribeFieldResult describe = field.getDescribe();
             if (describe.getType() == Schema.DisplayType.REFERENCE) {
                 // Ignore polymorphic for now or handle carefully
                 if (describe.getReferenceTo().size() > 0) {
                     String relationshipName = describe.getRelationshipName();
                     String targetObject = describe.getReferenceTo()[0].getDescribe().getName(); // Take first parent for now
                     if (relationshipName != null) {
                        sortedParents.add(new Option(
                            describe.getLabel() + ' (' + relationshipName + ')',
                            relationshipName,
                            targetObject
                        ));
                     }
                 }
             }
        }
        sortedParents.sort();

        List<Map<String, String>> parents = new List<Map<String, String>>();
        for (Option opt : sortedParents) {
            parents.add(new Map<String, String>{
                'label' => opt.label, 
                'value' => opt.value, 
                'targetObject' => opt.childObjectApiName // Reusing field
            });
        }
        return parents;
    }

    // Sample data creation method removed per cleanup request.

    // --- Template Sharing Logic ---

    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getTemplateShares(Id templateId) {
        List<Map<String, String>> shares = new List<Map<String, String>>();
        
        List<SObject> shareRecords = Database.query(
            'SELECT Id, UserOrGroupId, UserOrGroup.Name, AccessLevel, RowCause ' +
            'FROM DocGen_Template__Share ' +
            'WHERE ParentId = :templateId AND RowCause != \'Owner\' WITH SYSTEM_MODE'
        );

        for (SObject s : shareRecords) {
            Map<String, String> row = new Map<String, String>();
            row.put('Id', (String)s.get('Id'));
            row.put('UserOrGroupId', (String)s.get('UserOrGroupId'));
            row.put('UserOrGroupName', (String)s.getSObject('UserOrGroup').get('Name'));
            row.put('AccessLevel', (String)s.get('AccessLevel'));
            row.put('RowCause', (String)s.get('RowCause'));
            shares.add(row);
        }
        return shares;
    }

    @AuraEnabled
    public static void shareTemplate(Id templateId, Id userOrGroupId, String accessLevel) {
        SObject share = Schema.getGlobalDescribe().get('DocGen_Template__Share').newSObject();
        share.put('ParentId', templateId);
        share.put('UserOrGroupId', userOrGroupId);
        share.put('AccessLevel', accessLevel);
        share.put('RowCause', 'Manual');
        
        try {
            SObjectAccessDecision shareDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<SObject>{ share });
            insert shareDecision.getRecords();
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error sharing template: ' + e.getMessage());
            throw new AuraHandledException('Error sharing template. Please check permissions.');
        }
    }

    @AuraEnabled
    public static void removeShare(Id shareId) {
        try {
            if (!Schema.sObjectType.DocGen_Template__c.isDeletable()) {
                throw new AuraHandledException('Insufficient access.');
            }
            delete new DocGen_Template__Share(Id = shareId);
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error removing share: ' + e.getMessage());
            throw new AuraHandledException('Error removing share. Please check permissions.');
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchUsersAndGroups(String searchTerm) {
        String key = '%' + searchTerm + '%';
        List<Map<String, String>> results = new List<Map<String, String>>();

        for (User u : [SELECT Id, Name FROM User WHERE Name LIKE :key AND IsActive = TRUE WITH USER_MODE LIMIT 10]) {
             Map<String, String> row = new Map<String, String>();
             row.put('Id', u.Id);
             row.put('Name', u.Name);
             row.put('Type', 'User');
             row.put('Icon', 'standard:user');
             results.add(row);
        }

        for (Group g : [SELECT Id, Name FROM Group WHERE Name LIKE :key AND Type = 'Regular' WITH USER_MODE LIMIT 10]) {
             Map<String, String> row = new Map<String, String>();
             row.put('Id', g.Id);
             row.put('Name', g.Name);
             row.put('Type', 'Group');
             row.put('Icon', 'standard:groups');
             results.add(row);
        }
        return results;
    }

    // --- Rich Text Image Resolution ---

    /**
     * Recursively walks record data and normalizes Salesforce image URLs in rich text
     * fields to absolute URLs. No HTTP callouts — Blob.toPdf() resolves Salesforce URLs
     * natively via the VF rendering engine. For DOCX, processRichTextImage fetches blobs
     * using the URL. No session IDs needed (AppExchange safe).
     */
    private static void resolveRichTextImages(Object data) {
        if (data instanceof Map<String, Object>) {
            Map<String, Object> mapData = (Map<String, Object>) data;

            for (String key : new List<String>(mapData.keySet())) {
                Object val = mapData.get(key);
                if (val instanceof String) {
                    String strVal = (String) val;
                    if (strVal.containsIgnoreCase('<img') &&
                        (strVal.containsIgnoreCase('refid=') || strVal.containsIgnoreCase('/servlet/') || strVal.containsIgnoreCase('/sfc/'))) {
                        mapData.put(key, normalizeImageUrls(strVal));
                    }
                } else {
                    resolveRichTextImages(val);
                }
            }
        } else if (data instanceof List<Object>) {
            for (Object item : (List<Object>) data) {
                resolveRichTextImages(item);
            }
        }
    }

    /**
     * Normalizes relative Salesforce image URLs to absolute URLs.
     * No HTTP callouts, no session IDs. Blob.toPdf() resolves these natively.
     */
    private static String normalizeImageUrls(String html) {
        try {
            String baseUrl = URL.getOrgDomainUrl().toExternalForm();
            // Replace relative paths with absolute, handling both & and &amp; forms
            // Pattern: src="/servlet/..." or src="/sfc/..."
            html = html.replaceAll('(?i)(src\\s*=\\s*["\'])(/servlet/)', '$1' + baseUrl + '$2');
            html = html.replaceAll('(?i)(src\\s*=\\s*["\'])(/sfc/)', '$1' + baseUrl + '$2');
            return html;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: normalizeImageUrls failed: ' + e.getMessage());
            return html;
        }
    }
}