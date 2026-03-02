public without sharing class DocGenSignatureService {

    public class SignatureException extends Exception {}

    /**
     * Injects a Base64 PNG image into an existing DOCX ContentVersion and returns the Blob without inserting to DB.
     * This is used by the Hybrid Flow to get stamped content for client-side PDF rendering.
     */
    public static Blob stampSignatureToBlob(Id sourceCvId, String base64Image, String requestNumber) {
        ContentVersion cv = [SELECT Id, VersionData, Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) {
            throw new SignatureException('Source document not found or has no content.');
        }

        Blob docxBlob = cv.VersionData;
        Blob signatureBlob = EncodingUtil.base64Decode(base64Image);
        
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        String imageRelId = 'rIdSig' + String.valueOf(System.currentTimeMillis()).substring(8);
        String imageFileName = 'signature_' + imageRelId + '.png';

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            
            if (name == '[Content_Types].xml') {
                String contentTypes = reader.extract(name).toString();
                if (!contentTypes.contains('Extension="png"')) {
                    contentTypes = contentTypes.replace('</Types>', '<Default Extension="png" ContentType="image/png"/></Types>');
                }
                writer.addEntry(name, Blob.valueOf(contentTypes));

            } else if (name == 'word/_rels/document.xml.rels') {
                String rels = reader.extract(name).toString();
                String newRel = '<Relationship Id="' + imageRelId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + imageFileName + '"/>';
                rels = rels.replace('</Relationships>', newRel + '</Relationships>');
                writer.addEntry(name, Blob.valueOf(rels));

            } else if (name == 'word/document.xml') {
                String docXml = reader.extract(name).toString();
                String drawingXml = 
                    '<w:r><w:drawing>' +
                      '<wp:inline distT="0" distB="0" distL="0" distR="0">' +
                        '<wp:extent cx="1905000" cy="476250"/>' +
                        '<wp:effectExtent l="0" t="0" r="0" b="0"/>' +
                        '<wp:docPr id="888" name="Signature"/>' +
                        '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>' +
                        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                          '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                              '<pic:nvPicPr><pic:cNvPr id="0" name="Signature"/><pic:cNvPicPr/></pic:nvPicPr>' +
                              '<pic:blipFill>' +
                                '<a:blip r:embed="' + imageRelId + '"/>' +
                                '<a:stretch><a:fillRect/></a:stretch>' +
                              '</pic:blipFill>' +
                              '<pic:spPr>' +
                                '<a:xfrm><a:off x="0" y="0"/><a:ext cx="1905000" cy="476250"/></a:xfrm>' +
                                '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                              '</pic:spPr>' +
                            '</pic:pic>' +
                          '</a:graphicData>' +
                        '</a:graphic>' +
                      '</wp:inline>' +
                    '</w:drawing></w:r>';

                if (docXml.contains('{#Signature}')) {
                    docXml = docXml.replace('{#Signature}', '</w:t></w:r>' + drawingXml + '<w:r><w:t xml:space="preserve">');
                } else {
                    docXml = docXml.replace('</w:body>', '<w:p><w:r><w:t xml:space="preserve">Signature: </w:t></w:r>' + drawingXml + '</w:p></w:body>');
                }
                writer.addEntry(name, Blob.valueOf(docXml));
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        writer.addEntry('word/media/' + imageFileName, signatureBlob);
        return writer.getArchive();
    }

    /**
     * Data wrapper for multi-signer stamping.
     */
    public class SignerData {
        public String roleName;
        public String base64Image;
        public SignerData(String roleName, String base64Image) {
            this.roleName = roleName;
            this.base64Image = base64Image;
        }
    }

    /**
     * Stamps ALL signer signatures into a DOCX at their named placeholders.
     * Each signer's role maps to {#Signature_RoleName} in the document.
     * Falls back to legacy {#Signature} for single signer with blank role.
     */
    public static Blob stampAllSignaturesToBlob(Id sourceCvId, List<SignerData> signers) {
        ContentVersion cv = [SELECT Id, VersionData, Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) {
            throw new SignatureException('Source document not found or has no content.');
        }

        Blob docxBlob = cv.VersionData;
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        // Build per-signer metadata: relationship IDs, file names, blobs
        List<Map<String, String>> signerMeta = new List<Map<String, String>>();
        List<Blob> signerBlobs = new List<Blob>();
        Integer docPrIdBase = 888;

        for (Integer i = 0; i < signers.size(); i++) {
            SignerData sd = signers[i];
            String relId = 'rIdSig' + String.valueOf(i) + String.valueOf(System.currentTimeMillis()).right(5);
            String fileName = 'signature_' + relId + '.png';
            // Build placeholder tag: blank role → {#Signature}, otherwise {#Signature_RoleName}
            String placeholder;
            if (String.isBlank(sd.roleName)) {
                placeholder = '{#Signature}';
            } else {
                placeholder = '{#Signature_' + sd.roleName.replaceAll(' ', '_') + '}';
            }
            Map<String, String> meta = new Map<String, String>{
                'relId' => relId,
                'fileName' => fileName,
                'placeholder' => placeholder,
                'docPrId' => String.valueOf(docPrIdBase + i)
            };
            signerMeta.add(meta);
            signerBlobs.add(EncodingUtil.base64Decode(sd.base64Image));
        }

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();

            if (name == '[Content_Types].xml') {
                String contentTypes = reader.extract(name).toString();
                if (!contentTypes.contains('Extension="png"')) {
                    contentTypes = contentTypes.replace('</Types>', '<Default Extension="png" ContentType="image/png"/></Types>');
                }
                writer.addEntry(name, Blob.valueOf(contentTypes));

            } else if (name == 'word/_rels/document.xml.rels') {
                String rels = reader.extract(name).toString();
                for (Map<String, String> meta : signerMeta) {
                    String newRel = '<Relationship Id="' + meta.get('relId') + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + meta.get('fileName') + '"/>';
                    rels = rels.replace('</Relationships>', newRel + '</Relationships>');
                }
                writer.addEntry(name, Blob.valueOf(rels));

            } else if (name == 'word/document.xml') {
                String docXml = reader.extract(name).toString();

                for (Map<String, String> meta : signerMeta) {
                    String drawingXml =
                        '<w:r><w:drawing>' +
                          '<wp:inline distT="0" distB="0" distL="0" distR="0">' +
                            '<wp:extent cx="1905000" cy="476250"/>' +
                            '<wp:effectExtent l="0" t="0" r="0" b="0"/>' +
                            '<wp:docPr id="' + meta.get('docPrId') + '" name="Signature"/>' +
                            '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>' +
                            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                              '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                                  '<pic:nvPicPr><pic:cNvPr id="0" name="Signature"/><pic:cNvPicPr/></pic:nvPicPr>' +
                                  '<pic:blipFill>' +
                                    '<a:blip r:embed="' + meta.get('relId') + '"/>' +
                                    '<a:stretch><a:fillRect/></a:stretch>' +
                                  '</pic:blipFill>' +
                                  '<pic:spPr>' +
                                    '<a:xfrm><a:off x="0" y="0"/><a:ext cx="1905000" cy="476250"/></a:xfrm>' +
                                    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                                  '</pic:spPr>' +
                                '</pic:pic>' +
                              '</a:graphicData>' +
                            '</a:graphic>' +
                          '</wp:inline>' +
                        '</w:drawing></w:r>';

                    String placeholder = meta.get('placeholder');
                    if (docXml.contains(placeholder)) {
                        docXml = docXml.replace(placeholder, '</w:t></w:r>' + drawingXml + '<w:r><w:t xml:space="preserve">');
                    } else {
                        // Append at end of document as fallback
                        docXml = docXml.replace('</w:body>', '<w:p><w:r><w:t xml:space="preserve">' + placeholder.substringBetween('{#', '}') + ': </w:t></w:r>' + drawingXml + '</w:p></w:body>');
                    }
                }
                writer.addEntry(name, Blob.valueOf(docXml));
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        // Add all signature images
        for (Integer i = 0; i < signerMeta.size(); i++) {
            writer.addEntry('word/media/' + signerMeta[i].get('fileName'), signerBlobs[i]);
        }

        return writer.getArchive();
    }

    /**
     * Stamping legacy entry point - inserts the DOCX to DB and returns ID.
     */
    public static Id stampSignature(Id sourceCvId, String base64Image, String requestNumber, String relatedRecordId) {
        ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        Blob resultBlob = stampSignatureToBlob(sourceCvId, base64Image, requestNumber);

        ContentVersion newCv = new ContentVersion();
        newCv.Title = source.Title + ' - Signed';
        newCv.PathOnClient = newCv.Title + '.docx';
        newCv.VersionData = resultBlob;
        newCv.IsMajorVersion = true;
        SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ newCv });
        insert cvDecision.getRecords();
        Id savedCvId = cvDecision.getRecords()[0].Id;

        Id newDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH SYSTEM_MODE].ContentDocumentId;

        if (String.isNotBlank(relatedRecordId)) {
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = newDocId;
            cdl.LinkedEntityId = relatedRecordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            SObjectAccessDecision cdlDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{ cdl });
            insert cdlDecision.getRecords();
        }

        return savedCvId;
    }

    /**
     * @description Privileged entry point called by the Platform Event trigger or legacy actions.
     */
    public static void handleSignatureSubmission(String token, String base64Image) {
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Source_Document_Id__c, Related_Record_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            return; 
        }

        DocGen_Signature_Request__c req = requests[0];

        try {
            // 1. Inject the Signature into the DOCX and SAVE to Record (Old Path)
            Id signedCvId = stampSignature(req.Source_Document_Id__c, base64Image, req.Id, req.Related_Record_Id__c);

            // 2. Mark audit trail
            DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
            audit.Signature_Request__c = req.Id;
            audit.Signed_Date__c = System.now();
            audit.Document_Hash_SHA256__c = 'PENDING_RENDITION:' + signedCvId;
            audit.IP_Address__c = 'Captured via Async Path'; 
            audit.User_Agent__c = 'System Handler';
            insert audit;

            // 3. Mark Request as Signed
            req.Status__c = 'Signed';
            update req;

            // 4. Trigger PDF Rendition (requires external credential access)
            DocGenRenditionService.addPendingRendition(signedCvId, req.Related_Record_Id__c);
            DocGenRenditionService.enqueueRenditions();

        } catch (Exception e) {
            System.debug('DocGen: Error in signature handling: ' + e.getMessage());
        }
    }
}