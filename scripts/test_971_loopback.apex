String fileId = '069dL000000test'; // Dummy ID
String endpoint = 'callout:DocGen_Loopback/services/data/v63.0/connect/files/' + fileId + '/rendition?type=PDF';
HttpRequest req = new HttpRequest();
req.setEndpoint(endpoint);
req.setMethod('GET');
Http h = new Http();
HttpResponse res = h.send(req);
System.debug('Status Code: ' + res.getStatusCode());
System.debug('Body: ' + res.getBody());
