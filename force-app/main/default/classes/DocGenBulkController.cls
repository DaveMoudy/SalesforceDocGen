public with sharing class DocGenBulkController {

    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getBulkTemplates() {
        return [SELECT Id, Name, Base_Object_API__c, Description__c, Output_Format__c, Query_Config__c, Test_Record_Id__c FROM DocGen_Template__c WITH SYSTEM_MODE ORDER BY Name];
    }

    @AuraEnabled
    public static Integer validateFilter(String objectName, String condition) {
        if (String.isBlank(objectName)) return 0;
        // Validate object name against Schema to prevent injection
        if (Schema.getGlobalDescribe().get(objectName) == null) {
            throw new AuraHandledException('Invalid or inaccessible object.');
        }
        String sanitizedCondition = sanitizeCondition(condition);
        String query = 'SELECT Count() FROM ' + objectName;
        if (String.isNotBlank(sanitizedCondition)) {
            query += ' WHERE ' + sanitizedCondition;
        }
        query += ' WITH USER_MODE';
        return Database.countQuery(query);
    }

    /**
     * Basic sanitization of dynamic WHERE conditions to prevent SOQL injection.
     * Rejects conditions containing dangerous SOQL keywords that should never
     * appear in a WHERE clause fragment from the filter builder.
     */
    private static String sanitizeCondition(String condition) {
        if (String.isBlank(condition)) return condition;
        // Reject dangerous characters (statement termination, comments)
        if (condition.contains(';') || condition.contains('--') || condition.contains('/*')) {
            throw new AuraHandledException('Invalid filter condition.');
        }
        // Normalize whitespace for keyword matching (tabs, newlines, multiple spaces → single space)
        String normalized = condition.replaceAll('\\s+', ' ').toUpperCase().trim();
        // Reject conditions containing SOQL/DML keywords that don't belong in a WHERE clause
        List<String> disallowed = new List<String>{
            'SELECT ', 'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'UNDELETE ',
            'WITH ', 'GROUP BY ', 'ORDER BY ', 'LIMIT ', 'OFFSET ', 'FOR UPDATE',
            'HAVING ', 'TYPEOF '
        };
        for (String keyword : disallowed) {
            if (normalized.contains(keyword)) {
                throw new AuraHandledException('Invalid filter condition.');
            }
        }
        return condition;
    }

    @AuraEnabled
    public static Id submitJob(Id templateId, String condition) {
        try {
            // 1. Create Job Record
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = templateId,
                Query_Condition__c = condition,
                Status__c = 'Queued'
            );
            // Package-internal object — CRUD controlled by DocGen permission sets
            insert job;

            // 2. Run Batch
            // Batch Size 1: each record needs its own transaction so callouts
            // (rich text image resolution) happen before DML (ContentVersion insert).
            // Salesforce blocks callouts after uncommitted DML in the same transaction.
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);

            return job.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error starting job: ' + e.getMessage());
            throw new AuraHandledException('Error starting bulk generation job.');
        }
    }

    @AuraEnabled
    public static DocGen_Job__c getJobStatus(Id jobId) {
        return [SELECT Id, Name, Status__c, Success_Count__c, Error_Count__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE];
    }

    @AuraEnabled
    public static List<DocGen_Job__c> getRecentJobs() {
        return [
            SELECT Id, Name, Status__c, Success_Count__c, Error_Count__c, Total_Records__c, CreatedDate, Template__r.Name
            FROM DocGen_Job__c
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];
    }

    // --- Saved Queries ---
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Saved_Query__c> getSavedQueries(Id templateId) {
        return [
            SELECT Id, Name, Description__c, Query_Condition__c
            FROM DocGen_Saved_Query__c
            WHERE DocGen_Template__c = :templateId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    @AuraEnabled
    public static void saveQuery(Id templateId, String label, String description, String condition) {
        try {
            DocGen_Saved_Query__c sq = new DocGen_Saved_Query__c(
                DocGen_Template__c = templateId,
                Name = label,
                Description__c = description,
                Query_Condition__c = condition
            );
            // Package-internal object — CRUD controlled by DocGen permission sets
            insert sq;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error saving query: ' + e.getMessage());
            throw new AuraHandledException('Error saving query.');
        }
    }

    @AuraEnabled
    public static void deleteQuery(Id queryId) {
        try {
            if (!Schema.sObjectType.DocGen_Saved_Query__c.isDeletable()) {
                throw new AuraHandledException('Insufficient access.');
            }
            delete new DocGen_Saved_Query__c(Id = queryId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error deleting query: ' + e.getMessage());
            throw new AuraHandledException('Error deleting query.');
        }
    }
}