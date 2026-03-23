// PDF Merger Test — Account with 12 Contacts
System.debug('=== PDF Merger Test Data ===');

Account acc = new Account(
    Name = 'Meridian Dynamics',
    Industry = 'Technology',
    Phone = '(512) 555-9000',
    Website = 'www.meridiandynamics.com',
    BillingStreet = '1200 Congress Ave',
    BillingCity = 'Austin',
    BillingState = 'TX',
    BillingPostalCode = '78701',
    NumberOfEmployees = 250,
    AnnualRevenue = 45000000,
    Description = 'Enterprise software company specializing in logistics and supply chain optimization.'
);
insert acc;

List<Contact> contacts = new List<Contact>{
    new Contact(AccountId=acc.Id, FirstName='Marcus',  LastName='Whitfield',  Title='CEO',                    Email='marcus.whitfield@meridiandynamics.com',  Phone='(512) 555-9001'),
    new Contact(AccountId=acc.Id, FirstName='Elena',   LastName='Vasquez',    Title='CFO',                    Email='elena.vasquez@meridiandynamics.com',     Phone='(512) 555-9002'),
    new Contact(AccountId=acc.Id, FirstName='Jordan',  LastName='Nakamura',   Title='VP Engineering',         Email='jordan.nakamura@meridiandynamics.com',   Phone='(512) 555-9003'),
    new Contact(AccountId=acc.Id, FirstName='Priya',   LastName='Sharma',     Title='Director of Product',    Email='priya.sharma@meridiandynamics.com',      Phone='(512) 555-9004'),
    new Contact(AccountId=acc.Id, FirstName='Tobias',  LastName='Lindgren',   Title='Head of Sales',          Email='tobias.lindgren@meridiandynamics.com',   Phone='(512) 555-9005'),
    new Contact(AccountId=acc.Id, FirstName='Camille', LastName='Dubois',     Title='Marketing Director',     Email='camille.dubois@meridiandynamics.com',    Phone='(512) 555-9006'),
    new Contact(AccountId=acc.Id, FirstName='Rashid',  LastName='Al-Farsi',   Title='Solutions Architect',    Email='rashid.alfarsi@meridiandynamics.com',    Phone='(512) 555-9007'),
    new Contact(AccountId=acc.Id, FirstName='Sienna',  LastName='O\'Malley',  Title='Customer Success Lead',  Email='sienna.omalley@meridiandynamics.com',    Phone='(512) 555-9008'),
    new Contact(AccountId=acc.Id, FirstName='Dmitri',  LastName='Volkov',     Title='Data Science Manager',   Email='dmitri.volkov@meridiandynamics.com',     Phone='(512) 555-9009'),
    new Contact(AccountId=acc.Id, FirstName='Aisha',   LastName='Mensah',     Title='Legal Counsel',          Email='aisha.mensah@meridiandynamics.com',      Phone='(512) 555-9010'),
    new Contact(AccountId=acc.Id, FirstName='Liam',    LastName='Carruthers', Title='DevOps Lead',            Email='liam.carruthers@meridiandynamics.com',   Phone='(512) 555-9011'),
    new Contact(AccountId=acc.Id, FirstName='Yuki',    LastName='Tanaka',     Title='UX Design Director',     Email='yuki.tanaka@meridiandynamics.com',       Phone='(512) 555-9012')
};
insert contacts;

System.debug('');
System.debug('=== TEST DATA READY ===');
System.debug('Account:  ' + acc.Id + ' (' + acc.Name + ')');
System.debug('Contacts: ' + contacts.size());
System.debug('');
for (Contact c : contacts) {
    System.debug('  ' + c.FirstName + ' ' + c.LastName + ' — ' + c.Title);
}
