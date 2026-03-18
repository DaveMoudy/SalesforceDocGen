@isTest
private class DocGenTests {
  @testSetup
  static void setup() {
    // Create Template
    DocGen_Template__c tpl = new DocGen_Template__c(
      Name = 'Test Template',
      Base_Object_API__c = 'Account',
      Query_Config__c = 'Name, AccountSource',
      Type__c = 'Word'
    );
    insert tpl;

    // Create Account
    Account acc = new Account(
      Name = 'Test Account',
      AccountSource = 'Web',
      Website = 'https://www.example.com'
    );
    insert acc;

    // Create ContentVersion (File)
    ContentVersion cv = new ContentVersion(
      Title = 'TestDoc',
      PathOnClient = 'TestDoc.docx',
      VersionData = Blob.valueOf('Test Content'),
      IsMajorVersion = true
    );
    insert cv;

    // Get ContentDocumentId
    Id conDocId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;

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
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
    Account acc = [SELECT Id FROM Account LIMIT 1];

    Test.startTest();
    Map<String, Object> result = DocGenController.generateDocumentData(
      tpl.Id,
      acc.Id
    );
    Test.stopTest();

    System.assertNotEquals(null, result.get('data'), 'Data should not be null');
    System.assertNotEquals(
      null,
      result.get('templateFile'),
      'File should not be null'
    );
    Map<String, Object> data = (Map<String, Object>) result.get('data');
    System.assertEquals('Test Account', data.get('Name'));
  }

  @isTest
  static void testGetTemplates() {
    List<DocGen_Template__c> tpls = DocGenController.getTemplatesForObject(
      'Account'
    );
    System.assertEquals(1, tpls.size());
  }
  @isTest
  static void testProcessDocumentForClient_returnsPreZipPayload() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    DocGen_Template__c tpl = [
      SELECT Id
      FROM DocGen_Template__c
      WHERE Type__c = 'Word'
      LIMIT 1
    ];

    // Replace the fake blob from @testSetup with a valid minimal DOCX ZIP
    List<ContentDocumentLink> existingLinks = [
      SELECT ContentDocumentId
      FROM ContentDocumentLink
      WHERE LinkedEntityId = :tpl.Id
    ];
    if (!existingLinks.isEmpty()) {
      delete [
        SELECT Id
        FROM ContentDocument
        WHERE Id = :existingLinks[0].ContentDocumentId
      ];
    }
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
      Title = 'TestDocx',
      PathOnClient = 'TestDocx.docx',
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
    Map<String, Object> result = DocGenService.processDocumentForClient(
      tpl.Id,
      acc.Id,
      null
    );
    Test.stopTest();

    System.assertNotEquals(null, result, 'Result should not be null');
    System.assert(result.containsKey('xmlParts'), 'Should contain xmlParts');
    System.assert(
      result.containsKey('mediaParts'),
      'Should contain mediaParts'
    );
    System.assert(result.containsKey('fileName'), 'Should contain fileName');
    System.assertEquals(
      'Word',
      result.get('templateType'),
      'templateType should be Word'
    );
  }

  @isTest
  static void testVersioning() {
    DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

    // 1. Setup - Create V1 Record
    ContentVersion cv1 = [
      SELECT Id, ContentDocumentId
      FROM ContentVersion
      LIMIT 1
    ];

    DocGen_Template_Version__c v1 = new DocGen_Template_Version__c(
      Template__c = tpl.Id,
      Content_Version_Id__c = cv1.Id,
      Is_Active__c = true,
      Type__c = 'Word',
      Base_Object_API__c = 'Account',
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
    Id conDocId2 = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv2.Id
    ]
    .ContentDocumentId;
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
      Base_Object_API__c = 'Account',
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
    System.assertEquals(
      EncodingUtil.base64Encode(Blob.valueOf('V2 Content')),
      contentV2,
      'Should return V2 content'
    );

    // 4. Activate V1
    DocGenController.activateVersion(v1.Id); // This method handles deactivation of others

    String contentV1 = DocGenTemplateManager.getTemplateFileContent(tpl.Id);
    System.assertEquals(
      EncodingUtil.base64Encode(Blob.valueOf('Test Content')),
      contentV1,
      'Should return V1 content'
    );
    Test.stopTest();
  }
}
