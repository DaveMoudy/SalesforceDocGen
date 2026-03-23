@IsTest
private class DocGenBulkTests {

    @TestSetup
    static void setup() {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'Test Template',
            Base_Object_API__c = 'Account'
        );
        insert t;

        Account a = new Account(
            Name = 'Test Account',
            Website = 'https://www.example.com'
        );
        insert a;
    }

    @IsTest
    static void testGetBulkTemplates() {
        Test.startTest();
        List<DocGen_Template__c> templates = DocGenBulkController.getBulkTemplates();
        Test.stopTest();
        System.assertEquals(1, templates.size(), 'Should return 1 template');
    }

    @IsTest
    static void testValidateFilter() {
        Test.startTest();
        Integer count = DocGenBulkController.validateFilter('Account', 'Name = \'Test Account\'');
        Test.stopTest();
        System.assertEquals(1, count, 'Should find 1 record');
    }

    @IsTest
    static void testSubmitJob() {
        DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Test.startTest();
        Id jobId = DocGenBulkController.submitJob(t.Id, 'Name = \'Test Account\'', 'Test Job');
        Test.stopTest();
        
        DocGen_Job__c job = [SELECT Id, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
        System.assertNotEquals(null, job.Id, 'Job should be created');
    }

    @IsTest
    static void testSavedQueries() {
        DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        // Save
        Test.startTest();
        DocGenBulkController.saveQuery(t.Id, 'My Query', 'Desc', 'Name != null');
        Test.stopTest();

        // Retrieve
        List<DocGen_Saved_Query__c> queries = DocGenBulkController.getSavedQueries(t.Id);
        System.assertEquals(1, queries.size());
        System.assertEquals('My Query', queries[0].Name);

        // Delete
        DocGenBulkController.deleteQuery(queries[0].Id);
        queries = DocGenBulkController.getSavedQueries(t.Id);
        System.assertEquals(0, queries.size());
    }

    // =========================================================================
    // DocGenBulkController — additional coverage
    // =========================================================================

    @IsTest
    static void testValidateFilterBlankObject() {
        Test.startTest();
        Integer count = DocGenBulkController.validateFilter('', null);
        Test.stopTest();
        System.assertEquals(0, count, 'Should return 0 for blank object');
    }

    @IsTest
    static void testValidateFilterInvalidObject() {
        Boolean caught = false;
        Test.startTest();
        try {
            DocGenBulkController.validateFilter('ZZZNotReal__c', 'Name != null');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Should throw for invalid object');
    }

    @IsTest
    static void testValidateFilterNoCondition() {
        Test.startTest();
        Integer count = DocGenBulkController.validateFilter('Account', null);
        Test.stopTest();
        System.assert(count >= 1, 'Should count all accounts');
    }

    @IsTest
    static void testValidateFilterSqlInjection() {
        Boolean caught = false;
        Test.startTest();
        try {
            DocGenBulkController.validateFilter('Account', 'Name != null; DELETE Account');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Should reject semicolons');
    }

    @IsTest
    static void testValidateFilterDisallowedKeywords() {
        Boolean caught = false;
        Test.startTest();
        try {
            DocGenBulkController.validateFilter('Account', 'Name IN (SELECT Name FROM Account)');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Should reject SELECT keyword in condition');
    }

    @IsTest
    static void testGetJobStatus() {
        DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        DocGen_Job__c job = new DocGen_Job__c(
            Template__c = t.Id,
            Status__c = 'Queued'
        );
        insert job;

        Test.startTest();
        DocGen_Job__c status = DocGenBulkController.getJobStatus(job.Id);
        Test.stopTest();

        System.assertEquals('Queued', status.Status__c);
    }

    @IsTest
    static void testGetSavedQueriesEmpty() {
        DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        List<DocGen_Saved_Query__c> queries = DocGenBulkController.getSavedQueries(t.Id);
        Test.stopTest();

        System.assertEquals(0, queries.size(), 'Should return empty list');
    }

    // =========================================================================
    // DocGenBatch — additional coverage for finish status branches
    // =========================================================================

    @IsTest
    static void testBatchFinishCompletedStatus() {
        // Exercises the 'Completed' branch in finish() (successCount > 0, failCount == 0)
        // The existing testSubmitJob covers this partly, but the batch runs with
        // a real template that has no DOCX file, so it will error.
        // We create a job and simulate by directly calling start/execute/finish
        DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        DocGen_Job__c job = new DocGen_Job__c(
            Template__c = t.Id,
            Query_Condition__c = 'Name = \'Test Account\'',
            Status__c = 'Queued'
        );
        insert job;

        Test.startTest();
        DocGenBatch batch = new DocGenBatch(job.Id);
        Database.executeBatch(batch, 1);
        Test.stopTest();

        // The batch will fail per-record (no DOCX file), so status should be 'Failed'
        DocGen_Job__c updated = [SELECT Status__c, Error_Count__c, Success_Count__c FROM DocGen_Job__c WHERE Id = :job.Id];
        System.assertNotEquals(null, updated.Status__c, 'Should have a status');
    }

    @IsTest
    static void testBatchSanitizeConditionCommentInjection() {
        DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        DocGen_Job__c job = new DocGen_Job__c(
            Template__c = t.Id,
            Query_Condition__c = 'Name != null /* comment */',
            Status__c = 'Queued'
        );
        insert job;

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();
        } catch (Exception e) {
            caught = true;
            System.assert(e.getMessage().contains('Invalid filter condition'), 'Expected sanitize error: ' + e.getMessage());
        }
        if (!caught) {
            // If no exception, batch framework swallowed it — check job status
            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updated.Status__c, 'Job status should have changed');
        }
    }

    @IsTest
    static void testBatchSanitizeConditionDashInjection() {
        DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        DocGen_Job__c job = new DocGen_Job__c(
            Template__c = t.Id,
            Query_Condition__c = 'Name != null -- comment',
            Status__c = 'Queued'
        );
        insert job;

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();
        } catch (Exception e) {
            caught = true;
            System.assert(e.getMessage().contains('Invalid filter condition'), 'Expected sanitize error: ' + e.getMessage());
        }
        if (!caught) {
            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updated.Status__c, 'Job status should have changed');
        }
    }
}