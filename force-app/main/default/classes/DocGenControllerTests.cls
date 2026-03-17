@isTest
private class DocGenControllerTests {

    @testSetup
    static void setup() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Controller Test Template',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, AccountSource',
            Type__c = 'Word'
        );
        insert tpl;

        Account acc = new Account(
            Name = 'Controller Test Account',
            AccountSource = 'Web',
            Website = 'https://test.com'
        );
        insert acc;
    }

    private static ContentVersion createTestFile() {
        ContentVersion cv = new ContentVersion(
            Title = 'ControllerTestDoc',
            PathOnClient = 'ControllerTestDoc.docx',
            VersionData = Blob.valueOf('Test Content For Controller')
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        insert new ContentDocumentLink(
            LinkedEntityId = tpl.Id,
            ContentDocumentId = conDocId,
            ShareType = 'V'
        );
        return cv;
    }

    // -----------------------------------------------------------------------
    // saveGeneratedDocument
    // -----------------------------------------------------------------------
    @isTest
    static void testSaveGeneratedDocument() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];
        String dummyContent = EncodingUtil.base64Encode(Blob.valueOf('Dummy PDF content'));

        Test.startTest();
        Id contentDocId = DocGenController.saveGeneratedDocument(
            acc.Id, 'TestOutput', dummyContent, '.pdf'
        );
        Test.stopTest();

        System.assertNotEquals(null, contentDocId, 'Should return a ContentDocument Id');

        // Verify ContentVersion was created
        List<ContentVersion> versions = [
            SELECT Title, PathOnClient FROM ContentVersion
            WHERE ContentDocumentId = :contentDocId
        ];
        System.assertEquals(1, versions.size(), 'Should have exactly one ContentVersion');
        System.assertEquals('TestOutput', versions[0].Title, 'Title should match');
        System.assert(versions[0].PathOnClient.endsWith('.pdf'), 'PathOnClient should end with .pdf');
    }

    @isTest
    static void testSaveGeneratedDocumentExtensionWithoutDot() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];
        String dummyContent = EncodingUtil.base64Encode(Blob.valueOf('Dummy DOCX content'));

        Test.startTest();
        Id contentDocId = DocGenController.saveGeneratedDocument(
            acc.Id, 'TestOutputNoDot', dummyContent, 'docx'
        );
        Test.stopTest();

        System.assertNotEquals(null, contentDocId, 'Should return a ContentDocument Id');

        List<ContentVersion> versions = [
            SELECT PathOnClient FROM ContentVersion
            WHERE ContentDocumentId = :contentDocId
        ];
        System.assert(versions[0].PathOnClient.endsWith('.docx'),
            'Extension without leading dot should still produce correct PathOnClient');
    }

    // -----------------------------------------------------------------------
    // processAndReturnDocument - throws AuraHandledException for non-DOCX
    // -----------------------------------------------------------------------
    @isTest
    static void testProcessAndReturnDocumentThrows() {
        createTestFile();
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

        Test.startTest();
        Boolean caughtException = false;
        try {
            DocGenController.processAndReturnDocument(tpl.Id, acc.Id);
        } catch (AuraHandledException e) {
            caughtException = true;
        }
        Test.stopTest();

        System.assert(caughtException, 'Should have thrown AuraHandledException for non-real DOCX template');
    }

    // -----------------------------------------------------------------------
    // previewRecordData
    // -----------------------------------------------------------------------
    @isTest
    static void testPreviewRecordData() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocGenController.previewRecordData(
            acc.Id, 'Account', 'Name, AccountSource'
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Preview data should not be null');
        System.assertEquals('Controller Test Account', result.get('Name'),
            'Name field should match the test account');
    }

    @isTest
    static void testPreviewRecordDataNullParams() {
        Test.startTest();
        Map<String, Object> result = DocGenController.previewRecordData(null, null, null);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null when parameters are blank');
    }

    // -----------------------------------------------------------------------
    // getAllTemplates
    // -----------------------------------------------------------------------
    @isTest
    static void testGetAllTemplates() {
        Test.startTest();
        List<DocGen_Template__c> templates = DocGenController.getAllTemplates();
        Test.stopTest();

        System.assert(!templates.isEmpty(), 'Should return at least the test template');
        Boolean found = false;
        for (DocGen_Template__c t : templates) {
            if (t.Name == 'Controller Test Template') {
                found = true;
                break;
            }
        }
        System.assert(found, 'Should contain the test template');
    }

    // -----------------------------------------------------------------------
    // saveTemplate (update without version)
    // -----------------------------------------------------------------------
    @isTest
    static void testSaveTemplateUpdateOnly() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Map<String, Object> fields = new Map<String, Object>{
            'Id' => tpl.Id,
            'Name' => 'Renamed Template',
            'Category__c' => 'Legal',
            'Type__c' => 'Word',
            'Base_Object_API__c' => 'Account',
            'Description__c' => 'Updated description',
            'Query_Config__c' => 'Name',
            'Test_Record_Id__c' => null,
            'Document_Title_Format__c' => '{Name}_Doc',
            'Output_Format__c' => 'PDF'
        };

        Test.startTest();
        DocGenController.saveTemplate(fields, false);
        Test.stopTest();

        DocGen_Template__c updated = [SELECT Name, Category__c, Description__c FROM DocGen_Template__c WHERE Id = :tpl.Id];
        System.assertEquals('Renamed Template', updated.Name, 'Name should be updated');
        System.assertEquals('Legal', updated.Category__c, 'Category should be updated');
        System.assertEquals('Updated description', updated.Description__c, 'Description should be updated');
    }

    // -----------------------------------------------------------------------
    // saveTemplate (update with version creation)
    // -----------------------------------------------------------------------
    @isTest
    static void testSaveTemplateWithVersion() {
        createTestFile();
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Map<String, Object> fields = new Map<String, Object>{
            'Id' => tpl.Id,
            'Name' => 'Versioned Template',
            'Category__c' => 'Finance',
            'Type__c' => 'Word',
            'Base_Object_API__c' => 'Account',
            'Description__c' => 'Version test',
            'Query_Config__c' => 'Name, AccountSource',
            'Test_Record_Id__c' => null,
            'Document_Title_Format__c' => null
        };

        Test.startTest();
        DocGenController.saveTemplate(fields, true);
        Test.stopTest();

        List<DocGen_Template_Version__c> versions = [
            SELECT Is_Active__c, Category__c, Type__c, Base_Object_API__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :tpl.Id
        ];
        System.assert(!versions.isEmpty(), 'Should have created at least one version');

        // The newly created version should be active
        Boolean hasActive = false;
        for (DocGen_Template_Version__c v : versions) {
            if (v.Is_Active__c) {
                hasActive = true;
                System.assertEquals('Finance', v.Category__c, 'Version category should match');
                System.assertEquals('Word', v.Type__c, 'Version type should match');
            }
        }
        System.assert(hasActive, 'Newly created version should be active');
    }

    // -----------------------------------------------------------------------
    // deleteTemplate
    // -----------------------------------------------------------------------
    @isTest
    static void testDeleteTemplate() {
        // Create a disposable template to delete
        DocGen_Template__c disposable = new DocGen_Template__c(
            Name = 'To Be Deleted',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Type__c = 'Word'
        );
        insert disposable;

        Test.startTest();
        DocGenController.deleteTemplate(disposable.Id);
        Test.stopTest();

        List<DocGen_Template__c> remaining = [
            SELECT Id FROM DocGen_Template__c WHERE Id = :disposable.Id
        ];
        System.assertEquals(0, remaining.size(), 'Template should have been deleted');
    }

    // -----------------------------------------------------------------------
    // getTemplateVersions
    // -----------------------------------------------------------------------
    @isTest
    static void testGetTemplateVersions() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        // Create a version record
        DocGen_Template_Version__c v = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Type__c = 'Word',
            Base_Object_API__c = 'Account',
            Category__c = 'General',
            Description__c = 'Test version'
        );
        insert v;

        Test.startTest();
        List<DocGen_Template_Version__c> versions = DocGenController.getTemplateVersions(tpl.Id);
        Test.stopTest();

        System.assert(!versions.isEmpty(), 'Should return the created version');
        System.assertEquals(v.Id, versions[0].Id, 'Should return the correct version');
    }

    // -----------------------------------------------------------------------
    // getObjectOptions (Schema)
    // -----------------------------------------------------------------------
    @isTest
    static void testGetObjectOptions() {
        Test.startTest();
        List<Map<String, String>> options = DocGenController.getObjectOptions();
        Test.stopTest();

        System.assert(!options.isEmpty(), 'Should return at least some queryable objects');

        // Verify Account is in the list
        Boolean foundAccount = false;
        for (Map<String, String> opt : options) {
            if (opt.get('value') == 'Account') {
                foundAccount = true;
                break;
            }
        }
        System.assert(foundAccount, 'Account should be in the object options');
    }

    // -----------------------------------------------------------------------
    // getObjectFields (Schema)
    // -----------------------------------------------------------------------
    @isTest
    static void testGetObjectFields() {
        Test.startTest();
        List<Map<String, String>> fields = DocGenController.getObjectFields('Account');
        Test.stopTest();

        System.assert(!fields.isEmpty(), 'Account should have fields');

        // Verify Name field is present
        Boolean foundName = false;
        for (Map<String, String> f : fields) {
            if (f.get('value') == 'Name') {
                foundName = true;
                break;
            }
        }
        System.assert(foundName, 'Name field should be present for Account');
    }

    @isTest
    static void testGetObjectFieldsInvalidObject() {
        Test.startTest();
        List<Map<String, String>> fields = DocGenController.getObjectFields('NonExistentObject__x');
        Test.stopTest();

        System.assertEquals(0, fields.size(), 'Should return empty list for invalid object');
    }

    // -----------------------------------------------------------------------
    // getChildRelationships (Schema)
    // -----------------------------------------------------------------------
    @isTest
    static void testGetChildRelationships() {
        Test.startTest();
        List<Map<String, String>> rels = DocGenController.getChildRelationships('Account');
        Test.stopTest();

        System.assert(!rels.isEmpty(), 'Account should have child relationships');

        // Verify at least one relationship has expected keys
        Map<String, String> firstRel = rels[0];
        System.assert(firstRel.containsKey('label'), 'Each relationship should have a label');
        System.assert(firstRel.containsKey('value'), 'Each relationship should have a value');
        System.assert(firstRel.containsKey('childObjectApiName'),
            'Each relationship should have childObjectApiName');
    }

    @isTest
    static void testGetChildRelationshipsInvalidObject() {
        Test.startTest();
        List<Map<String, String>> rels = DocGenController.getChildRelationships('NonExistentObject__x');
        Test.stopTest();

        System.assertEquals(0, rels.size(), 'Should return empty list for invalid object');
    }

    // -----------------------------------------------------------------------
    // getParentRelationships (Schema)
    // -----------------------------------------------------------------------
    @isTest
    static void testGetParentRelationships() {
        Test.startTest();
        List<Map<String, String>> parents = DocGenController.getParentRelationships('Account');
        Test.stopTest();

        System.assert(!parents.isEmpty(), 'Account should have parent/lookup relationships');

        // Verify structure
        Map<String, String> firstParent = parents[0];
        System.assert(firstParent.containsKey('label'), 'Each parent should have a label');
        System.assert(firstParent.containsKey('value'), 'Each parent should have a value');
        System.assert(firstParent.containsKey('targetObject'), 'Each parent should have targetObject');
    }

    @isTest
    static void testGetParentRelationshipsInvalidObject() {
        Test.startTest();
        List<Map<String, String>> parents = DocGenController.getParentRelationships('NonExistentObject__x');
        Test.stopTest();

        System.assertEquals(0, parents.size(), 'Should return empty list for invalid object');
    }

    // -----------------------------------------------------------------------
    // searchUsersAndGroups
    // -----------------------------------------------------------------------
    @isTest
    static void testSearchUsersAndGroups() {
        // The running user should always exist and be matchable
        String currentUserName = UserInfo.getLastName();

        Test.startTest();
        List<Map<String, String>> results = DocGenController.searchUsersAndGroups(currentUserName);
        Test.stopTest();

        // At minimum the running test user should match
        System.assert(!results.isEmpty(), 'Should find at least the running user');

        Map<String, String> firstResult = results[0];
        System.assert(firstResult.containsKey('Id'), 'Result should have Id');
        System.assert(firstResult.containsKey('Name'), 'Result should have Name');
        System.assert(firstResult.containsKey('Type'), 'Result should have Type');
        System.assert(firstResult.containsKey('Icon'), 'Result should have Icon');
    }

    @isTest
    static void testSearchUsersAndGroupsNoResults() {
        Test.startTest();
        List<Map<String, String>> results = DocGenController.searchUsersAndGroups('ZZZZNONEXISTENT99999');
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Should return empty list for non-matching search');
    }

    // -----------------------------------------------------------------------
    // getTemplateShares
    // -----------------------------------------------------------------------
    @isTest
    static void testGetTemplateSharesEmpty() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        List<Map<String, String>> shares = DocGenController.getTemplateShares(tpl.Id);
        Test.stopTest();

        // No manual shares have been created, so list should be empty
        // (Owner share is excluded by the query)
        System.assertNotEquals(null, shares, 'Should return a list, not null');
    }

    // -----------------------------------------------------------------------
    // shareTemplate + getTemplateShares + removeShare (integration)
    // -----------------------------------------------------------------------
    @isTest
    static void testShareAndRemoveTemplate() {
        DocGen_Template__c tpl = [SELECT Id, OwnerId FROM DocGen_Template__c LIMIT 1];

        // We need a different user or group to share with.
        // Use a public group for reliability in tests.
        Group testGroup = new Group(Name = 'DocGen Test Group', Type = 'Regular');
        insert testGroup;

        Test.startTest();
        // Share the template with the group
        DocGenController.shareTemplate(tpl.Id, testGroup.Id, 'Read');

        // Verify the share exists
        List<Map<String, String>> shares = DocGenController.getTemplateShares(tpl.Id);
        System.assert(!shares.isEmpty(), 'Should have at least one manual share');

        Boolean foundShare = false;
        String shareId = null;
        for (Map<String, String> s : shares) {
            if (s.get('UserOrGroupId') == testGroup.Id) {
                foundShare = true;
                shareId = s.get('Id');
                System.assertEquals('Read', s.get('AccessLevel'), 'Access level should be Read');
                break;
            }
        }
        System.assert(foundShare, 'Should find the share for our test group');

        // Remove the share
        DocGenController.removeShare(shareId);

        // Verify removal
        List<Map<String, String>> sharesAfter = DocGenController.getTemplateShares(tpl.Id);
        Boolean stillFound = false;
        for (Map<String, String> s : sharesAfter) {
            if (s.get('UserOrGroupId') == testGroup.Id) {
                stillFound = true;
                break;
            }
        }
        System.assert(!stillFound, 'Share should have been removed');
        Test.stopTest();
    }

    // -----------------------------------------------------------------------
    // Option inner class compareTo
    // -----------------------------------------------------------------------
    @isTest
    static void testOptionCompareTo() {
        DocGenController.Option optA = new DocGenController.Option('Alpha', 'a');
        DocGenController.Option optB = new DocGenController.Option('Beta', 'b');
        DocGenController.Option optA2 = new DocGenController.Option('Alpha', 'a2');

        Test.startTest();
        System.assertEquals(-1, optA.compareTo(optB), 'Alpha should sort before Beta');
        System.assertEquals(1, optB.compareTo(optA), 'Beta should sort after Alpha');
        System.assertEquals(0, optA.compareTo(optA2), 'Same label should return 0');
        Test.stopTest();
    }

    @isTest
    static void testOptionThreeArgConstructor() {
        DocGenController.Option opt = new DocGenController.Option('Contacts', 'Contacts', 'Contact');

        System.assertEquals('Contacts', opt.label, 'Label should match');
        System.assertEquals('Contacts', opt.value, 'Value should match');
        System.assertEquals('Contact', opt.childObjectApiName, 'Child object API name should match');
    }

    // -----------------------------------------------------------------------
    // generateDocumentData - null templateId throws DocGenException
    // -----------------------------------------------------------------------
    @isTest
    static void testGenerateDocumentDataNullTemplateId() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

        Test.startTest();
        Boolean caughtException = false;
        try {
            DocGenController.generateDocumentData(null, acc.Id);
        } catch (DocGenException e) {
            caughtException = true;
            System.assert(e.getMessage().contains('Template ID is missing'),
                'Should indicate missing template ID');
        }
        Test.stopTest();

        System.assert(caughtException, 'Should throw DocGenException for null template ID');
    }
}
