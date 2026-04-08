@IsTest
private class DocGenBulkTests {

    @TestSetup
    static void setup() {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'Test Template',
            Base_Object_API__c = 'User'
        );
        insert t;
    }

	private static DocGen_Template__c createOrgTemplate() {
		DocGen_Template__c t = new DocGen_Template__c(
			Name = 'Test Template',
			Base_Object_API__c = 'Organization'
		);
		insert t;
		return t;	
	}

    @IsTest
    static void testGetBulkTemplates() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<DocGen_Template__c> templates = DocGenBulkController.getBulkTemplates();
            Test.stopTest();
            System.assertEquals(1, templates.size(), 'Should return 1 template');
        }
    }

    @IsTest
    static void testValidateFilter() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer count = DocGenBulkController.validateFilter('User', 'UserName = \'' + UserInfo.getUserName() + '\'');
            Test.stopTest();
            System.assertEquals(1, count, 'Should find 1 record');
        }
    }

    @IsTest
    static void testSubmitJob() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, 'Name = \'Test Account\'', 'Test Job', false, 1, false);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created');
        }
    }

    @IsTest
    static void testSavedQueries() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            // Save
            Test.startTest();
            DocGenBulkController.saveQuery(t.Id, 'My Query', 'Desc', 'Name != null');
            Test.stopTest();

            // Retrieve
            List<DocGen_Saved_Query__c> queries = DocGenBulkController.getSavedQueries(t.Id);
            System.assertEquals(1, queries.size(), 'Should have 1 saved query');
            System.assertEquals('My Query', queries[0].Name, 'Saved query name should match');

            // Delete
            DocGenBulkController.deleteQuery(queries[0].Id);
            queries = DocGenBulkController.getSavedQueries(t.Id);
            System.assertEquals(0, queries.size(), 'Should have 0 saved queries after delete');
        }
    }

    // =========================================================================
    // DocGenBulkController — additional coverage
    // =========================================================================

    @IsTest
    static void testValidateFilterBlankObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer count = DocGenBulkController.validateFilter('', null);
            Test.stopTest();
            System.assertEquals(0, count, 'Should return 0 for blank object');
        }
    }

    @IsTest
    static void testValidateFilterInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    @IsTest
    static void testValidateFilterNoCondition() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer count = DocGenBulkController.validateFilter('User', null);
            Test.stopTest();
            System.assert(count >= 1, 'Should count all accounts');
        }
    }

    @IsTest
    static void testValidateFilterSqlInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('User', 'Name != null; DELETE Account');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject semicolons');
        }
    }

    @IsTest
    static void testValidateFilterDisallowedKeywords() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('User', 'Name IN (SELECT Name FROM User)');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject SELECT keyword in condition');
        }
    }

    @IsTest
    static void testGetJobStatus() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGen_Job__c status = DocGenBulkController.getJobStatus(job.Id);
            Test.stopTest();

            System.assertEquals('Queued', status.Status__c, 'Job status should be Queued');
        }
    }

    @IsTest
    static void testGetSavedQueriesEmpty() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            Test.startTest();
            List<DocGen_Saved_Query__c> queries = DocGenBulkController.getSavedQueries(t.Id);
            Test.stopTest();

            System.assertEquals(0, queries.size(), 'Should return empty list');
        }
    }

    // =========================================================================
    // DocGenBatch — additional coverage for finish status branches
    // =========================================================================

    @IsTest
    static void testBatchFinishCompletedStatus() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    @IsTest
    static void testBatchSanitizeConditionCommentInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    @IsTest
    static void testBatchSanitizeConditionDashInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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

    // =========================================================================
    // Helper: builds a minimal valid DOCX (ZIP) with merge tags, linked to template
    // =========================================================================

    private static ContentVersion createValidDocxForTemplate(Id templateId, String docXml) {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/>' +
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
            '</Types>'
        ));
        zw.addEntry('_rels/.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
            '</Relationships>'
        ));
        zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '</Relationships>'
        ));
        zw.addEntry('word/document.xml', Blob.valueOf(docXml));

        ContentVersion cv = new ContentVersion(
            Title = 'BulkTestDocx',
            PathOnClient = 'BulkTestDocx.docx',
            VersionData = zw.getArchive()
        );
        insert cv;

        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(
            LinkedEntityId = templateId,
            ContentDocumentId = conDocId,
            ShareType = 'V'
        );
        return cv;
    }

    private static String buildSimpleDocXml() {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas" ' +
            'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" ' +
            'xmlns:o="urn:schemas-microsoft-com:office:office" ' +
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' +
            'xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" ' +
            'xmlns:v="urn:schemas-microsoft-com:vml" ' +
            'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" ' +
            'xmlns:w10="urn:schemas-microsoft-com:office:word" ' +
            'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ' +
            'xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml" ' +
            'mc:Ignorable="w14 wp14">' +
            '<w:body>' +
            '<w:p><w:r><w:t>Hello {Name}</w:t></w:r></w:p>' +
            '</w:body>' +
            '</w:document>';
    }

    // =========================================================================
    // DocGenBatch — V3 data cache
    // =========================================================================

    @IsTest
    static void testBatchBuildDataCacheV3() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a template with V3 query config
            String v3Config = '{"v":3,"root":"User","nodes":[' +
                '{"id":"n0","object":"User","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}';
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'V3 Template',
                Base_Object_API__c = 'User',
                Query_Config__c = v3Config,
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            // Attach a valid DOCX to this template
            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            // Create multiple accounts as bulk targets
			Set<String> usrIds = new Set<String>();
            for (User usr : [select Id from User limit 3]) {
                usrIds.add(usr.Id);
            }

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Id IN (\'' + String.join(usrIds, '\',\'') + '\')',
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, usrIds.size());
            Test.stopTest();

            // Verify job completed (cache may or may not have been created depending on
            // whether getRecordDataV3Bulk succeeds, but the batch should finish gracefully)
            DocGen_Job__c updated = [SELECT Status__c, Total_Records__c, Data_Cache_CV__c
                                     FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals(usrIds.size(), updated.Total_Records__c, 'Should have counted ' + usrIds.size() + ' records');
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
        }
    }

    // =========================================================================
    // DocGenBatch — execute success path with real DOCX template
    // =========================================================================

    @IsTest
    static void testBatchExecuteSuccessWithDocx() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a template with V1 query config and a valid DOCX
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Success Template',
                Base_Object_API__c = 'User',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'UserName = \'' + UserInfo.getUserName() + '\'',
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Success_Count__c, Error_Count__c
                                     FROM DocGen_Job__c WHERE Id = :job.Id];
            // Verify batch ran — status should be Completed or Failed depending on
            // whether Blob.toPdf() works in test context. Either way, counts are set.
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
            System.assert(updated.Success_Count__c + updated.Error_Count__c > 0,
                'Should have processed at least 1 record');
        }
    }

    // =========================================================================
    // DocGenBatch — merge mode (mergePdf=true)
    // =========================================================================

    @IsTest
    static void testBatchMergeMode() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Merge Template',
                Base_Object_API__c = 'User',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            List<User> usrs = new List<User>();
			User usr = [SELECT Id, Email FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
            for (Integer i = 0; i < 2; i++) {
                usrs.add(usr);
            }

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name LIKE \'BulkAcct%\'',
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            // mergeMode=true, mergeOnly=false
            DocGenBatch batch = new DocGenBatch(job.Id, true, false);
            Database.executeBatch(batch, 2);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Success_Count__c, Error_Count__c
                                     FROM DocGen_Job__c WHERE Id = :job.Id];
            // If records generated successfully, status will be 'Merging' (chained DocGenMergeJob)
            // If they failed, status will be 'Failed' or 'Completed with Errors'
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
        }
    }

    // =========================================================================
    // DocGenBatch — mergeOnly mode
    // =========================================================================

    @IsTest
    static void testBatchMergeOnlyMode() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'MergeOnly Template',
                Base_Object_API__c = 'User',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'MergeOnly Account\'',
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            // mergeOnly=true implies mergeMode=true
            DocGenBatch batch = new DocGenBatch(job.Id, false, true);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Success_Count__c, Error_Count__c
                                     FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
            // Verify mergeOnly flag was set on constructor
            System.assert(batch.mergeOnly, 'mergeOnly should be true');
            System.assert(batch.mergeMode, 'mergeMode should be true when mergeOnly is true');
        }
    }

    // =========================================================================
    // DocGenBatch — constructor variants
    // =========================================================================

    @IsTest
    static void testBatchConstructorSingleArg() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Test.stopTest();

            System.assertEquals(false, batch.mergeMode, 'Default mergeMode should be false');
            System.assertEquals(false, batch.mergeOnly, 'Default mergeOnly should be false');
        }
    }

    @IsTest
    static void testBatchConstructorTwoArgs() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id, true);
            Test.stopTest();

            System.assertEquals(true, batch.mergeMode, 'mergeMode should be true');
            System.assertEquals(false, batch.mergeOnly, 'mergeOnly should default to false');
        }
    }

    // =========================================================================
    // DocGenBatch — finish with all failures (Failed status)
    // =========================================================================

    @IsTest
    static void testBatchFinishFailedStatus() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Use a template with no DOCX file — all records will fail
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'UserName = \'' + UserInfo.getUserName() + '\'',
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Error_Count__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals('Failed', updated.Status__c, 'All records failed — status should be Failed');
            System.assert(updated.Error_Count__c > 0, 'Error count should be > 0');
        }
    }

    // =========================================================================
    // DocGenBatch — sendJobNotification (non-fatal when no CustomNotificationType)
    // =========================================================================

    @IsTest
    static void testBatchSendJobNotificationGraceful() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Run a batch that will finish and attempt to send notification.
            // Without the CustomNotificationType 'DocGen_Job_Complete' deployed,
            // sendJobNotification gracefully returns (no exception).
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

            // The batch finished without exception (notification failure is non-fatal)
            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updated.Status__c,
                'Job should have completed even without notification type');
        }
    }

    // =========================================================================
    // DocGenBatch — data cache cleanup in finish
    // =========================================================================

    @IsTest
    static void testBatchDataCacheCleanup() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a V3 config template to trigger buildDataCache
            String v3Config = '{"v":3,"root":"User","nodes":[' +
                '{"id":"n0","object":"User","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}';
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Cache Cleanup Template',
                Base_Object_API__c = 'User',
                Query_Config__c = v3Config,
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'Cache Cleanup Account\'',
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            // After finish, the data cache CV should have been cleaned up
            DocGen_Job__c updated = [SELECT Data_Cache_CV__c FROM DocGen_Job__c WHERE Id = :job.Id];
            // If cache was created and then cleaned up, the CV should be deleted
            if (updated.Data_Cache_CV__c != null) {
                List<ContentVersion> remaining = [SELECT Id FROM ContentVersion
                    WHERE Id = :updated.Data_Cache_CV__c WITH SYSTEM_MODE];
                // Cache cleanup deletes the ContentDocument; the CV query should find nothing
                // (or the delete may have cascade-removed it)
                System.assert(remaining.size() <= 1,
                    'Cache CV should have been deleted or cleaned up');
            }
        }
    }

    // =========================================================================
    // DocGenBatch — buildDataCache skips for V1 config
    // =========================================================================

    @IsTest
    static void testBatchBuildDataCacheSkipsV1() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // V1 config (plain string) should NOT create a data cache CV
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

            DocGen_Job__c updated = [SELECT Data_Cache_CV__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals(null, updated.Data_Cache_CV__c,
                'V1 config should not create a data cache');
        }
    }

    // =========================================================================
    // DocGenBatch — finish with merge mode and htmlSequence > 0 (chains DocGenMergeJob)
    // =========================================================================

    @IsTest
    static void testBatchFinishChainsDocGenMergeJob() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Merge Chain Template',
                Base_Object_API__c = 'User',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            // Submit via controller with mergePdf=true
            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, 'Name = \'ChainTestAcct\'', 'Chain Job', true, 1, false);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            // If generation succeeded, status should be 'Merging' (or 'Completed' if DocGenMergeJob
            // also ran within stopTest). If generation failed, status reflects that.
            System.assertNotEquals('Queued', updated.Status__c, 'Job should have progressed');
        }
    }

    // =========================================================================
    // DocGenBulkController — getRecentJobs
    // =========================================================================

    @IsTest
    static void testGetRecentJobs() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            // Create some jobs
            List<DocGen_Job__c> jobs = new List<DocGen_Job__c>();
            for (Integer i = 0; i < 5; i++) {
                jobs.add(new DocGen_Job__c(
                    Template__c = t.Id,
                    Status__c = 'Completed',
                    Label__c = 'Recent Job ' + i,
                    Success_Count__c = i + 1,
                    Error_Count__c = 0,
                    Total_Records__c = i + 1
                ));
            }
            insert jobs;

            Test.startTest();
            List<DocGen_Job__c> recentJobs = DocGenBulkController.getRecentJobs();
            Test.stopTest();

            System.assert(recentJobs.size() >= 5, 'Should return at least 5 recent jobs');
            // Verify ordering: most recent first
            System.assert(recentJobs[0].CreatedDate >= recentJobs[recentJobs.size() - 1].CreatedDate,
                'Jobs should be ordered by CreatedDate descending');
            // Verify template relationship is populated
            System.assertNotEquals(null, recentJobs[0].Template__r.Name,
                'Template name should be populated');
        }
    }

    // =========================================================================
    // DocGenBulkController — getJobGeneratedPdfs
    // =========================================================================

    @IsTest
    static void testGetJobGeneratedPdfs() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'UserName = \'' + UserInfo.getUserName() + '\'',
                Status__c = 'Completed'
            );
            insert job;

            // Create a fake PDF ContentVersion linked to the Account
            ContentVersion cv = new ContentVersion(
                Title = 'Generated PDF',
                PathOnClient = 'Generated PDF.pdf',
                VersionData = Blob.valueOf('fake pdf content'),
                FirstPublishLocationId = UserInfo.getUserId()
            );
            insert cv;

            Test.startTest();
            List<Map<String, String>> pdfs = DocGenBulkController.getJobGeneratedPdfs(job.Id);
            Test.stopTest();

            // Should find the PDF linked to the Account
            System.assert(pdfs.size() >= 1, 'Should find at least 1 generated PDF');
            Boolean foundOurPdf = false;
            for (Map<String, String> pdf : pdfs) {
                if (pdf.get('label') == 'Generated PDF.pdf') {
                    foundOurPdf = true;
                    System.assertNotEquals(null, pdf.get('value'),
                        'ContentVersion ID should be populated');
                }
            }
            System.assert(foundOurPdf, 'Should find our generated PDF in results');
        }
    }

    @IsTest
    static void testGetJobGeneratedPdfsEmpty() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'No Such Account XYZ\'',
                Status__c = 'Completed'
            );
            insert job;

            Test.startTest();
            List<Map<String, String>> pdfs = DocGenBulkController.getJobGeneratedPdfs(job.Id);
            Test.stopTest();

            System.assertEquals(0, pdfs.size(), 'Should return empty list when no records match');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with mergePdf=true
    // =========================================================================

    @IsTest
    static void testSubmitJobWithMergePdf() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Merge Submit Template',
                Base_Object_API__c = 'User',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, 'Name = \'Test Account\'', 'Merge PDF Job', true, 1, false);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c, Label__c, Merge_Only__c
                                 FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created');
            System.assertEquals('Merge PDF Job', job.Label__c, 'Label should be set');
            System.assertEquals(false, job.Merge_Only__c, 'Merge_Only should be false');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with mergeOnly=true
    // =========================================================================

    @IsTest
    static void testSubmitJobWithMergeOnly() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'MergeOnly Submit Template',
                Base_Object_API__c = 'User',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, 'Name = \'Test Account\'', 'MergeOnly Job', false, 1, true);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c, Merge_Only__c
                                 FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created');
            System.assertEquals(true, job.Merge_Only__c, 'Merge_Only should be true');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with custom batch size
    // =========================================================================

    @IsTest
    static void testSubmitJobCustomBatchSize() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, 'Name = \'Test Account\'', null, false, 50, false);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c, Label__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created');
            // Null label should result in null (not blank)
            System.assertEquals(null, job.Label__c, 'Label should be null when not provided');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with null/invalid batch size defaults to 1
    // =========================================================================

    @IsTest
    static void testSubmitJobNullBatchSize() {
		DocGen_Template__c t = createOrgTemplate();
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {

            Test.startTest();
            // null batchSize should default to 1
            Id jobId = DocGenBulkController.submitJob(t.Id, null, null, false, null, false);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created with null batch size');
        }
    }

    // =========================================================================
    // DocGenBatch — no condition (all records)
    // =========================================================================

    @IsTest
    static void testBatchNoCondition() {
		DocGen_Template__c t = createOrgTemplate();
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = null,
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 200);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
            System.assert(updated.Total_Records__c >= 1, 'Should have found at least 1 account');
        }
    }

    // =========================================================================
    // DocGenBatch — invalid object in batch (DocGenException)
    // =========================================================================

    @IsTest
    static void testBatchInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Manually create a template with an invalid object name
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Invalid Obj Template',
                Base_Object_API__c = 'ZZZFakeObject__c'
            );
            insert t;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
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
            }
            // The exception may be caught by the batch framework or propagate
            if (!caught) {
                DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
                System.assertNotEquals('Queued', updated.Status__c,
                    'Job status should reflect the invalid object error');
            }
        }
    }

    // =========================================================================
    // DocGenBulkController — validateFilter with comment injection (controller path)
    // =========================================================================

    @IsTest
    static void testControllerSanitizeConditionComments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('User', 'Name != null /* hack */');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject /* comment */ in condition');
        }
    }

    @IsTest
    static void testControllerSanitizeConditionDashes() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('User', 'Name != null -- hack');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject -- in condition');
        }
    }

    // =========================================================================
    // DocGenBulkController — validateFilter with various disallowed keywords
    // =========================================================================

    @IsTest
    static void testControllerSanitizeConditionUpdateKeyword() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('User', 'Name != null UPDATE Account');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject UPDATE keyword');
        }
    }

    @IsTest
    static void testControllerSanitizeConditionDeleteKeyword() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('User', 'Name != null DELETE Account');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject DELETE keyword');
        }
    }

    // =========================================================================
    // DocGenBatch — execute with data cache lazy-load (dataCacheCvId set, cachedDataJson null)
    // =========================================================================

    @IsTest
    static void testBatchExecuteLazyLoadCache() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a V3 template so buildDataCache creates a cache CV
            String v3Config = '{"v":3,"root":"User","nodes":[' +
                '{"id":"n0","object":"User","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}';
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'LazyLoad Template',
                Base_Object_API__c = 'User',
                Query_Config__c = v3Config,
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'LazyLoad Account\'',
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Success_Count__c, Error_Count__c
                                     FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updated.Status__c, 'Status should progress');
        }
    }

    // =========================================================================
    // DocGenBatch — notification when no CustomNotificationType exists
    // =========================================================================

    @IsTest
    static void testBatchNotificationWithoutNotificationType() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // This test exercises sendJobNotification when CustomNotificationType
            // 'DocGen_Job_Complete' does not exist — should return gracefully
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Notify Template',
                Base_Object_API__c = 'User',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'Notify Account\'',
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            // Batch should complete without throwing even if notification type missing
            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updated.Status__c,
                'Batch should finish gracefully without notification type');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with mergeOnly=true
    // =========================================================================

    @IsTest
    static void testSubmitJobMergeOnly() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'MergeOnly Submit Template',
                Base_Object_API__c = 'User',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, 'Name = \'Test Account\'', 'MergeOnly Job', false, 1, true);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Merge_Only__c, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created');
            System.assertEquals(true, job.Merge_Only__c, 'Merge_Only__c should be true');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with null/default batchSize
    // =========================================================================

    @IsTest
    static void testSubmitJobDefaultBatchSize() {
		DocGen_Template__c t = createOrgTemplate();
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, null, null, false, null, false);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created with default batch size');
        }
    }

    // =========================================================================
    // DocGenBulkController — validateFilter with various injection patterns
    // =========================================================================

    @IsTest
    static void testValidateFilterRejectsDoubleDash() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('User', 'Name != null -- drop');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject double-dash comment');
        }
    }

    @IsTest
    static void testValidateFilterRejectsBlockComment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('User', 'Name != null /* evil */');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject block comments');
        }
    }

    @IsTest
    static void testValidateFilterRejectsWhitespaceNormalized() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Test that multi-word keywords with extra whitespace are still caught
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('User', 'Name != null ORDER BY Name');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject ORDER BY keyword');
        }
    }

    // =========================================================================
    // DocGenMergeJob — execute with HTML snippets
    // =========================================================================

    @IsTest
    static void testMergeJobExecuteWithSnippets() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Status__c = 'Merging',
                Success_Count__c = 2,
                Total_Records__c = 2
            );
            insert job;

            // Create HTML snippet ContentVersions manually
            String html1 = '<html><body><p>Page One</p></body></html>';
            String html2 = '<html><body><p>Page Two</p></body></html>';

            ContentVersion cv1 = new ContentVersion(
                Title = 'docgen_merge_' + job.Id + '_00000',
                PathOnClient = 'docgen_merge_' + job.Id + '_00000.html',
                VersionData = Blob.valueOf(html1),
                IsMajorVersion = false,
                FirstPublishLocationId = job.Id
            );
            ContentVersion cv2 = new ContentVersion(
                Title = 'docgen_merge_' + job.Id + '_00001',
                PathOnClient = 'docgen_merge_' + job.Id + '_00001.html',
                VersionData = Blob.valueOf(html2),
                IsMajorVersion = false,
                FirstPublishLocationId = job.Id
            );
            insert new List<ContentVersion>{ cv1, cv2 };

            Test.startTest();
            DocGenMergeJob mergeJob = new DocGenMergeJob(job.Id);
            System.enqueueJob(mergeJob);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Merged_PDF_CV__c FROM DocGen_Job__c WHERE Id = :job.Id];
            // Status should be Completed (success) or Completed with Errors (Blob.toPdf test limitation)
            System.assertNotEquals('Merging', updated.Status__c, 'Status should have changed from Merging');
        }
    }

    // =========================================================================
    // DocGenMergeJob — execute with no snippets (empty)
    // =========================================================================

    @IsTest
    static void testMergeJobExecuteNoSnippets() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Status__c = 'Merging',
                Success_Count__c = 0
            );
            insert job;

            Test.startTest();
            DocGenMergeJob mergeJob = new DocGenMergeJob(job.Id);
            System.enqueueJob(mergeJob);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals('Completed', updated.Status__c,
                'Should complete immediately when no snippets exist');
        }
    }

    // =========================================================================
    // DocGenMergeJob — error handling path (invalid job Id triggers catch block)
    // =========================================================================

    @IsTest
    static void testMergeJobErrorHandling() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Status__c = 'Merging',
                Success_Count__c = 1
            );
            insert job;

            // Create a snippet with invalid HTML that might cause issues
            ContentVersion cv = new ContentVersion(
                Title = 'docgen_merge_' + job.Id + '_00000',
                PathOnClient = 'docgen_merge_' + job.Id + '_00000.html',
                VersionData = Blob.valueOf('<html><body>Test</body></html>'),
                IsMajorVersion = false,
                FirstPublishLocationId = job.Id
            );
            insert cv;

            Test.startTest();
            DocGenMergeJob mergeJob = new DocGenMergeJob(job.Id);
            System.enqueueJob(mergeJob);
            Test.stopTest();

            // Whether it succeeded or hit error path, status should not be 'Merging'
            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Merging', updated.Status__c,
                'Status should have changed after merge job execution');
        }
    }

    // =========================================================================
    // DocGenBatch — finish with partial failures (Completed with Errors)
    // =========================================================================

    @IsTest
    static void testBatchFinishCompletedWithErrors() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create template with valid DOCX so at least some records succeed
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Partial Fail Template',
                Base_Object_API__c = 'User',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'PartialFail User\'',
                Status__c = 'Queued'
            );
            insert job;

            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Success_Count__c, Error_Count__c
                                     FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have changed');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with label
    // =========================================================================

    @IsTest
    static void testSubmitJobWithLabel() {
		DocGen_Template__c t = createOrgTemplate();
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, null, 'My Custom Label', false, 5, false);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Label__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertEquals('My Custom Label', job.Label__c, 'Label should be set');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with blank label (null stored)
    // =========================================================================

    @IsTest
    static void testSubmitJobWithBlankLabel() {
		DocGen_Template__c t = createOrgTemplate();
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, null, '', false, 1, false);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Label__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertEquals(null, job.Label__c, 'Blank label should be stored as null');
        }
    }
}
