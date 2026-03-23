import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplatesForObject from '@salesforce/apex/DocGenController.getTemplatesForObject';
import processAndReturnDocument from '@salesforce/apex/DocGenController.processAndReturnDocument';
import generateDocumentParts from '@salesforce/apex/DocGenController.generateDocumentParts';
import getContentVersionBase64 from '@salesforce/apex/DocGenController.getContentVersionBase64';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import saveGeneratedDocument from '@salesforce/apex/DocGenController.saveGeneratedDocument';
import getRecordPdfs from '@salesforce/apex/DocGenController.getRecordPdfs';
import { buildDocx } from './docGenZipWriter';
import { mergePdfs } from './docGenPdfMerger';

export default class DocGenRunner extends LightningElement {
    @api recordId;
    @api objectApiName;

    @track templateOptions = [];
    @track selectedTemplateId;
    @track outputMode = 'download';
    @track templateOutputFormat = 'Document';

    // PDF Merge state
    @track mergeEnabled = false;
    @track recordPdfOptions = [];
    @track selectedPdfCvIds = [];

    isLoading = false;
    error;
    _templateData = [];

    get outputOptions() {
        const formatLabel = this.templateOutputFormat || 'Document';
        const options = [
            { label: `Download ${formatLabel}`, value: 'download' }
        ];
        // Save to Record is only available for PDF — client-side DOCX/PPTX
        // assembly exceeds the Aura 4MB payload limit for save operations
        if (formatLabel === 'PDF') {
            options.push({ label: `Save to Record (${formatLabel})`, value: 'save' });
        }
        return options;
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

    handleOutputModeChange(event) {
        this.outputMode = event.detail.value;
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
            const isPDF = this.templateOutputFormat === 'PDF' && !isPPT;
            const saveToRecord = this.outputMode === 'save';
            const shouldMerge = isPDF && this.mergeEnabled && this.selectedPdfCvIds.length > 0;

            if (isPDF) {
                if (shouldMerge) {
                    // PDF merge path — generate template PDF + fetch selected PDFs + merge client-side
                    await this._generateMergedPdf(saveToRecord);
                } else {
                    // Standard PDF path — same backend as bulk generation
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
            } else if (!isPPT) {
                // Word DOCX — client-side assembly for zero heap
                this.showToast('Info', 'Generating Word document...', 'info');
                await this._generateDocxClientSide(saveToRecord);
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
     * Client-side DOCX assembly. Server merges XML (lightweight), client fetches
     * the shell ZIP and images by URL, then assembles the final DOCX.
     * Zero server-side heap for ZIP assembly — enables unlimited document size.
     */
    async _generateDocxClientSide(saveToRecord) {
        // 1. Server merges the XML — returns parts, not a ZIP
        const parts = await generateDocumentParts({
            templateId: this.selectedTemplateId,
            recordId: this.recordId
        });

        if (!parts || !parts.allXmlParts) {
            throw new Error('Document generation returned empty result.');
        }

        const docTitle = parts.title || 'Document';

        // 2. Fetch dynamic images one at a time — each Apex call gets fresh heap
        const allImages = { ...(parts.imageBase64Map || {}) };
        if (parts.imageCvIdMap) {
            // Deduplicate: multiple media paths may reference the same CV ID
            const uniqueCvIds = new Map();
            for (const [mediaPath, cvId] of Object.entries(parts.imageCvIdMap)) {
                if (!uniqueCvIds.has(cvId)) {
                    uniqueCvIds.set(cvId, []);
                }
                uniqueCvIds.get(cvId).push(mediaPath);
            }

            // Fetch each unique image in its own Apex call — fresh 6MB heap each time
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

        // 3. Build the DOCX ZIP from scratch — all XML parts + media as base64
        const docxBytes = buildDocx(parts.allXmlParts, allImages);
        const docxBase64 = this._uint8ArrayToBase64(docxBytes);

        // 6. Download or save
        if (saveToRecord) {
            this.showToast('Info', 'Saving to Record...', 'info');
            await saveGeneratedDocument({
                recordId: this.recordId,
                fileName: docTitle,
                base64Data: docxBase64,
                extension: 'docx'
            });
            this.showToast('Success', 'DOCX saved to record.', 'success');
        } else {
            this.downloadBase64(docxBase64, docTitle + '.docx', 'application/octet-stream');
            this.showToast('Success', 'Word document downloaded.', 'success');
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
