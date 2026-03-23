import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplatesForObject from '@salesforce/apex/DocGenController.getTemplatesForObject';
import processAndReturnDocument from '@salesforce/apex/DocGenController.processAndReturnDocument';
import generateDocumentParts from '@salesforce/apex/DocGenController.generateDocumentParts';
import getContentVersionBase64 from '@salesforce/apex/DocGenController.getContentVersionBase64';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import saveGeneratedDocument from '@salesforce/apex/DocGenController.saveGeneratedDocument';
import getRecordPdfs from '@salesforce/apex/DocGenController.getRecordPdfs';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getChildRecordPdfs from '@salesforce/apex/DocGenController.getChildRecordPdfs';
import { buildDocx } from './docGenZipWriter';
import { mergePdfs } from './docGenPdfMerger';

export default class DocGenRunner extends LightningElement {
    @api recordId;
    @api objectApiName;

    @track templateOptions = [];
    @track selectedTemplateId;
    @track outputMode = 'download';
    @track templateOutputFormat = 'Document';
    @track appMode = 'generate';

    // PDF Merge state
    @track mergeEnabled = false;
    @track recordPdfOptions = [];
    @track selectedPdfCvIds = [];
    @track mergeOnlyCvIds = [];

    // Packet mode state
    @track packetTemplateIds = [];
    @track packetIncludeExisting = false;
    @track packetExistingPdfIds = [];

    // Merge Children mode state
    @track childRelOptions = [];
    @track selectedChildRel = null;
    @track childFilterClause = '';
    @track childRecordGroups = [];
    @track selectedChildPdfCvIds = [];
    @track childPdfsLoaded = false;

    isLoading = false;
    error;
    _templateData = [];

    // --- Mode getters ---

    get modeOptions() {
        return [
            { label: 'Generate', value: 'generate' },
            { label: 'Document Packet', value: 'packet' },
            { label: 'Merge PDFs', value: 'mergeOnly' },
            { label: 'Child Record PDFs', value: 'mergeChildren' }
        ];
    }

    get isGenerateMode() {
        return this.appMode === 'generate';
    }

    get isPacketMode() {
        return this.appMode === 'packet';
    }

    get isMergeOnlyMode() {
        return this.appMode === 'mergeOnly';
    }

    get isMergeChildrenMode() {
        return this.appMode === 'mergeChildren';
    }

    /** PDF templates available for packet mode */
    get pdfTemplateOptions() {
        return this._templateData
            .filter(t => t.Output_Format__c === 'PDF')
            .map(t => ({ label: t.Name, value: t.Id }));
    }

    get packetButtonLabel() {
        const count = this.packetTemplateIds.length + (this.packetIncludeExisting ? this.packetExistingPdfIds.length : 0);
        return count > 0 ? 'Generate Packet (' + count + ' docs)' : 'Generate Packet';
    }

    get isPacketDisabled() {
        return this.packetTemplateIds.length < 1 || this.isLoading;
    }

    get outputOptions() {
        const formatLabel = this.templateOutputFormat || 'Document';
        const options = [
            { label: `Download ${formatLabel}`, value: 'download' },
            { label: `Save to Record`, value: 'save' }
        ];
        return options;
    }

    get mergeOnlyOutputOptions() {
        return [
            { label: 'Download PDF', value: 'download' },
            { label: 'Save to Record', value: 'save' }
        ];
    }

    /** Show merge option only for PDF output templates */
    get showMergeOption() {
        return this.templateOutputFormat === 'PDF';
    }

    get hasRecordPdfs() {
        return this.recordPdfOptions.length > 0;
    }

    get generateButtonLabel() {
        if (this.mergeEnabled && this.selectedPdfCvIds.length > 0) {
            return 'Generate & Merge (' + (this.selectedPdfCvIds.length + 1) + ' PDFs)';
        }
        return 'Generate Document';
    }

    get mergeOnlyButtonLabel() {
        const count = this.mergeOnlyCvIds.length;
        return count > 0 ? 'Merge ' + count + ' PDFs' : 'Merge PDFs';
    }

    get isMergeOnlyDisabled() {
        return this.mergeOnlyCvIds.length < 2 || this.isLoading;
    }

    @wire(getTemplatesForObject, { objectApiName: '$objectApiName' })
    wiredTemplates({ error, data }) {
        if (data) {
            this._templateData = data;
            this.templateOptions = data.map(t => ({
                label: t.Name + (t.Is_Default__c ? ' ★' : ''),
                value: t.Id
            }));
            this.error = undefined;

            // Auto-select default template (first with Is_Default__c = true)
            if (!this.selectedTemplateId) {
                const defaultTemplate = data.find(t => t.Is_Default__c);
                if (defaultTemplate) {
                    this.selectedTemplateId = defaultTemplate.Id;
                    this.templateOutputFormat = defaultTemplate.Output_Format__c || 'Document';
                }
            }
        } else if (error) {
            this.error = 'Error fetching templates: ' + (error.body ? error.body.message : error.message);
            this.templateOptions = [];
        }
    }

    handleTemplateChange(event) {
        this.selectedTemplateId = event.detail.value;
        this.error = null;
        const selected = this._templateData.find(t => t.Id === this.selectedTemplateId);
        if (selected) {
            this.templateOutputFormat = selected.Output_Format__c || 'Document';
            // Reset to download if save isn't available for this format
            if (this.templateOutputFormat !== 'PDF' && this.outputMode === 'save') {
                this.outputMode = 'download';
            }
            // Reset merge state when switching templates
            if (this.templateOutputFormat !== 'PDF') {
                this.mergeEnabled = false;
                this.selectedPdfCvIds = [];
            }
        }
    }

    handleModeChange(event) {
        this.appMode = event.detail.value;
        this.error = null;
        if ((this.appMode === 'mergeOnly' || this.appMode === 'packet') && this.recordPdfOptions.length === 0) {
            this._loadRecordPdfs();
        }
        if (this.appMode === 'mergeChildren' && this.childRelOptions.length === 0) {
            this._loadChildRelationships();
        }
    }

    handlePacketTemplateSelection(event) {
        this.packetTemplateIds = event.detail.value;
    }

    handlePacketIncludeToggle(event) {
        this.packetIncludeExisting = event.target.checked;
        if (this.packetIncludeExisting && this.recordPdfOptions.length === 0) {
            this._loadRecordPdfs();
        }
    }

    handlePacketPdfSelection(event) {
        this.packetExistingPdfIds = event.detail.value;
    }

    handleOutputModeChange(event) {
        this.outputMode = event.detail.value;
    }

    handleMergeOnlySelection(event) {
        this.mergeOnlyCvIds = event.detail.value;
    }

    handleMergeToggle(event) {
        this.mergeEnabled = event.target.checked;
        if (this.mergeEnabled && this.recordPdfOptions.length === 0) {
            this._loadRecordPdfs();
        }
    }

    handlePdfSelection(event) {
        this.selectedPdfCvIds = event.detail.value;
    }

    async _loadRecordPdfs() {
        try {
            const pdfs = await getRecordPdfs({ recordId: this.recordId });
            this.recordPdfOptions = pdfs.map(p => ({
                label: p.label,
                value: p.value
            }));
        } catch (e) {
            console.warn('DocGen: Failed to load record PDFs', e);
            this.recordPdfOptions = [];
        }
    }

    // --- Merge Children mode ---

    async _loadChildRelationships() {
        try {
            const rels = await getChildRelationships({ objectName: this.objectApiName });
            this.childRelOptions = rels.map(r => ({
                label: r.label,
                value: r.value,
                childObjectApiName: r.childObjectApiName,
                lookupField: r.lookupField
            }));
        } catch (e) {
            console.warn('DocGen: Failed to load child relationships', e);
            this.childRelOptions = [];
        }
    }

    get childRelComboboxOptions() {
        return this.childRelOptions.map(r => ({ label: r.label, value: r.value }));
    }

    handleChildRelChange(event) {
        const relName = event.detail.value;
        this.selectedChildRel = this.childRelOptions.find(r => r.value === relName);
        this.childRecordGroups = [];
        this.selectedChildPdfCvIds = [];
        this.childPdfsLoaded = false;
    }

    handleChildFilterChange(event) {
        this.childFilterClause = event.target.value;
    }

    async handleLoadChildPdfs() {
        if (!this.selectedChildRel) return;
        this.isLoading = true;
        this.error = null;
        try {
            const groups = await getChildRecordPdfs({
                parentRecordId: this.recordId,
                childObject: this.selectedChildRel.childObjectApiName,
                lookupField: this.selectedChildRel.lookupField,
                filterClause: this.childFilterClause || ''
            });
            this.childRecordGroups = groups.map(g => ({
                ...g,
                pdfs: g.pdfs || []
            }));
            this.childPdfsLoaded = true;
            this.selectedChildPdfCvIds = [];
        } catch (e) {
            let msg = e.body ? e.body.message : e.message;
            this.error = 'Error loading child PDFs: ' + msg;
        } finally {
            this.isLoading = false;
        }
    }

    handleChildPdfCheckbox(event) {
        const cvId = event.target.dataset.cvid;
        const checked = event.target.checked;
        if (checked) {
            this.selectedChildPdfCvIds = [...this.selectedChildPdfCvIds, cvId];
        } else {
            this.selectedChildPdfCvIds = this.selectedChildPdfCvIds.filter(id => id !== cvId);
        }
    }

    handleSelectAllChildPdfs(event) {
        if (event.target.checked) {
            const allCvIds = [];
            for (const group of this.childRecordGroups) {
                for (const pdf of group.pdfs) {
                    allCvIds.push(pdf.value);
                }
            }
            this.selectedChildPdfCvIds = allCvIds;
        } else {
            this.selectedChildPdfCvIds = [];
        }
    }

    get totalChildPdfs() {
        let count = 0;
        for (const g of this.childRecordGroups) count += (g.pdfs || []).length;
        return count;
    }

    get allChildPdfsSelected() {
        return this.totalChildPdfs > 0 && this.selectedChildPdfCvIds.length === this.totalChildPdfs;
    }

    get mergeChildrenButtonLabel() {
        const count = this.selectedChildPdfCvIds.length;
        return count > 0 ? 'Merge ' + count + ' PDFs' : 'Merge Child PDFs';
    }

    get isMergeChildrenDisabled() {
        return this.selectedChildPdfCvIds.length < 1 || this.isLoading;
    }

    get hasChildRecordGroups() {
        return this.childRecordGroups.length > 0;
    }

    get childRecordGroupsWithState() {
        return this.childRecordGroups.map(g => ({
            ...g,
            pdfs: (g.pdfs || []).map(p => ({
                ...p,
                checked: this.selectedChildPdfCvIds.includes(p.value)
            })),
            hasPdfs: (g.pdfs || []).length > 0
        }));
    }

    async mergeChildrenDocument() {
        this.isLoading = true;
        this.error = null;
        try {
            const count = this.selectedChildPdfCvIds.length;
            this.showToast('Info', `Merging ${count} PDFs from child records...`, 'info');

            const pdfBytesArray = [];
            for (const cvId of this.selectedChildPdfCvIds) {
                const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                if (b64) {
                    pdfBytesArray.push(this._base64ToUint8Array(b64));
                }
            }

            if (pdfBytesArray.length < 1) {
                throw new Error('No PDFs could be loaded.');
            }

            let finalBytes;
            if (pdfBytesArray.length === 1) {
                finalBytes = pdfBytesArray[0];
            } else {
                finalBytes = mergePdfs(pdfBytesArray);
            }

            const finalBase64 = this._uint8ArrayToBase64(finalBytes);
            const saveToRecord = this.outputMode === 'save';

            if (saveToRecord) {
                this.showToast('Info', 'Saving merged PDF to record...', 'info');
                await saveGeneratedDocument({
                    recordId: this.recordId,
                    fileName: 'Merged Child PDFs',
                    base64Data: finalBase64,
                    extension: 'pdf'
                });
                this.showToast('Success', 'Merged PDF saved to record.', 'success');
            } else {
                this.downloadBase64(finalBase64, 'Merged Child PDFs.pdf', 'application/pdf');
                this.showToast('Success', 'Merged PDF downloaded.', 'success');
            }
        } catch (e) {
            let msg = e.body ? e.body.message : e.message || 'Unknown error';
            this.error = 'Merge Error: ' + msg;
        } finally {
            this.isLoading = false;
        }
    }

    get isGenerateDisabled() {
        return !this.selectedTemplateId || this.isLoading;
    }

    async generateDocument() {
        this.isLoading = true;
        this.error = null;

        try {
            const selected = this._templateData.find(t => t.Id === this.selectedTemplateId);
            const templateType = selected ? selected.Type__c : 'Word';
            const isPPT = templateType === 'PowerPoint';
            const isExcel = templateType === 'Excel';
            const isPDF = this.templateOutputFormat === 'PDF' && !isPPT && !isExcel;
            const saveToRecord = this.outputMode === 'save';
            const shouldMerge = isPDF && this.mergeEnabled && this.selectedPdfCvIds.length > 0;

            if (isPDF) {
                if (shouldMerge) {
                    await this._generateMergedPdf(saveToRecord);
                } else {
                    this.showToast('Info', 'Generating PDF...', 'info');

                    const result = await generatePdf({
                        templateId: this.selectedTemplateId,
                        recordId: this.recordId,
                        saveToRecord: saveToRecord
                    });

                    if (result.saved) {
                        this.showToast('Success', 'PDF saved to record.', 'success');
                    } else if (result.base64) {
                        const docTitle = result.title || 'Document';
                        this.downloadBase64(result.base64, docTitle + '.pdf', 'application/pdf');
                        this.showToast('Success', 'PDF downloaded.', 'success');
                    }
                }
            } else if (isExcel) {
                // Excel XLSX — client-side assembly (same pattern as DOCX)
                this.showToast('Info', 'Generating Excel spreadsheet...', 'info');
                await this._generateOfficeClientSide(saveToRecord, 'xlsx',
                    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
            } else if (!isPPT) {
                // Word DOCX — client-side assembly for zero heap
                this.showToast('Info', 'Generating Word document...', 'info');
                await this._generateOfficeClientSide(saveToRecord, 'docx', 'application/octet-stream');
            } else {
                // PowerPoint — still server-side (different ZIP structure)
                const result = await processAndReturnDocument({
                    templateId: this.selectedTemplateId,
                    recordId: this.recordId
                });

                if (!result || !result.base64) {
                    throw new Error('Document generation returned empty result.');
                }

                const docTitle = result.title || 'Document';

                if (saveToRecord) {
                    this.showToast('Info', 'Saving to Record...', 'info');
                    await saveGeneratedDocument({
                        recordId: this.recordId,
                        fileName: docTitle,
                        base64Data: result.base64,
                        extension: 'pptx'
                    });
                    this.showToast('Success', 'PPTX saved to record.', 'success');
                } else {
                    this.downloadBase64(result.base64, docTitle + '.pptx', 'application/octet-stream');
                    this.showToast('Success', 'PowerPoint downloaded.', 'success');
                }
            }
        } catch (e) {
            let msg = 'Unknown error during generation';
            if (e.body && e.body.message) {
                msg = e.body.message;
            } else if (e.message) {
                msg = e.message;
            } else if (typeof e === 'string') {
                msg = e;
            }
            this.error = 'Generation Error: ' + msg;
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Generates the template PDF, fetches selected existing PDFs,
     * and merges them all client-side. Each PDF fetch is a separate
     * Apex call with fresh 6MB heap — no server-side size limit.
     */
    async _generateMergedPdf(saveToRecord) {
        const totalPdfs = this.selectedPdfCvIds.length + 1;
        this.showToast('Info', `Generating and merging ${totalPdfs} PDFs...`, 'info');

        // 1. Generate the template PDF (always download mode — we merge client-side)
        const result = await generatePdf({
            templateId: this.selectedTemplateId,
            recordId: this.recordId,
            saveToRecord: false
        });

        if (!result || !result.base64) {
            throw new Error('Template PDF generation returned empty result.');
        }

        const docTitle = result.title || 'Document';

        // Convert template PDF base64 to Uint8Array
        const pdfBytesArray = [this._base64ToUint8Array(result.base64)];

        // 2. Fetch each selected PDF — one Apex call each = fresh 6MB heap
        for (const cvId of this.selectedPdfCvIds) {
            const b64 = await getContentVersionBase64({ contentVersionId: cvId });
            if (b64) {
                pdfBytesArray.push(this._base64ToUint8Array(b64));
            }
        }

        // 3. Merge all PDFs client-side — zero heap, browser handles it
        const mergedBytes = mergePdfs(pdfBytesArray);

        // 4. Download or save
        const mergedBase64 = this._uint8ArrayToBase64(mergedBytes);
        if (saveToRecord) {
            this.showToast('Info', 'Saving merged PDF to record...', 'info');
            await saveGeneratedDocument({
                recordId: this.recordId,
                fileName: docTitle,
                base64Data: mergedBase64,
                extension: 'pdf'
            });
            this.showToast('Success', 'Merged PDF saved to record.', 'success');
        } else {
            this.downloadBase64(mergedBase64, docTitle + '.pdf', 'application/pdf');
            this.showToast('Success', 'Merged PDF downloaded.', 'success');
        }
    }

    /**
     * Merge-only mode — no template generation. Fetches selected PDFs
     * from the record and merges them client-side in the user's chosen order.
     */
    /**
     * Document Packet — generates multiple templates as PDFs, optionally
     * appends existing PDFs, and merges everything into one document.
     */
    async generatePacket() {
        this.isLoading = true;
        this.error = null;

        try {
            const templateCount = this.packetTemplateIds.length;
            const existingCount = this.packetIncludeExisting ? this.packetExistingPdfIds.length : 0;
            const totalDocs = templateCount + existingCount;
            this.showToast('Info', `Generating packet (${totalDocs} documents)...`, 'info');

            const pdfBytesArray = [];

            // Generate each template as PDF (in packet order)
            for (const templateId of this.packetTemplateIds) {
                const result = await generatePdf({
                    templateId: templateId,
                    recordId: this.recordId,
                    saveToRecord: false
                });
                if (result && result.base64) {
                    pdfBytesArray.push(this._base64ToUint8Array(result.base64));
                }
            }

            // Fetch existing PDFs if included
            if (this.packetIncludeExisting && this.packetExistingPdfIds.length > 0) {
                for (const cvId of this.packetExistingPdfIds) {
                    const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                    if (b64) {
                        pdfBytesArray.push(this._base64ToUint8Array(b64));
                    }
                }
            }

            if (pdfBytesArray.length === 0) {
                throw new Error('No documents were generated.');
            }

            // Single template, no existing PDFs — just download/save directly
            let finalBase64;
            if (pdfBytesArray.length === 1) {
                finalBase64 = this._uint8ArrayToBase64(pdfBytesArray[0]);
            } else {
                const mergedBytes = mergePdfs(pdfBytesArray);
                finalBase64 = this._uint8ArrayToBase64(mergedBytes);
            }

            const saveToRecord = this.outputMode === 'save';
            if (saveToRecord) {
                this.showToast('Info', 'Saving packet to record...', 'info');
                await saveGeneratedDocument({
                    recordId: this.recordId,
                    fileName: 'Document Packet',
                    base64Data: finalBase64,
                    extension: 'pdf'
                });
                this.showToast('Success', 'Document packet saved to record.', 'success');
            } else {
                this.downloadBase64(finalBase64, 'Document Packet.pdf', 'application/pdf');
                this.showToast('Success', 'Document packet downloaded.', 'success');
            }
        } catch (e) {
            let msg = 'Unknown error during packet generation';
            if (e.body && e.body.message) msg = e.body.message;
            else if (e.message) msg = e.message;
            else if (typeof e === 'string') msg = e;
            this.error = 'Packet Error: ' + msg;
        } finally {
            this.isLoading = false;
        }
    }

    async mergeOnlyDocument() {
        this.isLoading = true;
        this.error = null;

        try {
            const count = this.mergeOnlyCvIds.length;
            this.showToast('Info', `Merging ${count} PDFs...`, 'info');

            // Fetch each PDF — one Apex call each = fresh 6MB heap
            const pdfBytesArray = [];
            for (const cvId of this.mergeOnlyCvIds) {
                const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                if (b64) {
                    pdfBytesArray.push(this._base64ToUint8Array(b64));
                }
            }

            if (pdfBytesArray.length < 2) {
                throw new Error('Need at least 2 PDFs to merge.');
            }

            // Merge client-side
            const mergedBytes = mergePdfs(pdfBytesArray);
            const mergedBase64 = this._uint8ArrayToBase64(mergedBytes);
            const saveToRecord = this.outputMode === 'save';

            if (saveToRecord) {
                this.showToast('Info', 'Saving merged PDF to record...', 'info');
                await saveGeneratedDocument({
                    recordId: this.recordId,
                    fileName: 'Merged Document',
                    base64Data: mergedBase64,
                    extension: 'pdf'
                });
                this.showToast('Success', 'Merged PDF saved to record.', 'success');
            } else {
                this.downloadBase64(mergedBase64, 'Merged Document.pdf', 'application/pdf');
                this.showToast('Success', 'Merged PDF downloaded.', 'success');
            }
        } catch (e) {
            let msg = 'Unknown error during merge';
            if (e.body && e.body.message) msg = e.body.message;
            else if (e.message) msg = e.message;
            else if (typeof e === 'string') msg = e;
            this.error = 'Merge Error: ' + msg;
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Client-side Office document assembly (DOCX or XLSX).
     * Server merges XML (lightweight), client fetches images, assembles ZIP.
     * Zero server-side heap for ZIP assembly — enables unlimited document size.
     */
    async _generateOfficeClientSide(saveToRecord, extension, mimeType) {
        const parts = await generateDocumentParts({
            templateId: this.selectedTemplateId,
            recordId: this.recordId
        });

        if (!parts || !parts.allXmlParts) {
            throw new Error('Document generation returned empty result.');
        }

        const docTitle = parts.title || 'Document';

        // Fetch dynamic images one at a time — each Apex call gets fresh heap
        const allImages = { ...(parts.imageBase64Map || {}) };
        if (parts.imageCvIdMap) {
            const uniqueCvIds = new Map();
            for (const [mediaPath, cvId] of Object.entries(parts.imageCvIdMap)) {
                if (!uniqueCvIds.has(cvId)) {
                    uniqueCvIds.set(cvId, []);
                }
                uniqueCvIds.get(cvId).push(mediaPath);
            }

            for (const [cvId, mediaPaths] of uniqueCvIds) {
                try {
                    const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                    if (b64) {
                        for (const mediaPath of mediaPaths) {
                            allImages[mediaPath] = b64;
                        }
                    }
                } catch (imgErr) {
                    console.warn('DocGen: Failed to fetch image CV ' + cvId, imgErr);
                }
            }
        }

        // Build the ZIP from scratch — works for DOCX, XLSX, or any Office Open XML
        const fileBytes = buildDocx(parts.allXmlParts, allImages);
        const fileBase64 = this._uint8ArrayToBase64(fileBytes);
        const label = extension.toUpperCase();

        if (saveToRecord) {
            this.showToast('Info', 'Saving to Record...', 'info');
            await saveGeneratedDocument({
                recordId: this.recordId,
                fileName: docTitle,
                base64Data: fileBase64,
                extension: extension
            });
            this.showToast('Success', label + ' saved to record.', 'success');
        } else {
            this.downloadBase64(fileBase64, docTitle + '.' + extension, mimeType);
            this.showToast('Success', label + ' downloaded.', 'success');
        }
    }


    /**
     * Converts a base64 string to a Uint8Array.
     */
    _base64ToUint8Array(base64) {
        const binaryStr = atob(base64);
        const bytes = new Uint8Array(binaryStr.length);
        for (let i = 0; i < binaryStr.length; i++) {
            bytes[i] = binaryStr.charCodeAt(i);
        }
        return bytes;
    }

    /**
     * Converts a Uint8Array to a base64 string.
     */
    _uint8ArrayToBase64(bytes) {
        let binary = '';
        for (let i = 0; i < bytes.length; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    }

    /**
     * Downloads a base64-encoded file via an anchor element.
     */
    downloadBase64(base64Data, fileName, mimeType) {
        const binaryString = atob(base64Data);
        const bytes = new Uint8Array(binaryString.length);
        for (let i = 0; i < binaryString.length; i++) {
            bytes[i] = binaryString.charCodeAt(i);
        }
        const blob = new Blob([bytes], { type: mimeType });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = fileName;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
