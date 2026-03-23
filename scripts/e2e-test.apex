// =====================================================================
// DocGen FULL End-to-End Test — ONE CLICK, ZERO DEPENDENCIES
// Creates ALL data including template + DOCX file. Cleans up after.
// Tests: template creation, data retrieval, V3 tree walker, parent
//        fields, grandchildren, legacy compat, images, doc generation,
//        junction stitching
// Run: sf apex run --target-org <org> -f scripts/e2e-test.apex
// =====================================================================

Integer pass = 0;
Integer fail = 0;

Database.DMLOptions dml = new Database.DMLOptions();
dml.DuplicateRuleHeader.allowSave = true;
String uid = String.valueOf(Math.mod(Math.abs(Crypto.getRandomInteger()), 100000));

// =====================================================================
// 1. CREATE TEST DATA
// =====================================================================

Account acc = new Account(
    Name = 'E2E-' + uid,
    Industry = 'Technology',
    Phone = '(555) 999-' + uid.leftPad(4, '0').right(4),
    Website = 'www.test.com',
    BillingStreet = '100 Test Dr',
    BillingCity = 'San Francisco',
    BillingState = 'CA',
    BillingPostalCode = '94105'
);
Database.insert(acc, dml);

List<Contact> cons = new List<Contact>{
    new Contact(AccountId = acc.Id, FirstName = 'Alice', LastName = 'Johnson-' + uid, Title = 'CEO', Email = 'alice' + uid + '@test.com'),
    new Contact(AccountId = acc.Id, FirstName = 'Bob', LastName = 'Smith-' + uid, Title = 'CTO', Email = 'bob' + uid + '@test.com')
};
Database.insert(cons, dml);

Opportunity opp = new Opportunity(
    Name = 'Test Deal-' + uid,
    AccountId = acc.Id,
    Amount = 100000,
    StageName = 'Proposal/Price Quote',
    CloseDate = Date.today().addDays(30)
);
Database.insert(opp, dml);

// Products + Line Items
List<Pricebook2> pbs = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
Product2 p1;
Product2 p2;
if (!pbs.isEmpty()) {
    p1 = new Product2(Name = 'Widget Pro-' + uid, IsActive = true);
    p2 = new Product2(Name = 'Support Plan-' + uid, IsActive = true);
    insert new List<Product2>{ p1, p2 };
    PricebookEntry pe1 = new PricebookEntry(Pricebook2Id = pbs[0].Id, Product2Id = p1.Id, UnitPrice = 5000, IsActive = true);
    PricebookEntry pe2 = new PricebookEntry(Pricebook2Id = pbs[0].Id, Product2Id = p2.Id, UnitPrice = 1000, IsActive = true);
    insert new List<PricebookEntry>{ pe1, pe2 };
    insert new List<OpportunityLineItem>{
        new OpportunityLineItem(OpportunityId = opp.Id, PricebookEntryId = pe1.Id, Quantity = 10, UnitPrice = 5000),
        new OpportunityLineItem(OpportunityId = opp.Id, PricebookEntryId = pe2.Id, Quantity = 5, UnitPrice = 1000)
    };
}

// Contact Role for junction test
insert new OpportunityContactRole(OpportunityId = opp.Id, ContactId = cons[0].Id, Role = 'Decision Maker', IsPrimary = true);

// Test image (100x100 red square PNG)
String pngB64 = 'iVBORw0KGgoAAAANSUhEUgAAAGQAAABkCAIAAAD/gAIDAAAA40lEQVR42u3QMQEAAAgDINc/9Mzg0QSJdnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dnZ2dv4HAAD//9jQAQGH1FniAAAAAElFTkSuQmCC';
ContentVersion imgCv = new ContentVersion(
    Title = 'E2E Test Image ' + uid,
    PathOnClient = 'test_image.png',
    VersionData = EncodingUtil.base64Decode(pngB64),
    IsMajorVersion = true
);
Database.insert(imgCv, dml);
imgCv = [SELECT Id FROM ContentVersion WHERE Id = :imgCv.Id];

// Store image CV ID in Description (simulates an image field)
acc.Description = String.valueOf(imgCv.Id);
update acc;

System.debug('Setup: Account=' + acc.Id + ' | Opp=' + opp.Id + ' | Image CV=' + imgCv.Id);

// =====================================================================
// 2. CREATE TEMPLATE + DOCX FILE + VERSION (fully self-contained)
// =====================================================================

// V3 query config for Account with Contacts, Opportunities, and Line Items
String v3Config = '{"v":3,"root":"Account","nodes":[' +
    '{"id":"n0","object":"Account","fields":["Name","Industry","Phone","Description"],"parentFields":["Owner.Name"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
    '{"id":"n1","object":"Contact","fields":["FirstName","LastName","Title","Email"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"},' +
    '{"id":"n2","object":"Opportunity","fields":["Name","Amount","StageName"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Opportunities"},' +
    '{"id":"n3","object":"OpportunityLineItem","fields":["Quantity","UnitPrice","TotalPrice"],"parentFields":["Product2.Name"],"parentNode":"n2","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}' +
    ']}';

DocGen_Template__c tmpl = new DocGen_Template__c(
    Name = 'E2E Test-' + uid,
    Base_Object_API__c = 'Account',
    Type__c = 'Word',
    Output_Format__c = 'PDF',
    Query_Config__c = v3Config,
    Test_Record_Id__c = acc.Id
);
insert tmpl;

// Minimal valid DOCX with merge tags: {Name}, {Industry}, {Owner.Name},
// {#Contacts}...{/Contacts}, {#Opportunities}...{/Opportunities},
// {#OpportunityLineItems}{Product2.Name}{/OpportunityLineItems}
String docxB64 = 'UEsDBBQAAAAAAGeUdlzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFuZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMiPgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9uc2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5hbWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJvY2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAAGeUdlwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9wZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAABnlHZcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAAGeUdlyLLJ4uSQYAAEkGAAARAAAAd29yZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndwYz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczptYz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAgIHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAgICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFzLm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6cD48dzpyPjx3OnQ+QWNjb3VudDoge05hbWV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6dD5JbmR1c3RyeToge0luZHVzdHJ5fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpyPjx3OnQ+T3duZXI6IHtPd25lci5OYW1lfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpyPjx3OnQ+eyNDb250YWN0c308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cj48dzp0Pi0ge0ZpcnN0TmFtZX0ge0xhc3ROYW1lfSAoe0VtYWlsfSk8L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cj48dzp0PnsvQ29udGFjdHN9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6dD57I09wcG9ydHVuaXRpZXN9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6dD5EZWFsOiB7TmFtZX0gLSB7QW1vdW50fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpyPjx3OnQ+eyNPcHBvcnR1bml0eUxpbmVJdGVtc308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cj48dzp0PiAgUHJvZHVjdDoge1Byb2R1Y3QyLk5hbWV9IHh7UXVhbnRpdHl9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6dD57L09wcG9ydHVuaXR5TGluZUl0ZW1zfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpyPjx3OnQ+ey9PcHBvcnR1bml0aWVzfTwvdzp0PjwvdzpyPjwvdzpwPgogIDwvdzpib2R5Pgo8L3c6ZG9jdW1lbnQ+UEsBAhQDFAAAAAAAZ5R2XNd5hOq4AQAAuAEAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQSwECFAMUAAAAAABnlHZcIBuG6i4BAAAuAQAACwAAAAAAAAAAAAAAgAHpAQAAX3JlbHMvLnJlbHNQSwECFAMUAAAAAABnlHZcjA6F0J0AAACdAAAAHAAAAAAAAAAAAAAAgAFAAwAAd29yZC9fcmVscy9kb2N1bWVudC54bWwucmVsc1BLAQIUAxQAAAAAAGeUdlyLLJ4uSQYAAEkGAAARAAAAAAAAAAAAAACAARcEAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAABAAEAAMBAACPCgAAAAA=';

// Upload DOCX as ContentVersion linked to the template
ContentVersion docxCv = new ContentVersion(
    Title = 'E2E Template-' + uid,
    PathOnClient = 'e2e_template_' + uid + '.docx',
    VersionData = EncodingUtil.base64Decode(docxB64),
    IsMajorVersion = true,
    FirstPublishLocationId = tmpl.Id
);
insert docxCv;
docxCv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :docxCv.Id];

// Create active template version pointing to the DOCX
DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
    Template__c = tmpl.Id,
    Content_Version_Id__c = docxCv.Id,
    Is_Active__c = true
);
insert ver;

System.debug('Template: ' + tmpl.Id + ' | Version: ' + ver.Id + ' | DOCX CV: ' + docxCv.Id);

// =====================================================================
// 3. V3 TREE WALKER TESTS
// =====================================================================

Map<String, Object> data = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);

// Test 1: Account Name
if (data.get('Name') == acc.Name) { pass++; } else { fail++; System.debug('FAIL T1: Account Name expected=' + acc.Name + ' got=' + data.get('Name')); }

// Test 2: Owner.Name parent field
Object owner = data.get('Owner');
if (owner instanceof Map<String, Object> && ((Map<String, Object>) owner).get('Name') != null) { pass++; } else { fail++; System.debug('FAIL T2: Owner.Name missing'); }

// Test 3: Contacts count
Object cObj = data.get('Contacts');
Integer cCount = 0;
if (cObj instanceof Map<String, Object>) { cCount = ((List<Object>) ((Map<String, Object>) cObj).get('records')).size(); }
if (cCount == 2) { pass++; } else { fail++; System.debug('FAIL T3: Contacts count=' + cCount + ' expected 2'); }

// Test 4: Opportunities count
Object oObj = data.get('Opportunities');
Integer oCount = 0;
Integer liCount = 0;
if (oObj instanceof Map<String, Object>) {
    List<Object> oRecs = (List<Object>) ((Map<String, Object>) oObj).get('records');
    oCount = oRecs.size();
    if (!oRecs.isEmpty()) {
        Map<String, Object> firstOpp = (Map<String, Object>) oRecs[0];
        Object liObj = firstOpp.get('OpportunityLineItems');
        if (liObj instanceof Map<String, Object>) {
            liCount = ((List<Object>) ((Map<String, Object>) liObj).get('records')).size();
            // Test 5: Product2.Name parent field on line items
            List<Object> liRecs = (List<Object>) ((Map<String, Object>) liObj).get('records');
            if (!liRecs.isEmpty()) {
                Map<String, Object> firstLi = (Map<String, Object>) liRecs[0];
                Object prod = firstLi.get('Product2');
                if (prod instanceof Map<String, Object> && ((Map<String, Object>) prod).get('Name') != null) {
                    pass++;
                    System.debug('Product2.Name = ' + ((Map<String, Object>) prod).get('Name'));
                } else { fail++; System.debug('FAIL T5: Product2.Name missing on LineItem'); }
            }
        }
    }
}
if (oCount == 1) { pass++; } else { fail++; System.debug('FAIL T4: Opp count=' + oCount + ' expected 1'); }

// Test 6: Line Items count
if (liCount == 2) { pass++; } else { fail++; System.debug('FAIL T6: LineItem count=' + liCount + ' expected 2'); }

// Test 7: Description contains CV ID (image field simulation)
String descVal = (String) data.get('Description');
if (descVal != null && descVal.startsWith('068')) { pass++; } else { fail++; System.debug('FAIL T7: Description CV ID = ' + descVal); }

// =====================================================================
// 4. LEGACY V1 BACKWARD COMPAT
// =====================================================================

// Test 8: Legacy V1 config still works
Map<String, Object> legData = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, Industry, (SELECT FirstName, LastName FROM Contacts)');
Object lcObj = legData.get('Contacts');
Integer lcCount = 0;
if (lcObj instanceof Map<String, Object>) { lcCount = ((List<Object>) ((Map<String, Object>) lcObj).get('records')).size(); }
if (lcCount == 2) { pass++; } else { fail++; System.debug('FAIL T8: Legacy contacts count=' + lcCount); }

// =====================================================================
// 5. IMAGE CV VALIDATION
// =====================================================================

// Test 9: Image CV ID format
if (String.valueOf(imgCv.Id).startsWith('068')) { pass++; } else { fail++; System.debug('FAIL T9: Image CV ID format'); }

// Test 10: Image CV accessible with correct extension
List<ContentVersion> imgCheck = [SELECT Id, FileExtension, ContentSize FROM ContentVersion WHERE Id = :imgCv.Id];
if (!imgCheck.isEmpty() && imgCheck[0].FileExtension == 'png') { pass++; } else { fail++; System.debug('FAIL T10: Image CV not accessible'); }

// =====================================================================
// 6. DOCUMENT GENERATION (full pipeline: template → merge → output)
// =====================================================================

// Test 11 + 12: Generate document from template we just created
try {
    Id cdId = DocGenService.generateDocument(tmpl.Id, acc.Id);
    if (cdId != null) {
        pass++;
        System.debug('Generated ContentDocument: ' + cdId);
    } else {
        fail++;
        System.debug('FAIL T11: generateDocument returned null');
    }
    List<ContentVersion> cvs = [SELECT ContentSize, FileExtension FROM ContentVersion WHERE ContentDocumentId = :cdId LIMIT 1];
    if (!cvs.isEmpty() && cvs[0].ContentSize > 0) {
        pass++;
        System.debug('Generated file: ' + cvs[0].FileExtension + ' — ' + cvs[0].ContentSize + ' bytes');
    } else {
        fail++;
        System.debug('FAIL T12: Generated file empty or missing');
    }
} catch (Exception e) {
    fail += 2;
    System.debug('FAIL T11/12: Generation error: ' + e.getMessage() + ' | ' + e.getStackTraceString());
}

// =====================================================================
// 7. V2 JUNCTION TEST
// =====================================================================

// Test 13: V2 config with junction stitching (OCR → Contact)
String v2Junction = '{"v":2,"baseObject":"Opportunity","baseFields":["Name","Amount"],"parentFields":["Account.Name"],"children":[],"junctions":[{"junctionRel":"OpportunityContactRoles","junctionFields":["Role"],"targetObject":"Contact","targetIdField":"ContactId","targetFields":["FirstName","LastName","Email"]}]}';
Map<String, Object> jData = DocGenDataRetriever.getRecordData(opp.Id, 'Opportunity', v2Junction);
Object ocrObj = jData.get('OpportunityContactRoles');
if (ocrObj instanceof Map<String, Object>) {
    List<Object> ocrRecs = (List<Object>) ((Map<String, Object>) ocrObj).get('records');
    if (!ocrRecs.isEmpty()) {
        Map<String, Object> firstOcr = (Map<String, Object>) ocrRecs[0];
        Object contactData = firstOcr.get('Contact');
        if (contactData instanceof Map<String, Object> && ((Map<String, Object>) contactData).get('FirstName') != null) {
            pass++;
            System.debug('Junction: ' + firstOcr.get('Role') + ' => ' + ((Map<String, Object>) contactData).get('FirstName'));
        } else { fail++; System.debug('FAIL T13: Junction Contact data not stitched'); }
    } else { fail++; System.debug('FAIL T13: No OCR records found'); }
} else { fail++; System.debug('FAIL T13: No OpportunityContactRoles in data'); }

// =====================================================================
// 8. AGGREGATE TAG TESTS (processXml with aggregate tags)
// =====================================================================

// Build a simple XML string with aggregate tags and run through processXml
// Data: Account with Contacts (2) and Opportunities (1) with LineItems (2: Qty=10,UnitPrice=5000 + Qty=5,UnitPrice=1000)
// LineItem TotalPrice = Quantity * UnitPrice: 50000 + 5000 = 55000

// Test 14: COUNT:Contacts
String countXml = '<w:t>{COUNT:Contacts}</w:t>';
String countResult = DocGenService.processXmlForTest(countXml, data);
if (countResult.contains('2')) { pass++; } else { fail++; System.debug('FAIL T14: COUNT:Contacts expected 2, got: ' + countResult); }

// Test 15: SUM on line items (via Opportunities child data — need to test at Opportunity level)
// Get the first opportunity's data for line item aggregates
Map<String, Object> oppData = (Map<String, Object>) ((List<Object>) ((Map<String, Object>) data.get('Opportunities')).get('records'))[0];
String sumXml = '<w:t>{SUM:OpportunityLineItems.TotalPrice}</w:t>';
String sumResult = DocGenService.processXmlForTest(sumXml, oppData);
// TotalPrice = 10*5000 + 5*1000 = 55000
if (sumResult.contains('55000')) { pass++; } else { fail++; System.debug('FAIL T15: SUM:LineItems.TotalPrice expected 55000, got: ' + sumResult); }

// Test 16: SUM with format specifier
String sumFmtXml = '<w:t>{SUM:OpportunityLineItems.TotalPrice:currency}</w:t>';
String sumFmtResult = DocGenService.processXmlForTest(sumFmtXml, oppData);
if (sumFmtResult.contains('$55,000.00')) { pass++; } else { fail++; System.debug('FAIL T16: SUM:currency expected $55,000.00, got: ' + sumFmtResult); }

// Test 17: AVG
String avgXml = '<w:t>{AVG:OpportunityLineItems.UnitPrice}</w:t>';
String avgResult = DocGenService.processXmlForTest(avgXml, oppData);
if (avgResult.contains('3000')) { pass++; } else { fail++; System.debug('FAIL T17: AVG:UnitPrice expected 3000, got: ' + avgResult); }

// Test 18: MIN/MAX
String minXml = '<w:t>{MIN:OpportunityLineItems.Quantity}</w:t>';
String minResult = DocGenService.processXmlForTest(minXml, oppData);
if (minResult.contains('5')) { pass++; } else { fail++; System.debug('FAIL T18: MIN:Quantity expected 5, got: ' + minResult); }

String maxXml = '<w:t>{MAX:OpportunityLineItems.Quantity}</w:t>';
String maxResult = DocGenService.processXmlForTest(maxXml, oppData);
if (maxResult.contains('10')) { pass++; } else { fail++; System.debug('FAIL T19: MAX:Quantity expected 10, got: ' + maxResult); }

// =====================================================================
// RESULTS
// =====================================================================

System.debug('');
System.debug('==============================================');
System.debug('  PASS: ' + pass + '  FAIL: ' + fail);
System.debug('  ' + (fail == 0 ? 'ALL TESTS PASSED' : fail + ' TEST(S) FAILED'));
System.debug('==============================================');
System.debug('Tests: T1 Account name, T2 Owner.Name, T3 Contacts(2),');
System.debug('  T4 Opps(1), T5 Product2.Name, T6 LineItems(2),');
System.debug('  T7 Description CV, T8 Legacy V1, T9 Image CV format,');
System.debug('  T10 Image CV access, T11 Doc generation, T12 Doc not empty,');
System.debug('  T13 Junction stitching, T14 COUNT, T15 SUM,');
System.debug('  T16 SUM:currency, T17 AVG, T18 MIN, T19 MAX');

// =====================================================================
// CLEANUP — delete everything we created
// =====================================================================

// NOTE: Salesforce throws "entity is deleted" if you delete ContentDocuments
// and their linked entities in the same transaction. Delete non-content records
// only — content documents become orphaned but don't affect future test runs.

// Delete template first (cascades to template version)
try { delete tmpl; } catch (Exception ex) { System.debug('Cleanup tmpl: ' + ex.getMessage()); }

// Delete children before parents
try { delete [SELECT Id FROM OpportunityContactRole WHERE OpportunityId = :opp.Id]; } catch (Exception ex) {}
try { delete [SELECT Id FROM OpportunityLineItem WHERE OpportunityId = :opp.Id]; } catch (Exception ex) {}
try { delete [SELECT Id FROM Opportunity WHERE Id = :opp.Id]; } catch (Exception ex) {}
try { delete [SELECT Id FROM Contact WHERE AccountId = :acc.Id]; } catch (Exception ex) {}
try { if (p1 != null) delete [SELECT Id FROM Product2 WHERE Id IN (:p1.Id, :p2.Id)]; } catch (Exception ex) {}
try { delete [SELECT Id FROM Account WHERE Id = :acc.Id]; } catch (Exception ex) {}
System.debug('Cleanup: DONE');
