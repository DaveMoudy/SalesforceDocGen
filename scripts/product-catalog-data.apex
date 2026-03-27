/**
 * Product Catalog Data Generator
 * Creates 500 realistic products with images, a custom pricebook, and pricebook entries.
 * Each product gets a unique product image (ContentVersion) stored in Product_Image__c.
 *
 * Run: sf apex run --target-org <org> -f scripts/product-catalog-data.apex
 */

// ─── Product Names by Category ───────────────────────────────────────────────
// 10 categories × 50 products each = 500

List<String> electronics = new List<String>{
    'ProVision 4K Monitor 27"','ThunderBolt Wireless Mouse','ArcLight Mechanical Keyboard','NovaPad Pro Tablet 12"','SonicBoom Bluetooth Speaker',
    'ClearView Webcam HD','PowerSurge USB-C Hub 7-Port','EchoLink Wireless Earbuds','FlexCharge 65W Adapter','DataVault 2TB External SSD',
    'PixelPerfect Drawing Tablet','SwiftScan Document Scanner','CloudSync Wi-Fi 6 Router','QuietZone ANC Headphones','MagLock Laptop Stand',
    'TrueColor LED Desk Lamp','StreamPro Capture Card','BrightEdge Ring Light 18"','TechGuard Surge Protector 8','SpeedLink Cat8 Ethernet Cable 50ft',
    'UltraWide Monitor 34" Curved','MiniPod Portable Charger 20K','VoiceClear Conference Mic','HyperDock Thunderbolt 4','SmartTag Bluetooth Tracker 4-Pack',
    'CrystalClear HDMI Cable 6ft','PowerBar Desktop Charger','AirStream Laptop Cooler','PixelShift Webcam 4K','DataBridge USB Adapter Kit',
    'EchoSphere Smart Speaker','TurboCharge Car Adapter','ProLink DisplayPort Cable 10ft','SilentType Wireless Keyboard','NightOwl Gaming Mouse',
    'WaveForm Digital Audio Mixer','QuickShot Wireless Presenter','TechVault Laptop Sleeve 15"','PowerGrid Smart Power Strip','ArcBeam Portable Projector',
    'SoundStage Soundbar 36"','FlexMount Monitor Arm Dual','NetGuard VPN Router','ProCapture Streaming Kit','ChargePad Wireless Qi 15W',
    'CablePro Organizer Box','SmartPlug Wi-Fi Outlet 2-Pack','TrueTrack Fitness Band','UltraSlim Portable Monitor 15"','DataSync Card Reader USB-C'
};

List<String> officeSupplies = new List<String>{
    'Premium Copy Paper 5000-Sheet','Executive Ballpoint Pen Set','Heavy-Duty Stapler Industrial','Ergonomic Gel Mouse Pad','Filing Cabinet 4-Drawer Steel',
    'Whiteboard Magnetic 48x36','Desk Organizer Bamboo 6-Slot','Label Maker Pro Wireless','Binder Clips Assorted 120-Pack','Standing Desk Converter 36"',
    'Paper Shredder Cross-Cut 12-Sheet','Sticky Notes Neon 24-Pack','Ink Cartridge Multi-Color 4-Pack','Desk Calendar 2026 Large','Manila Folders Letter 100-Pack',
    'Highlighters Assorted 12-Pack','Tape Dispenser Weighted Black','Scissors Precision 8" Titanium','Push Pins Multi-Color 500-Pack','Envelope #10 Security 500-Pack',
    'Dry Erase Markers 12-Pack','Correction Tape 10-Pack','Paper Clips Jumbo 250-Pack','Index Cards Ruled 3x5 500-Pack','Pencil Sharpener Electric Desktop',
    'Rubber Bands Assorted 1lb','Presentation Binder 2" White 6-Pack','Tab Dividers 8-Tab 24-Set','Post-It Flag Markers 8-Color','Glue Sticks 30-Pack',
    'Letter Tray Stackable 3-Tier','Clipboard Hardboard Letter 12-Pack','Mechanical Pencils 0.7mm 24-Pack','Printer Paper Recycled 2500-Sheet','Desk Pad Large 36x20 Leather',
    'Packing Tape Clear 12-Roll','Hanging File Folders 50-Pack','Business Card Holder 240-Card','Laminating Pouches Letter 200-Pack','Calculator Desktop 12-Digit',
    'Stamp Pad Ink Red','Bookends Metal Heavy-Duty Pair','Page Protectors Clear 200-Pack','Marker Permanent Black 36-Pack','Notebook Spiral College 10-Pack',
    'Cork Board 24x18 with Frame','Pen Cup Mesh Desktop Black','Ruler Aluminum 18"','Mouse Pad Extended 35x16','Wrist Rest Keyboard Gel'
};

List<String> furniture = new List<String>{
    'Executive Mesh Office Chair','Standing Desk Electric 60x30','Conference Table Oval 8ft','Bookshelf 5-Tier Walnut','Filing Pedestal Mobile 3-Drawer',
    'Reception Desk L-Shaped','Guest Chair Stackable Fabric','Credenza Modern 60" Oak','Corner Desk with Hutch','Task Chair Ergonomic Lumbar',
    'Round Meeting Table 42"','Lateral File Cabinet 2-Drawer','Coat Rack Freestanding Wood','Side Table Modern 24x24','Storage Cabinet Locking 72"',
    'Drafting Stool Adjustable','Training Table Folding 72"','Privacy Screen Desktop 48"','Monitor Riser Walnut','Under-Desk Keyboard Tray',
    'Executive Desk 72x36 Mahogany','Whiteboard Stand Mobile 48x36','Lounge Chair Modern Leather','Coffee Table Round 36" Glass','Desk Return 48x24',
    'Adjustable Footrest Ergonomic','Wall-Mount Shelf 48"','Cubicle Panel 66" Fabric','Desk Lamp Architect Arm','Plant Stand 3-Tier Metal',
    'Breakroom Table Round 36"','Stacking Chair Polypropylene','TV Stand Mobile 65" Cart','Lectern Adjustable Height','Bench Entryway Storage 48"',
    'Sit-Stand Stool Active','End Table Drawer 18x18','Coat Hook Wall Mount 5-Hook','Desk Grommet Cable 2-Pack','Acoustic Panel 24x48 Charcoal',
    'Sofa Office 2-Seat Gray','Desk Partition Frosted 24x18','Pedestal Fan 16" Oscillating','Floor Mat Chair 46x60','Magazine Rack Wall Mount',
    'Wardrobe Locker Single','Step Stool 2-Step Folding','Corner Shelf Unit 5-Tier','Whiteboard Cabinet 48x36','Desk Bridge Connector 48"'
};

List<String> kitchenware = new List<String>{
    'Chef Knife Set 15-Piece Block','Non-Stick Frying Pan 12"','Stainless Steel Mixing Bowls 5-Set','Digital Kitchen Scale 22lb','Silicone Spatula Set 6-Piece',
    'Cast Iron Dutch Oven 6qt','Bamboo Cutting Board XL','Electric Kettle 1.7L Glass','Colander Stainless 5qt','Measuring Cup Set 7-Piece',
    'Food Storage Container Set 24-Pc','Blender Professional 64oz','Toaster 4-Slice Wide Slot','Coffee Maker 12-Cup Programmable','Stand Mixer 5qt 10-Speed',
    'Baking Sheet Set 3-Piece','Rolling Pin Marble 18"','Whisk Set Stainless 3-Piece','Ice Cream Scoop Spring-Loaded','Pizza Stone 16" Round',
    'Cheese Grater 4-Sided Box','Potato Masher Stainless','Tongs Set 9" and 12"','Ladle Stainless 6oz','Can Opener Manual Heavy-Duty',
    'Vegetable Peeler Swivel 3-Pack','Meat Thermometer Digital Instant','Egg Timer Digital Magnetic','Tea Infuser Ball Stainless','Citrus Juicer Manual',
    'Bread Knife Serrated 10"','Wok Carbon Steel 14"','Steamer Basket Stainless 9"','Cake Pan Round 9" 2-Pack','Muffin Tin 12-Cup Non-Stick',
    'Pie Dish Ceramic 9"','Cookie Sheet Air Insulated','Cooling Rack Stackable 2-Pack','Pastry Brush Silicone 2-Pack','Kitchen Timer Dual Digital',
    'Garlic Press Heavy-Duty','Corkscrew Double-Hinged','Pepper Mill Wooden 8"','Salt Cellar Bamboo Lid','Spice Rack Rotating 20-Jar',
    'Paper Towel Holder Counter','Dish Rack 2-Tier Stainless','Sponge Holder Sink Caddy','Compost Bin Counter 1.3gal','Utensil Crock Ceramic White'
};

List<String> clothing = new List<String>{
    'Oxford Button-Down Shirt Blue','Slim Fit Chinos Khaki','Merino Wool V-Neck Sweater','Classic Polo Shirt Navy','Stretch Dress Pants Charcoal',
    'Denim Jacket Trucker Medium','Performance T-Shirt Moisture-Wick','Fleece Quarter-Zip Pullover','Linen Blazer Summer Tan','Cargo Shorts Relaxed Olive',
    'Flannel Shirt Plaid Red','Athletic Joggers Tapered Black','Cashmere Scarf Heather Gray','Leather Belt Reversible 34"','Wool Peacoat Double-Breasted',
    'Rain Jacket Packable Blue','Thermal Henley Long-Sleeve','Corduroy Pants Straight Brown','Chambray Shirt Casual Fit','Down Vest Lightweight Navy',
    'Board Shorts Quick-Dry 9"','Dress Shirt French Cuff White','Windbreaker Half-Zip','Cable Knit Sweater Cream','Tech Pants 5-Pocket Gray',
    'Bomber Jacket Nylon Green','Compression Shirt Base Layer','Tweed Sport Coat Classic','Swimsuit Trunk Solid Navy','Hoodie Zip-Up Heather Gray',
    'Turtleneck Fine-Gauge Black','Hiking Pants Convertible','Graphic Tee Vintage Logo','Suit Jacket Slim Fit Navy','Parka Insulated Winter Black',
    'Rugby Shirt Striped','Track Pants Side-Stripe','Overcoat Wool-Blend Camel','Denim Shirt Western Snap','Softshell Jacket Waterproof',
    'Cardigan Button-Front Charcoal','Linen Pants Drawstring White','Performance Polo Quick-Dry','Varsity Jacket Letterman','Thermal Pants Base Layer',
    'Safari Jacket Multi-Pocket','Hawaiian Shirt Floral','Vest Quilted Field Green','Driving Gloves Leather Brown','Beanie Ribbed Knit Charcoal'
};

List<String> sports = new List<String>{
    'Running Shoes Lightweight 10.5','Yoga Mat Premium 6mm Purple','Resistance Band Set 5-Level','Adjustable Dumbbell 52.5lb Pair','Jump Rope Speed Bearing',
    'Foam Roller High-Density 36"','Kettlebell Cast Iron 35lb','Pull-Up Bar Doorway','Exercise Ball 65cm Anti-Burst','Boxing Gloves 14oz Leather',
    'Tennis Racket Carbon Fiber','Basketball Indoor/Outdoor Size 7','Soccer Ball FIFA Official Size 5','Golf Club Set 12-Piece','Baseball Glove 12.5" Leather',
    'Swimming Goggles Anti-Fog','Cycling Helmet Road Large','Ski Goggles UV Protection','Badminton Racket 2-Pack','Table Tennis Paddle Pro Set',
    'Lacrosse Stick Complete','Hockey Stick Composite 60"','Volleyball Indoor Official','Cricket Bat English Willow','Archery Target Bag 26"',
    'Weight Bench Adjustable FID','Barbell Olympic 7ft 45lb','Weight Plates Rubber 45lb Pair','Squat Rack Folding Wall-Mount','Ab Roller Wheel Double',
    'Battle Rope 30ft 1.5"','Medicine Ball Rubber 15lb','Agility Ladder 20ft','Cone Set Training 50-Pack','Speed Parachute Running',
    'Grip Strengthener Set 3-Pack','Ankle Weights 5lb Pair','Stability Ball Chair Base','Stretch Strap Yoga 10-Loop','Massage Gun Percussion Deep',
    'Heart Rate Monitor Chest Strap','GPS Sports Watch Multi-Sport','Bike Computer Wireless','Swim Cap Silicone 2-Pack','Water Bottle Insulated 32oz',
    'Gym Bag Duffel 40L','Sweatband Headband 6-Pack','Athletic Tape 1.5" 6-Roll','Compression Sleeve Calf Pair','Sports Sunglasses Polarized'
};

List<String> gardening = new List<String>{
    'Garden Hose Expandable 100ft','Pruning Shears Bypass Titanium','Raised Garden Bed 4x8 Cedar','Wheelbarrow Steel 6 Cubic Ft','Sprinkler Oscillating Brass',
    'Potting Soil Premium 40qt','Garden Gloves Thorn-Proof','Seed Starting Kit 72-Cell','Lawn Mower Push 22"','Hedge Trimmer Electric 24"',
    'Plant Labels Bamboo 100-Pack','Watering Can Galvanized 2gal','Garden Kneeler Pad Foam','Trowel Stainless Steel','Cultivator 3-Prong Hand',
    'Fertilizer All-Purpose 10lb','Compost Bin Tumbling 43gal','Garden Fork Steel 4-Tine','Leaf Rake Adjustable 30"','Edging Border 20ft',
    'Planter Pot Ceramic 12"','Hanging Basket Coconut Liner','Plant Stand Indoor 3-Tier','Garden Hose Reel Wall-Mount','Soaker Hose 50ft',
    'Weed Barrier Fabric 4x100ft','Mulch Cedar Red 2 Cubic Ft','Topsoil Screened 40lb','Bird Feeder Cedar House','Birdbath Pedestal Concrete',
    'Rain Gauge Clear 5"','Thermometer Outdoor Wireless','Solar Path Lights 10-Pack','Garden Statue Gnome 12"','Wind Chime Bamboo 36"',
    'Greenhouse Mini 4-Tier','Cold Frame Double-Wall','Drip Irrigation Kit 100ft','Timer Hose Digital 2-Zone','Pest Control Neem Oil 32oz',
    'Insect Net Garden 10x12','Tomato Cage Heavy-Duty 5-Pack','Plant Support Stakes 4ft 20-Pack','Seed Storage Box Organizer','Soil Test Kit Digital pH',
    'Pressure Washer 2100 PSI','Garden Cart Dump 10 Cubic Ft','Chainsaw Electric 16"','Leaf Blower Cordless 20V','String Trimmer 15" Dual-Line'
};

List<String> automotive = new List<String>{
    'Floor Mats All-Weather 4-Piece','Car Cover Waterproof XL','Dash Cam Dual 4K Front+Rear','Jump Starter Portable 2000A','Tire Inflator Digital 12V',
    'Car Vacuum Cordless Handheld','Phone Mount Magnetic Vent','Seat Cover Set Leather 2-Pack','Steering Wheel Cover Leather','Sun Shade Windshield Foldable',
    'Trunk Organizer Collapsible','Emergency Kit Roadside 120-Pc','OBD2 Scanner Bluetooth Pro','Battery Charger Smart 12V','Wiper Blades Premium 24" Pair',
    'Car Wash Kit Complete 10-Piece','Polishing Machine Dual-Action','Clay Bar Kit Detailing','Tire Pressure Gauge Digital','Lug Wrench Telescoping Cross',
    'Jack Stand 3-Ton Pair','Creeper Mechanic Padded 40"','Tool Set Mechanic 200-Piece','Oil Drain Pan 16qt','Funnel Set Flexible 4-Piece',
    'Air Freshener Vent Clip 6-Pack','LED Headlight Bulb H11 Pair','Fog Light Kit Yellow 3000K','License Plate Frame 2-Pack','Cargo Net Trunk Elastic',
    'Roof Rack Cross Bars Universal','Bike Rack Hitch 4-Bike','Trailer Hitch Ball 2"','Tow Strap 30ft 30000lb','Recovery Board Traction 2-Pack',
    'Blind Spot Mirror Pair','Backup Camera Wireless HD','Parking Sensor Kit 8-Sensor','Paint Touch-Up Kit Universal','Scratch Remover Compound',
    'Interior Cleaner All-Surface','Leather Conditioner 16oz','Glass Cleaner Streak-Free 32oz','Tire Shine Gel Long-Lasting','Microfiber Towels 24-Pack',
    'Ice Scraper Snow Brush 36"','Antifreeze Coolant 1gal','Transmission Fluid ATF 1qt','Brake Fluid DOT 4 12oz','Engine Oil Synthetic 5W-30 5qt'
};

List<String> healthBeauty = new List<String>{
    'Vitamin D3 5000 IU 360-Cap','Protein Powder Whey 5lb Vanilla','Multivitamin Complete Daily','Omega-3 Fish Oil 1000mg 120-Soft','Probiotic 50 Billion CFU 60-Cap',
    'Collagen Peptides Powder 20oz','Magnesium Glycinate 400mg','Zinc Picolinate 50mg 120-Cap','Vitamin C 1000mg 250-Tab','B-Complex Super 100-Cap',
    'Sunscreen SPF 50 Face 3oz','Moisturizer Daily SPF 30','Face Wash Gentle Cleanser 8oz','Retinol Serum 2.5% 1oz','Hyaluronic Acid Serum 2oz',
    'Eye Cream Anti-Aging 0.5oz','Lip Balm SPF 15 3-Pack','Body Lotion Unscented 16oz','Hand Cream Intensive 3oz','Foot Cream Repair 4oz',
    'Shampoo Volumizing 16oz','Conditioner Hydrating 16oz','Hair Oil Argan 4oz','Hair Mask Deep Repair 8oz','Dry Shampoo Spray 7oz',
    'Toothbrush Electric Sonic','Toothpaste Whitening 2-Pack','Dental Floss Mint 6-Pack','Mouthwash Antiseptic 1.5L','Tongue Scraper Stainless',
    'Deodorant Natural 3-Pack','Razor Safety Double-Edge','Shaving Cream Sensitive 6oz','Aftershave Balm 3.4oz','Beard Oil Sandalwood 2oz',
    'Nail Clipper Set 3-Piece','Tweezers Precision Slant','Cotton Rounds 100-Pack','Facial Tissue Soft 12-Box','Hand Sanitizer 8oz 3-Pack',
    'Heating Pad Electric 12x24','Ice Pack Gel Reusable 2-Pack','Thermometer Forehead Digital','Blood Pressure Monitor Arm','Pulse Oximeter Fingertip',
    'First Aid Kit 300-Piece','Bandages Adhesive 100-Pack','Melatonin 5mg Gummies 120','Electrolyte Powder 30-Pack','Essential Oil Set 6-Bottle'
};

List<String> petSupplies = new List<String>{
    'Dog Food Premium Chicken 30lb','Cat Food Indoor Formula 16lb','Dog Bed Orthopedic Large','Cat Tree Tower 72" Multi-Level','Pet Carrier Airline Approved',
    'Dog Leash Retractable 16ft','Cat Litter Clumping 40lb','Dog Crate Wire Folding 42"','Pet Water Fountain 128oz','Dog Toy Chew Rope 5-Pack',
    'Cat Toy Interactive Feather','Dog Brush Deshedding Tool','Cat Scratcher Lounge Cardboard','Dog Bowl Slow Feeder','Cat Bowl Elevated 2-Pack',
    'Pet Shampoo Oatmeal 16oz','Dog Treats Training 1lb','Cat Treats Freeze-Dried 5oz','Flea Collar Dog Large 8-Month','Tick Remover Tool Kit',
    'Dog Harness No-Pull Padded','Cat Harness and Leash Set','Pet First Aid Kit 75-Piece','Dog Waste Bags 900-Count','Cat Litter Mat 30x24',
    'Pet Camera Indoor Wi-Fi','Dog Door Flap Large','Cat Flap Microchip Smart','Pet Gate Freestanding 76"','Dog Ramp Folding Car',
    'Pet Blanket Waterproof','Dog Coat Winter Reflective','Cat Bed Heated Electric','Fish Tank Starter Kit 20gal','Aquarium Filter Canister 75gal',
    'Bird Cage Large 30x18x36','Hamster Habitat Multi-Level','Reptile Terrarium 40gal','Pet Nail Grinder Quiet','Dog Toothbrush Kit 3-Piece',
    'Cat Fountain Filter 6-Pack','Dog ID Tag Stainless Custom','Pet Hair Remover Roller','Dog Training Clicker 2-Pack','Cat Catnip Organic 2oz',
    'Aquarium Heater 200W','Fish Food Tropical Flake 4oz','Bird Seed Mix Premium 10lb','Small Animal Bedding 56L','Pet Odor Eliminator Spray 32oz'
};

// ─── Build master list with categories ──────────────────────────────────────
List<List<String>> allCategories = new List<List<String>>{
    electronics, officeSupplies, furniture, kitchenware, clothing,
    sports, gardening, automotive, healthBeauty, petSupplies
};
List<String> categoryNames = new List<String>{
    'Electronics', 'Office Supplies', 'Furniture', 'Kitchen & Dining', 'Clothing & Apparel',
    'Sports & Fitness', 'Garden & Outdoor', 'Automotive', 'Health & Beauty', 'Pet Supplies'
};

// ─── Generate color-coded placeholder product images ────────────────────────
// Each category gets a distinct background color to visually distinguish products.
// Images are 200x200 SVG rendered as PNG-like placeholders stored as ContentVersion.

// Actually, we'll create simple but visually distinct images using SVG stored as content.
// Since we can't generate real PNGs in Apex, we'll create HTML-rendered images via a different approach:
// Store the product name as text in a small colored rectangle using SVG (converted to blob).

// Category colors (vibrant, distinct)
List<String> categoryColors = new List<String>{
    '3B82F6', 'F59E0B', '10B981', 'EF4444', '8B5CF6',
    'EC4899', '14B8A6', 'F97316', '06B6D4', '84CC16'
};

// Category icons (emoji-like symbols for the SVG)
List<String> categoryIcons = new List<String>{
    '&#9889;',    // ⚡ Electronics
    '&#9998;',    // ✎ Office
    '&#9750;',    // ☆ Furniture
    '&#9832;',    // ♨ Kitchen
    '&#9733;',    // ★ Clothing
    '&#9917;',    // ⚽ Sports
    '&#9752;',    // ☘ Garden
    '&#9881;',    // ⚙ Automotive
    '&#9829;',    // ♥ Health
    '&#128062;'   // 🐾 Pets
};

System.debug('Creating 500 products with images, pricebook, and entries...');

// ─── Step 1: Create all products ────────────────────────────────────────────
List<Product2> products = new List<Product2>();
List<Integer> productCategoryIndex = new List<Integer>();
for (Integer catIdx = 0; catIdx < allCategories.size(); catIdx++) {
    List<String> catProducts = allCategories[catIdx];
    for (Integer pIdx = 0; pIdx < catProducts.size(); pIdx++) {
        Product2 p = new Product2();
        p.Name = catProducts[pIdx];
        p.ProductCode = categoryNames[catIdx].substring(0, 3).toUpperCase() + '-' + String.valueOf(catIdx * 50 + pIdx + 1).leftPad(4, '0');
        p.Description = categoryNames[catIdx] + ' — ' + catProducts[pIdx];
        p.Family = categoryNames[catIdx];
        p.IsActive = true;
        products.add(p);
        productCategoryIndex.add(catIdx);
    }
}
insert products;
System.debug('Inserted ' + products.size() + ' products');

// ─── Step 2: Create product images as ContentVersion (SVG) ──────────────────
List<ContentVersion> imageCvs = new List<ContentVersion>();
for (Integer i = 0; i < products.size(); i++) {
    Integer catIdx = productCategoryIndex[i];
    String color = categoryColors[catIdx];
    String icon = categoryIcons[catIdx];
    String prodName = products[i].Name;
    // Truncate long names for the image
    if (prodName.length() > 30) {
        prodName = prodName.substring(0, 28) + '..';
    }
    String category = categoryNames[catIdx];

    // Create a simple but attractive SVG product image
    String svg = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200">' +
        '<defs><linearGradient id="bg' + i + '" x1="0%" y1="0%" x2="100%" y2="100%">' +
        '<stop offset="0%" style="stop-color:#' + color + ';stop-opacity:1"/>' +
        '<stop offset="100%" style="stop-color:#' + color + ';stop-opacity:0.7"/>' +
        '</linearGradient></defs>' +
        '<rect width="200" height="200" rx="12" fill="url(#bg' + i + ')"/>' +
        '<text x="100" y="80" font-family="Arial,sans-serif" font-size="48" fill="white" text-anchor="middle" opacity="0.9">' + icon + '</text>' +
        '<text x="100" y="120" font-family="Arial,sans-serif" font-size="10" fill="white" text-anchor="middle" font-weight="bold">' + prodName.escapeXml() + '</text>' +
        '<text x="100" y="145" font-family="Arial,sans-serif" font-size="9" fill="white" text-anchor="middle" opacity="0.8">' + category.escapeXml() + '</text>' +
        '<rect x="60" y="160" width="80" height="20" rx="10" fill="rgba(255,255,255,0.2)"/>' +
        '<text x="100" y="174" font-family="Arial,sans-serif" font-size="8" fill="white" text-anchor="middle">' + products[i].ProductCode + '</text>' +
        '</svg>';

    ContentVersion cv = new ContentVersion();
    cv.Title = 'Product Image - ' + products[i].Name;
    cv.PathOnClient = products[i].ProductCode + '.svg';
    cv.VersionData = Blob.valueOf(svg);
    cv.FirstPublishLocationId = products[i].Id;
    imageCvs.add(cv);
}

// Insert in batches of 200 to avoid DML limits
List<ContentVersion> batch1 = new List<ContentVersion>();
List<ContentVersion> batch2 = new List<ContentVersion>();
List<ContentVersion> batch3 = new List<ContentVersion>();
for (Integer i = 0; i < imageCvs.size(); i++) {
    if (i < 200) { batch1.add(imageCvs[i]); }
    else if (i < 400) { batch2.add(imageCvs[i]); }
    else { batch3.add(imageCvs[i]); }
}
insert batch1;
insert batch2;
insert batch3;
System.debug('Inserted ' + imageCvs.size() + ' product images');

// ─── Step 3: Query back ContentVersion IDs and update Product_Image__c ──────
// We need the committed CV IDs (after insert)
Set<Id> allCvIds = new Set<Id>();
for (ContentVersion cv : imageCvs) { allCvIds.add(cv.Id); }

Map<Id, ContentVersion> cvMap = new Map<Id, ContentVersion>([
    SELECT Id, FirstPublishLocationId
    FROM ContentVersion
    WHERE Id IN :allCvIds
]);

List<Product2> productsToUpdate = new List<Product2>();
for (ContentVersion cv : cvMap.values()) {
    if (cv.FirstPublishLocationId != null) {
        Product2 p = new Product2(Id = cv.FirstPublishLocationId);
        p.put('portwoodglobal__Product_Image__c', cv.Id);
        productsToUpdate.add(p);
    }
}

// Update in batches
List<Product2> upBatch1 = new List<Product2>();
List<Product2> upBatch2 = new List<Product2>();
List<Product2> upBatch3 = new List<Product2>();
for (Integer i = 0; i < productsToUpdate.size(); i++) {
    if (i < 200) { upBatch1.add(productsToUpdate[i]); }
    else if (i < 400) { upBatch2.add(productsToUpdate[i]); }
    else { upBatch3.add(productsToUpdate[i]); }
}
if (!upBatch1.isEmpty()) { update upBatch1; }
if (!upBatch2.isEmpty()) { update upBatch2; }
if (!upBatch3.isEmpty()) { update upBatch3; }
System.debug('Updated ' + productsToUpdate.size() + ' products with image CV IDs');

// ─── Step 4: Create Pricebook and Entries ───────────────────────────────────
// Get standard pricebook
Id stdPbId = Test.isRunningTest() ? Test.getStandardPricebookId() : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

// Create standard pricebook entries first (required before custom PB entries)
List<PricebookEntry> stdEntries = new List<PricebookEntry>();
for (Integer i = 0; i < products.size(); i++) {
    Integer catIdx = productCategoryIndex[i];
    // Realistic price ranges by category
    Decimal basePrice;
    if (catIdx == 0) { basePrice = 29.99 + (Math.random() * 470); }      // Electronics: $30-500
    else if (catIdx == 1) { basePrice = 4.99 + (Math.random() * 95); }    // Office: $5-100
    else if (catIdx == 2) { basePrice = 89.99 + (Math.random() * 910); }  // Furniture: $90-1000
    else if (catIdx == 3) { basePrice = 9.99 + (Math.random() * 190); }   // Kitchen: $10-200
    else if (catIdx == 4) { basePrice = 19.99 + (Math.random() * 280); }  // Clothing: $20-300
    else if (catIdx == 5) { basePrice = 14.99 + (Math.random() * 285); }  // Sports: $15-300
    else if (catIdx == 6) { basePrice = 9.99 + (Math.random() * 290); }   // Garden: $10-300
    else if (catIdx == 7) { basePrice = 7.99 + (Math.random() * 192); }   // Auto: $8-200
    else if (catIdx == 8) { basePrice = 6.99 + (Math.random() * 93); }    // Health: $7-100
    else { basePrice = 8.99 + (Math.random() * 141); }                     // Pets: $9-150

    // Round to .99
    basePrice = Math.floor(basePrice) + 0.99;

    PricebookEntry pbe = new PricebookEntry();
    pbe.Pricebook2Id = stdPbId;
    pbe.Product2Id = products[i].Id;
    pbe.UnitPrice = basePrice;
    pbe.IsActive = true;
    stdEntries.add(pbe);
}

// Insert standard entries in batches
List<PricebookEntry> sBatch1 = new List<PricebookEntry>();
List<PricebookEntry> sBatch2 = new List<PricebookEntry>();
List<PricebookEntry> sBatch3 = new List<PricebookEntry>();
for (Integer i = 0; i < stdEntries.size(); i++) {
    if (i < 200) { sBatch1.add(stdEntries[i]); }
    else if (i < 400) { sBatch2.add(stdEntries[i]); }
    else { sBatch3.add(stdEntries[i]); }
}
insert sBatch1;
insert sBatch2;
insert sBatch3;
System.debug('Inserted ' + stdEntries.size() + ' standard pricebook entries');

// Create custom pricebook
Pricebook2 catalog = new Pricebook2();
catalog.Name = 'Product Catalog 2026';
catalog.Description = '2026 Full Product Catalog — 500 products across 10 categories';
catalog.IsActive = true;
insert catalog;
System.debug('Created pricebook: ' + catalog.Name);

// Create custom pricebook entries (with slight markup)
List<PricebookEntry> catalogEntries = new List<PricebookEntry>();
for (Integer i = 0; i < products.size(); i++) {
    PricebookEntry pbe = new PricebookEntry();
    pbe.Pricebook2Id = catalog.Id;
    pbe.Product2Id = products[i].Id;
    pbe.UnitPrice = stdEntries[i].UnitPrice; // Same price as standard
    pbe.IsActive = true;
    catalogEntries.add(pbe);
}

List<PricebookEntry> cBatch1 = new List<PricebookEntry>();
List<PricebookEntry> cBatch2 = new List<PricebookEntry>();
List<PricebookEntry> cBatch3 = new List<PricebookEntry>();
for (Integer i = 0; i < catalogEntries.size(); i++) {
    if (i < 200) { cBatch1.add(catalogEntries[i]); }
    else if (i < 400) { cBatch2.add(catalogEntries[i]); }
    else { cBatch3.add(catalogEntries[i]); }
}
insert cBatch1;
insert cBatch2;
insert cBatch3;
System.debug('Inserted ' + catalogEntries.size() + ' catalog pricebook entries');

// ─── Summary ────────────────────────────────────────────────────────────────
System.debug('');
System.debug('═══════════════════════════════════════════════════');
System.debug('  PRODUCT CATALOG DATA GENERATION COMPLETE');
System.debug('═══════════════════════════════════════════════════');
System.debug('  Products created:      ' + products.size());
System.debug('  Product images:        ' + imageCvs.size());
System.debug('  Pricebook:             ' + catalog.Name);
System.debug('  Standard PB entries:   ' + stdEntries.size());
System.debug('  Catalog PB entries:    ' + catalogEntries.size());
System.debug('');
System.debug('  Categories:');
for (Integer c = 0; c < categoryNames.size(); c++) {
    System.debug('    • ' + categoryNames[c] + ' (' + allCategories[c].size() + ' products)');
}
System.debug('');
System.debug('  Template fields to use:');
System.debug('    {Product2.Name}');
System.debug('    {Product2.Id}');
System.debug('    {%Product2.portwoodglobal__Product_Image__c}');
System.debug('    {Product2.ProductCode}');
System.debug('    {Product2.Family}');
System.debug('    {UnitPrice:currency}');
System.debug('    {*Product2.ProductCode} (barcode)');
System.debug('═══════════════════════════════════════════════════');
