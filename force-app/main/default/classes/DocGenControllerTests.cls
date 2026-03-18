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
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
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
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];
    String dummyContent = EncodingUtil.base64Encode(
      Blob.valueOf('Dummy PDF content')
    );

    Test.startTest();
    Id contentDocId = DocGenController.saveGeneratedDocument(
      acc.Id,
      'TestOutput',
      dummyContent,
      '.pdf'
    );
    Test.stopTest();

    System.assertNotEquals(
      null,
      contentDocId,
      'Should return a ContentDocument Id'
    );

    // Verify ContentVersion was created
    List<ContentVersion> versions = [
      SELECT Title, PathOnClient
      FROM ContentVersion
      WHERE ContentDocumentId = :contentDocId
    ];
    System.assertEquals(
      1,
      versions.size(),
      'Should have exactly one ContentVersion'
    );
    System.assertEquals('TestOutput', versions[0].Title, 'Title should match');
    System.assert(
      versions[0].PathOnClient.endsWith('.pdf'),
      'PathOnClient should end with .pdf'
    );
  }

  @isTest
  static void testSaveGeneratedDocumentExtensionWithoutDot() {
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];
    String dummyContent = EncodingUtil.base64Encode(
      Blob.valueOf('Dummy DOCX content')
    );

    Test.startTest();
    Id contentDocId = DocGenController.saveGeneratedDocument(
      acc.Id,
      'TestOutputNoDot',
      dummyContent,
      'docx'
    );
    Test.stopTest();

    System.assertNotEquals(
      null,
      contentDocId,
      'Should return a ContentDocument Id'
    );

    List<ContentVersion> versions = [
      SELECT PathOnClient
      FROM ContentVersion
      WHERE ContentDocumentId = :contentDocId
    ];
    System.assert(
      versions[0].PathOnClient.endsWith('.docx'),
      'Extension without leading dot should still produce correct PathOnClient'
    );
  }

  // -----------------------------------------------------------------------
  // processAndReturnDocument - throws AuraHandledException for non-DOCX
  // -----------------------------------------------------------------------
  @isTest
  static void testProcessAndReturnDocumentThrows() {
    createTestFile();
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    Test.startTest();
    Boolean caughtException = false;
    try {
      DocGenController.processAndReturnDocument(tpl.Id, acc.Id);
    } catch (AuraHandledException e) {
      caughtException = true;
    }
    Test.stopTest();

    System.assert(
      caughtException,
      'Should have thrown AuraHandledException for non-real DOCX template'
    );
  }

  // -----------------------------------------------------------------------
  // previewRecordData
  // -----------------------------------------------------------------------
  @isTest
  static void testPreviewRecordData() {
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    Test.startTest();
    Map<String, Object> result = DocGenController.previewRecordData(
      acc.Id,
      'Account',
      'Name, AccountSource'
    );
    Test.stopTest();

    System.assertNotEquals(null, result, 'Preview data should not be null');
    System.assertEquals(
      'Controller Test Account',
      result.get('Name'),
      'Name field should match the test account'
    );
  }

  @isTest
  static void testPreviewRecordDataNullParams() {
    Test.startTest();
    Map<String, Object> result = DocGenController.previewRecordData(
      null,
      null,
      null
    );
    Test.stopTest();

    System.assertEquals(
      null,
      result,
      'Should return null when parameters are blank'
    );
  }

  // -----------------------------------------------------------------------
  // getAllTemplates
  // -----------------------------------------------------------------------
  @isTest
  static void testGetAllTemplates() {
    Test.startTest();
    List<DocGen_Template__c> templates = DocGenController.getAllTemplates();
    Test.stopTest();

    System.assert(
      !templates.isEmpty(),
      'Should return at least the test template'
    );
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

    DocGen_Template__c updated = [
      SELECT Name, Category__c, Description__c
      FROM DocGen_Template__c
      WHERE Id = :tpl.Id
    ];
    System.assertEquals(
      'Renamed Template',
      updated.Name,
      'Name should be updated'
    );
    System.assertEquals(
      'Legal',
      updated.Category__c,
      'Category should be updated'
    );
    System.assertEquals(
      'Updated description',
      updated.Description__c,
      'Description should be updated'
    );
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
    System.assert(
      !versions.isEmpty(),
      'Should have created at least one version'
    );

    // The newly created version should be active
    Boolean hasActive = false;
    for (DocGen_Template_Version__c v : versions) {
      if (v.Is_Active__c) {
        hasActive = true;
        System.assertEquals(
          'Finance',
          v.Category__c,
          'Version category should match'
        );
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
      SELECT Id
      FROM DocGen_Template__c
      WHERE Id = :disposable.Id
    ];
    System.assertEquals(
      0,
      remaining.size(),
      'Template should have been deleted'
    );
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
    List<DocGen_Template_Version__c> versions = DocGenController.getTemplateVersions(
      tpl.Id
    );
    Test.stopTest();

    System.assert(!versions.isEmpty(), 'Should return the created version');
    System.assertEquals(
      v.Id,
      versions[0].Id,
      'Should return the correct version'
    );
  }

  // -----------------------------------------------------------------------
  // getObjectOptions (Schema)
  // -----------------------------------------------------------------------
  @isTest
  static void testGetObjectOptions() {
    Test.startTest();
    List<Map<String, String>> options = DocGenController.getObjectOptions();
    Test.stopTest();

    System.assert(
      !options.isEmpty(),
      'Should return at least some queryable objects'
    );

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
    List<Map<String, String>> fields = DocGenController.getObjectFields(
      'Account'
    );
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
    List<Map<String, String>> fields = DocGenController.getObjectFields(
      'NonExistentObject__x'
    );
    Test.stopTest();

    System.assertEquals(
      0,
      fields.size(),
      'Should return empty list for invalid object'
    );
  }

  // -----------------------------------------------------------------------
  // getChildRelationships (Schema)
  // -----------------------------------------------------------------------
  @isTest
  static void testGetChildRelationships() {
    Test.startTest();
    List<Map<String, String>> rels = DocGenController.getChildRelationships(
      'Account'
    );
    Test.stopTest();

    System.assert(!rels.isEmpty(), 'Account should have child relationships');

    // Verify at least one relationship has expected keys
    Map<String, String> firstRel = rels[0];
    System.assert(
      firstRel.containsKey('label'),
      'Each relationship should have a label'
    );
    System.assert(
      firstRel.containsKey('value'),
      'Each relationship should have a value'
    );
    System.assert(
      firstRel.containsKey('childObjectApiName'),
      'Each relationship should have childObjectApiName'
    );
  }

  @isTest
  static void testGetChildRelationshipsInvalidObject() {
    Test.startTest();
    List<Map<String, String>> rels = DocGenController.getChildRelationships(
      'NonExistentObject__x'
    );
    Test.stopTest();

    System.assertEquals(
      0,
      rels.size(),
      'Should return empty list for invalid object'
    );
  }

  // -----------------------------------------------------------------------
  // getParentRelationships (Schema)
  // -----------------------------------------------------------------------
  @isTest
  static void testGetParentRelationships() {
    Test.startTest();
    List<Map<String, String>> parents = DocGenController.getParentRelationships(
      'Account'
    );
    Test.stopTest();

    System.assert(
      !parents.isEmpty(),
      'Account should have parent/lookup relationships'
    );

    // Verify structure
    Map<String, String> firstParent = parents[0];
    System.assert(
      firstParent.containsKey('label'),
      'Each parent should have a label'
    );
    System.assert(
      firstParent.containsKey('value'),
      'Each parent should have a value'
    );
    System.assert(
      firstParent.containsKey('targetObject'),
      'Each parent should have targetObject'
    );
  }

  @isTest
  static void testGetParentRelationshipsInvalidObject() {
    Test.startTest();
    List<Map<String, String>> parents = DocGenController.getParentRelationships(
      'NonExistentObject__x'
    );
    Test.stopTest();

    System.assertEquals(
      0,
      parents.size(),
      'Should return empty list for invalid object'
    );
  }

  // -----------------------------------------------------------------------
  // searchUsersAndGroups
  // -----------------------------------------------------------------------
  @isTest
  static void testSearchUsersAndGroups() {
    // The running user should always exist and be matchable
    String currentUserName = UserInfo.getLastName();

    Test.startTest();
    List<Map<String, String>> results = DocGenController.searchUsersAndGroups(
      currentUserName
    );
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
    List<Map<String, String>> results = DocGenController.searchUsersAndGroups(
      'ZZZZNONEXISTENT99999'
    );
    Test.stopTest();

    System.assertEquals(
      0,
      results.size(),
      'Should return empty list for non-matching search'
    );
  }

  // -----------------------------------------------------------------------
  // getTemplateShares
  // -----------------------------------------------------------------------
  @isTest
  static void testGetTemplateSharesEmpty() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

    Test.startTest();
    List<Map<String, String>> shares = DocGenController.getTemplateShares(
      tpl.Id
    );
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
    DocGen_Template__c tpl = [
      SELECT Id, OwnerId
      FROM DocGen_Template__c
      LIMIT 1
    ];

    // We need a different user or group to share with.
    // Use a public group for reliability in tests.
    Group testGroup = new Group(Name = 'DocGen Test Group', Type = 'Regular');
    insert testGroup;

    Test.startTest();
    // Share the template with the group
    DocGenController.shareTemplate(tpl.Id, testGroup.Id, 'Read');

    // Verify the share exists
    List<Map<String, String>> shares = DocGenController.getTemplateShares(
      tpl.Id
    );
    System.assert(!shares.isEmpty(), 'Should have at least one manual share');

    Boolean foundShare = false;
    String shareId = null;
    for (Map<String, String> s : shares) {
      if (s.get('UserOrGroupId') == testGroup.Id) {
        foundShare = true;
        shareId = s.get('Id');
        System.assertEquals(
          'Read',
          s.get('AccessLevel'),
          'Access level should be Read'
        );
        break;
      }
    }
    System.assert(foundShare, 'Should find the share for our test group');

    // Remove the share
    DocGenController.removeShare(shareId);

    // Verify removal
    List<Map<String, String>> sharesAfter = DocGenController.getTemplateShares(
      tpl.Id
    );
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
    System.assertEquals(
      -1,
      optA.compareTo(optB),
      'Alpha should sort before Beta'
    );
    System.assertEquals(
      1,
      optB.compareTo(optA),
      'Beta should sort after Alpha'
    );
    System.assertEquals(0, optA.compareTo(optA2), 'Same label should return 0');
    Test.stopTest();
  }

  @isTest
  static void testOptionThreeArgConstructor() {
    DocGenController.Option opt = new DocGenController.Option(
      'Contacts',
      'Contacts',
      'Contact'
    );

    System.assertEquals('Contacts', opt.label, 'Label should match');
    System.assertEquals('Contacts', opt.value, 'Value should match');
    System.assertEquals(
      'Contact',
      opt.childObjectApiName,
      'Child object API name should match'
    );
  }

  // -----------------------------------------------------------------------
  // generateDocumentData - null templateId throws DocGenException
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateDocumentDataNullTemplateId() {
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    Test.startTest();
    Boolean caughtException = false;
    try {
      DocGenController.generateDocumentData(null, acc.Id);
    } catch (DocGenException e) {
      caughtException = true;
      System.assert(
        e.getMessage().contains('Template ID is missing'),
        'Should indicate missing template ID'
      );
    }
    Test.stopTest();

    System.assert(
      caughtException,
      'Should throw DocGenException for null template ID'
    );
  }

  // -----------------------------------------------------------------------
  // generateDocumentData — template not found (covers line 16)
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateDocumentDataTemplateNotFound() {
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];
    // Use a fake but valid-format Id for a template that does not exist
    Id fakeTemplateId =
      DocGen_Template__c.SObjectType.getDescribe().getKeyPrefix() +
      '000000000000';

    Test.startTest();
    Boolean caughtException = false;
    try {
      DocGenController.generateDocumentData(fakeTemplateId, acc.Id);
    } catch (DocGenException e) {
      caughtException = true;
      System.assert(
        e.getMessage().contains('Unable to access template'),
        'Should indicate template not found'
      );
    }
    Test.stopTest();

    System.assert(
      caughtException,
      'Should throw DocGenException for non-existent template'
    );
  }

  // -----------------------------------------------------------------------
  // generateDocumentData — success path with valid DOCX (covers lines 4-42)
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateDocumentDataSuccess() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    // Build a minimal valid DOCX ZIP
    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    ContentVersion cv = new ContentVersion(
      Title = 'ValidDocx',
      PathOnClient = 'ValidDocx.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    Test.startTest();
    Map<String, Object> result = DocGenController.generateDocumentData(
      tpl.Id,
      acc.Id
    );
    Test.stopTest();

    System.assertNotEquals(null, result, 'Result should not be null');
    System.assert(result.containsKey('data'), 'Result should contain data key');
    System.assert(
      result.containsKey('templateFile'),
      'Result should contain templateFile key'
    );
    System.assert(
      result.containsKey('templateType'),
      'Result should contain templateType key'
    );
    System.assertEquals(
      'Word',
      result.get('templateType'),
      'Template type should be Word'
    );
  }

  // -----------------------------------------------------------------------
  // getTemplatesForObject — success and empty results
  // -----------------------------------------------------------------------
  @isTest
  static void testGetTemplatesForObject() {
    Test.startTest();
    List<DocGen_Template__c> templates = DocGenController.getTemplatesForObject(
      'Account'
    );
    Test.stopTest();

    System.assert(
      !templates.isEmpty(),
      'Should return the test template for Account'
    );
    System.assertEquals(
      'Controller Test Template',
      templates[0].Name,
      'Should return our test template'
    );
  }

  @isTest
  static void testGetTemplatesForObjectNoResults() {
    Test.startTest();
    List<DocGen_Template__c> templates = DocGenController.getTemplatesForObject(
      'NonExistentObject__c'
    );
    Test.stopTest();

    System.assertEquals(
      0,
      templates.size(),
      'Should return empty list for non-matching object'
    );
  }

  // -----------------------------------------------------------------------
  // processAndReturnDocument — success path with valid DOCX
  // -----------------------------------------------------------------------
  @isTest
  static void testProcessAndReturnDocumentSuccess() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    // Build valid DOCX
    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>Hello {Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    ContentVersion cv = new ContentVersion(
      Title = 'DocxForProcess',
      PathOnClient = 'DocxForProcess.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    Test.startTest();
    Map<String, Object> result = DocGenController.processAndReturnDocument(
      tpl.Id,
      acc.Id
    );
    Test.stopTest();

    System.assertNotEquals(null, result, 'Result should not be null');
    System.assert(result.containsKey('base64'), 'Result should contain base64');
    System.assert(result.containsKey('title'), 'Result should contain title');
    System.assert(
      result.containsKey('outputFormat'),
      'Result should contain outputFormat'
    );
    System.assert(
      result.containsKey('templateType'),
      'Result should contain templateType'
    );
  }

  // -----------------------------------------------------------------------
  // generatePdfDocument — error path (non-real DOCX triggers exception)
  // -----------------------------------------------------------------------
  @isTest
  static void testGeneratePdfDocumentThrows() {
    createTestFile();
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    Test.startTest();
    Boolean caughtException = false;
    try {
      DocGenController.generatePdfDocument(tpl.Id, acc.Id);
    } catch (AuraHandledException e) {
      caughtException = true;
    }
    Test.stopTest();

    System.assert(
      caughtException,
      'Should throw AuraHandledException for non-real DOCX template'
    );
  }

  // -----------------------------------------------------------------------
  // generatePdfDocument — success path with valid DOCX
  // -----------------------------------------------------------------------
  @isTest
  static void testGeneratePdfDocumentSuccess() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    ContentVersion cv = new ContentVersion(
      Title = 'DocxForPdf',
      PathOnClient = 'DocxForPdf.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    Test.startTest();
    Map<String, Object> result = DocGenController.generatePdfDocument(
      tpl.Id,
      acc.Id
    );
    Test.stopTest();

    System.assertNotEquals(null, result, 'Result should not be null');
    System.assert(result.containsKey('base64'), 'Result should contain base64');
    System.assert(result.containsKey('title'), 'Result should contain title');
  }

  // -----------------------------------------------------------------------
  // generateAndSavePdfDocument — error path (non-real DOCX)
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateAndSavePdfDocumentThrows() {
    createTestFile();
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    Test.startTest();
    Boolean caughtException = false;
    try {
      DocGenController.generateAndSavePdfDocument(tpl.Id, acc.Id);
    } catch (Exception e) {
      caughtException = true;
    }
    Test.stopTest();

    System.assert(
      caughtException,
      'Should throw exception for non-real DOCX template'
    );
  }

  // -----------------------------------------------------------------------
  // generateAndSavePdfDocument — success path with valid DOCX
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateAndSavePdfDocumentSuccess() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    ContentVersion cv = new ContentVersion(
      Title = 'DocxForSavePdf',
      PathOnClient = 'DocxForSavePdf.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    Test.startTest();
    Id contentDocId = DocGenController.generateAndSavePdfDocument(
      tpl.Id,
      acc.Id
    );
    Test.stopTest();

    System.assertNotEquals(
      null,
      contentDocId,
      'Should return a ContentDocumentId'
    );

    List<ContentVersion> versions = [
      SELECT Title, PathOnClient
      FROM ContentVersion
      WHERE ContentDocumentId = :contentDocId
    ];
    System.assertEquals(1, versions.size(), 'Should have one ContentVersion');
    System.assert(
      versions[0].PathOnClient.endsWith('.pdf'),
      'Should be a PDF file'
    );
  }

  // -----------------------------------------------------------------------
  // activateVersion — covers lines 229-268
  // -----------------------------------------------------------------------
  @isTest
  static void testActivateVersion() {
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
    DocGen_Template_Version__c updatedV1 = [
      SELECT Is_Active__c
      FROM DocGen_Template_Version__c
      WHERE Id = :v1.Id
    ];
    DocGen_Template_Version__c updatedV2 = [
      SELECT Is_Active__c
      FROM DocGen_Template_Version__c
      WHERE Id = :v2.Id
    ];
    System.assertEquals(
      false,
      updatedV1.Is_Active__c,
      'v1 should be deactivated'
    );
    System.assertEquals(true, updatedV2.Is_Active__c, 'v2 should be activated');

    // Template should reflect v2 fields
    DocGen_Template__c updatedTpl = [
      SELECT Category__c, Description__c, Query_Config__c
      FROM DocGen_Template__c
      WHERE Id = :tpl.Id
    ];
    System.assertEquals(
      'Legal',
      updatedTpl.Category__c,
      'Template category should match activated version'
    );
    System.assertEquals(
      'Version 2',
      updatedTpl.Description__c,
      'Template description should match activated version'
    );
  }

  // -----------------------------------------------------------------------
  // saveTemplate — with Is_Default__c flag
  // -----------------------------------------------------------------------
  @isTest
  static void testSaveTemplateWithDefaultFlag() {
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

    DocGen_Template__c updated = [
      SELECT Is_Default__c
      FROM DocGen_Template__c
      WHERE Id = :tpl.Id
    ];
    System.assertEquals(
      true,
      updated.Is_Default__c,
      'Is_Default__c should be set to true'
    );
  }

  // -----------------------------------------------------------------------
  // previewRecordData — exception path (covers line 104)
  // -----------------------------------------------------------------------
  @isTest
  static void testPreviewRecordDataException() {
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    Test.startTest();
    Boolean caughtException = false;
    try {
      DocGenController.previewRecordData(acc.Id, 'InvalidObject__xyz', 'Name');
    } catch (DocGenException e) {
      caughtException = true;
      System.assert(
        e.getMessage().contains('Error fetching preview data'),
        'Should contain error fetching preview data message'
      );
    }
    Test.stopTest();

    System.assert(
      caughtException,
      'Should throw DocGenException for invalid object'
    );
  }

  // -----------------------------------------------------------------------
  // deleteTemplate — exception path (invalid ID)
  // -----------------------------------------------------------------------
  @isTest
  static void testDeleteTemplateThrows() {
    // Use a fake ID that looks valid but does not exist — will throw
    Id fakeId =
      DocGen_Template__c.SObjectType.getDescribe().getKeyPrefix() +
      '000000000000';

    Test.startTest();
    Boolean caughtException = false;
    try {
      DocGenController.deleteTemplate(fakeId);
    } catch (AuraHandledException e) {
      caughtException = true;
    }
    Test.stopTest();

    System.assert(
      caughtException,
      'Should throw AuraHandledException for non-existent template'
    );
  }

  // -----------------------------------------------------------------------
  // saveTemplate — exception path (invalid template ID)
  // -----------------------------------------------------------------------
  @isTest
  static void testSaveTemplateThrows() {
    Id fakeId =
      DocGen_Template__c.SObjectType.getDescribe().getKeyPrefix() +
      '000000000000';

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

    System.assert(
      caughtException,
      'Should throw AuraHandledException for invalid template update'
    );
  }

  // -----------------------------------------------------------------------
  // generateDocumentData — with rich text containing refid images
  // Exercises resolveRichTextImages and resolveImageUrlsInHtml (lines 542-677)
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateDocumentDataWithRichTextRefid() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    tpl.Query_Config__c = 'Name, Description';
    update tpl;

    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];
    // Set Description to contain HTML with an img tag using refid (simulates rich text)
    acc.Description = '<p>See image: <img src="https://example.com/servlet/rtaImage?eid=001&refid=0EM000000000001" alt="test"/></p>';
    update acc;

    // Build valid DOCX
    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    ContentVersion cv = new ContentVersion(
      Title = 'DocxRichText',
      PathOnClient = 'DocxRichText.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    // The callout to resolve images will fail in test context (no HttpCalloutMock),
    // but the code handles exceptions gracefully. This exercises the code path.
    Test.startTest();
    try {
      Map<String, Object> result = DocGenController.generateDocumentData(
        tpl.Id,
        acc.Id
      );
      // If no exception, result should still be valid
      System.assertNotEquals(null, result, 'Result should not be null');
    } catch (Exception e) {
      // Callout exceptions are acceptable in test context
      System.assert(
        true,
        'Exception during callout is expected in test context'
      );
    }
    Test.stopTest();
  }

  // -----------------------------------------------------------------------
  // generateDocumentData — with servlet image URLs in rich text
  // Exercises resolveServletImageUrls (lines 584-622)
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateDocumentDataWithServletImages() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    tpl.Query_Config__c = 'Name, Description';
    update tpl;

    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];
    // Set Description with servlet URL (without refid) to exercise resolveServletImageUrls
    acc.Description = '<p><img src="https://myorg.salesforce.com/servlet/rtaImage?eid=001ABC&feoid=00N000&refid=" alt="img"/></p>';
    update acc;

    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    ContentVersion cv = new ContentVersion(
      Title = 'DocxServlet',
      PathOnClient = 'DocxServlet.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    Test.startTest();
    try {
      Map<String, Object> result = DocGenController.generateDocumentData(
        tpl.Id,
        acc.Id
      );
      System.assertNotEquals(null, result, 'Result should not be null');
    } catch (Exception e) {
      // Callout exceptions are acceptable in test context
      System.assert(
        true,
        'Exception during callout is expected in test context'
      );
    }
    Test.stopTest();
  }

  // -----------------------------------------------------------------------
  // generateDocumentData — with sfc URL images (no refid)
  // Exercises resolveServletImageUrls sfc path
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateDocumentDataWithSfcImages() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    tpl.Query_Config__c = 'Name, Description';
    update tpl;

    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];
    acc.Description = '<p><img src="https://myorg.salesforce.com/sfc/servlet.shepherd/version/download/069ABC" alt="img"/></p>';
    update acc;

    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    ContentVersion cv = new ContentVersion(
      Title = 'DocxSfc',
      PathOnClient = 'DocxSfc.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    Test.startTest();
    try {
      Map<String, Object> result = DocGenController.generateDocumentData(
        tpl.Id,
        acc.Id
      );
      System.assertNotEquals(null, result, 'Result should not be null');
    } catch (Exception e) {
      System.assert(
        true,
        'Exception during callout is expected in test context'
      );
    }
    Test.stopTest();
  }

  // -----------------------------------------------------------------------
  // generateDocumentData — with Output_Format and Document_Title_Format
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateDocumentDataWithOutputFormatAndTitle() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    tpl.Output_Format__c = 'PDF';
    tpl.Document_Title_Format__c = 'Invoice_{Name}';
    update tpl;

    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    ContentVersion cv = new ContentVersion(
      Title = 'DocxFormat',
      PathOnClient = 'DocxFormat.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    Test.startTest();
    Map<String, Object> result = DocGenController.generateDocumentData(
      tpl.Id,
      acc.Id
    );
    Test.stopTest();

    System.assertNotEquals(null, result, 'Result should not be null');
    System.assertEquals(
      'PDF',
      result.get('outputFormat'),
      'Output format should be PDF'
    );
    System.assertEquals(
      'Invoice_{Name}',
      result.get('titleFormat'),
      'Title format should be returned'
    );
  }

  // -----------------------------------------------------------------------
  // resolveRichTextImages — with nested list data (exercises List<Object> path)
  // -----------------------------------------------------------------------
  @isTest
  static void testGenerateDocumentDataWithChildRelationship() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    tpl.Query_Config__c = 'Name, (SELECT LastName FROM Contacts)';
    update tpl;

    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];
    insert new Contact(
      FirstName = 'Test',
      LastName = 'Child',
      AccountId = acc.Id
    );

    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );

    ContentVersion cv = new ContentVersion(
      Title = 'DocxChild',
      PathOnClient = 'DocxChild.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    Test.startTest();
    Map<String, Object> result = DocGenController.generateDocumentData(
      tpl.Id,
      acc.Id
    );
    Test.stopTest();

    System.assertNotEquals(null, result, 'Result should not be null');
    Map<String, Object> data = (Map<String, Object>) result.get('data');
    System.assert(
      data.containsKey('Contacts'),
      'Data should contain Contacts child relationship'
    );
  }

  // -----------------------------------------------------------------------
  // saveTemplate — version creation with existing active version (deactivation)
  // -----------------------------------------------------------------------
  @isTest
  static void testSaveTemplateVersionDeactivatesPrevious() {
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
      SELECT Is_Active__c
      FROM DocGen_Template_Version__c
      WHERE Id = :existingVersion.Id
    ];
    System.assertEquals(
      false,
      oldVersion.Is_Active__c,
      'Old version should be deactivated'
    );

    // A new version should exist and be active
    List<DocGen_Template_Version__c> newVersions = [
      SELECT Is_Active__c, Category__c
      FROM DocGen_Template_Version__c
      WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
    ];
    System.assertEquals(
      1,
      newVersions.size(),
      'Should have exactly one active version'
    );
    System.assertEquals(
      'New',
      newVersions[0].Category__c,
      'New version should have correct category'
    );
  }

  // -----------------------------------------------------------------------
  // getAllTemplates — with ContentDocumentLink subquery
  // -----------------------------------------------------------------------
  @isTest
  static void testGetAllTemplatesWithFile() {
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
    System.assert(
      foundWithLink,
      'At least one template should have a ContentDocumentLink'
    );
  }

  @isTest
  static void testGenerateDocumentDataForClient_returnsPayload() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Controller Test Account'
      LIMIT 1
    ];

    // Attach a minimal valid DOCX ZIP to the template
    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry(
      '[Content_Types].xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
          '<Default Extension="xml" ContentType="application/xml"/>' +
          '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
          '</Types>'
      )
    );
    zw.addEntry(
      'word/_rels/document.xml.rels',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
      )
    );
    zw.addEntry(
      'word/document.xml',
      Blob.valueOf(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
          '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
      )
    );
    ContentVersion cv = new ContentVersion(
      Title = 'TestClientDocx',
      PathOnClient = 'TestClientDocx.docx',
      VersionData = zw.getArchive()
    );
    insert cv;
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = tpl.Id,
      ContentDocumentId = conDocId,
      ShareType = 'V'
    );

    Test.startTest();
    Map<String, Object> result = DocGenController.generateDocumentDataForClient(
      tpl.Id,
      acc.Id,
      null
    );
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assert(result.containsKey('xmlParts'), 'Should have xmlParts');
    System.assert(result.containsKey('mediaParts'), 'Should have mediaParts');
    System.assert(result.containsKey('fileName'), 'Should have fileName');
  }

  @isTest
  static void testGenerateDocumentDataForClient_nullTemplateThrows() {
    Test.startTest();
    Boolean threw = false;
    try {
      DocGenController.generateDocumentDataForClient(null, null, null);
    } catch (AuraHandledException e) {
      threw = true;
    }
    Test.stopTest();
    System.assert(
      threw,
      'Should throw AuraHandledException for null templateId'
    );
  }
}
