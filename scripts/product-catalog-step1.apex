/**
 * Step 1: Create 500 products + pricebook + pricebook entries.
 * Run: sf apex run --target-org <org> -f scripts/product-catalog-step1.apex
 * Then run step2 and step3 for images.
 */

List<String> names = new List<String>{
'ProVision 4K Monitor 27"','ThunderBolt Wireless Mouse','ArcLight Mechanical Keyboard','NovaPad Pro Tablet 12"','SonicBoom Bluetooth Speaker',
'ClearView Webcam HD','PowerSurge USB-C Hub 7-Port','EchoLink Wireless Earbuds','FlexCharge 65W Adapter','DataVault 2TB External SSD',
'PixelPerfect Drawing Tablet','SwiftScan Document Scanner','CloudSync Wi-Fi 6 Router','QuietZone ANC Headphones','MagLock Laptop Stand',
'TrueColor LED Desk Lamp','StreamPro Capture Card','BrightEdge Ring Light 18"','TechGuard Surge Protector 8','SpeedLink Cat8 Ethernet Cable 50ft',
'UltraWide Monitor 34" Curved','MiniPod Portable Charger 20K','VoiceClear Conference Mic','HyperDock Thunderbolt 4','SmartTag Bluetooth Tracker 4-Pack',
'CrystalClear HDMI Cable 6ft','PowerBar Desktop Charger','AirStream Laptop Cooler','PixelShift Webcam 4K','DataBridge USB Adapter Kit',
'EchoSphere Smart Speaker','TurboCharge Car Adapter','ProLink DisplayPort Cable 10ft','SilentType Wireless Keyboard','NightOwl Gaming Mouse',
'WaveForm Digital Audio Mixer','QuickShot Wireless Presenter','TechVault Laptop Sleeve 15"','PowerGrid Smart Power Strip','ArcBeam Portable Projector',
'SoundStage Soundbar 36"','FlexMount Monitor Arm Dual','NetGuard VPN Router','ProCapture Streaming Kit','ChargePad Wireless Qi 15W',
'CablePro Organizer Box','SmartPlug Wi-Fi Outlet 2-Pack','TrueTrack Fitness Band','UltraSlim Portable Monitor 15"','DataSync Card Reader USB-C',
'Premium Copy Paper 5000-Sheet','Executive Ballpoint Pen Set','Heavy-Duty Stapler Industrial','Ergonomic Gel Mouse Pad','Filing Cabinet 4-Drawer Steel',
'Whiteboard Magnetic 48x36','Desk Organizer Bamboo 6-Slot','Label Maker Pro Wireless','Binder Clips Assorted 120-Pack','Standing Desk Converter 36"',
'Paper Shredder Cross-Cut 12-Sheet','Sticky Notes Neon 24-Pack','Ink Cartridge Multi-Color 4-Pack','Desk Calendar 2026 Large','Manila Folders Letter 100-Pack',
'Highlighters Assorted 12-Pack','Tape Dispenser Weighted Black','Scissors Precision 8" Titanium','Push Pins Multi-Color 500-Pack','Envelope #10 Security 500-Pack',
'Dry Erase Markers 12-Pack','Correction Tape 10-Pack','Paper Clips Jumbo 250-Pack','Index Cards Ruled 3x5 500-Pack','Pencil Sharpener Electric Desktop',
'Rubber Bands Assorted 1lb','Presentation Binder 2" White 6-Pack','Tab Dividers 8-Tab 24-Set','Post-It Flag Markers 8-Color','Glue Sticks 30-Pack',
'Letter Tray Stackable 3-Tier','Clipboard Hardboard Letter 12-Pack','Mechanical Pencils 0.7mm 24-Pack','Printer Paper Recycled 2500-Sheet','Desk Pad Large 36x20 Leather',
'Packing Tape Clear 12-Roll','Hanging File Folders 50-Pack','Business Card Holder 240-Card','Laminating Pouches Letter 200-Pack','Calculator Desktop 12-Digit',
'Stamp Pad Ink Red','Bookends Metal Heavy-Duty Pair','Page Protectors Clear 200-Pack','Marker Permanent Black 36-Pack','Notebook Spiral College 10-Pack',
'Cork Board 24x18 with Frame','Pen Cup Mesh Desktop Black','Ruler Aluminum 18"','Mouse Pad Extended 35x16','Wrist Rest Keyboard Gel',
'Executive Mesh Office Chair','Standing Desk Electric 60x30','Conference Table Oval 8ft','Bookshelf 5-Tier Walnut','Filing Pedestal Mobile 3-Drawer',
'Reception Desk L-Shaped','Guest Chair Stackable Fabric','Credenza Modern 60" Oak','Corner Desk with Hutch','Task Chair Ergonomic Lumbar',
'Round Meeting Table 42"','Lateral File Cabinet 2-Drawer','Coat Rack Freestanding Wood','Side Table Modern 24x24','Storage Cabinet Locking 72"',
'Drafting Stool Adjustable','Training Table Folding 72"','Privacy Screen Desktop 48"','Monitor Riser Walnut','Under-Desk Keyboard Tray',
'Executive Desk 72x36 Mahogany','Whiteboard Stand Mobile 48x36','Lounge Chair Modern Leather','Coffee Table Round 36" Glass','Desk Return 48x24',
'Adjustable Footrest Ergonomic','Wall-Mount Shelf 48"','Cubicle Panel 66" Fabric','Desk Lamp Architect Arm','Plant Stand 3-Tier Metal',
'Breakroom Table Round 36"','Stacking Chair Polypropylene','TV Stand Mobile 65" Cart','Lectern Adjustable Height','Bench Entryway Storage 48"',
'Sit-Stand Stool Active','End Table Drawer 18x18','Coat Hook Wall Mount 5-Hook','Desk Grommet Cable 2-Pack','Acoustic Panel 24x48 Charcoal',
'Sofa Office 2-Seat Gray','Desk Partition Frosted 24x18','Pedestal Fan 16" Oscillating','Floor Mat Chair 46x60','Magazine Rack Wall Mount',
'Wardrobe Locker Single','Step Stool 2-Step Folding','Corner Shelf Unit 5-Tier','Whiteboard Cabinet 48x36','Desk Bridge Connector 48"',
'Chef Knife Set 15-Piece Block','Non-Stick Frying Pan 12"','Stainless Steel Mixing Bowls 5-Set','Digital Kitchen Scale 22lb','Silicone Spatula Set 6-Piece',
'Cast Iron Dutch Oven 6qt','Bamboo Cutting Board XL','Electric Kettle 1.7L Glass','Colander Stainless 5qt','Measuring Cup Set 7-Piece',
'Food Storage Container Set 24-Pc','Blender Professional 64oz','Toaster 4-Slice Wide Slot','Coffee Maker 12-Cup Programmable','Stand Mixer 5qt 10-Speed',
'Baking Sheet Set 3-Piece','Rolling Pin Marble 18"','Whisk Set Stainless 3-Piece','Ice Cream Scoop Spring-Loaded','Pizza Stone 16" Round',
'Cheese Grater 4-Sided Box','Potato Masher Stainless','Tongs Set 9" and 12"','Ladle Stainless 6oz','Can Opener Manual Heavy-Duty',
'Vegetable Peeler Swivel 3-Pack','Meat Thermometer Digital Instant','Egg Timer Digital Magnetic','Tea Infuser Ball Stainless','Citrus Juicer Manual',
'Bread Knife Serrated 10"','Wok Carbon Steel 14"','Steamer Basket Stainless 9"','Cake Pan Round 9" 2-Pack','Muffin Tin 12-Cup Non-Stick',
'Pie Dish Ceramic 9"','Cookie Sheet Air Insulated','Cooling Rack Stackable 2-Pack','Pastry Brush Silicone 2-Pack','Kitchen Timer Dual Digital',
'Garlic Press Heavy-Duty','Corkscrew Double-Hinged','Pepper Mill Wooden 8"','Salt Cellar Bamboo Lid','Spice Rack Rotating 20-Jar',
'Paper Towel Holder Counter','Dish Rack 2-Tier Stainless','Sponge Holder Sink Caddy','Compost Bin Counter 1.3gal','Utensil Crock Ceramic White',
'Oxford Button-Down Shirt Blue','Slim Fit Chinos Khaki','Merino Wool V-Neck Sweater','Classic Polo Shirt Navy','Stretch Dress Pants Charcoal',
'Denim Jacket Trucker Medium','Performance T-Shirt Moisture-Wick','Fleece Quarter-Zip Pullover','Linen Blazer Summer Tan','Cargo Shorts Relaxed Olive',
'Flannel Shirt Plaid Red','Athletic Joggers Tapered Black','Cashmere Scarf Heather Gray','Leather Belt Reversible 34"','Wool Peacoat Double-Breasted',
'Rain Jacket Packable Blue','Thermal Henley Long-Sleeve','Corduroy Pants Straight Brown','Chambray Shirt Casual Fit','Down Vest Lightweight Navy',
'Board Shorts Quick-Dry 9"','Dress Shirt French Cuff White','Windbreaker Half-Zip','Cable Knit Sweater Cream','Tech Pants 5-Pocket Gray',
'Bomber Jacket Nylon Green','Compression Shirt Base Layer','Tweed Sport Coat Classic','Swimsuit Trunk Solid Navy','Hoodie Zip-Up Heather Gray',
'Turtleneck Fine-Gauge Black','Hiking Pants Convertible','Graphic Tee Vintage Logo','Suit Jacket Slim Fit Navy','Parka Insulated Winter Black',
'Rugby Shirt Striped','Track Pants Side-Stripe','Overcoat Wool-Blend Camel','Denim Shirt Western Snap','Softshell Jacket Waterproof',
'Cardigan Button-Front Charcoal','Linen Pants Drawstring White','Performance Polo Quick-Dry','Varsity Jacket Letterman','Thermal Pants Base Layer',
'Safari Jacket Multi-Pocket','Hawaiian Shirt Floral','Vest Quilted Field Green','Driving Gloves Leather Brown','Beanie Ribbed Knit Charcoal',
'Running Shoes Lightweight 10.5','Yoga Mat Premium 6mm Purple','Resistance Band Set 5-Level','Adjustable Dumbbell 52.5lb Pair','Jump Rope Speed Bearing',
'Foam Roller High-Density 36"','Kettlebell Cast Iron 35lb','Pull-Up Bar Doorway','Exercise Ball 65cm Anti-Burst','Boxing Gloves 14oz Leather',
'Tennis Racket Carbon Fiber','Basketball Indoor/Outdoor Size 7','Soccer Ball FIFA Official Size 5','Golf Club Set 12-Piece','Baseball Glove 12.5" Leather',
'Swimming Goggles Anti-Fog','Cycling Helmet Road Large','Ski Goggles UV Protection','Badminton Racket 2-Pack','Table Tennis Paddle Pro Set',
'Lacrosse Stick Complete','Hockey Stick Composite 60"','Volleyball Indoor Official','Cricket Bat English Willow','Archery Target Bag 26"',
'Weight Bench Adjustable FID','Barbell Olympic 7ft 45lb','Weight Plates Rubber 45lb Pair','Squat Rack Folding Wall-Mount','Ab Roller Wheel Double',
'Battle Rope 30ft 1.5"','Medicine Ball Rubber 15lb','Agility Ladder 20ft','Cone Set Training 50-Pack','Speed Parachute Running',
'Grip Strengthener Set 3-Pack','Ankle Weights 5lb Pair','Stability Ball Chair Base','Stretch Strap Yoga 10-Loop','Massage Gun Percussion Deep',
'Heart Rate Monitor Chest Strap','GPS Sports Watch Multi-Sport','Bike Computer Wireless','Swim Cap Silicone 2-Pack','Water Bottle Insulated 32oz',
'Gym Bag Duffel 40L','Sweatband Headband 6-Pack','Athletic Tape 1.5" 6-Roll','Compression Sleeve Calf Pair','Sports Sunglasses Polarized',
'Garden Hose Expandable 100ft','Pruning Shears Bypass Titanium','Raised Garden Bed 4x8 Cedar','Wheelbarrow Steel 6 Cubic Ft','Sprinkler Oscillating Brass',
'Potting Soil Premium 40qt','Garden Gloves Thorn-Proof','Seed Starting Kit 72-Cell','Lawn Mower Push 22"','Hedge Trimmer Electric 24"',
'Plant Labels Bamboo 100-Pack','Watering Can Galvanized 2gal','Garden Kneeler Pad Foam','Trowel Stainless Steel','Cultivator 3-Prong Hand',
'Fertilizer All-Purpose 10lb','Compost Bin Tumbling 43gal','Garden Fork Steel 4-Tine','Leaf Rake Adjustable 30"','Edging Border 20ft',
'Planter Pot Ceramic 12"','Hanging Basket Coconut Liner','Plant Stand Indoor 3-Tier','Garden Hose Reel Wall-Mount','Soaker Hose 50ft',
'Weed Barrier Fabric 4x100ft','Mulch Cedar Red 2 Cubic Ft','Topsoil Screened 40lb','Bird Feeder Cedar House','Birdbath Pedestal Concrete',
'Rain Gauge Clear 5"','Thermometer Outdoor Wireless','Solar Path Lights 10-Pack','Garden Statue Gnome 12"','Wind Chime Bamboo 36"',
'Greenhouse Mini 4-Tier','Cold Frame Double-Wall','Drip Irrigation Kit 100ft','Timer Hose Digital 2-Zone','Pest Control Neem Oil 32oz',
'Insect Net Garden 10x12','Tomato Cage Heavy-Duty 5-Pack','Plant Support Stakes 4ft 20-Pack','Seed Storage Box Organizer','Soil Test Kit Digital pH',
'Pressure Washer 2100 PSI','Garden Cart Dump 10 Cubic Ft','Chainsaw Electric 16"','Leaf Blower Cordless 20V','String Trimmer 15" Dual-Line',
'Floor Mats All-Weather 4-Piece','Car Cover Waterproof XL','Dash Cam Dual 4K Front+Rear','Jump Starter Portable 2000A','Tire Inflator Digital 12V',
'Car Vacuum Cordless Handheld','Phone Mount Magnetic Vent','Seat Cover Set Leather 2-Pack','Steering Wheel Cover Leather','Sun Shade Windshield Foldable',
'Trunk Organizer Collapsible','Emergency Kit Roadside 120-Pc','OBD2 Scanner Bluetooth Pro','Battery Charger Smart 12V','Wiper Blades Premium 24" Pair',
'Car Wash Kit Complete 10-Piece','Polishing Machine Dual-Action','Clay Bar Kit Detailing','Tire Pressure Gauge Digital','Lug Wrench Telescoping Cross',
'Jack Stand 3-Ton Pair','Creeper Mechanic Padded 40"','Tool Set Mechanic 200-Piece','Oil Drain Pan 16qt','Funnel Set Flexible 4-Piece',
'Air Freshener Vent Clip 6-Pack','LED Headlight Bulb H11 Pair','Fog Light Kit Yellow 3000K','License Plate Frame 2-Pack','Cargo Net Trunk Elastic',
'Roof Rack Cross Bars Universal','Bike Rack Hitch 4-Bike','Trailer Hitch Ball 2"','Tow Strap 30ft 30000lb','Recovery Board Traction 2-Pack',
'Blind Spot Mirror Pair','Backup Camera Wireless HD','Parking Sensor Kit 8-Sensor','Paint Touch-Up Kit Universal','Scratch Remover Compound',
'Interior Cleaner All-Surface','Leather Conditioner 16oz','Glass Cleaner Streak-Free 32oz','Tire Shine Gel Long-Lasting','Microfiber Towels 24-Pack',
'Ice Scraper Snow Brush 36"','Antifreeze Coolant 1gal','Transmission Fluid ATF 1qt','Brake Fluid DOT 4 12oz','Engine Oil Synthetic 5W-30 5qt',
'Vitamin D3 5000 IU 360-Cap','Protein Powder Whey 5lb Vanilla','Multivitamin Complete Daily','Omega-3 Fish Oil 1000mg 120-Soft','Probiotic 50 Billion CFU 60-Cap',
'Collagen Peptides Powder 20oz','Magnesium Glycinate 400mg','Zinc Picolinate 50mg 120-Cap','Vitamin C 1000mg 250-Tab','B-Complex Super 100-Cap',
'Sunscreen SPF 50 Face 3oz','Moisturizer Daily SPF 30','Face Wash Gentle Cleanser 8oz','Retinol Serum 2.5% 1oz','Hyaluronic Acid Serum 2oz',
'Eye Cream Anti-Aging 0.5oz','Lip Balm SPF 15 3-Pack','Body Lotion Unscented 16oz','Hand Cream Intensive 3oz','Foot Cream Repair 4oz',
'Shampoo Volumizing 16oz','Conditioner Hydrating 16oz','Hair Oil Argan 4oz','Hair Mask Deep Repair 8oz','Dry Shampoo Spray 7oz',
'Toothbrush Electric Sonic','Toothpaste Whitening 2-Pack','Dental Floss Mint 6-Pack','Mouthwash Antiseptic 1.5L','Tongue Scraper Stainless',
'Deodorant Natural 3-Pack','Razor Safety Double-Edge','Shaving Cream Sensitive 6oz','Aftershave Balm 3.4oz','Beard Oil Sandalwood 2oz',
'Nail Clipper Set 3-Piece','Tweezers Precision Slant','Cotton Rounds 100-Pack','Facial Tissue Soft 12-Box','Hand Sanitizer 8oz 3-Pack',
'Heating Pad Electric 12x24','Ice Pack Gel Reusable 2-Pack','Thermometer Forehead Digital','Blood Pressure Monitor Arm','Pulse Oximeter Fingertip',
'First Aid Kit 300-Piece','Bandages Adhesive 100-Pack','Melatonin 5mg Gummies 120','Electrolyte Powder 30-Pack','Essential Oil Set 6-Bottle',
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

List<String> categories = new List<String>{
    'Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics',
    'Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics',
    'Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics',
    'Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics',
    'Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics','Electronics',
    'Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies',
    'Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies',
    'Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies',
    'Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies',
    'Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies','Office Supplies',
    'Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture',
    'Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture',
    'Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture',
    'Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture',
    'Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture','Furniture',
    'Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen',
    'Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen',
    'Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen',
    'Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen',
    'Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen','Kitchen',
    'Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing',
    'Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing',
    'Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing',
    'Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing',
    'Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing','Clothing',
    'Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports',
    'Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports',
    'Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports',
    'Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports',
    'Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports','Sports',
    'Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden',
    'Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden',
    'Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden',
    'Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden',
    'Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden','Garden',
    'Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive',
    'Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive',
    'Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive',
    'Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive',
    'Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive','Automotive',
    'Health','Health','Health','Health','Health','Health','Health','Health','Health','Health',
    'Health','Health','Health','Health','Health','Health','Health','Health','Health','Health',
    'Health','Health','Health','Health','Health','Health','Health','Health','Health','Health',
    'Health','Health','Health','Health','Health','Health','Health','Health','Health','Health',
    'Health','Health','Health','Health','Health','Health','Health','Health','Health','Health',
    'Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets',
    'Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets',
    'Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets',
    'Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets',
    'Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets','Pets'
};

// Price ranges by category
Map<String, Decimal[]> priceRanges = new Map<String, Decimal[]>{
    'Electronics' => new Decimal[]{29.99, 499.99},
    'Office Supplies' => new Decimal[]{4.99, 99.99},
    'Furniture' => new Decimal[]{89.99, 999.99},
    'Kitchen' => new Decimal[]{9.99, 199.99},
    'Clothing' => new Decimal[]{19.99, 299.99},
    'Sports' => new Decimal[]{14.99, 299.99},
    'Garden' => new Decimal[]{9.99, 299.99},
    'Automotive' => new Decimal[]{7.99, 199.99},
    'Health' => new Decimal[]{6.99, 99.99},
    'Pets' => new Decimal[]{8.99, 149.99}
};

// Create products
List<Product2> products = new List<Product2>();
for (Integer i = 0; i < names.size(); i++) {
    String cat = categories[i];
    String prefix = cat.substring(0, 3).toUpperCase();
    Product2 p = new Product2(
        Name = names[i],
        ProductCode = prefix + '-' + String.valueOf(i + 1).leftPad(4, '0'),
        Description = cat + ' — ' + names[i],
        Family = cat,
        IsActive = true
    );
    products.add(p);
}
insert products;
System.debug('Inserted ' + products.size() + ' products');

// Create standard PB entries
Id stdPbId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
List<PricebookEntry> stdEntries = new List<PricebookEntry>();
for (Integer i = 0; i < products.size(); i++) {
    Decimal[] range = priceRanges.get(categories[i]);
    Decimal price = Math.floor(range[0] + (Math.random() * (range[1] - range[0]))) + 0.99;
    stdEntries.add(new PricebookEntry(
        Pricebook2Id = stdPbId,
        Product2Id = products[i].Id,
        UnitPrice = price,
        IsActive = true
    ));
}
// Batch insert
insert new List<PricebookEntry>(new List<PricebookEntry>{stdEntries[0],stdEntries[1],stdEntries[2],stdEntries[3],stdEntries[4],stdEntries[5],stdEntries[6],stdEntries[7],stdEntries[8],stdEntries[9],stdEntries[10],stdEntries[11],stdEntries[12],stdEntries[13],stdEntries[14],stdEntries[15],stdEntries[16],stdEntries[17],stdEntries[18],stdEntries[19],stdEntries[20],stdEntries[21],stdEntries[22],stdEntries[23],stdEntries[24],stdEntries[25],stdEntries[26],stdEntries[27],stdEntries[28],stdEntries[29],stdEntries[30],stdEntries[31],stdEntries[32],stdEntries[33],stdEntries[34],stdEntries[35],stdEntries[36],stdEntries[37],stdEntries[38],stdEntries[39],stdEntries[40],stdEntries[41],stdEntries[42],stdEntries[43],stdEntries[44],stdEntries[45],stdEntries[46],stdEntries[47],stdEntries[48],stdEntries[49],stdEntries[50],stdEntries[51],stdEntries[52],stdEntries[53],stdEntries[54],stdEntries[55],stdEntries[56],stdEntries[57],stdEntries[58],stdEntries[59],stdEntries[60],stdEntries[61],stdEntries[62],stdEntries[63],stdEntries[64],stdEntries[65],stdEntries[66],stdEntries[67],stdEntries[68],stdEntries[69],stdEntries[70],stdEntries[71],stdEntries[72],stdEntries[73],stdEntries[74],stdEntries[75],stdEntries[76],stdEntries[77],stdEntries[78],stdEntries[79],stdEntries[80],stdEntries[81],stdEntries[82],stdEntries[83],stdEntries[84],stdEntries[85],stdEntries[86],stdEntries[87],stdEntries[88],stdEntries[89],stdEntries[90],stdEntries[91],stdEntries[92],stdEntries[93],stdEntries[94],stdEntries[95],stdEntries[96],stdEntries[97],stdEntries[98],stdEntries[99],stdEntries[100],stdEntries[101],stdEntries[102],stdEntries[103],stdEntries[104],stdEntries[105],stdEntries[106],stdEntries[107],stdEntries[108],stdEntries[109],stdEntries[110],stdEntries[111],stdEntries[112],stdEntries[113],stdEntries[114],stdEntries[115],stdEntries[116],stdEntries[117],stdEntries[118],stdEntries[119],stdEntries[120],stdEntries[121],stdEntries[122],stdEntries[123],stdEntries[124],stdEntries[125],stdEntries[126],stdEntries[127],stdEntries[128],stdEntries[129],stdEntries[130],stdEntries[131],stdEntries[132],stdEntries[133],stdEntries[134],stdEntries[135],stdEntries[136],stdEntries[137],stdEntries[138],stdEntries[139],stdEntries[140],stdEntries[141],stdEntries[142],stdEntries[143],stdEntries[144],stdEntries[145],stdEntries[146],stdEntries[147],stdEntries[148],stdEntries[149],stdEntries[150],stdEntries[151],stdEntries[152],stdEntries[153],stdEntries[154],stdEntries[155],stdEntries[156],stdEntries[157],stdEntries[158],stdEntries[159],stdEntries[160],stdEntries[161],stdEntries[162],stdEntries[163],stdEntries[164],stdEntries[165],stdEntries[166],stdEntries[167],stdEntries[168],stdEntries[169],stdEntries[170],stdEntries[171],stdEntries[172],stdEntries[173],stdEntries[174],stdEntries[175],stdEntries[176],stdEntries[177],stdEntries[178],stdEntries[179],stdEntries[180],stdEntries[181],stdEntries[182],stdEntries[183],stdEntries[184],stdEntries[185],stdEntries[186],stdEntries[187],stdEntries[188],stdEntries[189],stdEntries[190],stdEntries[191],stdEntries[192],stdEntries[193],stdEntries[194],stdEntries[195],stdEntries[196],stdEntries[197],stdEntries[198],stdEntries[199]});
System.debug('Inserted standard PB entries batch 1');

List<PricebookEntry> batch2 = new List<PricebookEntry>();
for (Integer i = 200; i < stdEntries.size(); i++) { batch2.add(stdEntries[i]); }
insert batch2;
System.debug('Inserted standard PB entries batch 2');

// Custom pricebook
Pricebook2 catalog = new Pricebook2(Name = 'Product Catalog 2026', Description = '2026 Full Product Catalog — 500 products across 10 categories', IsActive = true);
insert catalog;

List<PricebookEntry> catEntries = new List<PricebookEntry>();
for (Integer i = 0; i < products.size(); i++) {
    catEntries.add(new PricebookEntry(
        Pricebook2Id = catalog.Id,
        Product2Id = products[i].Id,
        UnitPrice = stdEntries[i].UnitPrice,
        IsActive = true
    ));
}
List<PricebookEntry> cb1 = new List<PricebookEntry>();
for (Integer i = 0; i < 200; i++) { cb1.add(catEntries[i]); }
insert cb1;
List<PricebookEntry> cb2 = new List<PricebookEntry>();
for (Integer i = 200; i < catEntries.size(); i++) { cb2.add(catEntries[i]); }
insert cb2;

System.debug('DONE: ' + products.size() + ' products, pricebook "Product Catalog 2026", ' + stdEntries.size() + ' std entries, ' + catEntries.size() + ' catalog entries');
System.debug('Now run step2 and step3 to create images.');
