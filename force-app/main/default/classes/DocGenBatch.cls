public with sharing class DocGenBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {
    
    public Id jobId;
    public Id templateId;
    public String baseObject;
    public String condition;
    
    public Integer successCount = 0;
    public Integer failCount = 0;
    
    public DocGenBatch(Id jobId) {
        this.jobId = jobId;
        DocGen_Job__c job = [SELECT Template__c, Template__r.Base_Object_API__c, Query_Condition__c FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE];
        this.templateId = job.Template__c;
        this.baseObject = job.Template__r.Base_Object_API__c;
        this.condition = job.Query_Condition__c;
    }
    
    public Database.QueryLocator start(Database.BatchableContext BC) {
        // Update Status to Processing
        update new DocGen_Job__c(Id = jobId, Status__c = 'Processing');

        // Validate object name against Schema to prevent injection
        if (Schema.getGlobalDescribe().get(baseObject) == null) {
            throw new DocGenException('Invalid object: ' + baseObject);
        }

        String sanitizedCondition = sanitizeCondition(condition);
        String query = 'SELECT Id FROM ' + baseObject;
        if (String.isNotBlank(sanitizedCondition)) {
            query += ' WHERE ' + sanitizedCondition;
        }
        query += ' WITH USER_MODE';

        // Count total records for progress tracking
        String countQuery = 'SELECT Count() FROM ' + baseObject;
        if (String.isNotBlank(sanitizedCondition)) {
            countQuery += ' WHERE ' + sanitizedCondition;
        }
        countQuery += ' WITH USER_MODE';
        Integer total = Database.countQuery(countQuery);
        update new DocGen_Job__c(Id = jobId, Status__c = 'Processing', Total_Records__c = total);

        return Database.getQueryLocator(query);
    }

    /**
     * Basic sanitization of dynamic WHERE conditions to prevent SOQL injection.
     */
    private static String sanitizeCondition(String condition) {
        if (String.isBlank(condition)) return condition;
        // Reject dangerous characters (statement termination, comments)
        if (condition.contains(';') || condition.contains('--') || condition.contains('/*')) {
            throw new DocGenException('Invalid filter condition.');
        }
        String upper = condition.toUpperCase().trim();
        List<String> disallowed = new List<String>{
            'SELECT ', 'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'UNDELETE ',
            'WITH ', 'GROUP BY ', 'ORDER BY ', 'LIMIT ', 'OFFSET ', 'FOR UPDATE',
            'HAVING ', 'TYPEOF '
        };
        for (String keyword : disallowed) {
            if (upper.contains(keyword)) {
                throw new DocGenException('Invalid filter condition.');
            }
        }
        return condition;
    }
    
    public void execute(Database.BatchableContext BC, List<SObject> scope) {
        for (SObject rec : scope) {
            try {
                DocGenService.generateDocument(templateId, rec.Id);
                successCount++;
            } catch (Exception e) {
                failCount++;
                System.debug('DocGen Batch Error for ' + rec.Id + ': ' + e.getMessage());
            }
        }
        
        // Update Job record incrementally for real-time progress tracking
        update new DocGen_Job__c(
            Id = jobId,
            Success_Count__c = successCount,
            Error_Count__c = failCount
        );

        // Flush collected PDF rendition jobs (one per batch execute)
        // Direct enqueuing preserves the user's auth context for loopback callouts
        DocGenRenditionService.enqueueRenditions(true);
    }
    
    public void finish(Database.BatchableContext BC) {
        String status;
        if (successCount == 0 && failCount > 0) {
            status = 'Failed';
        } else if (failCount > 0) {
            status = 'Completed with Errors';
        } else {
            status = 'Completed';
        }

        DocGen_Job__c jobToUpdate = new DocGen_Job__c(
            Id = jobId,
            Status__c = status,
            Success_Count__c = successCount,
            Error_Count__c = failCount
        );
        update jobToUpdate;
    }
}