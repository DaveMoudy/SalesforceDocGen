/**
 * Step 3: Create product images for remaining 250 products (251-500) and set Product_Image__c.
 * Run AFTER step2. Run: sf apex run --target-org <org> -f scripts/product-catalog-step3.apex
 */

Map<String, String> catColors = new Map<String, String>{
    'Electronics'=>'3B82F6','Office Supplies'=>'F59E0B','Furniture'=>'10B981',
    'Kitchen'=>'EF4444','Clothing'=>'8B5CF6','Sports'=>'EC4899',
    'Garden'=>'14B8A6','Automotive'=>'F97316','Health'=>'06B6D4','Pets'=>'84CC16'
};

// Get products that DON'T have an image yet
List<Product2> products = [
    SELECT Id, Name, ProductCode, Family
    FROM Product2
    WHERE IsActive = true AND portwoodglobal__Product_Image__c = null
    ORDER BY ProductCode ASC
    LIMIT 250
];
System.debug('Found ' + products.size() + ' products needing images (batch 2)');

if (products.isEmpty()) {
    System.debug('All products already have images. Nothing to do.');
} else {
    List<ContentVersion> cvs = new List<ContentVersion>();
    for (Product2 p : products) {
        String color = catColors.containsKey(p.Family) ? catColors.get(p.Family) : '64748B';
        String label = p.Name.length() > 28 ? p.Name.substring(0, 26) + '..' : p.Name;
        String svg = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">' +
            '<rect width="200" height="200" rx="12" fill="#' + color + '"/>' +
            '<text x="100" y="70" font-size="11" fill="#fff" text-anchor="middle" font-weight="bold">' + label.escapeXml() + '</text>' +
            '<text x="100" y="95" font-size="9" fill="#fff" text-anchor="middle" opacity="0.8">' + (p.Family != null ? p.Family.escapeXml() : '') + '</text>' +
            '<rect x="50" y="110" width="100" height="22" rx="11" fill="rgba(255,255,255,0.2)"/>' +
            '<text x="100" y="125" font-size="9" fill="#fff" text-anchor="middle">' + p.ProductCode + '</text>' +
            '</svg>';
        cvs.add(new ContentVersion(
            Title = 'Product Image - ' + p.Name,
            PathOnClient = p.ProductCode + '.svg',
            VersionData = Blob.valueOf(svg),
            FirstPublishLocationId = p.Id
        ));
    }

    List<ContentVersion> b1 = new List<ContentVersion>();
    List<ContentVersion> b2 = new List<ContentVersion>();
    for (Integer i = 0; i < cvs.size(); i++) {
        if (i < 125) { b1.add(cvs[i]); } else { b2.add(cvs[i]); }
    }
    insert b1;
    if (!b2.isEmpty()) { insert b2; }
    System.debug('Created ' + cvs.size() + ' product images');

    Set<Id> cvIds = new Set<Id>();
    for (ContentVersion cv : cvs) { cvIds.add(cv.Id); }
    List<ContentVersion> committed = [SELECT Id, FirstPublishLocationId FROM ContentVersion WHERE Id IN :cvIds];

    List<Product2> updates = new List<Product2>();
    for (ContentVersion cv : committed) {
        Product2 p = new Product2(Id = cv.FirstPublishLocationId);
        p.put('portwoodglobal__Product_Image__c', cv.Id);
        updates.add(p);
    }
    List<Product2> u1 = new List<Product2>();
    List<Product2> u2 = new List<Product2>();
    for (Integer i = 0; i < updates.size(); i++) {
        if (i < 125) { u1.add(updates[i]); } else { u2.add(updates[i]); }
    }
    update u1;
    if (!u2.isEmpty()) { update u2; }
    System.debug('DONE: Updated ' + updates.size() + ' products with image CV IDs (batch 2 of 2)');
    System.debug('All 500 products should now have images!');
}
