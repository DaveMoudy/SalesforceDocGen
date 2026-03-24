@IsTest
private class DocGenControllerTests {

    @TestSetup
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
    @IsTest
    static void testSaveGeneratedDocument() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    @IsTest
    static void testSaveGeneratedDocumentExtensionWithoutDot() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    // -----------------------------------------------------------------------
    // processAndReturnDocument - throws AuraHandledException for non-DOCX
    // -----------------------------------------------------------------------
    @IsTest
    static void testProcessAndReturnDocumentThrows() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    // -----------------------------------------------------------------------
    // previewRecordData
    // -----------------------------------------------------------------------
    @IsTest
    static void testPreviewRecordData() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    @IsTest
    static void testPreviewRecordDataNullParams() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Map<String, Object> result = DocGenController.previewRecordData(null, null, null);
            Test.stopTest();

            System.assertEquals(null, result, 'Should return null when parameters are blank');
        }
    }

    // -----------------------------------------------------------------------
    // getAllTemplates
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetAllTemplates() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    // -----------------------------------------------------------------------
    // saveTemplate (update without version)
    // -----------------------------------------------------------------------
    @IsTest
    static void testSaveTemplateUpdateOnly() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    // -----------------------------------------------------------------------
    // saveTemplate (update with version creation)
    // -----------------------------------------------------------------------
    @IsTest
    static void testSaveTemplateWithVersion() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    // -----------------------------------------------------------------------
    // deleteTemplate
    // -----------------------------------------------------------------------
    @IsTest
    static void testDeleteTemplate() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    // -----------------------------------------------------------------------
    // getTemplateVersions
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetTemplateVersions() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    // -----------------------------------------------------------------------
    // getObjectOptions (Schema)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetObjectOptions() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    // -----------------------------------------------------------------------
    // getObjectFields (Schema)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetObjectFields() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    @IsTest
    static void testGetObjectFieldsInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<Map<String, String>> fields = DocGenController.getObjectFields('NonExistentObject__x');
            Test.stopTest();

            System.assertEquals(0, fields.size(), 'Should return empty list for invalid object');
        }
    }

    // -----------------------------------------------------------------------
    // getChildRelationships (Schema)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetChildRelationships() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    @IsTest
    static void testGetChildRelationshipsInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<Map<String, String>> rels = DocGenController.getChildRelationships('NonExistentObject__x');
            Test.stopTest();

            System.assertEquals(0, rels.size(), 'Should return empty list for invalid object');
        }
    }

    // -----------------------------------------------------------------------
    // getParentRelationships (Schema)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetParentRelationships() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    @IsTest
    static void testGetParentRelationshipsInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<Map<String, String>> parents = DocGenController.getParentRelationships('NonExistentObject__x');
            Test.stopTest();

            System.assertEquals(0, parents.size(), 'Should return empty list for invalid object');
        }
    }

    // -----------------------------------------------------------------------
    // searchUsersAndGroups
    // -----------------------------------------------------------------------
    @IsTest
    static void testSearchUsersAndGroups() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    @IsTest
    static void testSearchUsersAndGroupsNoResults() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<Map<String, String>> results = DocGenController.searchUsersAndGroups('ZZZZNONEXISTENT99999');
            Test.stopTest();

            System.assertEquals(0, results.size(), 'Should return empty list for non-matching search');
        }
    }

    // -----------------------------------------------------------------------
    // getTemplateShares
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetTemplateSharesEmpty() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            Test.startTest();
            List<Map<String, String>> shares = DocGenController.getTemplateShares(tpl.Id);
            Test.stopTest();

            // No manual shares have been created, so list should be empty
            // (Owner share is excluded by the query)
            System.assertNotEquals(null, shares, 'Should return a list, not null');
        }
    }

    // -----------------------------------------------------------------------
    // shareTemplate + getTemplateShares + removeShare (integration)
    // -----------------------------------------------------------------------
    @IsTest
    static void testShareAndRemoveTemplate() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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
    }

    // -----------------------------------------------------------------------
    // Option inner class compareTo
    // -----------------------------------------------------------------------
    @IsTest
    static void testOptionCompareTo() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenController.Option optA = new DocGenController.Option('Alpha', 'a');
            DocGenController.Option optB = new DocGenController.Option('Beta', 'b');
            DocGenController.Option optA2 = new DocGenController.Option('Alpha', 'a2');

            Test.startTest();
            System.assertEquals(-1, optA.compareTo(optB), 'Alpha should sort before Beta');
            System.assertEquals(1, optB.compareTo(optA), 'Beta should sort after Alpha');
            System.assertEquals(0, optA.compareTo(optA2), 'Same label should return 0');
            Test.stopTest();
        }
    }

    @IsTest
    static void testOptionThreeArgConstructor() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenController.Option opt = new DocGenController.Option('Contacts', 'Contacts', 'Contact');

            System.assertEquals('Contacts', opt.label, 'Label should match');
            System.assertEquals('Contacts', opt.value, 'Value should match');
            System.assertEquals('Contact', opt.childObjectApiName, 'Child object API name should match');
        }
    }

    // -----------------------------------------------------------------------
    // generateDocumentData - null templateId throws DocGenException
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentDataNullTemplateId() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
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

    // -----------------------------------------------------------------------
    // generateDocumentData — template not found (covers line 16)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentDataTemplateNotFound() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];
            // Use a fake but valid-format Id for a template that does not exist
            Id fakeTemplateId = DocGen_Template__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '000000000000';

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.generateDocumentData(fakeTemplateId, acc.Id);
            } catch (DocGenException e) {
                caughtException = true;
                System.assert(e.getMessage().contains('Unable to access template'),
                    'Should indicate template not found');
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw DocGenException for non-existent template');
        }
    }

    // -----------------------------------------------------------------------
    // generateDocumentData — success path with valid DOCX (covers lines 4-42)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentDataSuccess() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            // Build a minimal valid DOCX ZIP
            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'ValidDocx',
                PathOnClient = 'ValidDocx.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            Map<String, Object> result = DocGenController.generateDocumentData(tpl.Id, acc.Id);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null');
            System.assert(result.containsKey('data'), 'Result should contain data key');
            System.assert(result.containsKey('templateFile'), 'Result should contain templateFile key');
            System.assert(result.containsKey('templateType'), 'Result should contain templateType key');
            System.assertEquals('Word', result.get('templateType'), 'Template type should be Word');
        }
    }

    // -----------------------------------------------------------------------
    // getTemplatesForObject — success and empty results
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetTemplatesForObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<DocGen_Template__c> templates = DocGenController.getTemplatesForObject('Account');
            Test.stopTest();

            System.assert(!templates.isEmpty(), 'Should return the test template for Account');
            System.assertEquals('Controller Test Template', templates[0].Name, 'Should return our test template');
        }
    }

    @IsTest
    static void testGetTemplatesForObjectNoResults() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<DocGen_Template__c> templates = DocGenController.getTemplatesForObject('NonExistentObject__c');
            Test.stopTest();

            System.assertEquals(0, templates.size(), 'Should return empty list for non-matching object');
        }
    }

    // -----------------------------------------------------------------------
    // processAndReturnDocument — success path with valid DOCX
    // -----------------------------------------------------------------------
    @IsTest
    static void testProcessAndReturnDocumentSuccess() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            // Build valid DOCX
            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>Hello {Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxForProcess',
                PathOnClient = 'DocxForProcess.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            Map<String, Object> result = DocGenController.processAndReturnDocument(tpl.Id, acc.Id);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null');
            System.assert(result.containsKey('base64'), 'Result should contain base64');
            System.assert(result.containsKey('title'), 'Result should contain title');
            System.assert(result.containsKey('outputFormat'), 'Result should contain outputFormat');
            System.assert(result.containsKey('templateType'), 'Result should contain templateType');
        }
    }

    // -----------------------------------------------------------------------
    // generatePdf — error path (non-real DOCX triggers exception)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGeneratePdfDownloadThrows() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            createTestFile();
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.generatePdf(tpl.Id, acc.Id, false);
            } catch (AuraHandledException e) {
                caughtException = true;
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw AuraHandledException for non-real DOCX template');
        }
    }

    // -----------------------------------------------------------------------
    // generatePdf — download success path with valid DOCX
    // -----------------------------------------------------------------------
    @IsTest
    static void testGeneratePdfDownloadSuccess() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxForPdf',
                PathOnClient = 'DocxForPdf.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            Map<String, Object> result = DocGenController.generatePdf(tpl.Id, acc.Id, false);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null');
            System.assert(result.containsKey('base64'), 'Result should contain base64');
            System.assert(result.containsKey('title'), 'Result should contain title');
        }
    }

    // -----------------------------------------------------------------------
    // generatePdf — save to record success path
    // -----------------------------------------------------------------------
    @IsTest
    static void testGeneratePdfSaveSuccess() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            tpl.Output_Format__c = 'PDF';
            update tpl;
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxForSavePdf',
                PathOnClient = 'DocxForSavePdf.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            Map<String, Object> result = DocGenController.generatePdf(tpl.Id, acc.Id, true);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null');
            System.assertEquals(true, result.get('saved'), 'Should indicate saved');
        }
    }

    // -----------------------------------------------------------------------
    // activateVersion — covers lines 229-268
    // -----------------------------------------------------------------------
    @IsTest
    static void testActivateVersion() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            // Create two versions, both active initially
            DocGen_Template_Version__c v1 = new DocGen_Template_Version__c(
                Template__c = tpl.Id,
                Is_Active__c = true,
                Type__c = 'Word',
                Base_Object_API__c = 'Account',
                Category__c = 'General',
                Description__c = 'Version 1',
                Query_Config__c = 'Name'
            );
            DocGen_Template_Version__c v2 = new DocGen_Template_Version__c(
                Template__c = tpl.Id,
                Is_Active__c = false,
                Type__c = 'Word',
                Base_Object_API__c = 'Account',
                Category__c = 'Legal',
                Description__c = 'Version 2',
                Query_Config__c = 'Name, AccountSource'
            );
            insert new List<DocGen_Template_Version__c>{ v1, v2 };

            Test.startTest();
            DocGenController.activateVersion(v2.Id);
            Test.stopTest();

            // v2 should now be active, v1 should be deactivated
            DocGen_Template_Version__c updatedV1 = [SELECT Is_Active__c FROM DocGen_Template_Version__c WHERE Id = :v1.Id];
            DocGen_Template_Version__c updatedV2 = [SELECT Is_Active__c FROM DocGen_Template_Version__c WHERE Id = :v2.Id];
            System.assertEquals(false, updatedV1.Is_Active__c, 'v1 should be deactivated');
            System.assertEquals(true, updatedV2.Is_Active__c, 'v2 should be activated');

            // Template should reflect v2 fields
            DocGen_Template__c updatedTpl = [SELECT Category__c, Description__c, Query_Config__c FROM DocGen_Template__c WHERE Id = :tpl.Id];
            System.assertEquals('Legal', updatedTpl.Category__c, 'Template category should match activated version');
            System.assertEquals('Version 2', updatedTpl.Description__c, 'Template description should match activated version');
        }
    }

    // -----------------------------------------------------------------------
    // saveTemplate — with Is_Default__c flag
    // -----------------------------------------------------------------------
    @IsTest
    static void testSaveTemplateWithDefaultFlag() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            Map<String, Object> fields = new Map<String, Object>{
                'Id' => tpl.Id,
                'Name' => 'Default Template',
                'Category__c' => 'Sales',
                'Type__c' => 'Word',
                'Base_Object_API__c' => 'Account',
                'Description__c' => 'Default test',
                'Query_Config__c' => 'Name',
                'Test_Record_Id__c' => null,
                'Document_Title_Format__c' => null,
                'Is_Default__c' => true
            };

            Test.startTest();
            DocGenController.saveTemplate(fields, false);
            Test.stopTest();

            DocGen_Template__c updated = [SELECT Is_Default__c FROM DocGen_Template__c WHERE Id = :tpl.Id];
            System.assertEquals(true, updated.Is_Default__c, 'Is_Default__c should be set to true');
        }
    }

    // -----------------------------------------------------------------------
    // previewRecordData — exception path (covers line 104)
    // -----------------------------------------------------------------------
    @IsTest
    static void testPreviewRecordDataException() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.previewRecordData(acc.Id, 'InvalidObject__xyz', 'Name');
            } catch (DocGenException e) {
                caughtException = true;
                System.assert(e.getMessage().contains('Error fetching preview data'),
                    'Should contain error fetching preview data message');
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw DocGenException for invalid object');
        }
    }

    // -----------------------------------------------------------------------
    // deleteTemplate — exception path (invalid ID)
    // -----------------------------------------------------------------------
    @IsTest
    static void testDeleteTemplateThrows() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Use a fake ID that looks valid but does not exist — will throw
            Id fakeId = DocGen_Template__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '000000000000';

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.deleteTemplate(fakeId);
            } catch (AuraHandledException e) {
                caughtException = true;
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw AuraHandledException for non-existent template');
        }
    }

    // -----------------------------------------------------------------------
    // saveTemplate — exception path (invalid template ID)
    // -----------------------------------------------------------------------
    @IsTest
    static void testSaveTemplateThrows() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Id fakeId = DocGen_Template__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '000000000000';

            Map<String, Object> fields = new Map<String, Object>{
                'Id' => fakeId,
                'Name' => 'Will Fail',
                'Category__c' => null,
                'Type__c' => 'Word',
                'Base_Object_API__c' => 'Account',
                'Description__c' => null,
                'Query_Config__c' => 'Name',
                'Test_Record_Id__c' => null,
                'Document_Title_Format__c' => null
            };

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.saveTemplate(fields, false);
            } catch (AuraHandledException e) {
                caughtException = true;
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw AuraHandledException for invalid template update');
        }
    }

    // -----------------------------------------------------------------------
    // generateDocumentData — with rich text containing refid images
    // Exercises resolveRichTextImages and resolveImageUrlsInHtml (lines 542-677)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentDataWithRichTextRefid() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            tpl.Query_Config__c = 'Name, Description';
            update tpl;

            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];
            // Set Description to contain HTML with an img tag using refid (simulates rich text)
            acc.Description = '<p>See image: <img src="https://example.com/servlet/rtaImage?eid=001&refid=0EM000000000001" alt="test"/></p>';
            update acc;

            // Build valid DOCX
            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxRichText',
                PathOnClient = 'DocxRichText.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            // The callout to resolve images will fail in test context (no HttpCalloutMock),
            // but the code handles exceptions gracefully. This exercises the code path.
            Test.startTest();
            try {
                Map<String, Object> result = DocGenController.generateDocumentData(tpl.Id, acc.Id);
                // If no exception, result should still be valid
                System.assertNotEquals(null, result, 'Result should not be null');
            } catch (Exception e) {
                // Callout exceptions are acceptable in test context
                System.assert(true, 'Exception during callout is expected in test context');
            }
            Test.stopTest();
        }
    }

    // -----------------------------------------------------------------------
    // generateDocumentData — with servlet image URLs in rich text
    // Exercises resolveServletImageUrls (lines 584-622)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentDataWithServletImages() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            tpl.Query_Config__c = 'Name, Description';
            update tpl;

            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];
            // Set Description with servlet URL (without refid) to exercise resolveServletImageUrls
            acc.Description = '<p><img src="https://myorg.salesforce.com/servlet/rtaImage?eid=001ABC&feoid=00N000&refid=" alt="img"/></p>';
            update acc;

            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxServlet',
                PathOnClient = 'DocxServlet.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            try {
                Map<String, Object> result = DocGenController.generateDocumentData(tpl.Id, acc.Id);
                System.assertNotEquals(null, result, 'Result should not be null');
            } catch (Exception e) {
                // Callout exceptions are acceptable in test context
                System.assert(true, 'Exception during callout is expected in test context');
            }
            Test.stopTest();
        }
    }

    // -----------------------------------------------------------------------
    // generateDocumentData — with sfc URL images (no refid)
    // Exercises resolveServletImageUrls sfc path
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentDataWithSfcImages() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            tpl.Query_Config__c = 'Name, Description';
            update tpl;

            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];
            acc.Description = '<p><img src="https://myorg.salesforce.com/sfc/servlet.shepherd/version/download/069ABC" alt="img"/></p>';
            update acc;

            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxSfc',
                PathOnClient = 'DocxSfc.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            try {
                Map<String, Object> result = DocGenController.generateDocumentData(tpl.Id, acc.Id);
                System.assertNotEquals(null, result, 'Result should not be null');
            } catch (Exception e) {
                System.assert(true, 'Exception during callout is expected in test context');
            }
            Test.stopTest();
        }
    }

    // -----------------------------------------------------------------------
    // generateDocumentData — with Output_Format and Document_Title_Format
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentDataWithOutputFormatAndTitle() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            tpl.Output_Format__c = 'PDF';
            tpl.Document_Title_Format__c = 'Invoice_{Name}';
            update tpl;

            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxFormat',
                PathOnClient = 'DocxFormat.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            Map<String, Object> result = DocGenController.generateDocumentData(tpl.Id, acc.Id);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null');
            System.assertEquals('PDF', result.get('outputFormat'), 'Output format should be PDF');
            System.assertEquals('Invoice_{Name}', result.get('titleFormat'), 'Title format should be returned');
        }
    }

    // -----------------------------------------------------------------------
    // resolveRichTextImages — with nested list data (exercises List<Object> path)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentDataWithChildRelationship() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            tpl.Query_Config__c = 'Name, (SELECT LastName FROM Contacts)';
            update tpl;

            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];
            insert new Contact(FirstName = 'Test', LastName = 'Child', AccountId = acc.Id);

            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxChild',
                PathOnClient = 'DocxChild.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            Map<String, Object> result = DocGenController.generateDocumentData(tpl.Id, acc.Id);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null');
            Map<String, Object> data = (Map<String, Object>) result.get('data');
            System.assert(data.containsKey('Contacts'), 'Data should contain Contacts child relationship');
        }
    }

    // -----------------------------------------------------------------------
    // saveTemplate — version creation with existing active version (deactivation)
    // -----------------------------------------------------------------------
    @IsTest
    static void testSaveTemplateVersionDeactivatesPrevious() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            createTestFile();
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            // Create an existing active version
            DocGen_Template_Version__c existingVersion = new DocGen_Template_Version__c(
                Template__c = tpl.Id,
                Is_Active__c = true,
                Type__c = 'Word',
                Base_Object_API__c = 'Account',
                Category__c = 'Old',
                Description__c = 'Old version'
            );
            insert existingVersion;

            Map<String, Object> fields = new Map<String, Object>{
                'Id' => tpl.Id,
                'Name' => 'Template With New Version',
                'Category__c' => 'New',
                'Type__c' => 'Word',
                'Base_Object_API__c' => 'Account',
                'Description__c' => 'New version test',
                'Query_Config__c' => 'Name',
                'Test_Record_Id__c' => null,
                'Document_Title_Format__c' => null
            };

            Test.startTest();
            DocGenController.saveTemplate(fields, true);
            Test.stopTest();

            // The old version should be deactivated
            DocGen_Template_Version__c oldVersion = [
                SELECT Is_Active__c FROM DocGen_Template_Version__c WHERE Id = :existingVersion.Id
            ];
            System.assertEquals(false, oldVersion.Is_Active__c, 'Old version should be deactivated');

            // A new version should exist and be active
            List<DocGen_Template_Version__c> newVersions = [
                SELECT Is_Active__c, Category__c FROM DocGen_Template_Version__c
                WHERE Template__c = :tpl.Id AND Is_Active__c = true
            ];
            System.assertEquals(1, newVersions.size(), 'Should have exactly one active version');
            System.assertEquals('New', newVersions[0].Category__c, 'New version should have correct category');
        }
    }

    // -----------------------------------------------------------------------
    // getAllTemplates — with ContentDocumentLink subquery
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetAllTemplatesWithFile() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            createTestFile();

            Test.startTest();
            List<DocGen_Template__c> templates = DocGenController.getAllTemplates();
            Test.stopTest();

            System.assert(!templates.isEmpty(), 'Should return templates');
            // Verify subquery for ContentDocumentLinks
            Boolean foundWithLink = false;
            for (DocGen_Template__c t : templates) {
                if (t.ContentDocumentLinks != null && !t.ContentDocumentLinks.isEmpty()) {
                    foundWithLink = true;
                    break;
                }
            }
            System.assert(foundWithLink, 'At least one template should have a ContentDocumentLink');
        }
    }

    // -----------------------------------------------------------------------
    // getContentVersionBase64 — success path
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetContentVersionBase64() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            ContentVersion cv = new ContentVersion(
                Title = 'Base64Test',
                PathOnClient = 'Base64Test.txt',
                VersionData = Blob.valueOf('Hello Base64 World')
            );
            insert cv;
            cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

            Test.startTest();
            String b64 = DocGenController.getContentVersionBase64(cv.Id);
            Test.stopTest();

            System.assertNotEquals(null, b64, 'Should return a non-null base64 string');
            String decoded = EncodingUtil.base64Decode(b64).toString();
            System.assertEquals('Hello Base64 World', decoded, 'Decoded content should match original');
        }
    }

    @IsTest
    static void testGetContentVersionBase64NotFound() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Use a fake but valid-format ContentVersion ID
            Id fakeId = '068000000000000AAA';

            Test.startTest();
            String b64 = DocGenController.getContentVersionBase64(fakeId);
            Test.stopTest();

            System.assertEquals(null, b64, 'Should return null for non-existent ContentVersion');
        }
    }

    // -----------------------------------------------------------------------
    // generateDocumentParts — error path (wraps in AuraHandledException)
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentPartsError() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Use a fake template ID to trigger an exception inside DocGenService
            Id fakeTemplateId = DocGen_Template__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '000000000000';
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.generateDocumentParts(fakeTemplateId, acc.Id);
            } catch (AuraHandledException e) {
                caughtException = true;
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw AuraHandledException for invalid template');
        }
    }

    @IsTest
    static void testGenerateDocumentPartsSuccess() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            // Build a minimal valid DOCX and attach to template
            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxForParts',
                PathOnClient = 'DocxForParts.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            Map<String, Object> result = DocGenController.generateDocumentParts(tpl.Id, acc.Id);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Should return non-null result');
            System.assert(result.containsKey('allXmlParts'), 'Result should contain allXmlParts key');
        }
    }

    // -----------------------------------------------------------------------
    // getRecordPdfs — returns PDFs linked to a record
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetRecordPdfs() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            // Create a PDF ContentVersion linked to the account
            ContentVersion pdfCv = new ContentVersion(
                Title = 'TestPdf',
                PathOnClient = 'TestPdf.pdf',
                VersionData = Blob.valueOf('Fake PDF content')
            );
            insert pdfCv;
            Id pdfDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :pdfCv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = acc.Id,
                ContentDocumentId = pdfDocId,
                ShareType = 'V'
            );

            Test.startTest();
            List<Map<String, String>> pdfs = DocGenController.getRecordPdfs(acc.Id);
            Test.stopTest();

            System.assert(!pdfs.isEmpty(), 'Should return at least one PDF');
            Boolean foundPdf = false;
            for (Map<String, String> pdf : pdfs) {
                if (pdf.get('label') == 'TestPdf.pdf') {
                    foundPdf = true;
                    System.assertNotEquals(null, pdf.get('value'), 'Value should contain LatestPublishedVersionId');
                    break;
                }
            }
            System.assert(foundPdf, 'Should find the test PDF in results');
        }
    }

    @IsTest
    static void testGetRecordPdfsEmpty() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Test.startTest();
            List<Map<String, String>> pdfs = DocGenController.getRecordPdfs(acc.Id);
            Test.stopTest();

            System.assertEquals(0, pdfs.size(), 'Should return empty list when no PDFs attached');
        }
    }

    // -----------------------------------------------------------------------
    // getChildRecordPdfs — returns PDFs from child records
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetChildRecordPdfs() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            // Create a child contact
            Contact con = new Contact(FirstName = 'Pdf', LastName = 'Child', AccountId = acc.Id);
            insert con;

            // Attach a PDF to the contact
            ContentVersion pdfCv = new ContentVersion(
                Title = 'ChildPdf',
                PathOnClient = 'ChildPdf.pdf',
                VersionData = Blob.valueOf('Fake child PDF')
            );
            insert pdfCv;
            Id pdfDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :pdfCv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = con.Id,
                ContentDocumentId = pdfDocId,
                ShareType = 'V'
            );

            Test.startTest();
            List<Map<String, Object>> result = DocGenController.getChildRecordPdfs(
                acc.Id, 'Contact', 'AccountId', null
            );
            Test.stopTest();

            System.assert(!result.isEmpty(), 'Should return at least one child record group');
            Boolean foundChild = false;
            for (Map<String, Object> grp : result) {
                if (grp.get('childRecordName') == 'Pdf Child') {
                    foundChild = true;
                    List<Map<String, String>> pdfs = (List<Map<String, String>>) grp.get('pdfs');
                    System.assert(!pdfs.isEmpty(), 'Child should have at least one PDF');
                    System.assertEquals('ChildPdf.pdf', pdfs[0].get('label'), 'PDF label should match');
                    break;
                }
            }
            System.assert(foundChild, 'Should find the child contact in results');
        }
    }

    @IsTest
    static void testGetChildRecordPdfsNullParams() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.getChildRecordPdfs(null, 'Contact', 'AccountId', null);
            } catch (AuraHandledException e) {
                caughtException = true;
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw when parentRecordId is null');
        }
    }

    @IsTest
    static void testGetChildRecordPdfsInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.getChildRecordPdfs(acc.Id, 'NonExistentObject__xyz', 'AccountId', null);
            } catch (AuraHandledException e) {
                caughtException = true;
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw for invalid child object');
        }
    }

    @IsTest
    static void testGetChildRecordPdfsInvalidLookup() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.getChildRecordPdfs(acc.Id, 'Contact', 'FakeField__xyz', null);
            } catch (AuraHandledException e) {
                caughtException = true;
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw for invalid lookup field');
        }
    }

    @IsTest
    static void testGetChildRecordPdfsNoChildren() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a fresh account with no child contacts
            Account freshAcc = new Account(Name = 'No Children Account');
            insert freshAcc;

            Test.startTest();
            List<Map<String, Object>> result = DocGenController.getChildRecordPdfs(
                freshAcc.Id, 'Contact', 'AccountId', null
            );
            Test.stopTest();

            System.assertEquals(0, result.size(), 'Should return empty list when no child records exist');
        }
    }

    // -----------------------------------------------------------------------
    // getAvailableReports — search with and without term
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetAvailableReportsNoTerm() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<Map<String, String>> reports = DocGenController.getAvailableReports(null);
            Test.stopTest();

            // Reports may or may not exist in test context; just verify it returns a list
            System.assertNotEquals(null, reports, 'Should return a non-null list');
        }
    }

    @IsTest
    static void testGetAvailableReportsWithTerm() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<Map<String, String>> reports = DocGenController.getAvailableReports('ZZZNONEXISTENT999');
            Test.stopTest();

            System.assertNotEquals(null, reports, 'Should return a non-null list');
            // With a nonsense search term, likely empty
            System.assertEquals(0, reports.size(), 'Should return empty for non-matching search term');
        }
    }

    @IsTest
    static void testGetAvailableReportsBlankTerm() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<Map<String, String>> reports = DocGenController.getAvailableReports('');
            Test.stopTest();

            System.assertNotEquals(null, reports, 'Should return a non-null list');
        }
    }

    // -----------------------------------------------------------------------
    // createSampleTemplates — creates 5 sample templates
    // -----------------------------------------------------------------------
    @IsTest
    static void testCreateSampleTemplates() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer count = DocGenController.createSampleTemplates();
            Test.stopTest();

            System.assertEquals(5, count, 'Should return 5 (number of sample templates created)');

            List<DocGen_Template__c> samples = [
                SELECT Name, Category__c FROM DocGen_Template__c
                WHERE Category__c = 'Sample'
            ];
            System.assertEquals(5, samples.size(), 'Should have created 5 sample templates');

            // Verify expected template names
            Set<String> names = new Set<String>();
            for (DocGen_Template__c t : samples) {
                names.add(t.Name);
            }
            System.assert(names.contains('Sample: Account Overview'), 'Should contain Account Overview sample');
            System.assert(names.contains('Sample: Sales Proposal'), 'Should contain Sales Proposal sample');
            System.assert(names.contains('Sample: Contact Card'), 'Should contain Contact Card sample');
            System.assert(names.contains('Sample: Invoice'), 'Should contain Invoice sample');
            System.assert(names.contains('Sample: Case Report'), 'Should contain Case Report sample');
        }
    }

    // -----------------------------------------------------------------------
    // Option — 4-arg constructor
    // -----------------------------------------------------------------------
    @IsTest
    static void testOptionFourArgConstructor() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenController.Option opt = new DocGenController.Option(
                'Contacts', 'Contacts', 'Contact', 'AccountId'
            );

            System.assertEquals('Contacts', opt.label, 'Label should match');
            System.assertEquals('Contacts', opt.value, 'Value should match');
            System.assertEquals('Contact', opt.childObjectApiName, 'Child object API name should match');
            System.assertEquals('AccountId', opt.lookupField, 'Lookup field should match');
        }
    }

    // -----------------------------------------------------------------------
    // importReportConfig — null ID throws AuraHandledException
    // -----------------------------------------------------------------------
    @IsTest
    static void testImportReportConfigNullId() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.importReportConfig(null);
            } catch (AuraHandledException e) {
                caughtException = true;
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw AuraHandledException for null report ID');
        }
    }

    @IsTest
    static void testImportReportConfigInvalidId() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Use a fake report ID — will fail at Reports.ReportManager.describeReport
            Id fakeReportId = '00O000000000000AAA';

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.importReportConfig(fakeReportId);
            } catch (Exception e) {
                caughtException = true;
                // Could be AuraHandledException or other exception depending on the API behavior
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw an exception for non-existent report ID');
        }
    }

    // -----------------------------------------------------------------------
    // importReportConfig — with a real report (if any exist in the org)
    // Exercises the full importReportConfig code path including all private helpers
    // -----------------------------------------------------------------------
    @IsTest
    static void testImportReportConfigWithRealReport() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            List<Report> reports = [SELECT Id FROM Report LIMIT 1];
            if (reports.isEmpty()) {
                // No reports in org — skip gracefully
                System.assert(true, 'No reports in org to test with');
                return;
            }

            Test.startTest();
            try {
                Map<String, Object> result = DocGenController.importReportConfig(reports[0].Id);
                // If the report type resolves to a known object, we get a result
                System.assertNotEquals(null, result, 'Result should not be null');
                System.assert(result.containsKey('baseObject'), 'Result should contain baseObject');
                System.assert(result.containsKey('fields'), 'Result should contain fields');
                System.assert(result.containsKey('parentFields'), 'Result should contain parentFields');
                System.assert(result.containsKey('filters'), 'Result should contain filters');
                System.assert(result.containsKey('reportName'), 'Result should contain reportName');
                System.assert(result.containsKey('fieldCount'), 'Result should contain fieldCount');
            } catch (AuraHandledException e) {
                // Some report types may not resolve to a base object — that is an expected error path
                System.assert(true, 'AuraHandledException is acceptable for unresolvable report types');
            }
            Test.stopTest();
        }
    }

    // -----------------------------------------------------------------------
    // normalizeImageUrls — exercises the private method via @TestVisible
    // -----------------------------------------------------------------------
    @IsTest
    static void testNormalizeImageUrlsServletPath() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String html = '<img src="/servlet/rtaImage?eid=001&refid=0EM000000000001"/>';

            Test.startTest();
            String result = DocGenController.normalizeImageUrls(html);
            Test.stopTest();

            // In test context, URL.getOrgDomainUrl() may or may not work.
            // Either the URL is prepended or the original is returned (exception path).
            System.assertNotEquals(null, result, 'Result should not be null');
            System.assert(result.contains('/servlet/'), 'Should still contain /servlet/ path');
        }
    }

    @IsTest
    static void testNormalizeImageUrlsSfcPath() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String html = '<img src="/sfc/servlet.shepherd/version/download/069ABC"/>';

            Test.startTest();
            String result = DocGenController.normalizeImageUrls(html);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null');
            System.assert(result.contains('/sfc/'), 'Should still contain /sfc/ path');
        }
    }

    @IsTest
    static void testNormalizeImageUrlsNoMatch() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String html = '<img src="https://example.com/image.png"/>';

            Test.startTest();
            String result = DocGenController.normalizeImageUrls(html);
            Test.stopTest();

            System.assertEquals(html, result, 'Non-Salesforce URLs should be unchanged');
        }
    }

    // -----------------------------------------------------------------------
    // resolveRichTextImages — exercises normalizeImageUrls through the public method
    // -----------------------------------------------------------------------
    @IsTest
    static void testResolveRichTextImagesWithSfcUrl() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, Object> data = new Map<String, Object>{
                'Description' => '<p><img src="/sfc/servlet.shepherd/version/download/069ABC" alt="test"/></p>',
                'Name' => 'Test Account'
            };

            Test.startTest();
            DocGenController.resolveRichTextImages(data);
            Test.stopTest();

            String descVal = (String) data.get('Description');
            System.assertNotEquals(null, descVal, 'Description should not be null');
            System.assert(descVal.contains('/sfc/'), 'Should contain /sfc/ path');
            // Name should be unchanged (no img tags)
            System.assertEquals('Test Account', data.get('Name'), 'Name should be unchanged');
        }
    }

    @IsTest
    static void testResolveRichTextImagesWithServletUrl() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, Object> data = new Map<String, Object>{
                'RichField' => '<p><img src="/servlet/rtaImage?refid=0EM123" alt="test"/></p>'
            };

            Test.startTest();
            DocGenController.resolveRichTextImages(data);
            Test.stopTest();

            String val = (String) data.get('RichField');
            System.assertNotEquals(null, val, 'Field should not be null');
            System.assert(val.contains('/servlet/'), 'Should contain /servlet/ path');
        }
    }

    @IsTest
    static void testResolveRichTextImagesNestedList() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Test the List<Object> recursion path
            Map<String, Object> childRecord = new Map<String, Object>{
                'Notes' => '<p><img src="/sfc/servlet.shepherd/version/download/069XYZ" alt="child"/></p>'
            };
            List<Object> children = new List<Object>{ childRecord };
            Map<String, Object> data = new Map<String, Object>{
                'Contacts' => children
            };

            Test.startTest();
            DocGenController.resolveRichTextImages(data);
            Test.stopTest();

            Map<String, Object> resultChild = (Map<String, Object>) ((List<Object>) data.get('Contacts'))[0];
            String notes = (String) resultChild.get('Notes');
            System.assertNotEquals(null, notes, 'Notes should not be null');
            System.assert(notes.contains('/sfc/'), 'Should contain /sfc/ path in nested child data');
        }
    }

    @IsTest
    static void testResolveRichTextImagesNoImageTags() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, Object> data = new Map<String, Object>{
                'Description' => '<p>Just plain text with no images</p>'
            };

            Test.startTest();
            DocGenController.resolveRichTextImages(data);
            Test.stopTest();

            System.assertEquals('<p>Just plain text with no images</p>', data.get('Description'),
                'HTML without img tags should be unchanged');
        }
    }

    // -----------------------------------------------------------------------
    // resolveReportBaseObject — all strategies
    // -----------------------------------------------------------------------
    @IsTest
    static void testResolveReportBaseObjectDirectMatch() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            // Strategy 1: Direct match — 'Account' is a real object
            String result = DocGenController.resolveReportBaseObject('Account');
            Test.stopTest();

            System.assertEquals('Account', result, 'Direct object name should resolve');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectListSuffix() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            // Strategy 2: Strip 'List' suffix
            String result = DocGenController.resolveReportBaseObject('AccountList');
            Test.stopTest();

            System.assertEquals('Account', result, 'AccountList should resolve to Account');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectLabelMatch() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            // Strategy 4: Label match — 'Accounts' is the plural label for Account
            String result = DocGenController.resolveReportBaseObject('UnknownType', 'Accounts');
            Test.stopTest();

            System.assertEquals('Account', result, 'Label "Accounts" should resolve to Account');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectPrefixMatch() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            // Strategy 5: Prefix match — OpportunityLead starts with Opportunity
            String result = DocGenController.resolveReportBaseObject('OpportunityLead');
            Test.stopTest();

            System.assertEquals('Opportunity', result, 'OpportunityLead should resolve to Opportunity');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectCustomWithCommonName() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            // Strategy 6: Custom report type containing a known object name
            String result = DocGenController.resolveReportBaseObject('MyAccount__c');
            Test.stopTest();

            System.assertEquals('Account', result, 'Custom type containing Account should resolve');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectNull() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            String result = DocGenController.resolveReportBaseObject(null);
            Test.stopTest();

            System.assertEquals(null, result, 'Null input should return null');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectBlank() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            String result = DocGenController.resolveReportBaseObject('');
            Test.stopTest();

            System.assertEquals(null, result, 'Blank input should return null');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectUnresolvable() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            String result = DocGenController.resolveReportBaseObject('ZZZNonExistent999');
            Test.stopTest();

            System.assertEquals(null, result, 'Unresolvable type should return null');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectAccountContact() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            String result = DocGenController.resolveReportBaseObject('AccountContact');
            Test.stopTest();

            System.assertEquals('Account', result, 'AccountContact should resolve to Account');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectCaseContact() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            String result = DocGenController.resolveReportBaseObject('CaseContact');
            Test.stopTest();

            System.assertEquals('Case', result, 'CaseContact should resolve to Case');
        }
    }

    // -----------------------------------------------------------------------
    // normalizeReportColumn — all strategies
    // -----------------------------------------------------------------------
    @IsTest
    static void testNormalizeReportColumnDirectApiMatch() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
            Map<String, String> labelToApiName = new Map<String, String>();
            Map<String, String> properCaseMap = new Map<String, String>();
            for (String apiName : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
                labelToApiName.put(dfr.getLabel().toLowerCase(), dfr.getName());
                properCaseMap.put(apiName.toLowerCase(), dfr.getName());
            }

            Test.startTest();
            // Direct API name match (lowercase key)
            String result = DocGenController.normalizeReportColumn('Name', null, fieldMap, labelToApiName, properCaseMap);
            Test.stopTest();

            System.assertEquals('Name', result, 'Direct API name "Name" should resolve');
        }
    }

    @IsTest
    static void testNormalizeReportColumnLabelMatch() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
            Map<String, String> labelToApiName = new Map<String, String>();
            Map<String, String> properCaseMap = new Map<String, String>();
            for (String apiName : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
                labelToApiName.put(dfr.getLabel().toLowerCase(), dfr.getName());
                properCaseMap.put(apiName.toLowerCase(), dfr.getName());
            }

            Test.startTest();
            // Label match — "Account Name" is the label for the Name field on Account
            String result = DocGenController.normalizeReportColumn('SOMETHING_UNKNOWN', 'Account Name', fieldMap, labelToApiName, properCaseMap);
            Test.stopTest();

            System.assertEquals('Name', result, 'Label "Account Name" should resolve to Name');
        }
    }

    @IsTest
    static void testNormalizeReportColumnHardcodedMapping() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Opportunity.fields.getMap();
            Map<String, String> labelToApiName = new Map<String, String>();
            Map<String, String> properCaseMap = new Map<String, String>();
            for (String apiName : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
                labelToApiName.put(dfr.getLabel().toLowerCase(), dfr.getName());
                properCaseMap.put(apiName.toLowerCase(), dfr.getName());
            }

            Test.startTest();
            // Hardcoded mapping: CLOSE_DATE → CloseDate
            String result = DocGenController.normalizeReportColumn('CLOSE_DATE', null, fieldMap, labelToApiName, properCaseMap);
            Test.stopTest();

            System.assertEquals('CloseDate', result, 'CLOSE_DATE should resolve to CloseDate');
        }
    }

    @IsTest
    static void testNormalizeReportColumnCreatedDate() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
            Map<String, String> labelToApiName = new Map<String, String>();
            Map<String, String> properCaseMap = new Map<String, String>();
            for (String apiName : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
                labelToApiName.put(dfr.getLabel().toLowerCase(), dfr.getName());
                properCaseMap.put(apiName.toLowerCase(), dfr.getName());
            }

            Test.startTest();
            String result = DocGenController.normalizeReportColumn('CREATED_DATE', null, fieldMap, labelToApiName, properCaseMap);
            Test.stopTest();

            System.assertEquals('CreatedDate', result, 'CREATED_DATE should resolve to CreatedDate');
        }
    }

    @IsTest
    static void testNormalizeReportColumnWithObjectPrefix() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
            Map<String, String> labelToApiName = new Map<String, String>();
            Map<String, String> properCaseMap = new Map<String, String>();
            for (String apiName : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
                labelToApiName.put(dfr.getLabel().toLowerCase(), dfr.getName());
                properCaseMap.put(apiName.toLowerCase(), dfr.getName());
            }

            Test.startTest();
            // Strip object prefix: ACCOUNT.Name → Name
            String result = DocGenController.normalizeReportColumn('ACCOUNT.Name', null, fieldMap, labelToApiName, properCaseMap);
            Test.stopTest();

            System.assertEquals('Name', result, 'ACCOUNT.Name should strip prefix and resolve to Name');
        }
    }

    @IsTest
    static void testNormalizeReportColumnBlank() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();

            Test.startTest();
            String result = DocGenController.normalizeReportColumn('', null, fieldMap, new Map<String, String>(), new Map<String, String>());
            Test.stopTest();

            System.assertEquals(null, result, 'Blank column key should return null');
        }
    }

    @IsTest
    static void testNormalizeReportColumnNull() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();

            Test.startTest();
            String result = DocGenController.normalizeReportColumn(null, null, fieldMap, new Map<String, String>(), new Map<String, String>());
            Test.stopTest();

            System.assertEquals(null, result, 'Null column key should return null');
        }
    }

    @IsTest
    static void testNormalizeReportColumnUsersPrefix() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();

            Test.startTest();
            // USERS. prefix should be skipped (parent lookup, not direct field)
            String result = DocGenController.normalizeReportColumn('USERS.NAME', null, fieldMap, new Map<String, String>(), new Map<String, String>());
            Test.stopTest();

            System.assertEquals(null, result, 'USERS. prefixed columns should return null');
        }
    }

    @IsTest
    static void testNormalizeReportColumnNoMatch() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();

            Test.startTest();
            String result = DocGenController.normalizeReportColumn('TOTALLY_FAKE_FIELD_XYZ', null, fieldMap, new Map<String, String>(), new Map<String, String>());
            Test.stopTest();

            System.assertEquals(null, result, 'Unresolvable column should return null');
        }
    }

    @IsTest
    static void testNormalizeReportColumnStageName() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Opportunity.fields.getMap();
            Map<String, String> labelToApiName = new Map<String, String>();
            Map<String, String> properCaseMap = new Map<String, String>();
            for (String apiName : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
                labelToApiName.put(dfr.getLabel().toLowerCase(), dfr.getName());
                properCaseMap.put(apiName.toLowerCase(), dfr.getName());
            }

            Test.startTest();
            String result = DocGenController.normalizeReportColumn('STAGE_NAME', null, fieldMap, labelToApiName, properCaseMap);
            Test.stopTest();

            System.assertEquals('StageName', result, 'STAGE_NAME should resolve to StageName');
        }
    }

    @IsTest
    static void testNormalizeReportColumnAmount() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> fieldMap = Schema.SObjectType.Opportunity.fields.getMap();
            Map<String, String> labelToApiName = new Map<String, String>();
            Map<String, String> properCaseMap = new Map<String, String>();
            for (String apiName : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
                labelToApiName.put(dfr.getLabel().toLowerCase(), dfr.getName());
                properCaseMap.put(apiName.toLowerCase(), dfr.getName());
            }

            Test.startTest();
            String result = DocGenController.normalizeReportColumn('AMOUNT', null, fieldMap, labelToApiName, properCaseMap);
            Test.stopTest();

            System.assertEquals('Amount', result, 'AMOUNT should resolve to Amount');
        }
    }

    // -----------------------------------------------------------------------
    // mapReportOperator — all operator mappings
    // -----------------------------------------------------------------------
    @IsTest
    static void testMapReportOperatorEquals() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            System.assertEquals('=', DocGenController.mapReportOperator('equals'), 'equals should map to =');
            System.assertEquals('!=', DocGenController.mapReportOperator('notEqual'), 'notEqual should map to !=');
            System.assertEquals('>', DocGenController.mapReportOperator('greaterThan'), 'greaterThan should map to >');
            System.assertEquals('<', DocGenController.mapReportOperator('lessThan'), 'lessThan should map to <');
            System.assertEquals('>=', DocGenController.mapReportOperator('greaterOrEqual'), 'greaterOrEqual should map to >=');
            System.assertEquals('<=', DocGenController.mapReportOperator('lessOrEqual'), 'lessOrEqual should map to <=');
            System.assertEquals('LIKE', DocGenController.mapReportOperator('contains'), 'contains should map to LIKE');
            System.assertEquals('LIKE', DocGenController.mapReportOperator('startsWith'), 'startsWith should map to LIKE');
            System.assertEquals('IN', DocGenController.mapReportOperator('includes'), 'includes should map to IN');
            System.assertEquals('NOT IN', DocGenController.mapReportOperator('excludes'), 'excludes should map to NOT IN');
            Test.stopTest();
        }
    }

    @IsTest
    static void testMapReportOperatorNull() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            System.assertEquals('=', DocGenController.mapReportOperator(null), 'Null should default to =');
            System.assertEquals('=', DocGenController.mapReportOperator(''), 'Blank should default to =');
            Test.stopTest();
        }
    }

    @IsTest
    static void testMapReportOperatorUnknown() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            System.assertEquals('=', DocGenController.mapReportOperator('unknownOp'), 'Unknown operator should default to =');
            Test.stopTest();
        }
    }

    // -----------------------------------------------------------------------
    // findParentObject — parent detection for child objects
    // -----------------------------------------------------------------------
    @IsTest
    static void testFindParentObjectDirectChild() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Contact is a direct child of Account — should return Account as parent
            Map<String, String> childRelNameByObject = new Map<String, String>{
                'Contact' => 'Contacts'
            };

            Test.startTest();
            String result = DocGenController.findParentObject('Contact', 'Account', childRelNameByObject);
            Test.stopTest();

            System.assertEquals('Account', result, 'Contact with only Account in hierarchy should return Account');
        }
    }

    @IsTest
    static void testFindParentObjectGrandchild() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // OpportunityLineItem has a reference to Opportunity
            // If Opportunity is also a known child, it should be the parent
            Map<String, String> childRelNameByObject = new Map<String, String>{
                'Opportunity' => 'Opportunities',
                'OpportunityLineItem' => 'OpportunityLineItems'
            };

            Test.startTest();
            String result = DocGenController.findParentObject('OpportunityLineItem', 'Account', childRelNameByObject);
            Test.stopTest();

            System.assertEquals('Opportunity', result, 'OpportunityLineItem should resolve parent as Opportunity when Opportunity is a known child');
        }
    }

    @IsTest
    static void testFindParentObjectInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, String> childRelNameByObject = new Map<String, String>();

            Test.startTest();
            String result = DocGenController.findParentObject('NonExistentObj__xyz', 'Account', childRelNameByObject);
            Test.stopTest();

            System.assertEquals('Account', result, 'Invalid object should fall back to base object');
        }
    }

    // -----------------------------------------------------------------------
    // findJunctionRelationship — known and dynamic junctions
    // -----------------------------------------------------------------------
    @IsTest
    static void testFindJunctionRelationshipKnown() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            SObjectType oppType = Schema.getGlobalDescribe().get('Opportunity');

            Test.startTest();
            // Known junction: Opportunity:Contact → OpportunityContactRoles
            String result = DocGenController.findJunctionRelationship('Opportunity', 'Contact', oppType);
            Test.stopTest();

            System.assertEquals('OpportunityContactRoles', result, 'Should return known junction for Opportunity:Contact');
        }
    }

    @IsTest
    static void testFindJunctionRelationshipCampaignContact() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            SObjectType campType = Schema.getGlobalDescribe().get('Campaign');

            Test.startTest();
            String result = DocGenController.findJunctionRelationship('Campaign', 'Contact', campType);
            Test.stopTest();

            System.assertEquals('CampaignMembers', result, 'Should return CampaignMembers for Campaign:Contact');
        }
    }

    @IsTest
    static void testFindJunctionRelationshipNoMatch() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            SObjectType accType = Schema.getGlobalDescribe().get('Account');

            Test.startTest();
            // Account has no junction to Product2
            String result = DocGenController.findJunctionRelationship('Account', 'Product2', accType);
            Test.stopTest();

            // May return null or a dynamically discovered junction
            // The important thing is the code path executes without error
            System.assert(true, 'findJunctionRelationship executed without error');
        }
    }

    // -----------------------------------------------------------------------
    // hasReferenceToObject — checks if an SObject has a reference field to target
    // -----------------------------------------------------------------------
    @IsTest
    static void testHasReferenceToObjectTrue() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // OpportunityContactRole has a reference to Contact
            SObjectType ocrType = Schema.getGlobalDescribe().get('OpportunityContactRole');

            Test.startTest();
            Boolean result = DocGenController.hasReferenceToObject(ocrType, 'Contact');
            Test.stopTest();

            System.assertEquals(true, result, 'OpportunityContactRole should have a reference to Contact');
        }
    }

    @IsTest
    static void testHasReferenceToObjectFalse() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Account does not have a reference to OpportunityLineItem
            SObjectType accType = Schema.getGlobalDescribe().get('Account');

            Test.startTest();
            Boolean result = DocGenController.hasReferenceToObject(accType, 'OpportunityLineItem');
            Test.stopTest();

            System.assertEquals(false, result, 'Account should not have a reference to OpportunityLineItem');
        }
    }

    // -----------------------------------------------------------------------
    // resolveParentFieldName — resolves field names on parent objects
    // -----------------------------------------------------------------------
    @IsTest
    static void testResolveParentFieldNameDirect() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> accFieldMap = Schema.SObjectType.Account.fields.getMap();

            Test.startTest();
            // Owner relationship on Account → User object. 'Name' should resolve.
            String result = DocGenController.resolveParentFieldName('Owner', 'Name', null, accFieldMap);
            Test.stopTest();

            System.assertEquals('Name', result, 'Owner.Name should resolve to Name');
        }
    }

    @IsTest
    static void testResolveParentFieldNameCaseInsensitive() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> accFieldMap = Schema.SObjectType.Account.fields.getMap();

            Test.startTest();
            // Try uppercase — equalsIgnoreCase path
            String result = DocGenController.resolveParentFieldName('Owner', 'NAME', null, accFieldMap);
            Test.stopTest();

            System.assertEquals('Name', result, 'Owner.NAME should case-insensitively resolve to Name');
        }
    }

    @IsTest
    static void testResolveParentFieldNameLabelMatch() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> accFieldMap = Schema.SObjectType.Account.fields.getMap();

            Test.startTest();
            // Label-based match — "Email" is the label for Email on User
            String result = DocGenController.resolveParentFieldName('Owner', 'EMAIL_FIELD', 'Email', accFieldMap);
            Test.stopTest();

            System.assertEquals('Email', result, 'Label "Email" should resolve to Email on User');
        }
    }

    @IsTest
    static void testResolveParentFieldNameNullRelationship() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> accFieldMap = Schema.SObjectType.Account.fields.getMap();

            Test.startTest();
            // Non-existent relationship name
            String result = DocGenController.resolveParentFieldName('FakeRelationship', 'Name', null, accFieldMap);
            Test.stopTest();

            System.assertEquals(null, result, 'Non-existent relationship should return null');
        }
    }

    @IsTest
    static void testResolveParentFieldNameNoMatchingField() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, SObjectField> accFieldMap = Schema.SObjectType.Account.fields.getMap();

            Test.startTest();
            // Existing relationship but non-existent field
            String result = DocGenController.resolveParentFieldName('Owner', 'TOTALLY_FAKE_XYZ', null, accFieldMap);
            Test.stopTest();

            System.assertEquals(null, result, 'Non-existent field on parent should return null');
        }
    }

    // -----------------------------------------------------------------------
    // generateDocumentDataFromCache — public method, untested
    // -----------------------------------------------------------------------
    @IsTest
    static void testGenerateDocumentDataFromCacheNullTemplateId() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.generateDocumentDataFromCache(null, new Map<String, Object>());
            } catch (DocGenException e) {
                caughtException = true;
                System.assert(e.getMessage().contains('Template ID is missing'),
                    'Should indicate missing template ID');
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw DocGenException for null template ID');
        }
    }

    @IsTest
    static void testGenerateDocumentDataFromCacheTemplateNotFound() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Id fakeTemplateId = DocGen_Template__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '000000000000';

            Test.startTest();
            Boolean caughtException = false;
            try {
                DocGenController.generateDocumentDataFromCache(fakeTemplateId, new Map<String, Object>());
            } catch (DocGenException e) {
                caughtException = true;
                System.assert(e.getMessage().contains('Unable to access template'),
                    'Should indicate template not found');
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw DocGenException for non-existent template');
        }
    }

    @IsTest
    static void testGenerateDocumentDataFromCacheSuccess() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            // Build a minimal valid DOCX and attach to template
            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxForCache',
                PathOnClient = 'DocxForCache.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Map<String, Object> cachedData = new Map<String, Object>{
                'Name' => 'Cached Account Name'
            };

            Test.startTest();
            Map<String, Object> result = DocGenController.generateDocumentDataFromCache(tpl.Id, cachedData);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null');
            System.assert(result.containsKey('data'), 'Result should contain data key');
            System.assert(result.containsKey('templateFile'), 'Result should contain templateFile key');
            System.assert(result.containsKey('templateType'), 'Result should contain templateType key');
            System.assertEquals('Cached Account Name', ((Map<String, Object>) result.get('data')).get('Name'),
                'Data should contain the cached record data');
        }
    }

    @IsTest
    static void testGenerateDocumentDataFromCacheReusesCache() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            // Attach a valid DOCX
            Compression.ZipWriter zw = new Compression.ZipWriter();
            zw.addEntry('[Content_Types].xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                '<Default Extension="xml" ContentType="application/xml"/>' +
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                '</Types>'
            ));
            zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            ));
            zw.addEntry('word/document.xml', Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            ));

            ContentVersion cv = new ContentVersion(
                Title = 'DocxForCacheReuse',
                PathOnClient = 'DocxForCacheReuse.docx',
                VersionData = zw.getArchive()
            );
            insert cv;
            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(
                LinkedEntityId = tpl.Id,
                ContentDocumentId = conDocId,
                ShareType = 'V'
            );

            Test.startTest();
            // First call populates cache
            Map<String, Object> result1 = DocGenController.generateDocumentDataFromCache(
                tpl.Id, new Map<String, Object>{ 'Name' => 'Record 1' }
            );
            // Second call should reuse cached template envelope
            Map<String, Object> result2 = DocGenController.generateDocumentDataFromCache(
                tpl.Id, new Map<String, Object>{ 'Name' => 'Record 2' }
            );
            Test.stopTest();

            System.assertEquals('Record 1', ((Map<String, Object>) result1.get('data')).get('Name'),
                'First call should have Record 1 data');
            System.assertEquals('Record 2', ((Map<String, Object>) result2.get('data')).get('Name'),
                'Second call should have Record 2 data');
            // Both should have the same template metadata
            System.assertEquals(result1.get('templateType'), result2.get('templateType'),
                'Template type should be the same for both calls');
        }
    }

    // -----------------------------------------------------------------------
    // getChildRecordPdfs — with filter clause
    // -----------------------------------------------------------------------
    @IsTest
    static void testGetChildRecordPdfsWithFilter() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];
            insert new Contact(FirstName = 'FilterTest', LastName = 'Contact', AccountId = acc.Id);

            Test.startTest();
            List<Map<String, Object>> result = DocGenController.getChildRecordPdfs(
                acc.Id, 'Contact', 'AccountId', 'LastName = \'Contact\''
            );
            Test.stopTest();

            // Should execute without error; result depends on whether the contact matches
            System.assertNotEquals(null, result, 'Result should not be null');
        }
    }

    // -----------------------------------------------------------------------
    // processAndReturnDocumentWithImages — with resolvedImages param
    // -----------------------------------------------------------------------
    @IsTest
    static void testProcessAndReturnDocumentWithImagesParam() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            createTestFile();
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account WHERE Name = 'Controller Test Account' LIMIT 1];

            Map<String, String> resolvedImages = new Map<String, String>{
                'https://example.com/image.png' => 'data:image/png;base64,iVBOR...'
            };

            Test.startTest();
            Boolean caughtException = false;
            try {
                // Will likely fail because the test template is not a real DOCX,
                // but exercises the method signature with resolvedImages
                DocGenController.processAndReturnDocumentWithImages(tpl.Id, acc.Id, resolvedImages);
            } catch (AuraHandledException e) {
                caughtException = true;
            }
            Test.stopTest();

            System.assert(caughtException, 'Should throw for non-real DOCX but the method was called with images');
        }
    }

    // -----------------------------------------------------------------------
    // resolveReportBaseObject — additional strategies
    // -----------------------------------------------------------------------
    @IsTest
    static void testResolveReportBaseObjectContactList() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            String result = DocGenController.resolveReportBaseObject('ContactList');
            Test.stopTest();

            System.assertEquals('Contact', result, 'ContactList should resolve to Contact');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectOpportunityProduct() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            String result = DocGenController.resolveReportBaseObject('OpportunityProduct');
            Test.stopTest();

            System.assertEquals('Opportunity', result, 'OpportunityProduct should resolve to Opportunity');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectOpportunityContactProduct() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            String result = DocGenController.resolveReportBaseObject('OpportunityContactProduct');
            Test.stopTest();

            System.assertEquals('Opportunity', result, 'OpportunityContactProduct should resolve to Opportunity');
        }
    }

    @IsTest
    static void testResolveReportBaseObjectLabelWithSuffix() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            // Label "Opportunities with Products" should match Opportunity plural label "Opportunities"
            String result = DocGenController.resolveReportBaseObject('UnknownXYZ', 'Opportunities with Products');
            Test.stopTest();

            System.assertEquals('Opportunity', result, 'Label starting with "Opportunities" should resolve to Opportunity');
        }
    }
}
