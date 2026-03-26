public with sharing class DocGenTemplateManager {

    /**
     * Retrieves the ContentVersion Blob for the latest file attached to the DocGen Template.
     * @param templateId The ID of the DocGen_Template__c record.
     * @return String Base64 encoded file data.
     */
    public static String getTemplateFileContent(Id templateId) {
        if (templateId == null) {
             throw DocGenService.ahe('Template ID is required.');
        }

        // 1. Check for Active Version first
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId
            AND Is_Active__c = true
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        Id targetCvId = null;

        if (!activeVersions.isEmpty()) {
            targetCvId = activeVersions[0].Content_Version_Id__c;
        }

        // Fallback: If no active version OR active version has null CV ID (legacy/broken data)
        if (targetCvId == null) {
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :templateId
                WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate DESC
                LIMIT 1
            ];

            if (!links.isEmpty()) {
                 // Get latest ContentVersion for this document
                List<ContentVersion> cvs = [
                    SELECT Id
                    FROM ContentVersion
                    WHERE ContentDocumentId = :links[0].ContentDocumentId
                    AND IsLatest = true
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!cvs.isEmpty()) {
                    targetCvId = cvs[0].Id;
                }
            }
        }

        if (targetCvId == null) {
            throw DocGenService.ahe('No template file found (active or attached).');
        }

        // Get the specific ContentVersion
        List<ContentVersion> cvs = [
            SELECT VersionData, Title, FileExtension
            FROM ContentVersion
            WHERE Id = :targetCvId
            WITH USER_MODE
            LIMIT 1
        ];

        if (cvs.isEmpty()) {
            throw DocGenService.ahe('ContentVersion not found.');
        }

        return EncodingUtil.base64Encode(cvs[0].VersionData);
    }
}