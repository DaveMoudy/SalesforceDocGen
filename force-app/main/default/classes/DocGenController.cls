public with sharing class DocGenController {
    
    @AuraEnabled
    public static Map<String, Object> generateDocumentData(Id templateId, Id recordId) {
        if (templateId == null) throw new AuraHandledException('Template ID is missing.');
        
        List<DocGen_Template__c> templates = [
            SELECT Base_Object_API__c, Query_Config__c, Type__c, Output_Format__c, Document_Title_Format__c
            FROM DocGen_Template__c 
            WHERE Id = :templateId 
            WITH USER_MODE
            LIMIT 1
        ];
        
        if (templates.isEmpty()) {
            throw new AuraHandledException('Template not found or you do not have access.');
        }
        DocGen_Template__c template = templates[0];
        
        Map<String, Object> recordData = DocGenDataRetriever.getRecordData(
            recordId, 
            template.Base_Object_API__c, 
            template.Query_Config__c
        );
        
        String fileContent = DocGenTemplateManager.getTemplateFileContent(templateId);
        
        if (recordData == null) {
            throw new AuraHandledException('Record data not found.');
        }

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
            insert cv;

            Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH SYSTEM_MODE].ContentDocumentId;

            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = contentDocId;
            cdl.LinkedEntityId = recordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            insert cdl;

            return contentDocId;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving document to record: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> previewRecordData(Id recordId, String baseObject, String queryConfig) {
        if (recordId == null || String.isBlank(baseObject) || String.isBlank(queryConfig)) {
            return null;
        }
        
        try {
            return DocGenDataRetriever.getRecordData(recordId, baseObject, queryConfig);
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching preview data: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getTemplatesForObject(String objectApiName) {
        return [
            SELECT Id, Name, Description__c, Type__c 
            FROM DocGen_Template__c 
            WHERE Base_Object_API__c = :objectApiName
            WITH USER_MODE
        ];
    }
    
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getAllTemplates() {
        return [
            SELECT Id, Name, Description__c, Type__c, Base_Object_API__c, Category__c, Query_Config__c, Test_Record_Id__c, Output_Format__c, Document_Title_Format__c,
                   (SELECT ContentDocumentId FROM ContentDocumentLinks ORDER BY ContentDocument.CreatedDate DESC LIMIT 1)
            FROM DocGen_Template__c 
            WITH USER_MODE
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
            
            update template;
            
            // Update Output Format if provided
            if (fields.containsKey('Output_Format__c')) {
                template.Output_Format__c = (String) fields.get('Output_Format__c');
                update template;
            }
            
            // 2. Create Version if requested
            if (createVersion == true) {
                // Deactivate current active versions
                List<DocGen_Template_Version__c> activeVersions = [
                    SELECT Id FROM DocGen_Template_Version__c 
                    WHERE Template__c = :templateId AND Is_Active__c = true
                    WITH USER_MODE
                ];
                for (DocGen_Template_Version__c av : activeVersions) {
                    av.Is_Active__c = false;
                }
                update activeVersions;

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
                
                insert version;
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error saving template: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteTemplate(Id templateId) {
        try {
            DocGen_Template__c template = new DocGen_Template__c(Id = templateId);
            delete template;
        } catch (Exception e) {
            throw new AuraHandledException('Error deleting template: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static List<DocGen_Template_Version__c> getTemplateVersions(Id templateId) {
        return [
            SELECT Id, Name, CreatedDate, CreatedBy.Name, Query_Config__c, Content_Version_Id__c, 
                   Category__c, Description__c, Type__c, Base_Object_API__c, Is_Active__c
            FROM DocGen_Template_Version__c 
            WHERE Template__c = :templateId 
            WITH USER_MODE
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
                WITH USER_MODE
                LIMIT 1
            ];
            
            // 1. Deactivate others
            List<DocGen_Template_Version__c> others = [
                SELECT Id FROM DocGen_Template_Version__c 
                WHERE Template__c = :version.Template__c AND Is_Active__c = true
                WITH USER_MODE
            ];
            for (DocGen_Template_Version__c v : others) {
                v.Is_Active__c = false;
            }
            update others;
            
            // 2. Activate this one
            version.Is_Active__c = true;
            update version;
            
            // 3. Update Template Record Headline
            DocGen_Template__c template = new DocGen_Template__c(Id = version.Template__c);
            template.Query_Config__c = version.Query_Config__c;
            template.Category__c = version.Category__c;
            template.Description__c = version.Description__c;
            template.Type__c = version.Type__c;
            // Base Object usually constant but update it anyway
            template.Base_Object_API__c = version.Base_Object_API__c;
            
            update template;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error activating version: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static String saveTempHtml(String htmlContent, String fileName) {
        try {
            ContentVersion cv = new ContentVersion();
            cv.Title = fileName;
            cv.PathOnClient = fileName + '.html';
            cv.VersionData = Blob.valueOf(htmlContent);
            cv.Description = 'Temp DocGen HTML for PDF Rendering';
            cv.IsMajorVersion = false;
            insert cv;
            
            return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE].ContentDocumentId;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving temp HTML: ' + e.getMessage());
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
            if (describe.isAccessible() && describe.isFilterable()) {
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
            'WHERE ParentId = :templateId AND RowCause != \'Owner\''
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
            insert share;
        } catch (DmlException e) {
            throw new AuraHandledException('Error sharing template: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void removeShare(Id shareId) {
        try {
            DocGen_Template__Share shareToDelete = new DocGen_Template__Share(Id = shareId);
            delete shareToDelete;
        } catch (DmlException e) {
            throw new AuraHandledException('Error removing share: ' + e.getMessage());
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
}