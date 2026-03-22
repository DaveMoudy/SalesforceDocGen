// =====================================================================
// DocGen FULL End-to-End Test — ONE CLICK
// Creates data, builds tree config, generates document, validates all
// Run: sf apex run --target-org <org> -f /tmp/docgen_full_e2e.apex
// =====================================================================

Integer pass = 0;
Integer fail = 0;

// === 1. DATA SETUP ===
Account acc = new Account(Name='E2E-' + DateTime.now().getTime(), Industry='Technology', Phone='(555) 999-' + String.valueOf(Math.mod(Math.abs(Crypto.getRandomInteger()), 10000)).leftPad(4, '0'), Website='www.test.com', BillingStreet='100 Test Dr', BillingCity='San Francisco', BillingState='CA', BillingPostalCode='94105');
Database.DMLOptions dml = new Database.DMLOptions();
dml.DuplicateRuleHeader.allowSave = true;
Database.insert(acc, dml);

String uid = String.valueOf(Math.mod(Math.abs(Crypto.getRandomInteger()), 100000));
List<Contact> cons = new List<Contact>{
    new Contact(AccountId=acc.Id, FirstName='Alice', LastName='Johnson-'+uid, Title='CEO', Email='alice'+uid+'@test.com'),
    new Contact(AccountId=acc.Id, FirstName='Bob', LastName='Smith-'+uid, Title='CTO', Email='bob'+uid+'@test.com')
};
Database.insert(cons, dml);

Opportunity opp = new Opportunity(Name='Test Deal-'+uid, AccountId=acc.Id, Amount=100000, StageName='Proposal/Price Quote', CloseDate=Date.today().addDays(30));
Database.insert(opp, dml);

List<Pricebook2> pbs = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
if (!pbs.isEmpty()) {
    Product2 p1 = new Product2(Name='Widget Pro', IsActive=true);
    Product2 p2 = new Product2(Name='Support Plan', IsActive=true);
    insert new List<Product2>{p1, p2};
    PricebookEntry pe1 = new PricebookEntry(Pricebook2Id=pbs[0].Id, Product2Id=p1.Id, UnitPrice=5000, IsActive=true);
    PricebookEntry pe2 = new PricebookEntry(Pricebook2Id=pbs[0].Id, Product2Id=p2.Id, UnitPrice=1000, IsActive=true);
    insert new List<PricebookEntry>{pe1, pe2};
    insert new List<OpportunityLineItem>{
        new OpportunityLineItem(OpportunityId=opp.Id, PricebookEntryId=pe1.Id, Quantity=10, UnitPrice=5000),
        new OpportunityLineItem(OpportunityId=opp.Id, PricebookEntryId=pe2.Id, Quantity=5, UnitPrice=1000)
    };
}

// === 2. V3 TREE WALKER TEST ===
String v3 = '{"v":3,"root":"Account","nodes":[' +
    '{"id":"n0","object":"Account","fields":["Name","Industry","Phone"],"parentFields":["Owner.Name"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
    '{"id":"n1","object":"Contact","fields":["FirstName","LastName","Title","Email"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"},' +
    '{"id":"n2","object":"Opportunity","fields":["Name","Amount","StageName"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Opportunities"},' +
    '{"id":"n3","object":"OpportunityLineItem","fields":["Quantity","UnitPrice","TotalPrice"],"parentFields":["Product2.Name"],"parentNode":"n2","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}' +
    ']}';

Map<String, Object> data = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3);

// Validate tree structure
if (data.get('Name') == acc.Name) { pass++; } else { fail++; System.debug('FAIL: Account Name'); }

Object owner = data.get('Owner');
if (owner instanceof Map<String, Object> && ((Map<String, Object>)owner).get('Name') != null) { pass++; } else { fail++; System.debug('FAIL: Owner.Name'); }

Object cObj = data.get('Contacts');
Integer cCount = 0;
if (cObj instanceof Map<String, Object>) { cCount = ((List<Object>)((Map<String, Object>)cObj).get('records')).size(); }
if (cCount == 2) { pass++; } else { fail++; System.debug('FAIL: Contacts count=' + cCount + ' expected 2'); }

Object oObj = data.get('Opportunities');
Integer oCount = 0;
Integer liCount = 0;
if (oObj instanceof Map<String, Object>) {
    List<Object> oRecs = (List<Object>)((Map<String, Object>)oObj).get('records');
    oCount = oRecs.size();
    if (!oRecs.isEmpty()) {
        Map<String, Object> firstOpp = (Map<String, Object>)oRecs[0];
        Object liObj = firstOpp.get('OpportunityLineItems');
        if (liObj instanceof Map<String, Object>) {
            liCount = ((List<Object>)((Map<String, Object>)liObj).get('records')).size();
            // Check Product2.Name parent field on line items
            List<Object> liRecs = (List<Object>)((Map<String, Object>)liObj).get('records');
            if (!liRecs.isEmpty()) {
                Map<String, Object> firstLi = (Map<String, Object>)liRecs[0];
                Object prod = firstLi.get('Product2');
                if (prod instanceof Map<String, Object> && ((Map<String, Object>)prod).get('Name') != null) { pass++; } else { fail++; System.debug('FAIL: Product2.Name on LineItem'); }
            }
        }
    }
}
if (oCount == 1) { pass++; } else { fail++; System.debug('FAIL: Opp count=' + oCount); }
if (liCount == 2) { pass++; } else { fail++; System.debug('FAIL: LineItem count=' + liCount + ' expected 2'); }

// === 3. LEGACY V1 BACKWARD COMPAT ===
Map<String, Object> legData = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, Industry, (SELECT FirstName, LastName FROM Contacts)');
Object lcObj = legData.get('Contacts');
Integer lcCount = 0;
if (lcObj instanceof Map<String, Object>) { lcCount = ((List<Object>)((Map<String, Object>)lcObj).get('records')).size(); }
if (lcCount == 2) { pass++; } else { fail++; System.debug('FAIL: Legacy contacts count=' + lcCount); }

// === 4. DOCUMENT GENERATION ===
DocGen_Template__c tmpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'E2E Full Tree Test' LIMIT 1];
try {
    Id cdId = DocGenService.generateDocument(tmpl.Id, acc.Id);
    if (cdId != null) { pass++; } else { fail++; System.debug('FAIL: generateDocument returned null'); }
    List<ContentVersion> cvs = [SELECT ContentSize, FileExtension FROM ContentVersion WHERE ContentDocumentId = :cdId LIMIT 1];
    if (!cvs.isEmpty() && cvs[0].ContentSize > 0) { pass++; } else { fail++; System.debug('FAIL: Generated file empty'); }
    System.debug('Generated: ' + cvs[0].FileExtension + ' ' + cvs[0].ContentSize + ' bytes');
} catch (Exception e) {
    fail++;
    System.debug('FAIL: Generation error: ' + e.getMessage());
}

// === RESULTS ===
System.debug('');
System.debug('==============================');
System.debug('  PASS: ' + pass + '  FAIL: ' + fail);
System.debug('  ' + (fail == 0 ? 'ALL TESTS PASSED' : fail + ' TESTS FAILED'));
System.debug('==============================');
