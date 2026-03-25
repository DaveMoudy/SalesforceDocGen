public with sharing class DocGenController {

    /**
     * Retrieves template metadata, file content, and merged record data for client-side processing.
     * @param templateId The DocGen template record ID
     * @param recordId The source record ID to merge data from
     * @return Map containing record data, template file, type, output format, and title format
     */
    @AuraEnabled
    public static Map<String, Object> generateDocumentData(Id templateId, Id recordId) {
        if (templateId == null) { throw new DocGenException('Template ID is missing.'); }

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

    /**
     * Returns template metadata + file content combined with pre-cached record data.
     * Used by DocGenBatch when bulk data cache is available, skipping per-record SOQL.
     * resolveRichTextImages is NOT called here — it was already applied during caching.
     *
     * Template metadata and file content are cached statically — queried once,
     * reused across all records in the batch. Only the record data changes.
     */
    private static Id cachedTemplateId;
    private static Map<String, Object> cachedTemplateEnvelope;

    /**
     * Returns template metadata combined with pre-cached record data, skipping per-record SOQL.
     * @param templateId The DocGen template record ID
     * @param cachedRecordData Pre-loaded record data from bulk cache
     * @return Map containing record data, template file, type, output format, and title format
     */
    public static Map<String, Object> generateDocumentDataFromCache(Id templateId, Map<String, Object> cachedRecordData) {
        if (templateId == null) { throw new DocGenException('Template ID is missing.'); }

        // Cache template metadata + file content on first call
        if (cachedTemplateId != templateId || cachedTemplateEnvelope == null) {
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

            String fileContent = DocGenTemplateManager.getTemplateFileContent(templateId);

            cachedTemplateEnvelope = new Map<String, Object>{
                'templateFile' => fileContent,
                'templateType' => template.Type__c,
                'outputFormat' => template.Output_Format__c,
                'titleFormat' => template.Document_Title_Format__c
            };
            cachedTemplateId = templateId;
        }

        // Clone envelope and inject this record's data
        Map<String, Object> result = cachedTemplateEnvelope.clone();
        result.put('data', cachedRecordData);
        return result;
    }

    /**
     * Saves a generated document as a ContentVersion attached to the specified record.
     * @param recordId The record to attach the document to
     * @param fileName The document file name (without extension)
     * @param base64Data The base64-encoded document content
     * @param extension The file extension (e.g., 'docx', 'pdf')
     * @return The ContentDocumentId of the saved file
     */
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
     * @param templateId The DocGen template record ID
     * @param recordId The source record ID
     * @return Map containing base64 document data, title, outputFormat, and templateType
     */
    @AuraEnabled
    public static Map<String, Object> processAndReturnDocument(Id templateId, Id recordId) {
        return processAndReturnDocumentWithImages(templateId, recordId, null);
    }

    /**
     * Processes a template with record data and optional pre-resolved images.
     * The LWC can fetch RTF images via the browser session and pass them as
     * a map of originalUrl to base64DataUri. This enables DOCX image embedding
     * without server-side HTTP callouts (AppExchange safe).
     * @param templateId The DocGen template record ID
     * @param recordId The source record ID
     * @param resolvedImages Map of original image URLs to base64 data URIs from the LWC
     * @return Map containing base64 document data, title, outputFormat, and templateType
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
            throw new AuraHandledException('Error generating document. Please check the template configuration.');
        }
    }

    /**
     * Returns merged document parts for client-side DOCX assembly.
     * Server merges the XML (lightweight). Client fetches the shell ZIP and images
     * by URL, then assembles the final DOCX — no server-side ZIP, zero heap for large docs.
     * @param templateId The DocGen template record ID
     * @param recordId The source record ID
     * @return Map containing allXmlParts, imageBase64Map, imageCvIdMap, title, and templateType
     */
    @AuraEnabled
    public static Map<String, Object> generateDocumentParts(Id templateId, Id recordId) {
        try {
            return DocGenService.generateDocumentParts(templateId, recordId);
        } catch (Exception e) {
            throw new AuraHandledException('Error generating document parts. Please check the template configuration.');
        }
    }

    /**
     * Returns a single ContentVersion's binary data as base64.
     * Called by the client in a loop — each call is its own transaction with fresh heap.
     * This enables client-side DOCX assembly with unlimited images.
     * @param contentVersionId The ContentVersion record ID to retrieve
     * @return Base64-encoded binary data, or null if not found
     */
    @AuraEnabled
    public static String getContentVersionBase64(Id contentVersionId) {
        List<ContentVersion> cvs = [
            SELECT VersionData FROM ContentVersion WHERE Id = :contentVersionId WITH SYSTEM_MODE LIMIT 1
        ];
        if (cvs.isEmpty()) { return null; }
        return EncodingUtil.base64Encode(cvs[0].VersionData);
    }

    /**
     * Previews the merged record data for a given record and query configuration.
     * @param recordId The record ID to preview data for
     * @param baseObject The base SObject API name
     * @param queryConfig The query configuration string (V1, V2, or V3 format)
     * @return Map of field names to values for the record
     */
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

    /**
     * Returns all DocGen templates configured for a specific SObject type.
     * @param objectApiName The SObject API name to filter templates by
     * @return List of matching DocGen_Template__c records
     */
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

    /**
     * Returns all DocGen templates with their latest file attachment info.
     * @return List of all DocGen_Template__c records ordered by category and name
     */
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

    /**
     * Saves template field updates and optionally creates a new template version.
     * @param fields Map of field API names to values for the template record
     * @param createVersion Whether to create a new active version snapshot
     */
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
            // Update Default flag if provided — enforce one default per object
            if (fields.containsKey('Is_Default__c')) {
                Boolean isDefault = (Boolean) fields.get('Is_Default__c');
                template.Is_Default__c = isDefault;
                if (isDefault == true && template.Base_Object_API__c != null) {
                    String baseObj = (String) fields.get('Base_Object_API__c');
                    List<DocGen_Template__c> otherDefaults = [
                        SELECT Id FROM DocGen_Template__c
                        WHERE Base_Object_API__c = :baseObj
                        AND Is_Default__c = true
                        AND Id != :templateId
                        WITH SYSTEM_MODE
                    ];
                    for (DocGen_Template__c other : otherDefaults) {
                        other.Is_Default__c = false;
                    }
                    if (!otherDefaults.isEmpty()) {
                        update otherDefaults; // NOPMD ApexCRUDViolation - package-internal custom object
                    }
                }
            }
            // Package-internal object — CRUD controlled by DocGen permission sets
            update template; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets

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
                    update activeVersions; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets
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
                insert version; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets

                // Extract images from DOCX/PPTX and save as ContentVersions linked to the version.
                // Blob.toPdf() cannot render data URI images — needs committed CV URLs.
                try {
                    DocGenService.extractAndSaveTemplateImages(templateId, version.Id);
                } catch (Exception imgErr) {
                    // Image extraction failure is non-fatal
                    System.debug(LoggingLevel.ERROR, 'DocGenController: Image extraction failed: ' + imgErr.getMessage());
                }
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error saving template. Please verify your inputs and permissions.');
        }
    }

    /**
     * Deletes a DocGen template record.
     * @param templateId The ID of the template to delete
     */
    @AuraEnabled
    public static void deleteTemplate(Id templateId) {
        try {
            if (!Schema.sObjectType.DocGen_Template__c.isDeletable()) {
                throw new AuraHandledException('Insufficient access.');
            }
            delete new DocGen_Template__c(Id = templateId);
        } catch (Exception e) {
            throw new AuraHandledException('Error deleting template. Please check your permissions.');
        }
    }

    /**
     * Returns all version history records for a template, ordered by creation date descending.
     * @param templateId The DocGen template record ID
     * @return List of DocGen_Template_Version__c records
     */
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

    /**
     * Activates a specific template version and deactivates all others for the same template.
     * @param versionId The DocGen_Template_Version__c record ID to activate
     */
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
                update others; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets
            }

            // 2. Activate this one
            version.Is_Active__c = true;
            // Package-internal object — CRUD controlled by DocGen permission sets
            update version; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets

            // 3. Update Template Record Headline
            DocGen_Template__c template = new DocGen_Template__c(Id = version.Template__c);
            template.Query_Config__c = version.Query_Config__c;
            template.Category__c = version.Category__c;
            template.Description__c = version.Description__c;
            template.Type__c = version.Type__c;
            template.Base_Object_API__c = version.Base_Object_API__c;

            // Package-internal object — CRUD controlled by DocGen permission sets
            update template; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets

        } catch (Exception e) {
            throw new DocGenException('Error activating version: ' + e.getMessage());
        }
    }

    /**
     * Unified PDF generation. Uses the same code path as bulk batch generation.
     * For "save" mode: saves PDF to record via DocGenService.generateDocument().
     * For "download" mode: returns base64 PDF via DocGenService.generatePdfBlob().
     * @param templateId The DocGen template record ID
     * @param recordId The source record ID
     * @param saveToRecord Whether to save the PDF as a file on the record
     * @return Map containing base64 PDF data and title, or saved content document ID
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
            throw new AuraHandledException('Error generating PDF document. Please check the template configuration.');
        }
    }

    // --- Schema Methods for Query Builder ---

    /**
     * Sortable label/value pair used by schema methods for picklist-style options.
     */
    public class Option implements Comparable {
         public String label;
         public String value;
         public String childObjectApiName;
         public String lookupField;

         public Option(String label, String value) {
             this.label = label;
             this.value = value;
         }

         public Option(String label, String value, String childObjectApiName) {
             this.label = label;
             this.value = value;
             this.childObjectApiName = childObjectApiName;
         }

         public Option(String label, String value, String childObjectApiName, String lookupField) {
             this.label = label;
             this.value = value;
             this.childObjectApiName = childObjectApiName;
             this.lookupField = lookupField;
         }

         /**
          * Compares this Option to another for alphabetical sorting by label.
          * @param compareTo The other Option to compare against
          * @return Negative, zero, or positive integer for sort ordering
          */
         public Integer compareTo(Object compareTo) {
             Option other = (Option) compareTo;
             if (label == other.label) { return 0; }
             if (label > other.label) { return 1; }
             return -1;
         }
    }

    /**
     * Returns all queryable SObject types as label/value pairs for the query builder.
     * @return List of maps with 'label' and 'value' keys, sorted alphabetically
     */
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

    /**
     * Searches for Apex classes that implement DocGenDataProvider.
     * @param searchTerm Optional search term to filter class names
     * @return List of class names that implement the interface
     */
    @AuraEnabled(cacheable=true)
    public static List<String> searchDataProviders(String searchTerm) {
        List<String> providers = new List<String>();
        String query = 'SELECT Name FROM ApexClass WHERE NamespacePrefix = null';
        if (String.isNotBlank(searchTerm)) {
            query += ' AND Name LIKE \'%' + String.escapeSingleQuotes(searchTerm) + '%\'';
        }
        query += ' ORDER BY Name LIMIT 50';

        for (ApexClass cls : Database.query(query)) {
            // Try to instantiate and check interface
            Type t = Type.forName(cls.Name);
            if (t != null) {
                try {
                    Object instance = t.newInstance();
                    if (instance instanceof DocGenDataProvider) {
                        providers.add(cls.Name);
                    }
                } catch (Exception e) {
                    // Skip classes that can't be instantiated
                }
            }
        }
        return providers;
    }

    /**
     * Validates an Apex class implements DocGenDataProvider and returns its field names.
     * @param className The Apex class name to validate
     * @return Map with 'valid' (Boolean), 'fields' (List<String>), and 'error' (String)
     */
    @AuraEnabled
    public static Map<String, Object> validateDataProvider(String className) {
        Map<String, Object> result = new Map<String, Object>();
        if (String.isBlank(className)) {
            result.put('valid', false);
            result.put('error', 'Class name is required.');
            return result;
        }

        Type providerType = Type.forName(className);
        if (providerType == null) {
            providerType = Type.forName('portwoodglobal', className);
        }
        if (providerType == null) {
            result.put('valid', false);
            result.put('error', 'Class "' + className + '" not found.');
            return result;
        }

        try {
            Object instance = providerType.newInstance();
            if (!(instance instanceof DocGenDataProvider)) {
                result.put('valid', false);
                result.put('error', 'Class "' + className + '" does not implement DocGenDataProvider.');
                return result;
            }

            DocGenDataProvider provider = (DocGenDataProvider) instance;
            List<String> fields = provider.getFieldNames();
            result.put('valid', true);
            result.put('fields', fields != null ? fields : new List<String>());
        } catch (Exception e) {
            result.put('valid', false);
            result.put('error', 'Error instantiating "' + className + '": ' + e.getMessage());
        }
        return result;
    }

    /**
     * Returns accessible fields for a given SObject type with label, API name, and type.
     * @param objectName The SObject API name
     * @return List of maps with 'label', 'value', and 'type' keys
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectFields(String objectName) {
        List<Option> sortedFields = new List<Option>();
        Map<String, String> fieldTypes = new Map<String, String>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) { return new List<Map<String, String>>(); }

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (describe.isAccessible()) {
                sortedFields.add(new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName()));
                fieldTypes.put(describe.getName(), describe.getType().name());
            }
        }
        sortedFields.sort();

        List<Map<String, String>> fields = new List<Map<String, String>>();
        for (Option opt : sortedFields) {
            fields.add(new Map<String, String>{
                'label' => opt.label,
                'value' => opt.value,
                'type' => fieldTypes.get(opt.value)
            });
        }
        return fields;
    }

    /**
     * Returns child relationships for a given SObject type with relationship name and child object info.
     * @param objectName The parent SObject API name
     * @return List of maps with 'label', 'value', 'childObjectApiName', and 'lookupField' keys
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getChildRelationships(String objectName) {
        List<Option> sortedRels = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) { return new List<Map<String, String>>(); }

        for (Schema.ChildRelationship child : objType.getDescribe().getChildRelationships()) {
            if (child.getRelationshipName() != null) {
                sortedRels.add(new Option(
                    child.getRelationshipName() + ' (' + child.getChildSObject().getDescribe().getLabel() + ')',
                    child.getRelationshipName(),
                    child.getChildSObject().getDescribe().getName(),
                    child.getField().getDescribe().getName()
                ));
            }
        }
        sortedRels.sort();

        List<Map<String, String>> relationships = new List<Map<String, String>>();
        for (Option opt : sortedRels) {
            relationships.add(new Map<String, String>{
                'label' => opt.label,
                'value' => opt.value,
                'childObjectApiName' => opt.childObjectApiName,
                'lookupField' => opt.lookupField
            });
        }
        return relationships;
    }

    /**
     * Returns parent (lookup) relationships for a given SObject type.
     * @param objectName The SObject API name
     * @return List of maps with 'label', 'value', and 'targetObject' keys
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getParentRelationships(String objectName) {
        List<Option> sortedParents = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) { return new List<Map<String, String>>(); }

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
             Schema.DescribeFieldResult describe = field.getDescribe();
             if (describe.getType() != Schema.DisplayType.REFERENCE) { continue; }
             if (describe.getReferenceTo().isEmpty()) { continue; }
             String relationshipName = describe.getRelationshipName();
             if (relationshipName == null) { continue; }
             String targetObject = describe.getReferenceTo()[0].getDescribe().getName();
             sortedParents.add(new Option(
                 describe.getLabel() + ' (' + relationshipName + ')',
                 relationshipName,
                 targetObject
             ));
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

    /**
     * Returns sharing records for a template, excluding the owner share.
     * @param templateId The DocGen template record ID
     * @return List of maps with share record details (Id, UserOrGroupId, Name, AccessLevel, RowCause)
     */
    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getTemplateShares(Id templateId) {
        List<Map<String, String>> shares = new List<Map<String, String>>();

        String shareObject = DocGen_Template__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getName().replace('__c', '__Share');
        List<SObject> shareRecords = Database.query( // NOPMD ApexSOQLInjection - shareObject derived from Schema.SObjectType describe, not user input
            'SELECT Id, UserOrGroupId, UserOrGroup.Name, AccessLevel, RowCause ' +
            'FROM ' + String.escapeSingleQuotes(shareObject) + ' ' +
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

    /**
     * Creates a manual sharing record for a template with the specified user or group.
     * @param templateId The DocGen template record ID
     * @param userOrGroupId The User or Group ID to share with
     * @param accessLevel The access level (e.g., 'Read', 'Edit')
     */
    @AuraEnabled
    public static void shareTemplate(Id templateId, Id userOrGroupId, String accessLevel) {
        String shareObject = DocGen_Template__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getName().replace('__c', '__Share');
        SObject share = Schema.getGlobalDescribe().get(shareObject).newSObject();
        share.put('ParentId', templateId);
        share.put('UserOrGroupId', userOrGroupId);
        share.put('AccessLevel', accessLevel);
        share.put('RowCause', 'Manual');

        try {
            SObjectAccessDecision shareDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<SObject>{ share });
            insert shareDecision.getRecords();
        } catch (DmlException e) {
            throw new AuraHandledException('Error sharing template. Please check permissions.');
        }
    }

    /**
     * Removes a manual sharing record from a template.
     * @param shareId The DocGen_Template__Share record ID to delete
     */
    @AuraEnabled
    public static void removeShare(Id shareId) {
        try {
            if (!Schema.sObjectType.DocGen_Template__c.isDeletable()) {
                throw new AuraHandledException('Insufficient access.');
            }
            delete new DocGen_Template__Share(Id = shareId); // NOPMD ApexCRUDViolation - isDeletable() checked above; package-internal share object
        } catch (DmlException e) {
            throw new AuraHandledException('Error removing share. Please check permissions.');
        }
    }

    /**
     * Searches active users and public groups by name for the template sharing UI.
     * @param searchTerm The search string to match against user/group names
     * @return List of maps with Id, Name, Type, and Icon for matching users and groups
     */
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
     * @param data The record data object (Map or List) to walk and normalize
     */
    public static void resolveRichTextImages(Object data) {
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
    @TestVisible
    private static String normalizeImageUrls(String html) {
        try {
            String baseUrl = URL.getOrgDomainUrl().toExternalForm();
            html = html.replaceAll('(?i)(src\\s*=\\s*["\'])(/servlet/)', '$1' + baseUrl + '$2');
            html = html.replaceAll('(?i)(src\\s*=\\s*["\'])(/sfc/)', '$1' + baseUrl + '$2');
            return html;
        } catch (Exception e) {
            // Intentionally swallowed: URL normalization failed (e.g., org domain unavailable in test context) — return original HTML unchanged
            return html;
        }
    }

    // =========================================================================
    // Report Import — extract columns and filters from existing Salesforce Reports
    // =========================================================================

    /**
     * Returns PDF files attached to a record (for PDF merger).
     * Each entry has a label (file title) and value (ContentVersion ID).
     * @param recordId The record ID to find attached PDFs for
     * @return List of maps with 'label' (title) and 'value' (ContentVersion ID) keys
     */
    @AuraEnabled
    public static List<Map<String, String>> getRecordPdfs(Id recordId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId, ContentDocument.LatestPublishedVersionId,
                   ContentDocument.Title, ContentDocument.FileExtension
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
            AND ContentDocument.FileExtension = 'pdf'
            WITH SYSTEM_MODE
            ORDER BY ContentDocument.Title
        ];

        List<Map<String, String>> result = new List<Map<String, String>>();
        for (ContentDocumentLink link : links) {
            result.add(new Map<String, String>{
                'label' => link.ContentDocument.Title + '.pdf',
                'value' => link.ContentDocument.LatestPublishedVersionId
            });
        }
        return result;
    }

    /**
     * Returns PDFs attached to child records of a parent record.
     * Groups results by child record: [{childRecordId, childRecordName, pdfs: [{label, value}]}]
     * @param parentRecordId The parent record ID
     * @param childObject The child SObject API name
     * @param lookupField The lookup field on the child object pointing to the parent
     * @param filterClause Optional additional WHERE clause to filter child records
     * @return List of grouped results with child record info and their attached PDFs
     */
    @AuraEnabled
    public static List<Map<String, Object>> getChildRecordPdfs(Id parentRecordId, String childObject, String lookupField, String filterClause) {
        if (parentRecordId == null || String.isBlank(childObject) || String.isBlank(lookupField)) {
            throw new AuraHandledException('Parent record ID, child object, and lookup field are required.');
        }

        // Validate child object exists in schema
        SObjectType childType = Schema.getGlobalDescribe().get(childObject);
        if (childType == null) {
            throw new AuraHandledException('Invalid child object: ' + childObject);
        }

        // Validate lookup field exists on child object
        Map<String, SObjectField> fieldMap = childType.getDescribe().fields.getMap();
        if (!fieldMap.containsKey(lookupField.toLowerCase())) {
            throw new AuraHandledException('Invalid lookup field: ' + lookupField);
        }

        // Determine display field — use Name if available, else Id
        Boolean hasName = fieldMap.containsKey('name') && fieldMap.get('name').getDescribe().isAccessible();
        String displayField = hasName ? 'Name' : 'Id';

        // Query child records
        String childQuery = 'SELECT Id, ' + (hasName ? 'Name, ' : '') +
            String.escapeSingleQuotes(lookupField) +
            ' FROM ' + String.escapeSingleQuotes(childObject) +
            ' WHERE ' + String.escapeSingleQuotes(lookupField) + ' = :parentRecordId';
        if (String.isNotBlank(filterClause)) {
            childQuery += ' AND (' + filterClause + ')';
        }
        childQuery += ' ORDER BY ' + displayField + ' LIMIT 200';

        List<SObject> childRecords;
        try {
            childRecords = Database.query(childQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - object/field names validated against Schema.getGlobalDescribe(); runs with USER_MODE
        } catch (Exception e) {
            throw new AuraHandledException('Error querying child records: ' + e.getMessage());
        }

        if (childRecords.isEmpty()) {
            return new List<Map<String, Object>>();
        }

        // Collect child record IDs
        Set<Id> childIds = new Set<Id>();
        Map<Id, String> childNameMap = new Map<Id, String>();
        for (SObject rec : childRecords) {
            childIds.add(rec.Id);
            childNameMap.put(rec.Id, hasName ? (String) rec.get('Name') : String.valueOf(rec.Id));
        }

        // Query PDFs attached to all child records in one query
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId, ContentDocument.LatestPublishedVersionId,
                   ContentDocument.Title, ContentDocument.FileExtension,
                   LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :childIds
            AND ContentDocument.FileExtension = 'pdf'
            WITH SYSTEM_MODE
            ORDER BY ContentDocument.Title
        ];

        // Group by child record
        Map<Id, List<Map<String, String>>> pdfsByChild = new Map<Id, List<Map<String, String>>>();
        for (ContentDocumentLink link : links) {
            Id childId = link.LinkedEntityId;
            if (!pdfsByChild.containsKey(childId)) {
                pdfsByChild.put(childId, new List<Map<String, String>>());
            }
            pdfsByChild.get(childId).add(new Map<String, String>{
                'label' => link.ContentDocument.Title + '.pdf',
                'value' => link.ContentDocument.LatestPublishedVersionId
            });
        }

        // Build grouped result — include all child records (even those without PDFs)
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (SObject rec : childRecords) {
            List<Map<String, String>> pdfs = pdfsByChild.containsKey(rec.Id)
                ? pdfsByChild.get(rec.Id) : new List<Map<String, String>>();
            result.add(new Map<String, Object>{
                'childRecordId' => rec.Id,
                'childRecordName' => childNameMap.get(rec.Id),
                'pdfs' => pdfs
            });
        }
        return result;
    }

    /**
     * Returns available reports the user can access.
     * Searches by name if a search term is provided.
     * @param searchTerm Optional search string to filter reports by name
     * @return List of maps with 'id', 'name', and 'folder' keys
     */
    @AuraEnabled
    public static List<Map<String, String>> getAvailableReports(String searchTerm) {
        String query = 'SELECT Id, Name, DeveloperName, FolderName FROM Report';
        if (String.isNotBlank(searchTerm)) {
            String safeTerm = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            query += ' WHERE Name LIKE :safeTerm';
        }
        query += ' ORDER BY Name LIMIT 50';

        List<Map<String, String>> results = new List<Map<String, String>>();
        for (Report r : Database.query(query)) {
            results.add(new Map<String, String>{
                'id' => r.Id,
                'name' => r.Name,
                'folder' => r.FolderName
            });
        }
        return results;
    }

    /**
     * Imports a report's columns and filters as a DocGen query config.
     * Uses the Reports API to describe the report, then normalizes
     * column names to SOQL field API names.
     * @param reportId The Salesforce Report ID to import configuration from
     * @return Map containing baseObject, fields, parentFields, childFields, filters, and metadata
     */
    @AuraEnabled
    public static Map<String, Object> importReportConfig(Id reportId) {
        if (reportId == null) {
            throw new AuraHandledException('Report ID is required.');
        }

        Reports.ReportDescribeResult describe = Reports.ReportManager.describeReport(reportId);
        Reports.ReportMetadata metadata = describe.getReportMetadata();
        Reports.ReportExtendedMetadata extMeta = describe.getReportExtendedMetadata();

        // Determine base object from report type
        String reportTypeName = metadata.getReportType().getType();
        String reportTypeLabel = metadata.getReportType().getLabel();
        String baseObject = resolveReportBaseObject(reportTypeName, reportTypeLabel);
        if (baseObject == null) {
            throw new AuraHandledException('Could not determine the base object for this report. Report type: ' + reportTypeName);
        }

        // Get the field map for normalization
        SObjectType objType = Schema.getGlobalDescribe().get(baseObject);
        if (objType == null) {
            throw new AuraHandledException('Object not found: ' + baseObject);
        }
        Map<String, SObjectField> fieldMap = objType.getDescribe().fields.getMap();

        // Build label → proper API name map, and lowercase key → proper API name map
        Map<String, String> labelToApiName = new Map<String, String>();
        Map<String, String> properCaseMap = new Map<String, String>();
        for (String apiName : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
            String properName = dfr.getName(); // Proper-cased: 'BillingState', 'Name', etc.
            labelToApiName.put(dfr.getLabel().toLowerCase(), properName);
            properCaseMap.put(apiName.toLowerCase(), properName);
        }

        // Build parent relationship prefix map: USERS → Owner, ACCOUNT → Account, etc.
        Map<String, String> parentPrefixMap = new Map<String, String>();
        for (SObjectField sof : fieldMap.values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (dfr.getRelationshipName() != null && dfr.getReferenceTo() != null && !dfr.getReferenceTo().isEmpty()) {
                String refObjName = dfr.getReferenceTo()[0].getDescribe().getName().toUpperCase();
                parentPrefixMap.put(refObjName, dfr.getRelationshipName());
                if (dfr.getName() == 'OwnerId') { parentPrefixMap.put('USERS', dfr.getRelationshipName()); }
                if (dfr.getName() == 'CreatedById') { parentPrefixMap.put('CREATED_BY', dfr.getRelationshipName()); }
            }
        }

        // For cross-object reports (OpportunityContactProduct), build child object field maps
        // so we can route columns like FIRST_NAME to the Contact child, PRODUCT_NAME to LineItems
        Map<String, String> childRelNameByObject = new Map<String, String>();
        Map<String, Map<String, SObjectField>> childFieldMaps = new Map<String, Map<String, SObjectField>>();
        Map<String, Map<String, String>> childLabelMaps = new Map<String, Map<String, String>>();
        Map<String, Map<String, String>> childProperCaseMaps = new Map<String, Map<String, String>>();

        // Detect child objects from the report type name
        Map<String, String> reportTypeChildObjects = new Map<String, String>{
            'OpportunityContactProduct' => 'Contact,OpportunityLineItem',
            'OpportunityContact' => 'Contact',
            'OpportunityProduct' => 'OpportunityLineItem',
            'OpportunityLead' => 'Lead',
            'AccountContact' => 'Contact',
            'AccountCase' => 'Case',
            'CaseContact' => 'Contact',
            'CampaignMember' => 'Contact,Lead',
            'QuoteProduct' => 'Quote',
            'QuoteList' => 'Quote'
        };

        if (reportTypeChildObjects.containsKey(reportTypeName)) {
            for (String childObjName : reportTypeChildObjects.get(reportTypeName).split(',')) {
                // Find the relationship name for this child on the base object
                Boolean found = false;
                for (Schema.ChildRelationship cr : objType.getDescribe().getChildRelationships()) {
                    if (cr.getChildSObject().getDescribe().getName() == childObjName && cr.getRelationshipName() != null) {
                        childRelNameByObject.put(childObjName, cr.getRelationshipName());
                        found = true;
                        break;
                    }
                }
                // If not a direct child (e.g., Contact via OpportunityContactRole), skip SOQL routing
                // but still build the field map for label-based column detection
                if (!found) {
                    String junctionRelName = findJunctionRelationship(baseObject, childObjName, objType);
                    childRelNameByObject.put(childObjName,
                        junctionRelName != null ? '__junction_' + childObjName + ':' + junctionRelName : '__junction_' + childObjName);
                }

                // Build field maps for label matching regardless
                SObjectType childType = Schema.getGlobalDescribe().get(childObjName);
                if (childType != null) {
                    Map<String, SObjectField> cfm = childType.getDescribe().fields.getMap();
                    childFieldMaps.put(childObjName, cfm);
                    Map<String, String> clm = new Map<String, String>();
                    Map<String, String> cpm = new Map<String, String>();
                    for (String fn : cfm.keySet()) {
                        Schema.DescribeFieldResult cdfr = cfm.get(fn).getDescribe();
                        clm.put(cdfr.getLabel().toLowerCase(), cdfr.getName());
                        cpm.put(fn.toLowerCase(), cdfr.getName());
                    }
                    childLabelMaps.put(childObjName, clm);
                    childProperCaseMaps.put(childObjName, cpm);
                }
            }
        }

        // Also discover grandchildren (e.g., Quote → QuoteLineItems) so their
        // field labels can match against report columns dynamically.
        Map<String, String> grandchildRelNames = new Map<String, String>();
        for (String childObjName : new List<String>(childRelNameByObject.keySet())) {
            String relName = childRelNameByObject.get(childObjName);
            if (relName.startsWith('__junction_')) { continue; } // Skip junctions
            SObjectType childType = Schema.getGlobalDescribe().get(childObjName);
            if (childType == null) { continue; }
            for (Schema.ChildRelationship gcr : childType.getDescribe().getChildRelationships()) {
                if (gcr.getRelationshipName() == null) { continue; }
                String gcObjName = gcr.getChildSObject().getDescribe().getName();
                // Skip if already tracked or if it's a system object
                if (childFieldMaps.containsKey(gcObjName)) { continue; }
                if (gcObjName.endsWith('History') || gcObjName.endsWith('Share') || gcObjName.endsWith('Feed')) { continue; }
                // Only add grandchildren that might have report columns
                // Check if the grandchild object has meaningful fields
                Map<String, SObjectField> gcfm = gcr.getChildSObject().getDescribe().fields.getMap();
                if (gcfm.size() < 3) { continue; } // Skip trivial objects
                childFieldMaps.put(gcObjName, gcfm);
                childRelNameByObject.put(gcObjName, gcr.getRelationshipName());
                Map<String, String> gclm = new Map<String, String>();
                Map<String, String> gcpm = new Map<String, String>();
                for (String fn : gcfm.keySet()) {
                    Schema.DescribeFieldResult gcdfr = gcfm.get(fn).getDescribe();
                    gclm.put(gcdfr.getLabel().toLowerCase(), gcdfr.getName());
                    gcpm.put(fn.toLowerCase(), gcdfr.getName());
                }
                childLabelMaps.put(gcObjName, gclm);
                childProperCaseMaps.put(gcObjName, gcpm);
            }
        }

        // Report column abbreviation prefixes → target object
        Map<String, String> reportPrefixToObject = new Map<String, String>{
            'QLI' => 'QuoteLineItem',
            'Q' => 'Quote',
            'OLI' => 'OpportunityLineItem',
            'CM' => 'CampaignMember'
        };

        Map<String, Map<String, String>> reportKeyOverrides = new Map<String, Map<String, String>>{
            'PRODUCT_NAME' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'Name' },
            'QUANTITY' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'Quantity' },
            'TOTAL_PRICE' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'TotalPrice' },
            'UNIT_PRICE' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'UnitPrice' },
            'QUOTE_LINEITEM_NAME' => new Map<String, String>{ 'object' => 'QuoteLineItem', 'field' => 'Name' },
            'PHONE1' => new Map<String, String>{ 'object' => 'Contact', 'field' => 'Phone' },
            'PHONE2' => new Map<String, String>{ 'object' => 'Contact', 'field' => 'HomePhone' },
            'PHONE3' => new Map<String, String>{ 'object' => 'Contact', 'field' => 'MobilePhone' }
        };

        // Normalize report columns — route to base, parent, or child
        List<String> detailColumns = metadata.getDetailColumns();
        Map<String, Reports.DetailColumn> columnInfo = extMeta.getDetailColumnInfo();
        List<String> normalizedFields = new List<String>();
        List<String> parentFields = new List<String>();
        Map<String, List<String>> childFields = new Map<String, List<String>>();

        for (String colKey : detailColumns) {
            Reports.DetailColumn col = columnInfo.get(colKey);
            String colLabel = (col != null) ? col.getLabel() : null;
            Boolean mapped = false;

            // 0a. Dynamic label matching against ALL child objects
            // If the column label matches a field label on ANY known child object,
            // route it there. This works for any report type without hardcoding.
            if (!mapped && String.isNotBlank(colLabel) && !childFieldMaps.isEmpty()) {
                String labelLower = colLabel.toLowerCase();
                // Strip common label prefixes like "Quote Line Item: " or "Product: "
                String cleanLabel = labelLower;
                if (cleanLabel.contains(': ')) {
                    cleanLabel = cleanLabel.substringAfter(': ');
                }

                for (String childObjName : childLabelMaps.keySet()) {
                    Map<String, String> clm = childLabelMaps.get(childObjName);
                    String relName = childRelNameByObject.get(childObjName);
                    if (relName == null) { continue; }

                    // Try full label first, then cleaned label
                    String childFieldName = clm.get(labelLower);
                    if (childFieldName == null) { childFieldName = clm.get(cleanLabel); }

                    // Make sure it's NOT also a base object field (avoid stealing base fields)
                    if (childFieldName != null && (!labelToApiName.containsKey(labelLower) || colKey.contains('.'))) {
                        if (!childFields.containsKey(relName)) { childFields.put(relName, new List<String>()); }
                        if (!childFields.get(relName).contains(childFieldName)) { childFields.get(relName).add(childFieldName); }
                        mapped = true;
                        break;
                    }
                }
            }

            // 0b. Check hardcoded overrides for remaining unmapped columns
            if (!mapped && reportKeyOverrides.containsKey(colKey)) {
                Map<String, String> override_info = reportKeyOverrides.get(colKey);
                String targetObj = override_info.get('object');
                String targetField = override_info.get('field');
                String relName = childRelNameByObject.get(targetObj);
                if (relName != null) {
                    if (!childFields.containsKey(relName)) { childFields.put(relName, new List<String>()); }
                    if (!childFields.get(relName).contains(targetField)) { childFields.get(relName).add(targetField); }
                    mapped = true;
                }
            }

            // 1. Check parent prefix (USERS.NAME, ACCOUNT.NAME on non-Account base)
            if (!mapped && colKey.contains('.')) {
                String prefix = colKey.substringBefore('.').toUpperCase();
                String childField = colKey.substringAfter('.');
                Boolean isSelfPrefix = prefix.equalsIgnoreCase(baseObject) ||
                    prefix.equalsIgnoreCase(baseObject.removeEnd('__c')) ||
                    (baseObject == 'Opportunity' && prefix == 'OPPORTUNITY');
                if (isSelfPrefix) {
                    // Base object's own field — normalize the field part
                    String fieldName = normalizeReportColumn(childField, colLabel, fieldMap, labelToApiName, properCaseMap);
                    if (fieldName != null && !normalizedFields.contains(fieldName)) {
                        normalizedFields.add(fieldName);
                    }
                    mapped = true;
                } else if (parentPrefixMap.containsKey(prefix)) {
                    String relName = parentPrefixMap.get(prefix);
                    String parentFieldName = resolveParentFieldName(relName, childField, colLabel, fieldMap);
                    if (parentFieldName != null) {
                        String fullPath = relName + '.' + parentFieldName;
                        if (!parentFields.contains(fullPath)) { parentFields.add(fullPath); }
                        mapped = true;
                    }
                }
            }

            // 2. Check hardcoded owner mapping
            if (!mapped && colKey == 'OWNER_FULL_NAME') {
                if (!parentFields.contains('Owner.Name')) { parentFields.add('Owner.Name'); }
                mapped = true;
            }

            // 3. Try to route to a child object by label matching
            if (!mapped && !childFieldMaps.isEmpty()) {
                for (String childObjName : childFieldMaps.keySet()) {
                    Map<String, String> clm = childLabelMaps.get(childObjName);
                    Map<String, String> cpm = childProperCaseMaps.get(childObjName);
                    Map<String, SObjectField> cfm = childFieldMaps.get(childObjName);
                    String relName = childRelNameByObject.get(childObjName);

                    // Try label match on child object
                    String childFieldName = null;
                    if (String.isNotBlank(colLabel) && clm.containsKey(colLabel.toLowerCase())) {
                        childFieldName = clm.get(colLabel.toLowerCase());
                    }
                    // Try direct key match
                    if (childFieldName == null) {
                        childFieldName = normalizeReportColumn(colKey, colLabel, cfm, clm, cpm);
                    }

                    if (childFieldName == null) { continue; }
                    if (!childFields.containsKey(relName)) { childFields.put(relName, new List<String>()); }
                    if (!childFields.get(relName).contains(childFieldName)) {
                        childFields.get(relName).add(childFieldName);
                    }
                    mapped = true;
                    break;
                }
            }

            // 4. Fall through: try base object normalization
            if (!mapped) {
                String fieldName = normalizeReportColumn(colKey, colLabel, fieldMap, labelToApiName, properCaseMap);
                if (fieldName != null && !normalizedFields.contains(fieldName)) {
                    normalizedFields.add(fieldName);
                }
            }
        }

        // Convert report filters to a simple list
        List<Map<String, String>> filters = new List<Map<String, String>>();
        for (Reports.ReportFilter rf : metadata.getReportFilters()) {
            Reports.DetailColumn filterCol = columnInfo.get(rf.getColumn());
            String filterLabel = (filterCol != null) ? filterCol.getLabel() : null;
            String filterField = normalizeReportColumn(rf.getColumn(), filterLabel, fieldMap, labelToApiName, properCaseMap);
            if (filterField != null) {
                filters.add(new Map<String, String>{
                    'field' => filterField,
                    'operator' => mapReportOperator(rf.getOperator()),
                    'value' => rf.getValue()
                });
            }
        }

        // Capture standard date filter as a WHERE clause
        Reports.StandardDateFilter stdDateFilter = metadata.getStandardDateFilter();
        String whereClause = '';
        if (stdDateFilter != null) {
            String dateCol = stdDateFilter.getColumn();
            String dateField = normalizeReportColumn(dateCol, null, fieldMap, labelToApiName, properCaseMap);
            if (dateField == null) {
                // Common date column mappings
                Map<String, String> dateMap = new Map<String, String>{
                    'CREATED_DATE' => 'CreatedDate',
                    'CLOSE_DATE' => 'CloseDate',
                    'LAST_UPDATE' => 'LastModifiedDate'
                };
                dateField = dateMap.get(dateCol);
            }
            if (dateField != null) {
                String duration = stdDateFilter.getDurationValue();
                String startDate = stdDateFilter.getStartDate();
                String endDate = stdDateFilter.getEndDate();

                if (duration != null && duration != 'CUSTOM') {
                    // Relative date: THIS_MONTH, LAST_YEAR, etc.
                    whereClause = dateField + ' = ' + duration;
                } else {
                    if (String.isNotBlank(startDate) && String.isNotBlank(endDate)) {
                        whereClause = dateField + ' >= ' + startDate + ' AND ' + dateField + ' <= ' + endDate;
                    } else if (String.isNotBlank(startDate)) {
                        whereClause = dateField + ' >= ' + startDate;
                    } else if (String.isNotBlank(endDate)) {
                        whereClause = dateField + ' <= ' + endDate;
                    }
                }
            }
        }

        // Build WHERE string from custom filters too
        List<String> filterParts = new List<String>();
        if (String.isNotBlank(whereClause)) { filterParts.add(whereClause); }
        for (Map<String, String> f : filters) {
            String op = f.get('operator');
            String val = f.get('value');
            String fieldName = f.get('field');

            // Detect multi-value equals: "Value1,Value2,Value3" → convert to IN
            // But not formatted numbers like "2,000" (those start with " or are purely numeric)
            if ((op == '=' || op == '!=') && val.contains(',') && !val.startsWith('"')) {
                String stripped = val.replaceAll('[,\\d\\.\\s]', '');
                if (stripped.length() > 0) {
                    // Has non-numeric chars after stripping commas/digits → it's multi-value text
                    op = (op == '=') ? 'IN' : 'NOT IN';
                }
            }

            if (op == 'LIKE') {
                filterParts.add(fieldName + ' LIKE \'%' + String.escapeSingleQuotes(val) + '%\'');
            } else if (op == 'IN' || op == 'NOT IN') {
                // IN/NOT IN: value may be comma-separated list
                // Format: StageName IN ('Closed Won', 'Negotiation')
                List<String> vals = val.split(',');
                List<String> quotedVals = new List<String>();
                for (String v : vals) {
                    quotedVals.add('\'' + String.escapeSingleQuotes(v.trim()) + '\'');
                }
                filterParts.add(fieldName + ' ' + op + ' (' + String.join(quotedVals, ', ') + ')');
            } else {
                // Check if value is a SOQL date literal (no quotes needed)
                Set<String> dateLiterals = new Set<String>{
                    'TODAY', 'YESTERDAY', 'TOMORROW', 'LAST_WEEK', 'THIS_WEEK', 'NEXT_WEEK',
                    'LAST_MONTH', 'THIS_MONTH', 'NEXT_MONTH', 'LAST_QUARTER', 'THIS_QUARTER',
                    'NEXT_QUARTER', 'LAST_YEAR', 'THIS_YEAR', 'NEXT_YEAR', 'LAST_90_DAYS',
                    'NEXT_90_DAYS', 'LAST_N_DAYS', 'NEXT_N_DAYS'
                };
                String upperVal = val.toUpperCase().trim();
                Boolean isDateLiteral = dateLiterals.contains(upperVal) || upperVal.startsWith('LAST_N_') || upperVal.startsWith('NEXT_N_');
                Boolean isNumeric = val.trim().isNumeric() || Pattern.matches('-?\\d+\\.?\\d*', val.trim());
                Boolean isDateFormat = Pattern.matches('\\d{4}-\\d{2}-\\d{2}(T.*)?', val.trim());
                Boolean isBoolVal = upperVal == 'TRUE' || upperVal == 'FALSE' || upperVal == 'NULL';

                if (isDateLiteral || isNumeric || isDateFormat || isBoolVal) {
                    filterParts.add(fieldName + ' ' + op + ' ' + val.trim());
                } else {
                    filterParts.add(fieldName + ' ' + op + ' \'' + String.escapeSingleQuotes(val) + '\'');
                }
            }
        }
        String bulkWhereClause = String.join(filterParts, ' AND ');

        // Build child subqueries for the query config (skip junction-based children)
        List<String> childSubqueries = new List<String>();
        for (String relName : childFields.keySet()) {
            List<String> fields = childFields.get(relName);
            if (!fields.isEmpty() && !relName.startsWith('__junction_')) {
                childSubqueries.add('(SELECT ' + String.join(fields, ', ') + ' FROM ' + relName + ')');
            }
        }

        // Build junction info for the LWC
        List<Map<String, String>> junctionInfo = new List<Map<String, String>>();
        for (String relName : childFields.keySet()) {
            if (relName.startsWith('__junction_')) {
                // Parse: __junction_Contact or __junction_Contact:OpportunityContactRoles
                String remainder = relName.substring(11); // strip '__junction_'
                String targetObj;
                String junctionRel = '';
                if (remainder.contains(':')) {
                    targetObj = remainder.substringBefore(':');
                    junctionRel = remainder.substringAfter(':');
                } else {
                    targetObj = remainder;
                }
                // Resolve junction object name, lookup fields, and target relationship name
                String targetIdField = resolveJunctionTargetIdField(junctionRel, targetObj);
                String junctionObjName = resolveJunctionObjectName(junctionRel);
                String baseLookupField = resolveJunctionTargetIdField(junctionRel, baseObject);
                // Find the relationship name from junction object to target (e.g., ContactId → Contact)
                String targetRelName = resolveJunctionTargetRelName(junctionObjName, targetObj);
                junctionInfo.add(new Map<String, String>{
                    'targetObject' => targetObj,
                    'junctionRel' => junctionRel,
                    'junctionObject' => junctionObjName,
                    'baseLookupField' => baseLookupField,
                    'targetIdField' => targetIdField,
                    'targetRelName' => targetRelName != null ? targetRelName : targetObj,
                    'fields' => String.join(childFields.get(relName), ',')
                });
            }
        }

        Integer totalChildFields = 0;
        for (String relKey : childFields.keySet()) {
            totalChildFields += childFields.get(relKey).size();
        }

        // Build hierarchy map: relationship name → parent object
        // So LWC knows QuoteLineItems belongs under Quote, not Opportunity
        Map<String, Map<String, String>> childHierarchy = new Map<String, Map<String, String>>();
        for (String childObjName : childRelNameByObject.keySet()) {
            String relName = childRelNameByObject.get(childObjName);
            if (relName.startsWith('__junction_')) { continue; }
            if (!childFields.containsKey(relName)) { continue; } // Only include objects with matched fields

            // Find which parent this child belongs to
            String parentObj = findParentObject(childObjName, baseObject, childRelNameByObject);

            childHierarchy.put(relName, new Map<String, String>{
                'objectName' => childObjName,
                'parentObject' => parentObj,
                'lookupField' => parentObj + 'Id'
            });
        }

        return new Map<String, Object>{
            'baseObject' => baseObject,
            'fields' => normalizedFields,
            'parentFields' => parentFields,
            'childSubqueries' => childSubqueries,
            'childFields' => childFields,
            'childHierarchy' => childHierarchy,
            'junctions' => junctionInfo,
            'filters' => filters,
            'bulkWhereClause' => bulkWhereClause,
            'reportName' => metadata.getName(),
            'fieldCount' => normalizedFields.size() + parentFields.size() + totalChildFields,
            'filterCount' => filters.size()
        };
    }

    /**
     * Determines the parent object for a child by checking its reference fields.
     * If a reference points to another known child object, returns that as the parent (grandchild case).
     */
    @TestVisible
    private static String findParentObject(String childObjName, String baseObject, Map<String, String> childRelNameByObject) {
        SObjectType childSobjType = Schema.getGlobalDescribe().get(childObjName);
        if (childSobjType == null) { return baseObject; }

        for (Schema.SObjectField sof : childSobjType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (dfr.getType() != Schema.DisplayType.REFERENCE || dfr.getReferenceTo() == null) { continue; }
            for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                String refName = ref.getDescribe().getName();
                // Ignore the child object itself as a potential parent (e.g., ReportsToId on Contact)
                if (childRelNameByObject.containsKey(refName) && refName != baseObject && refName != childObjName) {
                    return refName;
                }
            }
        }
        return baseObject;
    }

    /**
     * Finds a junction relationship name for accessing a target object via the base object.
     * Checks known junctions first, then scans child relationships for a matching reference.
     */
    @TestVisible
    private static String findJunctionRelationship(String baseObject, String childObjName, SObjectType objType) {
        Map<String, String> knownJunctions = new Map<String, String>{
            'Opportunity:Contact' => 'OpportunityContactRoles',
            'Account:Contact' => 'AccountContactRelations',
            'Campaign:Contact' => 'CampaignMembers',
            'Campaign:Lead' => 'CampaignMembers'
        };
        String junctionKey = baseObject + ':' + childObjName;
        String junctionRelName = knownJunctions.get(junctionKey);
        if (junctionRelName != null) { return junctionRelName; }

        // Fallback: scan child relationships for a junction object
        for (Schema.ChildRelationship cr : objType.getDescribe().getChildRelationships()) {
            if (cr.getRelationshipName() == null) { continue; }
            String jObjName = cr.getChildSObject().getDescribe().getName();
            if (jObjName.endsWith('History') || jObjName.endsWith('Share') || jObjName.endsWith('Feed')) { continue; }

            if (hasReferenceToObject(cr.getChildSObject(), childObjName)) {
                return cr.getRelationshipName();
            }
        }
        return null;
    }

    /**
     * Resolves the lookup field API name on a junction object that points to the target object.
     * E.g., for OpportunityContactRoles → Contact, returns 'ContactId'.
     * Dynamically finds the junction SObject from the relationship name, then scans its reference fields.
     */
    private static String resolveJunctionTargetIdField(String junctionRelName, String targetObjectName) {
        if (String.isBlank(junctionRelName) || String.isBlank(targetObjectName)) {
            return targetObjectName + 'Id';
        }
        // Derive the junction object API name from the relationship name
        // OpportunityContactRoles → OpportunityContactRole, CampaignMembers → CampaignMember, etc.
        List<String> candidates = new List<String>{
            junctionRelName.removeEnd('s'),          // OpportunityContactRoles → OpportunityContactRole
            junctionRelName.removeEnd('es'),          // AccountContactRelations → AccountContactRelation (if ends in 'es')
            junctionRelName                           // Exact match (rare)
        };
        for (String candidate : candidates) {
            SObjectType juncType = Schema.getGlobalDescribe().get(candidate);
            if (juncType == null) { continue; }
            for (SObjectField sof : juncType.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult dfr = sof.getDescribe();
                if (dfr.getType() != Schema.DisplayType.REFERENCE || dfr.getReferenceTo() == null) { continue; }
                for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                    if (ref.getDescribe().getName() == targetObjectName) {
                        return dfr.getName();
                    }
                }
            }
        }
        return targetObjectName + 'Id';
    }

    /**
     * Resolves the junction SObject API name from the relationship name.
     * E.g., OpportunityContactRoles → OpportunityContactRole.
     */
    private static String resolveJunctionObjectName(String junctionRelName) {
        if (String.isBlank(junctionRelName)) { return null; }
        for (String candidate : new List<String>{
            junctionRelName.removeEnd('s'),
            junctionRelName.removeEnd('es'),
            junctionRelName
        }) {
            if (Schema.getGlobalDescribe().containsKey(candidate)) { return candidate; }
        }
        return junctionRelName.removeEnd('s');
    }

    /**
     * Resolves the relationship name from a junction object to its target object.
     * E.g., on OpportunityContactRole, the ContactId field has relationship name 'Contact'.
     */
    private static String resolveJunctionTargetRelName(String junctionObjName, String targetObjectName) {
        if (String.isBlank(junctionObjName) || String.isBlank(targetObjectName)) { return null; }
        SObjectType juncType = Schema.getGlobalDescribe().get(junctionObjName);
        if (juncType == null) { return null; }
        for (SObjectField sof : juncType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (dfr.getType() != Schema.DisplayType.REFERENCE || dfr.getReferenceTo() == null) { continue; }
            for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                if (ref.getDescribe().getName() == targetObjectName && dfr.getRelationshipName() != null) {
                    return dfr.getRelationshipName();
                }
            }
        }
        return null;
    }

    /**
     * Checks if a junction SObject has a reference field pointing to the target object.
     */
    @TestVisible
    private static Boolean hasReferenceToObject(Schema.SObjectType junctionType, String targetObjectName) {
        for (Schema.SObjectField jf : junctionType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult jdfr = jf.getDescribe();
            if (jdfr.getType() != Schema.DisplayType.REFERENCE || jdfr.getReferenceTo() == null) { continue; }
            for (Schema.SObjectType ref : jdfr.getReferenceTo()) {
                if (ref.getDescribe().getName() == targetObjectName) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * Resolves a field name on a parent object from a report column.
     * E.g., for Owner relationship with child field 'NAME', resolves to 'Name'.
     */
    @TestVisible
    private static String resolveParentFieldName(String relName, String childFieldKey,
            String columnLabel, Map<String, SObjectField> baseFieldMap) {
        // Find the lookup field to get the referenced object
        Map<String, SObjectField> parentFieldMap = null;
        for (SObjectField sof : baseFieldMap.values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (dfr.getRelationshipName() == relName && dfr.getReferenceTo() != null && !dfr.getReferenceTo().isEmpty()) {
                parentFieldMap = dfr.getReferenceTo()[0].getDescribe().fields.getMap();
                break;
            }
        }
        if (parentFieldMap == null) { return null; }

        // Try direct match
        if (parentFieldMap.containsKey(childFieldKey)) {
            return parentFieldMap.get(childFieldKey).getDescribe().getName();
        }

        // Try label match on parent object
        if (String.isNotBlank(columnLabel)) {
            for (String pKey : parentFieldMap.keySet()) {
                Schema.DescribeFieldResult pDfr = parentFieldMap.get(pKey).getDescribe();
                if (pDfr.getLabel().equalsIgnoreCase(columnLabel) ||
                    (pDfr.getLabel().equalsIgnoreCase('Name') && childFieldKey.equalsIgnoreCase('NAME'))) {
                    return pDfr.getName();
                }
            }
        }

        // Common: NAME → Name, EMAIL → Email
        for (String pKey : parentFieldMap.keySet()) {
            if (pKey.equalsIgnoreCase(childFieldKey)) {
                return parentFieldMap.get(pKey).getDescribe().getName();
            }
        }
        return null;
    }

    /**
     * Resolves a report type name to a base object API name.
     * Handles standard patterns like 'AccountList', 'OpportunityList', 'Contact', etc.
     */
    /**
     * Resolves a report type to its base Salesforce object.
     * Uses multiple strategies — works for ANY report type, not just hardcoded ones.
     */
    @TestVisible
    private static String resolveReportBaseObject(String reportTypeName) {
        return resolveReportBaseObject(reportTypeName, null);
    }

    @TestVisible
    private static String resolveReportBaseObject(String reportTypeName, String reportTypeLabel) {
        if (String.isBlank(reportTypeName)) { return null; }
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        // Strategy 1: Direct match (report type name IS the object name)
        if (globalDescribe.containsKey(reportTypeName)) { return reportTypeName; }

        // Strategy 2: Strip 'List' suffix — AccountList → Account
        if (reportTypeName.endsWith('List')) {
            String stripped = reportTypeName.removeEnd('List');
            if (globalDescribe.containsKey(stripped)) { return stripped; }
        }

        // Strategy 3: Custom report types ending in __c — query the DeveloperName
        if (reportTypeName.endsWith('__c')) {
            // Custom report type — the first column's prefix is often the base object
            // This is handled in Strategy 6 below
        }

        // Strategy 4: Match the report type label against object labels
        // "Accounts" → Account, "Opportunities with Contact Roles and Products" → Opportunity
        if (String.isNotBlank(reportTypeLabel)) {
            String labelLower = reportTypeLabel.toLowerCase();
            for (String objName : globalDescribe.keySet()) {
                Schema.DescribeSObjectResult objDesc = globalDescribe.get(objName).getDescribe();
                if (!objDesc.isQueryable() || objDesc.isDeprecatedAndHidden()) { continue; }
                String objLabel = objDesc.getLabel().toLowerCase();
                String objLabelPlural = objDesc.getLabelPlural() != null ? objDesc.getLabelPlural().toLowerCase() : '';
                // "Accounts" starts with "Account" label plural
                if (String.isNotBlank(objLabelPlural) && labelLower.startsWith(objLabelPlural)) {
                    return objDesc.getName();
                }
                if (labelLower.startsWith(objLabel)) {
                    return objDesc.getName();
                }
            }
        }

        // Strategy 5: Match standard object names as prefix of the report type name
        // OpportunityLead → Opportunity, AccountCase → Account
        List<String> commonObjects = new List<String>{
            'Opportunity', 'Account', 'Contact', 'Lead', 'Case', 'Campaign',
            'Contract', 'Order', 'Task', 'Event', 'User', 'Solution', 'Product'
        };
        for (String objName : commonObjects) {
            if (reportTypeName.startsWith(objName) && globalDescribe.containsKey(objName)) {
                return objName;
            }
        }

        // Strategy 6: Custom report type with __c — try to resolve via name minus suffix
        if (reportTypeName.contains('__c')) {
            String basePart = reportTypeName.substringBefore('__c');
            // Remove common prefixes/suffixes from custom report type developer names
            for (String objName : commonObjects) {
                if (basePart.containsIgnoreCase(objName) && globalDescribe.containsKey(objName)) {
                    return objName;
                }
            }
        }

        return null;
    }

    /**
     * Normalizes a report column key to a SOQL field API name.
     *
     * Report columns use internal identifiers (ACCOUNT.NAME, ADDRESS1_STATE, DUE_DATE)
     * that don't match SOQL field API names. We use a multi-strategy approach:
     *   1. Direct API name match
     *   2. Label-based matching (report label → field label → API name)
     *   3. Hardcoded mappings for common report columns
     */
    @TestVisible
    private static String normalizeReportColumn(String columnKey, String columnLabel,
            Map<String, SObjectField> fieldMap, Map<String, String> labelToApiName,
            Map<String, String> properCaseMap) {
        if (String.isBlank(columnKey)) { return null; }

        // Skip owner/user columns (parent lookups, not direct fields)
        if (columnKey.startsWith('USERS.')) { return null; }

        // 1. Label-based matching — most reliable for standard fields
        // Report labels like "Billing State/Province" map precisely to field labels
        if (String.isNotBlank(columnLabel) && labelToApiName.containsKey(columnLabel.toLowerCase())) {
            return labelToApiName.get(columnLabel.toLowerCase());
        }

        // 2. Direct API name match (works for custom fields like MyField__c)
        if (fieldMap.containsKey(columnKey)) {
            return properCaseMap.get(columnKey.toLowerCase());
        }

        // Strip object prefix: ACCOUNT.NAME → NAME
        String fieldPart = columnKey;
        if (columnKey.contains('.')) {
            fieldPart = columnKey.substringAfter('.');
        }
        if (fieldMap.containsKey(fieldPart)) {
            return properCaseMap.get(fieldPart.toLowerCase());
        }

        // 3. Hardcoded mappings for report-specific column keys that don't match labels
        Map<String, String> reportKeyMappings = new Map<String, String>{
            'CREATED_DATE' => 'CreatedDate',
            'LAST_UPDATE' => 'LastModifiedDate',
            'DUE_DATE' => 'LastActivityDate',
            'CLOSE_DATE' => 'CloseDate',
            'AMOUNT' => 'Amount',
            'FULL_NAME' => 'Name',
            'FIRST_NAME' => 'FirstName',
            'LAST_NAME' => 'LastName',
            'STAGE_NAME' => 'StageName',
            'ADDRESS1_STREET' => 'BillingStreet',
            'ADDRESS1_CITY' => 'BillingCity',
            'ADDRESS1_STATE' => 'BillingState',
            'ADDRESS1_ZIP' => 'BillingPostalCode',
            'ADDRESS1_COUNTRY' => 'BillingCountry',
            'ADDRESS2_STREET' => 'ShippingStreet',
            'ADDRESS2_CITY' => 'ShippingCity',
            'ADDRESS2_STATE' => 'ShippingState',
            'ADDRESS2_ZIP' => 'ShippingPostalCode',
            'ADDRESS2_COUNTRY' => 'ShippingCountry',
            'ACCOUNT_ID' => 'AccountId',
            'CONTACT_ID' => 'ContactId'
        };

        String upperKey = fieldPart.toUpperCase();
        if (reportKeyMappings.containsKey(upperKey)) {
            String mapped = reportKeyMappings.get(upperKey);
            if (fieldMap.containsKey(mapped)) { return mapped; }
        }

        // 4. Try with __c suffix for custom fields
        if (!fieldPart.endsWithIgnoreCase('__c') && fieldMap.containsKey(fieldPart + '__c')) {
            return properCaseMap.get((fieldPart + '__c').toLowerCase());
        }

        return null;
    }

    /**
     * Maps report filter operators to SOQL operators.
     */
    @TestVisible
    private static String mapReportOperator(String reportOperator) {
        if (String.isBlank(reportOperator)) { return '='; }

        Map<String, String> operatorMap = new Map<String, String>{
            'equals' => '=',
            'notEqual' => '!=',
            'greaterThan' => '>',
            'lessThan' => '<',
            'greaterOrEqual' => '>=',
            'lessOrEqual' => '<=',
            'contains' => 'LIKE',
            'startsWith' => 'LIKE',
            'includes' => 'IN',
            'excludes' => 'NOT IN'
        };

        return operatorMap.containsKey(reportOperator) ? operatorMap.get(reportOperator) : '=';
    }

    /**
     * Creates 5 sample templates with DOCX files and active versions.
     * Each template demonstrates different merge tag types using only standard fields.
     * @return The number of templates created
     */
    @AuraEnabled
    public static Integer createSampleTemplates() {
        // ---- Template definitions ----
        List<Map<String, String>> defs = new List<Map<String, String>>();

        // 1. Account Overview: simple fields, parent lookup, child loop, COUNT
        defs.add(new Map<String, String>{
            'name' => 'Sample: Account Overview',
            'object' => 'Account',
            'category' => 'Sample',
            'desc' => 'Demonstrates: field tags, parent lookups {Owner.Name}, child loops {#Contacts}, and {COUNT:Contacts} aggregate.',
            'config' => '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name","Industry","Phone","Website"],"parentFields":["Owner.Name"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Contact","fields":["FirstName","LastName","Title","Email","Phone"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"}' +
                ']}'
        });

        // 2. Sales Proposal: currency/date/percent formatting, line item loop, SUM/AVG/COUNT
        defs.add(new Map<String, String>{
            'name' => 'Sample: Sales Proposal',
            'object' => 'Opportunity',
            'category' => 'Sample',
            'desc' => 'Demonstrates: {Amount:currency}, {CloseDate:MMMM dd, yyyy}, {Probability:percent}, parent fields {Account.Name}, loops, {SUM:...:currency}, {AVG:...:currency}, {COUNT:...}.',
            'config' => '{"v":3,"root":"Opportunity","nodes":[' +
                '{"id":"n0","object":"Opportunity","fields":["Name","Amount","CloseDate","StageName","Probability"],"parentFields":["Account.Name","Account.Phone"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"OpportunityLineItem","fields":["Quantity","UnitPrice","TotalPrice"],"parentFields":["Product2.Name"],"parentNode":"n0","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}' +
                ']}'
        });

        // 3. Contact Card: boolean conditionals, date formatting, parent lookups
        defs.add(new Map<String, String>{
            'name' => 'Sample: Contact Card',
            'object' => 'Contact',
            'category' => 'Sample',
            'desc' => 'Demonstrates: boolean conditionals {#HasOptedOutOfEmail}...{/HasOptedOutOfEmail}, {#DoNotCall}, date format {CreatedDate:MM/dd/yyyy}, parent lookup {Account.Name}.',
            'config' => '{"v":3,"root":"Contact","nodes":[' +
                '{"id":"n0","object":"Contact","fields":["FirstName","LastName","Title","Email","Phone","MobilePhone","MailingStreet","MailingCity","MailingState","MailingPostalCode","HasOptedOutOfEmail","DoNotCall","CreatedDate"],"parentFields":["Account.Name","Account.Industry"],"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}'
        });

        // 4. Invoice: all 5 aggregate types, :number/:currency formatting
        defs.add(new Map<String, String>{
            'name' => 'Sample: Invoice',
            'object' => 'Opportunity',
            'category' => 'Sample',
            'desc' => 'Demonstrates: all aggregates — {SUM:...:currency}, {COUNT:...:number}, {AVG:...:currency}, {MIN:...:currency}, {MAX:...:currency}. Also {CloseDate:MM/dd/yyyy}, {Quantity:number}.',
            'config' => '{"v":3,"root":"Opportunity","nodes":[' +
                '{"id":"n0","object":"Opportunity","fields":["Name","CloseDate","StageName"],"parentFields":["Account.Name","Account.BillingStreet","Account.BillingCity","Account.BillingState","Account.BillingPostalCode","Account.Phone"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"OpportunityLineItem","fields":["Quantity","UnitPrice","TotalPrice"],"parentFields":["Product2.Name"],"parentNode":"n0","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}' +
                ']}'
        });

        // 5. Case Summary: barcode {*Field}, QR code {*Field:qr}, date formats
        defs.add(new Map<String, String>{
            'name' => 'Sample: Case Report',
            'object' => 'Case',
            'category' => 'Sample',
            'desc' => 'Demonstrates: barcode {*CaseNumber}, QR code {*CaseNumber:qr}, date formats {CreatedDate:MMMM dd, yyyy}, parent lookups {Contact.Name}, {Account.Name}.',
            'config' => '{"v":3,"root":"Case","nodes":[' +
                '{"id":"n0","object":"Case","fields":["CaseNumber","Subject","Description","Status","Priority","CreatedDate","ClosedDate"],"parentFields":["Contact.Name","Contact.Email","Account.Name"],"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}'
        });

        // ---- DOCX base64 strings (minimal valid DOCX with merge tags) ----
        List<String> docxFiles = new List<String>();

        // Template 1: Account Overview
        docxFiles.add(''
            + 'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu'
            + 'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi'
            + 'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u'
            + 'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h'
            + 'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv'
            + 'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w'
            + 'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54'
            + 'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFzWN2N1yB8AAMgfAAARAAAAd29y'
            + 'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw'
            + 'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt'
            + 'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz'
            + 'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg'
            + 'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg'
            + 'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz'
            + 'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy'
            + 'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6'
            + 'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y'
            + 'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNDgiLz48dzpzekNzIHc6dmFsPSI0OCIvPjwvdzpyUHI+PHc6dD5BQ0NPVU5UIE9WRVJWSUVXPC93OnQ+'
            + 'PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0iY2VudGVyIi8+PHc6c3BhY2luZyB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+'
            + 'PHc6clByPjx3OmkvPjx3OmNvbG9yIHc6dmFsPSI2QjcyODAiLz48dzpzeiB3OnZhbD0iMjIiLz48dzpzekNzIHc6dmFsPSIyMiIvPjwvdzpyUHI+PHc6dD57'
            + 'TmFtZX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBCZHI+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjYiIHc6c3BhY2U9'
            + 'IjEiIHc6Y29sb3I9IkQxRDVEQiIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzphZnRlcj0iMjAwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3'
            + 'OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRUZGNkZGIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAi'
            + 'Lz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIv'
            + 'PjwvdzpyUHI+PHc6dD5BY2NvdW50IEluZm9ybWF0aW9uPC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0'
            + 'MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpz'
            + 'ekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5JbmR1c3RyeTogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29s'
            + 'b3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntJbmR1c3RyeX08L3c6dD48L3c6'
            + 'cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+'
            + 'PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJl'
            + 'c2VydmUiPlBob25lOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3'
            + 'OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1Bob25lfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAi'
            + 'IHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD'
            + 'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+V2Vic2l0ZTogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Ig'
            + 'dzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntXZWJzaXRlfTwvdzp0PjwvdzpyPjwv'
            + 'dzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpj'
            + 'b2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2'
            + 'ZSI+QWNjb3VudCBPd25lcjogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6'
            + 'Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntPd25lci5OYW1lfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJl'
            + 'Zm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8i'
            + 'IHc6ZmlsbD0iRUZGNkZGIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNv'
            + 'bG9yIHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5Db250YWN0czwvdzp0Pjwvdzpy'
            + 'PjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xv'
            + 'ciB3OnZhbD0iNkI3MjgwIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+'
            + 'VG90YWwgQ29udGFjdHM6IHtDT1VOVDpDb250YWN0c308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYw'
            + 'IiB3OmFmdGVyPSI2MCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+'
            + 'PC93OnJQcj48dzp0PnsjQ29udGFjdHN9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzp0Ymw+PHc6dGJsUHI+PHc6dGJsVyB3Onc9IjAiIHc6dHlwZT0iYXV0'
            + 'byIvPjx3OnRibEJvcmRlcnM+PHc6dG9wIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OmxlZnQgdzp2'
            + 'YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3Bh'
            + 'Y2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OnJpZ2h0IHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3'
            + 'Omluc2lkZUggdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6aW5zaWRlViB3OnZhbD0ic2luZ2xlIiB3'
            + 'OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6dGJsQm9yZGVycz48L3c6dGJsUHI+PHc6dGJsR3JpZD48dzpncmlkQ29sIHc6dz0i'
            + 'MzIwMCIvPjx3OmdyaWRDb2wgdzp3PSIyNDAwIi8+PHc6Z3JpZENvbCB3Onc9IjI0MDAiLz48dzpncmlkQ29sIHc6dz0iMjQwMCIvPjwvdzp0YmxHcmlkPgog'
            + 'ICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iMUUzQThBIi8+PHc6dGNNYXI+PHc6'
            + 'dG9wIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6Ym90dG9tIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6bGVmdCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIv'
            + 'Pjx3OnJpZ2h0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PC93OnRjTWFyPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjAiIHc6'
            + 'YWZ0ZXI9IjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSJGRkZGRkYiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6'
            + 'dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD5OYW1lPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpj'
            + 'b2xvcj0iYXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0'
            + 'eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRj'
            + 'UHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2'
            + 'YWw9IkZGRkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlRpdGxlPC93OnQ+PC93OnI+PC93OnA+PC93'
            + 'OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3'
            + 'PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmln'
            + 'aHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0i'
            + 'MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZGRkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4'
            + 'Ii8+PC93OnJQcj48dzp0PkVtYWlsPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0i'
            + 'YXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJk'
            + 'eGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6'
            + 'cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZG'
            + 'RkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlBob25lPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjwv'
            + 'dzp0cj4KICAgICAgPHc6dHI+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIg'
            + 'dzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93'
            + 'OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9'
            + 'IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntGaXJzdE5h'
            + 'bWV9IHtMYXN0TmFtZX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEi'
            + 'Lz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBl'
            + 'PSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48'
            + 'dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFj'
            + 'ZT0icHJlc2VydmUiPntUaXRsZX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBl'
            + 'PSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIg'
            + 'dzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+'
            + 'PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHht'
            + 'bDpzcGFjZT0icHJlc2VydmUiPntFbWFpbH08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIg'
            + 'dzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3'
            + 'PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwv'
            + 'dzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48'
            + 'dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntQaG9uZX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PC93OnRyPgogICAgPC93OnRibD4KICAgIDx3OnA+PHc6'
            + 'cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSI2MCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFs'
            + 'PSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsvQ29udGFjdHN9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpw'
            + 'QmRyPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xlIiB3OnN6PSI2IiB3OnNwYWNlPSIxIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6cEJkcj48dzpzcGFjaW5nIHc6'
            + 'YWZ0ZXI9IjIwMCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0iY2VudGVyIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAi'
            + 'IHc6YWZ0ZXI9IjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmkvPjx3OmNvbG9yIHc6dmFsPSI5Q0EzQUYiLz48dzpzeiB3OnZhbD0iMTYiLz48dzpzekNz'
            + 'IHc6dmFsPSIxNiIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5HZW5lcmF0ZWQgb24ge1RPREFZfSB8IFBvd2VyZWQgYnkgRG9jR2VuPC93'
            + 'OnQ+PC93OnI+PC93OnA+CiAgICA8dzpzZWN0UHI+CiAgICAgIDx3OnBnU3ogdzp3PSIxMjI0MCIgdzpoPSIxNTg0MCIvPgogICAgICA8dzpwZ01hciB3OnRv'
            + 'cD0iMTQ0MCIgdzpyaWdodD0iMTQ0MCIgdzpib3R0b209IjE0NDAiIHc6bGVmdD0iMTQ0MCIgdzpoZWFkZXI9IjcyMCIgdzpmb290ZXI9IjcyMCIgdzpndXR0'
            + 'ZXI9IjAiLz4KICAgIDwvdzpzZWN0UHI+CiAgPC93OmJvZHk+Cjwvdzpkb2N1bWVudD5QSwECFAMUAAAAAAApN3hc13mE6rgBAAC4AQAAEwAAAAAAAAAAAAAA'
            + 'gAEAAAAAW0NvbnRlbnRfVHlwZXNdLnhtbFBLAQIUAxQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAAAAAAAAAAACAAekBAABfcmVscy8ucmVsc1BLAQIUAxQA'
            + 'AAAAACk3eFyMDoXQnQAAAJ0AAAAcAAAAAAAAAAAAAACAAUADAAB3b3JkL19yZWxzL2RvY3VtZW50LnhtbC5yZWxzUEsBAhQDFAAAAAAAKTd4XNY3Y3XIHwAA'
            + 'yB8AABEAAAAAAAAAAAAAAIABFwQAAHdvcmQvZG9jdW1lbnQueG1sUEsFBgAAAAAEAAQAAwEAAA4kAAAAAA=='
        );

        // Template 2: Sales Proposal
        docxFiles.add(''
            + 'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu'
            + 'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi'
            + 'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u'
            + 'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h'
            + 'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv'
            + 'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w'
            + 'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54'
            + 'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFxGcFSOQCcAAEAnAAARAAAAd29y'
            + 'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw'
            + 'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt'
            + 'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz'
            + 'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg'
            + 'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg'
            + 'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz'
            + 'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy'
            + 'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6'
            + 'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y'
            + 'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNDgiLz48dzpzekNzIHc6dmFsPSI0OCIvPjwvdzpyUHI+PHc6dD5TQUxFUyBQUk9QT1NBTDwvdzp0Pjwv'
            + 'dzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iMTIwIi8+PC93OnBQcj48dzpyPjx3'
            + 'OnJQcj48dzppLz48dzpjb2xvciB3OnZhbD0iNkI3MjgwIi8+PHc6c3ogdzp2YWw9IjIyIi8+PHc6c3pDcyB3OnZhbD0iMjIiLz48L3c6clByPjx3OnQ+UHJl'
            + 'cGFyZWQgZm9yIHtBY2NvdW50Lk5hbWV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpwQmRyPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xl'
            + 'IiB3OnN6PSI2IiB3OnNwYWNlPSIxIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6cEJkcj48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwMCIvPjwvdzpwUHI+PC93OnA+'
            + 'CiAgICA8dzpwPjx3OnBQcj48dzpzaGQgdzp2YWw9ImNsZWFyIiB3OmNvbG9yPSJhdXRvIiB3OmZpbGw9IkVGRjZGRiIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9'
            + 'IjI0MCIgdzphZnRlcj0iMTIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMUUzQThBIi8+PHc6c3ogdzp2YWw9IjI2Ii8+'
            + 'PHc6c3pDcyB3OnZhbD0iMjYiLz48L3c6clByPjx3OnQ+T3Bwb3J0dW5pdHkgRGV0YWlsczwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6'
            + 'c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6'
            + 'c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+RGVhbCBOYW1lOiA8L3c6dD48L3c6'
            + 'cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+'
            + 'e05hbWV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3'
            + 'OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6'
            + 'dCB4bWw6c3BhY2U9InByZXNlcnZlIj5BbW91bnQ6IDwvdzp0PjwvdzpyPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIxMTE4MjciLz48dzpzeiB3OnZh'
            + 'bD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57QW1vdW50OmN1cnJlbmN5fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpw'
            + 'UHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUx'
            + 'Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+Q2xvc2UgRGF0ZTogPC93'
            + 'OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQ'
            + 'cj48dzp0PntDbG9zZURhdGU6TU1NTSBkZCwgeXl5eX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQw'
            + 'IiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6'
            + 'Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPlN0YWdlOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3'
            + 'OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1N0YWdlTmFtZX08L3c6dD48L3c6cj48'
            + 'L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6'
            + 'Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2Vy'
            + 'dmUiPlByb2JhYmlsaXR5OiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD'
            + 'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1Byb2JhYmlsaXR5OnBlcmNlbnR9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFj'
            + 'aW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3'
            + 'OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5BY2NvdW50IFBob25lOiA8L3c6dD48L3c6'
            + 'cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+'
            + 'e0FjY291bnQuUGhvbmV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48'
            + 'L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJFRkY2RkYiLz48dzpzcGFj'
            + 'aW5nIHc6YmVmb3JlPSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjFFM0E4QSIvPjx3OnN6'
            + 'IHc6dmFsPSIyNiIvPjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0PkxpbmUgSXRlbXM8L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFBy'
            + 'Pjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjZCNzI4MCIvPjx3OnN6'
            + 'IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntDT1VOVDpPcHBvcnR1bml0eUxpbmVJ'
            + 'dGVtc30gaXRlbXM8L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSI2MCIvPjwvdzpw'
            + 'UHI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsjT3Bwb3J0'
            + 'dW5pdHlMaW5lSXRlbXN9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzp0Ymw+PHc6dGJsUHI+PHc6dGJsVyB3Onc9IjAiIHc6dHlwZT0iYXV0byIvPjx3OnRi'
            + 'bEJvcmRlcnM+PHc6dG9wIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OmxlZnQgdzp2YWw9InNpbmds'
            + 'ZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6'
            + 'Y29sb3I9IkQxRDVEQiIvPjx3OnJpZ2h0IHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3Omluc2lkZUgg'
            + 'dzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6aW5zaWRlViB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3'
            + 'OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6dGJsQm9yZGVycz48L3c6dGJsUHI+PHc6dGJsR3JpZD48dzpncmlkQ29sIHc6dz0iMzYwMCIvPjx3'
            + 'OmdyaWRDb2wgdzp3PSIxMjAwIi8+PHc6Z3JpZENvbCB3Onc9IjIxMDAiLz48dzpncmlkQ29sIHc6dz0iMjUwMCIvPjwvdzp0YmxHcmlkPgogICAgICA8dzp0'
            + 'cj48dzp0Yz48dzp0Y1ByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iMUUzQThBIi8+PHc6dGNNYXI+PHc6dG9wIHc6dz0i'
            + 'NDAiIHc6dHlwZT0iZHhhIi8+PHc6Ym90dG9tIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6bGVmdCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjx3OnJpZ2h0'
            + 'IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PC93OnRjTWFyPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjAiIHc6YWZ0ZXI9IjAi'
            + 'Lz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSJGRkZGRkYiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFsPSIxOCIv'
            + 'PjwvdzpyUHI+PHc6dD5Qcm9kdWN0PC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0i'
            + 'YXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJk'
            + 'eGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6'
            + 'cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZG'
            + 'RkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlF0eTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48dzp0'
            + 'Yz48dzp0Y1ByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iMUUzQThBIi8+PHc6dGNNYXI+PHc6dG9wIHc6dz0iNDAiIHc6'
            + 'dHlwZT0iZHhhIi8+PHc6Ym90dG9tIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6bGVmdCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjx3OnJpZ2h0IHc6dz0i'
            + 'ODAiIHc6dHlwZT0iZHhhIi8+PC93OnRjTWFyPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjAiIHc6YWZ0ZXI9IjAiLz48L3c6'
            + 'cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSJGRkZGRkYiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpy'
            + 'UHI+PHc6dD5Vbml0IFByaWNlPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0'
            + 'byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEi'
            + 'Lz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48'
            + 'dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZGRkZG'
            + 'RiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlRvdGFsPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjwvdzp0'
            + 'cj4KICAgICAgPHc6dHI+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0'
            + 'eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRj'
            + 'UHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3'
            + 'NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntQcm9kdWN0Mi5O'
            + 'YW1lfTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48dzp0Yz48dzp0Y1ByPjx3OnRjTWFyPjx3OnRvcCB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRv'
            + 'bSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpyaWdodCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwv'
            + 'dzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpj'
            + 'b2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2'
            + 'ZSI+e1F1YW50aXR5fTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48dzp0Yz48dzp0Y1ByPjx3OnRjTWFyPjx3OnRvcCB3Onc9IjQwIiB3OnR5cGU9ImR4YSIv'
            + 'Pjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpyaWdodCB3Onc9IjgwIiB3OnR5cGU9'
            + 'ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3'
            + 'OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNl'
            + 'PSJwcmVzZXJ2ZSI+e1VuaXRQcmljZTpjdXJyZW5jeX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3'
            + 'PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmln'
            + 'aHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0i'
            + 'MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93'
            + 'OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntUb3RhbFByaWNlOmN1cnJlbmN5fTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48L3c6dHI+CiAgICA8'
            + 'L3c6dGJsPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6'
            + 'cj48dzpyUHI+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+ey9PcHBvcnR1bml0eUxpbmVJdGVtc308L3c6dD48'
            + 'L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBCZHI+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjYiIHc6c3BhY2U9IjEiIHc6Y29sb3I9'
            + 'IjFFM0E4QSIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzphZnRlcj0iMjAwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0i'
            + 'Y2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRjBGREY0Ii8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3'
            + 'OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxNjY1MzQiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6'
            + 'dD5Ub3RhbHM8L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+'
            + 'PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48'
            + 'dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPlN1YnRvdGFsOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTY2NTM0Ii8+PHc6c3og'
            + 'dzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1NVTTpPcHBvcnR1bml0eUxpbmVJdGVtcy5Ub3RhbFByaWNlOmN1cnJlbmN5'
            + 'fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3'
            + 'OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1s'
            + 'OnNwYWNlPSJwcmVzZXJ2ZSI+QXZlcmFnZSBVbml0IFByaWNlOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6'
            + 'c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e0FWRzpPcHBvcnR1bml0eUxpbmVJdGVtcy5Vbml0UHJpY2U6Y3VycmVu'
            + 'Y3l9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpw'
            + 'PgogICAgPHc6cD48dzpwUHI+PHc6cEJkcj48dzpib3R0b20gdzp2YWw9InNpbmdsZSIgdzpzej0iNiIgdzpzcGFjZT0iMSIgdzpjb2xvcj0iRDFENURCIi8+'
            + 'PC93OnBCZHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMDAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3'
            + 'OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzppLz48dzpjb2xvciB3OnZhbD0iOUNBM0FGIi8+PHc6'
            + 'c3ogdzp2YWw9IjE2Ii8+PHc6c3pDcyB3OnZhbD0iMTYiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+R2VuZXJhdGVkIG9uIHtUT0RBWX0g'
            + 'fCBQb3dlcmVkIGJ5IERvY0dlbjwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6c2VjdFByPgogICAgICA8dzpwZ1N6IHc6dz0iMTIyNDAiIHc6aD0iMTU4NDAi'
            + 'Lz4KICAgICAgPHc6cGdNYXIgdzp0b3A9IjE0NDAiIHc6cmlnaHQ9IjE0NDAiIHc6Ym90dG9tPSIxNDQwIiB3OmxlZnQ9IjE0NDAiIHc6aGVhZGVyPSI3MjAi'
            + 'IHc6Zm9vdGVyPSI3MjAiIHc6Z3V0dGVyPSIwIi8+CiAgICA8L3c6c2VjdFByPgogIDwvdzpib2R5Pgo8L3c6ZG9jdW1lbnQ+UEsBAhQDFAAAAAAAKTd4XNd5'
            + 'hOq4AQAAuAEAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQSwECFAMUAAAAAAApN3hcIBuG6i4BAAAuAQAACwAAAAAAAAAAAAAAgAHp'
            + 'AQAAX3JlbHMvLnJlbHNQSwECFAMUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAAAAAAAAAAAAgAFAAwAAd29yZC9fcmVscy9kb2N1bWVudC54bWwucmVsc1BL'
            + 'AQIUAxQAAAAAACk3eFxGcFSOQCcAAEAnAAARAAAAAAAAAAAAAACAARcEAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAABAAEAAMBAACGKwAAAAA='
        );

        // Template 3: Contact Card
        docxFiles.add(''
            + 'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu'
            + 'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi'
            + 'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u'
            + 'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h'
            + 'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv'
            + 'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w'
            + 'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54'
            + 'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFyxF3OmsRoAALEaAAARAAAAd29y'
            + 'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw'
            + 'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt'
            + 'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz'
            + 'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg'
            + 'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg'
            + 'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz'
            + 'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy'
            + 'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6'
            + 'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y'
            + 'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNDgiLz48dzpzekNzIHc6dmFsPSI0OCIvPjwvdzpyUHI+PHc6dD5DT05UQUNUIENBUkQ8L3c6dD48L3c6'
            + 'cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJjZW50ZXIiLz48dzpzcGFjaW5nIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpy'
            + 'UHI+PHc6aS8+PHc6Y29sb3Igdzp2YWw9IjZCNzI4MCIvPjx3OnN6IHc6dmFsPSIyMiIvPjx3OnN6Q3Mgdzp2YWw9IjIyIi8+PC93OnJQcj48dzp0PntGaXJz'
            + 'dE5hbWV9IHtMYXN0TmFtZX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJjZW50ZXIiLz48dzpzcGFjaW5nIHc6YWZ0'
            + 'ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6aS8+PHc6Y29sb3Igdzp2YWw9IjZCNzI4MCIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2'
            + 'YWw9IjIwIi8+PC93OnJQcj48dzp0PntUaXRsZX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBCZHI+PHc6Ym90dG9tIHc6dmFsPSJz'
            + 'aW5nbGUiIHc6c3o9IjYiIHc6c3BhY2U9IjEiIHc6Y29sb3I9IkQxRDVEQiIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzphZnRlcj0iMjAwIi8+PC93OnBQcj48'
            + 'L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRUZGNkZGIi8+PHc6c3BhY2luZyB3OmJl'
            + 'Zm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0i'
            + 'MjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5Db250YWN0IERldGFpbHM8L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3'
            + 'OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3'
            + 'OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPkVtYWlsOiA8L3c6dD48L3c6cj48'
            + 'dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e0Vt'
            + 'YWlsfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpy'
            + 'Pjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQg'
            + 'eG1sOnNwYWNlPSJwcmVzZXJ2ZSI+UGhvbmU6IDwvdzp0PjwvdzpyPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIxMTE4MjciLz48dzpzeiB3OnZhbD0i'
            + 'MjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57UGhvbmV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5n'
            + 'IHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZh'
            + 'bD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5Nb2JpbGU6IDwvdzp0PjwvdzpyPjx3OnI+PHc6'
            + 'clByPjx3OmNvbG9yIHc6dmFsPSIxMTE4MjciLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57TW9iaWxlUGhv'
            + 'bmV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpw'
            + 'PgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJFRkY2RkYiLz48dzpzcGFjaW5nIHc6YmVmb3Jl'
            + 'PSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjFFM0E4QSIvPjx3OnN6IHc6dmFsPSIyNiIv'
            + 'Pjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0Pk1haWxpbmcgQWRkcmVzczwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3Bh'
            + 'Y2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9'
            + 'IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+e01haWxpbmdTdHJlZXR9PC93OnQ+PC93OnI+PC93'
            + 'OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6'
            + 'dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57TWFp'
            + 'bGluZ0NpdHl9LCB7TWFpbGluZ1N0YXRlfSB7TWFpbGluZ1Bvc3RhbENvZGV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5n'
            + 'IHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0i'
            + 'YXV0byIgdzpmaWxsPSJFRkY2RkYiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+'
            + 'PHc6Y29sb3Igdzp2YWw9IjFFM0E4QSIvPjx3OnN6IHc6dmFsPSIyNiIvPjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0Pk9yZ2FuaXphdGlvbjwv'
            + 'dzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQ'
            + 'cj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNw'
            + 'YWNlPSJwcmVzZXJ2ZSI+Q29tcGFueTogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIv'
            + 'Pjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntBY2NvdW50Lk5hbWV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFj'
            + 'aW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3'
            + 'OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5JbmR1c3RyeTogPC93OnQ+PC93OnI+PHc6'
            + 'cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntBY2Nv'
            + 'dW50LkluZHVzdHJ5fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93'
            + 'OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRkVGM0M3Ii8+PHc6c3BhY2lu'
            + 'ZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI5MjQwMEUiLz48dzpzeiB3'
            + 'OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5Db21tdW5pY2F0aW9uIFByZWZlcmVuY2VzPC93OnQ+PC93OnI+PC93OnA+CiAg'
            + 'ICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsjSGFzT3B0ZWRPdXRPZkVtYWls'
            + 'fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJGRUYyRjIiLz48'
            + 'dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI5OTFCMUIiLz48'
            + 'dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5FbWFpbCBPcHQtT3V0OiBUaGlz'
            + 'IGNvbnRhY3QgaGFzIG9wdGVkIG91dCBvZiBlbWFpbCBjb21tdW5pY2F0aW9ucy48L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cj48dzpyUHI+PHc6'
            + 'c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+ey9IYXNPcHRlZE91dE9mRW1haWx9PC93OnQ+PC93OnI+PC93OnA+CiAg'
            + 'ICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsjRG9Ob3RDYWxsfTwvdzp0Pjwv'
            + 'dzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJGRUYyRjIiLz48dzpzcGFjaW5n'
            + 'IHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI5OTFCMUIiLz48dzpzeiB3OnZh'
            + 'bD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5EbyBOb3QgQ2FsbDogVGhpcyBjb250YWN0IGhh'
            + 'cyByZXF1ZXN0ZWQgbm8gcGhvbmUgY2FsbHMuPC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6'
            + 'Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsvRG9Ob3RDYWxsfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJl'
            + 'Zm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBCZHI+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6'
            + 'c3o9IjYiIHc6c3BhY2U9IjEiIHc6Y29sb3I9IkQxRDVEQiIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzphZnRlcj0iMjAwIi8+PC93OnBQcj48L3c6cD4KICAg'
            + 'IDx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJjZW50ZXIiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpy'
            + 'UHI+PHc6aS8+PHc6Y29sb3Igdzp2YWw9IjlDQTNBRiIvPjx3OnN6IHc6dmFsPSIxNiIvPjx3OnN6Q3Mgdzp2YWw9IjE2Ii8+PC93OnJQcj48dzp0IHhtbDpz'
            + 'cGFjZT0icHJlc2VydmUiPlJlY29yZCBjcmVhdGVkOiB7Q3JlYXRlZERhdGU6TU0vZGQveXl5eX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFBy'
            + 'Pjx3OmpjIHc6dmFsPSJjZW50ZXIiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6aS8+PHc6'
            + 'Y29sb3Igdzp2YWw9IjlDQTNBRiIvPjx3OnN6IHc6dmFsPSIxNiIvPjx3OnN6Q3Mgdzp2YWw9IjE2Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2Vy'
            + 'dmUiPkdlbmVyYXRlZCBvbiB7VE9EQVl9IHwgUG93ZXJlZCBieSBEb2NHZW48L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnNlY3RQcj4KICAgICAgPHc6cGdT'
            + 'eiB3Onc9IjEyMjQwIiB3Omg9IjE1ODQwIi8+CiAgICAgIDx3OnBnTWFyIHc6dG9wPSIxNDQwIiB3OnJpZ2h0PSIxNDQwIiB3OmJvdHRvbT0iMTQ0MCIgdzps'
            + 'ZWZ0PSIxNDQwIiB3OmhlYWRlcj0iNzIwIiB3OmZvb3Rlcj0iNzIwIiB3Omd1dHRlcj0iMCIvPgogICAgPC93OnNlY3RQcj4KICA8L3c6Ym9keT4KPC93OmRv'
            + 'Y3VtZW50PlBLAQIUAxQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAAAKTd4XCAb'
            + 'huouAQAALgEAAAsAAAAAAAAAAAAAAIAB6QEAAF9yZWxzLy5yZWxzUEsBAhQDFAAAAAAAKTd4XIwOhdCdAAAAnQAAABwAAAAAAAAAAAAAAIABQAMAAHdvcmQv'
            + 'X3JlbHMvZG9jdW1lbnQueG1sLnJlbHNQSwECFAMUAAAAAAApN3hcsRdzprEaAACxGgAAEQAAAAAAAAAAAAAAgAEXBAAAd29yZC9kb2N1bWVudC54bWxQSwUG'
            + 'AAAAAAQABAADAQAA9x4AAAAA'
        );

        // Template 4: Invoice
        docxFiles.add(''
            + 'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu'
            + 'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi'
            + 'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u'
            + 'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h'
            + 'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv'
            + 'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w'
            + 'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54'
            + 'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFxc6G9jCjkAAAo5AAARAAAAd29y'
            + 'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw'
            + 'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt'
            + 'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz'
            + 'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg'
            + 'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg'
            + 'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz'
            + 'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy'
            + 'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6'
            + 'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y'
            + 'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNTYiLz48dzpzekNzIHc6dmFsPSI1NiIvPjwvdzpyUHI+PHc6dD5JTlZPSUNFPC93OnQ+PC93OnI+PC93'
            + 'OnA+CiAgICA8dzpwPjx3OnBQcj48dzpwQmRyPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xlIiB3OnN6PSI2IiB3OnNwYWNlPSIxIiB3OmNvbG9yPSIxRTNBOEEi'
            + 'Lz48L3c6cEJkcj48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwMCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2'
            + 'MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6dGJsPjx3OnRibFByPjx3OnRibFcgdzp3PSIwIiB3OnR5cGU9ImF1dG8iLz48dzp0YmxC'
            + 'b3JkZXJzPjx3OnRvcCB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48dzpsZWZ0IHc6dmFsPSJzaW5nbGUi'
            + 'IHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNv'
            + 'bG9yPSJEMUQ1REIiLz48dzpyaWdodCB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48dzppbnNpZGVIIHc6'
            + 'dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3Omluc2lkZVYgdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpz'
            + 'cGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PC93OnRibEJvcmRlcnM+PC93OnRibFByPjx3OnRibEdyaWQ+PHc6Z3JpZENvbCB3Onc9IjQ2ODAiLz48dzpn'
            + 'cmlkQ29sIHc6dz0iNDY4MCIvPjwvdzp0YmxHcmlkPgogICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnRjQm9yZGVycz48dzp0b3Agdzp2YWw9Im5vbmUi'
            + 'IHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpsZWZ0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJh'
            + 'dXRvIi8+PHc6Ym90dG9tIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6cmlnaHQgdzp2YWw9Im5vbmUiIHc6'
            + 'c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48L3c6dGNCb3JkZXJzPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzphZnRlcj0i'
            + 'NDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI2QjcyODAiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFsPSIx'
            + 'OCIvPjwvdzpyUHI+PHc6dD5CSUxMIFRPPC93OnQ+PC93OnI+PC93OnA+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMCIvPjwvdzpwUHI+PHc6'
            + 'cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjFFM0E4QSIvPjx3OnN6IHc6dmFsPSIyMiIvPjx3OnN6Q3Mgdzp2YWw9IjIyIi8+PC93OnJQcj48dzp0'
            + 'PntBY2NvdW50Lk5hbWV9PC93OnQ+PC93OnI+PC93OnA+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+'
            + 'PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQ+e0FjY291bnQuQmlsbGluZ1N0cmVldH08L3c6dD48L3c6cj48L3c6'
            + 'cD48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFs'
            + 'PSIxOCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57QWNjb3VudC5CaWxsaW5nQ2l0eX0sIHtBY2NvdW50LkJpbGxpbmdTdGF0ZX0ge0Fj'
            + 'Y291bnQuQmlsbGluZ1Bvc3RhbENvZGV9PC93OnQ+PC93OnI+PC93OnA+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMCIvPjwvdzpwUHI+PHc6'
            + 'cj48dzpyUHI+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+UGhvbmU6IHtB'
            + 'Y2NvdW50LlBob25lfTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48dzp0Yz48dzp0Y1ByPjx3OnRjQm9yZGVycz48dzp0b3Agdzp2YWw9Im5vbmUiIHc6c3o9'
            + 'IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpsZWZ0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+'
            + 'PHc6Ym90dG9tIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6cmlnaHQgdzp2YWw9Im5vbmUiIHc6c3o9IjAi'
            + 'IHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48L3c6dGNCb3JkZXJzPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJyaWdodCIvPjx3OnNw'
            + 'YWNpbmcgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI2QjcyODAiLz48dzpzeiB3OnZhbD0iMTgiLz48'
            + 'dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD5JTlZPSUNFIERFVEFJTFM8L3c6dD48L3c6cj48L3c6cD48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0i'
            + 'cmlnaHQiLz48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFs'
            + 'PSIxOCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5JbnZvaWNlOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpzeiB3OnZhbD0iMTgi'
            + 'Lz48dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD57TmFtZX08L3c6dD48L3c6cj48L3c6cD48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0icmlnaHQi'
            + 'Lz48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFsPSIxOCIv'
            + 'PjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5EYXRlOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNz'
            + 'IHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD57Q2xvc2VEYXRlOk1NL2RkL3l5eXl9PC93OnQ+PC93OnI+PC93OnA+PHc6cD48dzpwUHI+PHc6amMgdzp2YWw9'
            + 'InJpZ2h0Ii8+PHc6c3BhY2luZyB3OmFmdGVyPSIyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZh'
            + 'bD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+U3RhdHVzOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpzeiB3OnZhbD0iMTgi'
            + 'Lz48dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD57U3RhZ2VOYW1lfTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48L3c6dHI+CiAgICA8L3c6dGJs'
            + 'PgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3'
            + 'OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRUZGNkZGIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAi'
            + 'Lz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIv'
            + 'PjwvdzpyUHI+PHc6dD5MaW5lIEl0ZW1zICh7Q09VTlQ6T3Bwb3J0dW5pdHlMaW5lSXRlbXN9IGl0ZW1zKTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48'
            + 'dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cj48dzpyUHI+PHc6c3ogdzp2'
            + 'YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+eyNPcHBvcnR1bml0eUxpbmVJdGVtc308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3'
            + 'OnRibD48dzp0YmxQcj48dzp0YmxXIHc6dz0iMCIgdzp0eXBlPSJhdXRvIi8+PHc6dGJsQm9yZGVycz48dzp0b3Agdzp2YWw9InNpbmdsZSIgdzpzej0iNCIg'
            + 'dzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6bGVmdCB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIi'
            + 'Lz48dzpib3R0b20gdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6cmlnaHQgdzp2YWw9InNpbmdsZSIg'
            + 'dzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6aW5zaWRlSCB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNv'
            + 'bG9yPSJEMUQ1REIiLz48dzppbnNpZGVWIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjwvdzp0YmxCb3Jk'
            + 'ZXJzPjwvdzp0YmxQcj48dzp0YmxHcmlkPjx3OmdyaWRDb2wgdzp3PSIzNjAwIi8+PHc6Z3JpZENvbCB3Onc9IjEyMDAiLz48dzpncmlkQ29sIHc6dz0iMjEw'
            + 'MCIvPjx3OmdyaWRDb2wgdzp3PSIyNTAwIi8+PC93OnRibEdyaWQ+CiAgICAgIDx3OnRyPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpj'
            + 'b2xvcj0iYXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0'
            + 'eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRj'
            + 'UHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2'
            + 'YWw9IkZGRkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlByb2R1Y3Q8L3c6dD48L3c6cj48L3c6cD48'
            + 'L3c6dGM+PHc6dGM+PHc6dGNQcj48dzpzaGQgdzp2YWw9ImNsZWFyIiB3OmNvbG9yPSJhdXRvIiB3OmZpbGw9IjFFM0E4QSIvPjx3OnRjTWFyPjx3OnRvcCB3'
            + 'Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpy'
            + 'aWdodCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVy'
            + 'PSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iRkZGRkZGIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0i'
            + 'MTgiLz48L3c6clByPjx3OnQ+UXR5PC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0i'
            + 'YXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJk'
            + 'eGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6'
            + 'cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZG'
            + 'RkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlVuaXQgUHJpY2U8L3c6dD48L3c6cj48L3c6cD48L3c6'
            + 'dGM+PHc6dGM+PHc6dGNQcj48dzpzaGQgdzp2YWw9ImNsZWFyIiB3OmNvbG9yPSJhdXRvIiB3OmZpbGw9IjFFM0E4QSIvPjx3OnRjTWFyPjx3OnRvcCB3Onc9'
            + 'IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpyaWdo'
            + 'dCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVyPSIw'
            + 'Ii8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iRkZGRkZGIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgi'
            + 'Lz48L3c6clByPjx3OnQ+VG90YWw8L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PC93OnRyPgogICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnRjTWFyPjx3'
            + 'OnRvcCB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEi'
            + 'Lz48dzpyaWdodCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3'
            + 'OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0i'
            + 'MTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+e1Byb2R1Y3QyLk5hbWV9PC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRj'
            + 'UHI+PHc6dGNNYXI+PHc6dG9wIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6Ym90dG9tIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6bGVmdCB3Onc9Ijgw'
            + 'IiB3OnR5cGU9ImR4YSIvPjx3OnJpZ2h0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PC93OnRjTWFyPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcg'
            + 'dzpiZWZvcmU9IjAiIHc6YWZ0ZXI9IjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMTgiLz48'
            + 'dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57UXVhbnRpdHk6bnVtYmVyfTwvdzp0PjwvdzpyPjwvdzpwPjwv'
            + 'dzp0Yz48dzp0Yz48dzp0Y1ByPjx3OnRjTWFyPjx3OnRvcCB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIv'
            + 'Pjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpyaWdodCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3'
            + 'OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6'
            + 'c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+e1VuaXRQcmljZTpjdXJyZW5jeX08'
            + 'L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3'
            + 'PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNN'
            + 'YXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Ig'
            + 'dzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntU'
            + 'b3RhbFByaWNlOmN1cnJlbmN5fTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48L3c6dHI+CiAgICA8L3c6dGJsPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2lu'
            + 'ZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cj48dzpyUHI+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD'
            + 'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+ey9PcHBvcnR1bml0eUxpbmVJdGVtc308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBC'
            + 'ZHI+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjYiIHc6c3BhY2U9IjEiIHc6Y29sb3I9IjFFM0E4QSIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzph'
            + 'ZnRlcj0iMjAwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRjhG'
            + 'QUZDIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIx'
            + 'RTNBOEEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5TdW1tYXJ5PC93OnQ+PC93OnI+PC93OnA+CiAgICA8'
            + 'dzp0Ymw+PHc6dGJsUHI+PHc6dGJsVyB3Onc9IjAiIHc6dHlwZT0iYXV0byIvPjx3OnRibEJvcmRlcnM+PHc6dG9wIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQi'
            + 'IHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OmxlZnQgdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURC'
            + 'Ii8+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OnJpZ2h0IHc6dmFsPSJzaW5nbGUi'
            + 'IHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3Omluc2lkZUggdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpj'
            + 'b2xvcj0iRDFENURCIi8+PHc6aW5zaWRlViB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6dGJsQm9y'
            + 'ZGVycz48L3c6dGJsUHI+PHc6dGJsR3JpZD48dzpncmlkQ29sIHc6dz0iNjAwMCIvPjx3OmdyaWRDb2wgdzp3PSIzMzYwIi8+PC93OnRibEdyaWQ+CiAgICAg'
            + 'IDx3OnRyPjx3OnRjPjx3OnRjUHI+PHc6dGNCb3JkZXJzPjx3OnRvcCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIv'
            + 'Pjx3OmxlZnQgdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpib3R0b20gdzp2YWw9Im5vbmUiIHc6c3o9IjAi'
            + 'IHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpyaWdodCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjwv'
            + 'dzp0Y0JvcmRlcnM+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6amMgdzp2YWw9InJpZ2h0Ii8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0i'
            + 'Mzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+SXRlbSBDb3VudDo8L3c6dD48L3c6cj48L3c6cD48'
            + 'L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y0JvcmRlcnM+PHc6dG9wIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+'
            + 'PHc6bGVmdCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OmJvdHRvbSB3OnZhbD0ibm9uZSIgdzpzej0iMCIg'
            + 'dzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OnJpZ2h0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PC93'
            + 'OnRjQm9yZGVycz48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0icmlnaHQiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIz'
            + 'NzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57Q09VTlQ6T3Bwb3J0dW5pdHlMaW5lSXRlbXM6bnVt'
            + 'YmVyfTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48L3c6dHI+CiAgICAgIDx3OnRyPjx3OnRjPjx3OnRjUHI+PHc6dGNCb3JkZXJzPjx3OnRvcCB3OnZhbD0i'
            + 'bm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OmxlZnQgdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29s'
            + 'b3I9ImF1dG8iLz48dzpib3R0b20gdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpyaWdodCB3OnZhbD0ibm9u'
            + 'ZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjwvdzp0Y0JvcmRlcnM+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6amMgdzp2YWw9InJp'
            + 'Z2h0Ii8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48'
            + 'L3c6clByPjx3OnQ+QXZlcmFnZSBQcmljZTo8L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y0JvcmRlcnM+PHc6dG9wIHc6dmFs'
            + 'PSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6bGVmdCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpj'
            + 'b2xvcj0iYXV0byIvPjx3OmJvdHRvbSB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OnJpZ2h0IHc6dmFsPSJu'
            + 'b25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PC93OnRjQm9yZGVycz48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0i'
            + 'cmlnaHQiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIv'
            + 'PjwvdzpyUHI+PHc6dD57QVZHOk9wcG9ydHVuaXR5TGluZUl0ZW1zLlVuaXRQcmljZTpjdXJyZW5jeX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PC93OnRy'
            + 'PgogICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnRjQm9yZGVycz48dzp0b3Agdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9'
            + 'ImF1dG8iLz48dzpsZWZ0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6Ym90dG9tIHc6dmFsPSJub25lIiB3'
            + 'OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6cmlnaHQgdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1'
            + 'dG8iLz48L3c6dGNCb3JkZXJzPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJyaWdodCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Ig'
            + 'dzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0Pkxvd2VzdCBQcmljZTo8L3c6dD48L3c6'
            + 'cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y0JvcmRlcnM+PHc6dG9wIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9y'
            + 'PSJhdXRvIi8+PHc6bGVmdCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OmJvdHRvbSB3OnZhbD0ibm9uZSIg'
            + 'dzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OnJpZ2h0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJh'
            + 'dXRvIi8+PC93OnRjQm9yZGVycz48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0icmlnaHQiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9y'
            + 'IHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57TUlOOk9wcG9ydHVuaXR5TGluZUl0'
            + 'ZW1zLlVuaXRQcmljZTpjdXJyZW5jeX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PC93OnRyPgogICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnRjQm9y'
            + 'ZGVycz48dzp0b3Agdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpsZWZ0IHc6dmFsPSJub25lIiB3OnN6PSIw'
            + 'IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6Ym90dG9tIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+'
            + 'PHc6cmlnaHQgdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48L3c6dGNCb3JkZXJzPjwvdzp0Y1ByPjx3OnA+PHc6'
            + 'cFByPjx3OmpjIHc6dmFsPSJyaWdodCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3'
            + 'OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PkhpZ2hlc3QgUHJpY2U6PC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6dGNC'
            + 'b3JkZXJzPjx3OnRvcCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OmxlZnQgdzp2YWw9Im5vbmUiIHc6c3o9'
            + 'IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpib3R0b20gdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8i'
            + 'Lz48dzpyaWdodCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjwvdzp0Y0JvcmRlcnM+PC93OnRjUHI+PHc6cD48'
            + 'dzpwUHI+PHc6amMgdzp2YWw9InJpZ2h0Ii8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+'
            + 'PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e01BWDpPcHBvcnR1bml0eUxpbmVJdGVtcy5Vbml0UHJpY2U6Y3VycmVuY3l9PC93OnQ+PC93OnI+'
            + 'PC93OnA+PC93OnRjPjwvdzp0cj4KICAgIDwvdzp0Ymw+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48'
            + 'L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzpqYyB3'
            + 'OnZhbD0icmlnaHQiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSIxMjAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Ig'
            + 'dzp2YWw9IkZGRkZGRiIvPjx3OnN6IHc6dmFsPSIyOCIvPjx3OnN6Q3Mgdzp2YWw9IjI4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPlRP'
            + 'VEFMIERVRTogICB7U1VNOk9wcG9ydHVuaXR5TGluZUl0ZW1zLlRvdGFsUHJpY2U6Y3VycmVuY3l9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQ'
            + 'cj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6cEJkcj48dzpib3R0b20g'
            + 'dzp2YWw9InNpbmdsZSIgdzpzej0iNiIgdzpzcGFjZT0iMSIgdzpjb2xvcj0iRDFENURCIi8+PC93OnBCZHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMDAiLz48'
            + 'L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSIwIi8+'
            + 'PC93OnBQcj48dzpyPjx3OnJQcj48dzppLz48dzpjb2xvciB3OnZhbD0iOUNBM0FGIi8+PHc6c3ogdzp2YWw9IjE2Ii8+PHc6c3pDcyB3OnZhbD0iMTYiLz48'
            + 'L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+R2VuZXJhdGVkIG9uIHtUT0RBWX0gfCBQb3dlcmVkIGJ5IERvY0dlbjwvdzp0PjwvdzpyPjwvdzpw'
            + 'PgogICAgPHc6c2VjdFByPgogICAgICA8dzpwZ1N6IHc6dz0iMTIyNDAiIHc6aD0iMTU4NDAiLz4KICAgICAgPHc6cGdNYXIgdzp0b3A9IjE0NDAiIHc6cmln'
            + 'aHQ9IjE0NDAiIHc6Ym90dG9tPSIxNDQwIiB3OmxlZnQ9IjE0NDAiIHc6aGVhZGVyPSI3MjAiIHc6Zm9vdGVyPSI3MjAiIHc6Z3V0dGVyPSIwIi8+CiAgICA8'
            + 'L3c6c2VjdFByPgogIDwvdzpib2R5Pgo8L3c6ZG9jdW1lbnQ+UEsBAhQDFAAAAAAAKTd4XNd5hOq4AQAAuAEAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50'
            + 'X1R5cGVzXS54bWxQSwECFAMUAAAAAAApN3hcIBuG6i4BAAAuAQAACwAAAAAAAAAAAAAAgAHpAQAAX3JlbHMvLnJlbHNQSwECFAMUAAAAAAApN3hcjA6F0J0A'
            + 'AACdAAAAHAAAAAAAAAAAAAAAgAFAAwAAd29yZC9fcmVscy9kb2N1bWVudC54bWwucmVsc1BLAQIUAxQAAAAAACk3eFxc6G9jCjkAAAo5AAARAAAAAAAAAAAA'
            + 'AACAARcEAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAABAAEAAMBAABQPQAAAAA='
        );

        // Template 5: Case Summary
        docxFiles.add(''
            + 'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu'
            + 'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi'
            + 'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u'
            + 'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h'
            + 'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv'
            + 'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w'
            + 'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54'
            + 'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz'
            + 'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s'
            + 'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFw5Oib1VhsAAFYbAAARAAAAd29y'
            + 'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw'
            + 'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt'
            + 'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz'
            + 'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn'
            + 'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg'
            + 'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg'
            + 'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz'
            + 'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy'
            + 'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6'
            + 'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y'
            + 'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNDgiLz48dzpzekNzIHc6dmFsPSI0OCIvPjwvdzpyUHI+PHc6dD5DQVNFIFJFUE9SVDwvdzp0Pjwvdzpy'
            + 'PjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iMTIwIi8+PC93OnBQcj48dzpyPjx3OnJQ'
            + 'cj48dzppLz48dzpjb2xvciB3OnZhbD0iNkI3MjgwIi8+PHc6c3ogdzp2YWw9IjIyIi8+PHc6c3pDcyB3OnZhbD0iMjIiLz48L3c6clByPjx3OnQ+Q2FzZSAj'
            + 'e0Nhc2VOdW1iZXJ9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpwQmRyPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xlIiB3OnN6PSI2IiB3'
            + 'OnNwYWNlPSIxIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6cEJkcj48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwMCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3'
            + 'OnBQcj48dzpzaGQgdzp2YWw9ImNsZWFyIiB3OmNvbG9yPSJhdXRvIiB3OmZpbGw9IkVGRjZGRiIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjI0MCIgdzphZnRl'
            + 'cj0iMTIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMUUzQThBIi8+PHc6c3ogdzp2YWw9IjI2Ii8+PHc6c3pDcyB3OnZh'
            + 'bD0iMjYiLz48L3c6clByPjx3OnQ+Q2FzZSBJbmZvcm1hdGlvbjwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9y'
            + 'ZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+'
            + 'PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+U3ViamVjdDogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6'
            + 'Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntTdWJqZWN0fTwvdzp0Pjwv'
            + 'dzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpi'
            + 'Lz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJw'
            + 'cmVzZXJ2ZSI+U3RhdHVzOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD'
            + 'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1N0YXR1c308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9'
            + 'IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3'
            + 'OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPlByaW9yaXR5OiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpj'
            + 'b2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1ByaW9yaXR5fTwvdzp0Pjwv'
            + 'dzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpi'
            + 'Lz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJw'
            + 'cmVzZXJ2ZSI+T3BlbmVkOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD'
            + 'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e0NyZWF0ZWREYXRlOk1NTU0gZGQsIHl5eXl9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48'
            + 'dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48'
            + 'dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5DbG9zZWQ6IDwvdzp0Pjwvdzpy'
            + 'Pjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIxMTE4MjciLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57'
            + 'Q2xvc2VkRGF0ZTpNTS9kZC95eXl5fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9'
            + 'IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRUZGNkZGIi8+'
            + 'PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxRTNBOEEi'
            + 'Lz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5DdXN0b21lcjwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48'
            + 'dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0'
            + 'MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+QWNjb3VudDogPC93'
            + 'OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQ'
            + 'cj48dzp0PntBY2NvdW50Lk5hbWV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0i'
            + 'NDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIy'
            + 'MCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5Db250YWN0OiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTEx'
            + 'ODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e0NvbnRhY3QuTmFtZX08L3c6dD48L3c6cj48L3c6cD4K'
            + 'ICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Ig'
            + 'dzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPkVt'
            + 'YWlsOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAi'
            + 'Lz48L3c6clByPjx3OnQ+e0NvbnRhY3QuRW1haWx9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIg'
            + 'dzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJF'
            + 'RkY2RkYiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9'
            + 'IjFFM0E4QSIvPjx3OnN6IHc6dmFsPSIyNiIvPjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0PkRlc2NyaXB0aW9uPC93OnQ+PC93OnI+PC93OnA+'
            + 'CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFs'
            + 'PSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57RGVzY3Jp'
            + 'cHRpb259PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwv'
            + 'dzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJGM0Y0RjYiLz48dzpzcGFjaW5nIHc6YmVm'
            + 'b3JlPSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIy'
            + 'NiIvPjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0PkJhcmNvZGUgKENvZGUgMTI4KTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+'
            + 'PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3og'
            + 'dzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+eypDYXNlTnVtYmVyfTwvdzp0Pjwvdzpy'
            + 'PjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6'
            + 'cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRjNGNEY2Ii8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVy'
            + 'PSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFs'
            + 'PSIyNiIvPjwvdzpyUHI+PHc6dD5RUiBDb2RlPC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzph'
            + 'ZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIy'
            + 'MCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57KkNhc2VOdW1iZXI6cXJ9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48'
            + 'dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6cEJkcj48dzpib3R0b20gdzp2'
            + 'YWw9InNpbmdsZSIgdzpzej0iNiIgdzpzcGFjZT0iMSIgdzpjb2xvcj0iRDFENURCIi8+PC93OnBCZHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMDAiLz48L3c6'
            + 'cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSIwIi8+PC93'
            + 'OnBQcj48dzpyPjx3OnJQcj48dzppLz48dzpjb2xvciB3OnZhbD0iOUNBM0FGIi8+PHc6c3ogdzp2YWw9IjE2Ii8+PHc6c3pDcyB3OnZhbD0iMTYiLz48L3c6'
            + 'clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+R2VuZXJhdGVkIG9uIHtUT0RBWTpNTU1NIGRkLCB5eXl5fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6'
            + 'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48'
            + 'dzppLz48dzpjb2xvciB3OnZhbD0iOUNBM0FGIi8+PHc6c3ogdzp2YWw9IjE2Ii8+PHc6c3pDcyB3OnZhbD0iMTYiLz48L3c6clByPjx3OnQgeG1sOnNwYWNl'
            + 'PSJwcmVzZXJ2ZSI+UG93ZXJlZCBieSBEb2NHZW48L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnNlY3RQcj4KICAgICAgPHc6cGdTeiB3Onc9IjEyMjQwIiB3'
            + 'Omg9IjE1ODQwIi8+CiAgICAgIDx3OnBnTWFyIHc6dG9wPSIxNDQwIiB3OnJpZ2h0PSIxNDQwIiB3OmJvdHRvbT0iMTQ0MCIgdzpsZWZ0PSIxNDQwIiB3Omhl'
            + 'YWRlcj0iNzIwIiB3OmZvb3Rlcj0iNzIwIiB3Omd1dHRlcj0iMCIvPgogICAgPC93OnNlY3RQcj4KICA8L3c6Ym9keT4KPC93OmRvY3VtZW50PlBLAQIUAxQA'
            + 'AAAAACk3eFzXeYTquAEAALgBAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAAAKTd4XCAbhuouAQAALgEAAAsAAAAA'
            + 'AAAAAAAAAIAB6QEAAF9yZWxzLy5yZWxzUEsBAhQDFAAAAAAAKTd4XIwOhdCdAAAAnQAAABwAAAAAAAAAAAAAAIABQAMAAHdvcmQvX3JlbHMvZG9jdW1lbnQu'
            + 'eG1sLnJlbHNQSwECFAMUAAAAAAApN3hcOTom9VYbAABWGwAAEQAAAAAAAAAAAAAAgAEXBAAAd29yZC9kb2N1bWVudC54bWxQSwUGAAAAAAQABAADAQAAnB8A'
            + 'AAAA'
        );

        // ---- Create records ----
        List<DocGen_Template__c> templates = new List<DocGen_Template__c>();
        for (Map<String, String> d : defs) {
            templates.add(new DocGen_Template__c(
                Name = d.get('name'),
                Base_Object_API__c = d.get('object'),
                Type__c = 'Word',
                Output_Format__c = 'PDF',
                Query_Config__c = d.get('config'),
                Category__c = d.get('category'),
                Description__c = d.get('desc')
            ));
        }
        insert templates; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets

        // Create ContentVersions (DOCX files) linked to templates
        List<ContentVersion> cvs = new List<ContentVersion>();
        for (Integer i = 0; i < templates.size(); i++) {
            cvs.add(new ContentVersion(
                Title = templates[i].Name,
                PathOnClient = templates[i].Name.replaceAll('[^a-zA-Z0-9]', '_') + '.docx',
                VersionData = EncodingUtil.base64Decode(docxFiles[i]),
                IsMajorVersion = true,
                FirstPublishLocationId = templates[i].Id
            ));
        }
        insert cvs; // NOPMD ApexCRUDViolation - ContentVersion insert; access controlled by DocGen permission sets
        // IDs are populated on the list after insert — no re-query needed
        // (re-querying breaks insertion order and mismatches CVs to templates)

        // Create active template versions with snapshot headers
        List<DocGen_Template_Version__c> versions = new List<DocGen_Template_Version__c>();
        for (Integer i = 0; i < templates.size(); i++) {
            versions.add(new DocGen_Template_Version__c(
                Template__c = templates[i].Id,
                Content_Version_Id__c = cvs[i].Id,
                Is_Active__c = true,
                Query_Config__c = templates[i].Query_Config__c,
                Category__c = templates[i].Category__c,
                Description__c = templates[i].Description__c,
                Type__c = templates[i].Type__c,
                Base_Object_API__c = templates[i].Base_Object_API__c
            ));
        }
        insert versions; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets

        // Extract and save template images for PDF rendering
        for (Integer i = 0; i < versions.size(); i++) {
            try {
                DocGenService.extractAndSaveTemplateImages(templates[i].Id, versions[i].Id);
            } catch (Exception imgErr) {
                System.debug(LoggingLevel.ERROR, 'Sample template image extraction failed for ' + templates[i].Name + ': ' + imgErr.getMessage());
            }
        }

        return templates.size();
    }
}
