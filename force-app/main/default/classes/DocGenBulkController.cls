public with sharing class DocGenBulkController {

    /**
     * Returns all DocGen templates for the bulk generation UI.
     * @return List of DocGen_Template__c records ordered by name
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getBulkTemplates() {
        return [SELECT Id, Name, Base_Object_API__c, Description__c, Output_Format__c, Query_Config__c, Test_Record_Id__c FROM DocGen_Template__c WITH SYSTEM_MODE ORDER BY Name];
    }

    /**
     * Validates a SOQL WHERE clause filter and returns the count of matching records.
     * @param objectName The SObject API name to query against
     * @param condition The WHERE clause condition to validate
     * @return The number of records matching the filter
     */
    @AuraEnabled
    public static Integer validateFilter(String objectName, String condition) {
        if (String.isBlank(objectName)) { return 0; }
        // Validate object name against Schema to prevent injection
        if (Schema.getGlobalDescribe().get(objectName) == null) {
            throw DocGenService.ahe('Invalid or inaccessible object.');
        }
        String sanitizedCondition = sanitizeCondition(condition);
        String query = 'SELECT Count() FROM ' + objectName;
        if (String.isNotBlank(sanitizedCondition)) {
            query += ' WHERE ' + sanitizedCondition;
        }
        query += ' WITH USER_MODE';
        return Database.countQuery(query); // NOPMD ApexSOQLInjection - inputs validated by sanitizeCondition() which rejects SOQL keywords and dangerous chars; runs with USER_MODE
    }

    /**
     * Basic sanitization of dynamic WHERE conditions to prevent SOQL injection.
     * Rejects conditions containing dangerous SOQL keywords that should never
     * appear in a WHERE clause fragment from the filter builder.
     */
    private static String sanitizeCondition(String condition) {
        if (String.isBlank(condition)) { return condition; }
        // Reject dangerous characters (statement termination, comments)
        if (condition.contains(';') || condition.contains('--') || condition.contains('/*')) {
            throw DocGenService.ahe('Invalid filter condition.');
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
                throw DocGenService.ahe('Invalid filter condition.');
            }
        }
        return condition;
    }

    /**
     * Analyzes a bulk job for governor limit risks before execution.
     * Checks SOQL queries, DML statements, heap (merge mode), and record count.
     * @param templateId The DocGen template record ID
     * @param recordCount Total number of records to be processed
     * @param batchSize Records per batch execution
     * @param mergePdf Whether merge mode is enabled
     * @return JobAnalysis with per-check results and overall verdict
     */
    @AuraEnabled
    public static JobAnalysis analyzeJob(Id templateId, Integer recordCount, Integer batchSize, Boolean mergePdf) {
        JobAnalysis analysis = new JobAnalysis();
        analysis.recordCount = recordCount;
        analysis.items = new List<AnalysisItem>();
        analysis.canProceed = true;

        if (templateId == null || recordCount == null || recordCount <= 0) {
            analysis.summary = 'No records to process.';
            return analysis;
        }

        Integer safeBatchSize = (batchSize != null && batchSize >= 1 && batchSize <= 200) ? batchSize : 1;
        Boolean isMerge = (mergePdf == true);

        try {
            DocGen_Template__c temp = [
                SELECT Query_Config__c, Test_Record_Id__c, Output_Format__c
                FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1
            ];

            // --- 1. SOQL Queries per batch execution ---
            Integer queriesPerRecord = countQueriesPerRecord(temp.Query_Config__c);
            // Overhead: template load (~3 queries first batch, cached after), job update (1)
            Integer overhead = 4;
            Integer soqlPerBatch = (queriesPerRecord * safeBatchSize) + overhead;
            Integer soqlLimit = 100; // async limit

            AnalysisItem soqlItem = new AnalysisItem();
            soqlItem.label = 'SOQL Queries';
            soqlItem.estimated = soqlPerBatch;
            soqlItem.limitVal = soqlLimit;
            if (soqlPerBatch >= soqlLimit) {
                soqlItem.status = 'error';
                soqlItem.message = soqlPerBatch + ' / ' + soqlLimit + ' per batch — will exceed limit. Reduce batch size to ' + Math.max(1, Math.floor((soqlLimit - overhead) / queriesPerRecord)) + ' or lower.';
                analysis.canProceed = false;
            } else if (soqlPerBatch >= 80) {
                soqlItem.status = 'warning';
                soqlItem.message = soqlPerBatch + ' / ' + soqlLimit + ' per batch — approaching limit. Consider reducing batch size.';
            } else {
                soqlItem.status = 'ok';
                soqlItem.message = soqlPerBatch + ' / ' + soqlLimit + ' per batch.';
            }
            analysis.items.add(soqlItem);

            // --- 2. DML Statements per batch execution ---
            // Each record: 1 CV insert. Merge mode: +1 HTML snippet CV per record. Job update: 1.
            Integer dmlPerRecord = isMerge ? 2 : 1;
            Integer dmlPerBatch = (dmlPerRecord * safeBatchSize) + 1;
            Integer dmlLimit = 150;

            AnalysisItem dmlItem = new AnalysisItem();
            dmlItem.label = 'DML Statements';
            dmlItem.estimated = dmlPerBatch;
            dmlItem.limitVal = dmlLimit;
            if (dmlPerBatch >= dmlLimit) {
                dmlItem.status = 'error';
                dmlItem.message = dmlPerBatch + ' / ' + dmlLimit + ' per batch — will exceed limit. Reduce batch size.';
                analysis.canProceed = false;
            } else if (dmlPerBatch >= 120) {
                dmlItem.status = 'warning';
                dmlItem.message = dmlPerBatch + ' / ' + dmlLimit + ' per batch — approaching limit.';
            } else {
                dmlItem.status = 'ok';
                dmlItem.message = dmlPerBatch + ' / ' + dmlLimit + ' per batch.';
            }
            analysis.items.add(dmlItem);

            // --- 3. Record Count ---
            AnalysisItem countItem = new AnalysisItem();
            countItem.label = 'Record Count';
            countItem.estimated = recordCount;
            countItem.limitVal = 50000;
            if (recordCount > 50000) {
                countItem.status = 'error';
                countItem.message = recordCount + ' records — exceeds 50,000 batch query locator limit.';
                analysis.canProceed = false;
            } else if (recordCount > 10000) {
                countItem.status = 'warning';
                countItem.message = recordCount + ' records — large job, may take a while.';
            } else {
                countItem.status = 'ok';
                countItem.message = recordCount + ' records.';
            }
            analysis.items.add(countItem);

            // --- 4. Heap (merge mode only) ---
            if (isMerge) {
                AnalysisItem heapItem = new AnalysisItem();
                heapItem.label = 'Merge Heap';
                heapItem.limitVal = 12;

                if (String.isNotBlank(temp.Test_Record_Id__c)) {
                    try {
                        String html = DocGenService.generateHtmlForRecord(templateId, temp.Test_Record_Id__c, null);
                        Long singleRecordBytes = html.length() * 2;
                        Decimal totalMb = ((singleRecordBytes * recordCount) * 1.25) / (1024.0 * 1024.0);
                        heapItem.estimated = totalMb.setScale(2);

                        if (totalMb >= 10.0) {
                            heapItem.status = 'error';
                            heapItem.message = totalMb.setScale(1) + 'MB / 12MB — high risk of heap failure. Reduce record count or disable merge.';
                            analysis.canProceed = false;
                        } else if (totalMb >= 7.0) {
                            heapItem.status = 'warning';
                            heapItem.message = totalMb.setScale(1) + 'MB / 12MB — moderate usage, monitor job.';
                        } else {
                            heapItem.status = 'ok';
                            heapItem.message = totalMb.setScale(1) + 'MB / 12MB — safe.';
                        }
                    } catch (Exception e) {
                        heapItem.status = 'warning';
                        heapItem.message = 'Could not estimate — no test record data available.';
                    }
                } else {
                    heapItem.status = 'warning';
                    heapItem.message = 'No test record on template — heap estimate unavailable.';
                }
                analysis.items.add(heapItem);
            }

            // --- Build summary ---
            Integer errors = 0;
            Integer warnings = 0;
            for (AnalysisItem item : analysis.items) {
                if (item.status == 'error') { errors++; }
                else if (item.status == 'warning') { warnings++; }
            }
            if (errors > 0) {
                analysis.summary = 'Cannot proceed — ' + errors + ' limit(s) will be exceeded.';
            } else if (warnings > 0) {
                analysis.summary = 'Should work, but ' + warnings + ' item(s) need attention.';
            } else {
                analysis.summary = 'All checks passed. Safe to proceed.';
            }

        } catch (Exception e) {
            analysis.summary = 'Analysis error: ' + e.getMessage();
        }
        return analysis;
    }

    /**
     * Counts the number of SOQL queries needed per record based on the query config format.
     */
    private static Integer countQueriesPerRecord(String queryConfig) {
        if (String.isBlank(queryConfig)) { return 1; }
        if (!queryConfig.trim().startsWith('{')) { return 1; } // V1 flat string

        try {
            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(queryConfig);
            Object versionObj = config.get('v');
            Integer version = (versionObj instanceof Integer) ? (Integer) versionObj : ((Decimal) versionObj).intValue();

            if (version == 2) {
                // V2: 1 base + children + junctions
                Integer count = 1;
                List<Object> children = (List<Object>) config.get('children');
                if (children != null) { count += children.size(); }
                List<Object> junctions = (List<Object>) config.get('junctions');
                if (junctions != null) { count += junctions.size() * 2; } // junction query + target query
                return count;
            } else if (version == 3) {
                // V3: one query per node
                List<Object> nodes = (List<Object>) config.get('nodes');
                return (nodes != null) ? nodes.size() : 1;
            }
        } catch (Exception e) { // NOPMD EmptyCatchBlock — intentional fallback to 1 query for unparseable configs
            System.debug(LoggingLevel.FINE, 'Query config parse failed, defaulting to 1: ' + e.getMessage());
        }
        return 1;
    }

    public class JobAnalysis {
        @AuraEnabled public Integer recordCount;
        @AuraEnabled public Boolean canProceed = true;
        @AuraEnabled public List<AnalysisItem> items;
        @AuraEnabled public String summary;
    }

    public class AnalysisItem {
        @AuraEnabled public String label;
        @AuraEnabled public String status;   // 'ok', 'warning', 'error'
        @AuraEnabled public String message;
        @AuraEnabled public Decimal estimated;
        @AuraEnabled public Decimal limitVal;
    }

    // Keep for backward compatibility — delegates to analyzeJob
    @AuraEnabled
    public static HeapEstimate estimateHeapUsage(Id templateId, Integer recordCount) {
        JobAnalysis analysis = analyzeJob(templateId, recordCount, 1, true);
        HeapEstimate estimate = new HeapEstimate();
        for (AnalysisItem item : analysis.items) {
            if (item.label == 'Merge Heap') {
                estimate.estimatedHeapMb = item.estimated;
                estimate.isRisk = (item.status == 'error');
                estimate.message = item.message;
                return estimate;
            }
        }
        estimate.message = analysis.summary;
        return estimate;
    }

    public class HeapEstimate {
        @AuraEnabled public Decimal estimatedHeapMb;
        @AuraEnabled public Boolean isRisk = false;
        @AuraEnabled public String message;
    }

    /**
     * Submits a bulk document generation job for async processing.
     * @param templateId The DocGen template record ID
     * @param condition Optional SOQL WHERE clause to filter records
     * @param jobLabel Optional human-readable label for the job
     * @param mergePdf Whether to merge all outputs into a single PDF
     * @param batchSize Number of records per batch execution (1-200)
     * @param mergeOnly Whether to only generate merged PDF without individual files
     * @return The DocGen_Job__c record ID
     */
    @AuraEnabled
    public static Id submitJob(Id templateId, String condition, String jobLabel, Boolean mergePdf, Integer batchSize, Boolean mergeOnly) {
        try {
            Boolean isMergeOnly = (mergeOnly == true);
            Boolean isMergeMode = (mergePdf == true) || isMergeOnly;

            // 1. Create Job Record
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = templateId,
                Query_Condition__c = condition,
                Label__c = String.isNotBlank(jobLabel) ? jobLabel : null,
                Status__c = 'Queued',
                Merge_Only__c = isMergeOnly
            );
            // Package-internal object — CRUD controlled by DocGen permission sets
            insert job; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets

            // 2. Run Batch — user-configurable batch size (default 1, max 200)
            Integer size = (batchSize != null && batchSize >= 1 && batchSize <= 200) ? batchSize : 1;
            DocGenBatch batch = new DocGenBatch(job.Id, isMergeMode, isMergeOnly);
            Database.executeBatch(batch, size);

            return job.Id;
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error starting bulk generation job.');
        }
    }

    /**
     * Returns the current status and progress of a bulk generation job.
     * @param jobId The DocGen_Job__c record ID
     * @return The job record with status and count fields
     */
    @AuraEnabled
    public static DocGen_Job__c getJobStatus(Id jobId) {
        return [SELECT Id, Name, Status__c, Success_Count__c, Error_Count__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE];
    }

    /**
     * Returns the 20 most recent bulk generation jobs ordered by creation date.
     * @return List of DocGen_Job__c records with status and template info
     */
    @AuraEnabled
    public static List<DocGen_Job__c> getRecentJobs() {
        return [
            SELECT Id, Name, Label__c, Status__c, Success_Count__c, Error_Count__c, Total_Records__c,
                   CreatedDate, Template__r.Name, Template__r.Output_Format__c
            FROM DocGen_Job__c
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];
    }

    /**
     * Returns ContentVersion IDs for PDFs generated by a completed bulk job.
     * Queries the same records the job processed, finds PDFs created after the job started.
     * @param jobId The DocGen_Job__c record ID
     * @return List of maps with 'label' (file title) and 'value' (ContentVersion ID)
     */
    @AuraEnabled
    public static List<Map<String, String>> getJobGeneratedPdfs(Id jobId) {
        DocGen_Job__c job = [
            SELECT Template__c, Template__r.Base_Object_API__c, Template__r.Name,
                   Query_Condition__c, CreatedDate
            FROM DocGen_Job__c WHERE Id = :jobId WITH SYSTEM_MODE
        ];

        String baseObject = job.Template__r.Base_Object_API__c;
        if (Schema.getGlobalDescribe().get(baseObject) == null) {
            throw DocGenService.ahe('Invalid base object on job template.');
        }

        // Query the same records the batch processed
        String recQuery = 'SELECT Id FROM ' + String.escapeSingleQuotes(baseObject);
        String condition = sanitizeCondition(job.Query_Condition__c);
        if (String.isNotBlank(condition)) {
            recQuery += ' WHERE ' + condition;
        }
        recQuery += ' WITH USER_MODE LIMIT 2000';

        Set<Id> recordIds = new Set<Id>();
        for (SObject rec : Database.query(recQuery)) {
            recordIds.add(rec.Id);
        }

        if (recordIds.isEmpty()) { return new List<Map<String, String>>(); }

        // Find PDFs attached to those records created after the job was created
        Datetime jobStart = job.CreatedDate.addMinutes(-1);
        List<ContentDocumentLink> links = [
            SELECT ContentDocument.LatestPublishedVersionId,
                   ContentDocument.Title, LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :recordIds
            AND ContentDocument.FileExtension = 'pdf'
            AND ContentDocument.CreatedDate >= :jobStart
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

    // --- Saved Queries ---
    /**
     * Returns saved filter queries for a template, ordered by creation date descending.
     * @param templateId The DocGen template record ID
     * @return List of DocGen_Saved_Query__c records
     */
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

    /**
     * Saves a named filter query for reuse with a template.
     * @param templateId The DocGen template record ID
     * @param label The display name for the saved query
     * @param description Optional description of the query
     * @param condition The SOQL WHERE clause condition
     */
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
            insert sq; // NOPMD ApexCRUDViolation - package-internal custom object; access controlled by DocGen permission sets
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error saving query.');
        }
    }

    /**
     * Deletes a saved filter query.
     * @param queryId The DocGen_Saved_Query__c record ID to delete
     */
    @AuraEnabled
    public static void deleteQuery(Id queryId) {
        try {
            if (!Schema.sObjectType.DocGen_Saved_Query__c.isDeletable()) {
                throw DocGenService.ahe('Insufficient access.');
            }
            delete new DocGen_Saved_Query__c(Id = queryId);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error deleting query.');
        }
    }
}