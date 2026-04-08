@isTest
private class DocGenTests {

    @testSetup
    static void setup() {
        // Create Template
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Test Template',
            Base_Object_API__c = 'User',
            Query_Config__c = 'Email, CreatedBy.Email',
            Type__c = 'Word'
        );
        insert tpl;

        // Create ContentVersion (File)
        ContentVersion cv = new ContentVersion(
            Title = 'TestDoc',
            PathOnClient = 'TestDoc.docx',
            VersionData = Blob.valueOf('Test Content'),
            IsMajorVersion = true
        );
        insert cv;

        // Get ContentDocumentId
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        // Link to Template
        ContentDocumentLink cdl = new ContentDocumentLink(
            LinkedEntityId = tpl.Id,
            ContentDocumentId = conDocId,
            ShareType = 'V'
        );
        insert cdl;
    }

    @isTest
    static void testGenerationFlow() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            User usr = u;

            Test.startTest();
            Map<String, Object> result = DocGenController.generateDocumentData(tpl.Id, usr.Id);
            Test.stopTest();

            System.assertNotEquals(null, result.get('data'), 'Data should not be null');
            System.assertNotEquals(null, result.get('templateFile'), 'File should not be null');
            Map<String, Object> data = (Map<String, Object>) result.get('data');
            System.assertEquals(UserInfo.getUserEmail(), data.get('Email'), 'User Email should match test data');
        }
    }

    @isTest
    static void testGetTemplates() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            List<DocGen_Template__c> tpls = DocGenController.getTemplatesForObject('User');
            System.assertEquals(1, tpls.size(), 'Should return 1 template for Account');
        }
    }
    @isTest
    static void testVersioning() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            // 1. Setup - Create V1 Record
            ContentVersion cv1 = [SELECT Id, ContentDocumentId FROM ContentVersion LIMIT 1];

            DocGen_Template_Version__c v1 = new DocGen_Template_Version__c(
                Template__c = tpl.Id,
                Content_Version_Id__c = cv1.Id,
                Is_Active__c = true,
                Type__c = 'Word',
                Base_Object_API__c = 'User',
                Category__c = 'General',
                Description__c = 'V1 Description'
            );
            insert v1;

            // 2. Upload "V2" File
            ContentVersion cv2 = new ContentVersion(
                Title = 'TestDoc_V2',
                PathOnClient = 'TestDoc_V2.docx',
                VersionData = Blob.valueOf('V2 Content') // Distinct content
            );
            insert cv2;

            // Link V2 to Template (simulates upload)
            Id conDocId2 = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv2.Id].ContentDocumentId;
            ContentDocumentLink cdl2 = new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId2,
                ShareType = 'V'
            );
            insert cdl2;

            // Create V2 Version Record (Active)
            DocGen_Template_Version__c v2 = new DocGen_Template_Version__c(
                Template__c = tpl.Id,
                Content_Version_Id__c = cv2.Id,
                Is_Active__c = true,
                Type__c = 'Word',
                Base_Object_API__c = 'User',
                Category__c = 'General',
                Description__c = 'V2 Description'
            );
            insert v2;

            // Deactivate V1 (trigger would usually do this but we are manual here or relying on Service)
            v1.Is_Active__c = false;
            update v1;

            // 3. Verify Generation uses V2
            Test.startTest();
            String contentV2 = DocGenTemplateManager.getTemplateFileContent(tpl.Id);
            System.assertEquals(EncodingUtil.base64Encode(Blob.valueOf('V2 Content')), contentV2, 'Should return V2 content');

            // 4. Activate V1
            DocGenController.activateVersion(v1.Id); // This method handles deactivation of others

            String contentV1 = DocGenTemplateManager.getTemplateFileContent(tpl.Id);
            System.assertEquals(EncodingUtil.base64Encode(Blob.valueOf('Test Content')), contentV1, 'Should return V1 content');
            Test.stopTest();
        }
    }
}
