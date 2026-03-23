import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getBulkTemplates from '@salesforce/apex/DocGenBulkController.getBulkTemplates';
import validateFilter from '@salesforce/apex/DocGenBulkController.validateFilter';
import submitJob from '@salesforce/apex/DocGenBulkController.submitJob';
import getJobStatus from '@salesforce/apex/DocGenBulkController.getJobStatus';
import getSavedQueries from '@salesforce/apex/DocGenBulkController.getSavedQueries';
import saveQuery from '@salesforce/apex/DocGenBulkController.saveQuery';
import deleteQuery from '@salesforce/apex/DocGenBulkController.deleteQuery';
import getRecentJobs from '@salesforce/apex/DocGenBulkController.getRecentJobs';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import getJobGeneratedPdfs from '@salesforce/apex/DocGenBulkController.getJobGeneratedPdfs';
import getContentVersionBase64 from '@salesforce/apex/DocGenController.getContentVersionBase64';
import { mergePdfs } from './docGenPdfMerger';

const POLL_INTERVAL_MS = 5000;
const TERMINAL_STATUSES = ['Completed', 'Failed', 'Completed with Errors'];

export default class DocGenBulkRunner extends LightningElement {
    @track templates = [];
    @track selectedTemplateId;
    @track baseObject;
    @track condition = '';
    @track recordCount = null;
    @track isValidating = false;

    @track jobId;
    @track jobStatus;
    @track jobProgress = {};
    @track isProcessing = false;

    // Saved Queries State
    @track savedQueries = [];
    @track isSaveModalOpen = false;
    newQueryName = '';
    newQueryDesc = '';

    // Job history for display
    @track completedJobs = [];

    _pollTimer;

    // Merge state
    @track isMerging = false;

    // Wire Templates
    _wiredTemplateResult;
    _templateDataMap = {};

    @wire(getBulkTemplates)
    wiredTemplates(result) {
        this._wiredTemplateResult = result;
        if (result.data) {
            this._templateDataMap = {};
            this.templates = result.data.map(t => {
                this._templateDataMap[t.Id] = t;
                return {
                    label: t.Name + ' (' + t.Base_Object_API__c + ' \u2022 ' + (t.Output_Format__c || 'Document') + ')',
                    value: t.Id,
                    baseObject: t.Base_Object_API__c
                };
            });
        } else if (result.error) {
            this.showToast('Error', 'Failed to load templates', 'error');
        }
    }

    @track templateSearchTerm = '';
    @track showTemplateDropdown = false;
    @track selectedTemplateName = '';

    // Sample record + Preview state
    @track sampleRecordId = '';
    @track isGeneratingPreview = false;

    // Recent jobs from server
    @track recentJobs = [];
    @track jobLabel = '';
    @track jobSearchTerm = '';
    @track mergingJobId = null;

    get filteredTemplates() {
        const term = (this.templateSearchTerm || '').toLowerCase();
        if (!term) return this.templates;
        return this.templates.filter(t => t.label.toLowerCase().includes(term));
    }

    get canPreview() {
        return this.selectedTemplateId && this.sampleRecordId;
    }

    handleSampleRecordChange(event) {
        this.sampleRecordId = event.detail.recordId;
    }

    handleTemplateSearch(event) {
        this.templateSearchTerm = event.detail.value || event.target.value || '';
        this.showTemplateDropdown = this.templateSearchTerm.length > 0 || this.templates.length <= 20;
    }

    handleTemplateSearchFocus() {
        this.showTemplateDropdown = true;
    }

    handleTemplateSelect(event) {
        const templateId = event.currentTarget.dataset.id;
        this.selectedTemplateId = templateId;
        this.showTemplateDropdown = false;

        const selected = this.templates.find(t => t.value === templateId);
        if (selected) {
            this.baseObject = selected.baseObject;
            this.selectedTemplateName = selected.label;
            this.templateSearchTerm = '';
            this.recordCount = null;
            this.loadSavedQueries();

            // Auto-load report filter
            const tmplData = this._templateDataMap[this.selectedTemplateId];
            if (tmplData && tmplData.Query_Config__c) {
                try {
                    const config = JSON.parse(tmplData.Query_Config__c);
                    let autoFilter = null;
                    if (config.bulkWhereClause) {
                        autoFilter = config.bulkWhereClause;
                    } else if (config.reportFilters && config.reportFilters.length > 0) {
                        const parts = config.reportFilters.map(f => {
                            if (f.operator === 'LIKE') return f.field + " LIKE '%" + f.value + "%'";
                            if (f.operator === 'IN' || f.operator === 'NOT IN') {
                                const vals = f.value.split(',').map(v => "'" + v.trim() + "'").join(', ');
                                return f.field + ' ' + f.operator + ' (' + vals + ')';
                            }
                            const v = f.value.trim();
                            const dateLiterals = ['TODAY','YESTERDAY','TOMORROW','LAST_WEEK','THIS_WEEK','NEXT_WEEK','LAST_MONTH','THIS_MONTH','NEXT_MONTH','LAST_QUARTER','THIS_QUARTER','NEXT_QUARTER','LAST_YEAR','THIS_YEAR','NEXT_YEAR','LAST_90_DAYS','NEXT_90_DAYS'];
                            const upper = v.toUpperCase();
                            if (dateLiterals.includes(upper) || upper.startsWith('LAST_N_') || upper.startsWith('NEXT_N_') || /^\d+\.?\d*$/.test(v) || /^\d{4}-\d{2}-\d{2}/.test(v) || upper === 'TRUE' || upper === 'FALSE' || upper === 'NULL') {
                                return f.field + ' ' + f.operator + ' ' + v;
                            }
                            return f.field + " " + f.operator + " '" + f.value + "'";
                        });
                        autoFilter = parts.join(' AND ');
                    }
                    if (autoFilter) {
                        this.condition = autoFilter;
                        this.showToast('Filter Applied', 'Report filter loaded', 'info');
                        const existingMatch = this.savedQueries.find(q => q.Query_Condition__c === autoFilter);
                        if (!existingMatch) {
                            saveQuery({ templateId: this.selectedTemplateId, label: 'From Report', description: 'Auto-saved from report import', condition: autoFilter })
                                .then(() => this.loadSavedQueries()).catch(() => {});
                        }
                    }
                } catch (e) { /* not JSON */ }
            }
        }
    }

    handleRefreshTemplates() {
        refreshApex(this._wiredTemplateResult);
    }

    // Preview — generates a real PDF sample via the heap-efficient Blob.toPdf() path
    async handlePreviewSample() {
        if (!this.selectedTemplateId || !this.sampleRecordId) return;

        this.isGeneratingPreview = true;
        this.showToast('Info', 'Generating sample PDF...', 'info');

        try {
            const result = await generatePdf({
                templateId: this.selectedTemplateId,
                recordId: this.sampleRecordId,
                saveToRecord: false
            });

            if (!result || !result.base64) {
                throw new Error('PDF generation returned empty result.');
            }

            // Download the PDF
            const binaryString = atob(result.base64);
            const bytes = new Uint8Array(binaryString.length);
            for (let i = 0; i < binaryString.length; i++) {
                bytes[i] = binaryString.charCodeAt(i);
            }
            const blob = new Blob([bytes], { type: 'application/pdf' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'Sample_' + (result.title || 'Document') + '.pdf';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);

            this.showToast('Success', 'Sample PDF downloaded', 'success');
        } catch (error) {
            const msg = error.body ? error.body.message : (error.message || 'Could not generate preview.');
            this.showToast('Preview Error', msg, 'error');
        } finally {
            this.isGeneratingPreview = false;
        }
    }

    connectedCallback() {
        this.loadRecentJobs();
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    loadRecentJobs() {
        getRecentJobs()
            .then(data => {
                this.recentJobs = data.map(j => ({
                    id: j.Id,
                    name: j.Name,
                    label: j.Label__c || '',
                    templateName: j.Template__r ? j.Template__r.Name : '',
                    outputFormat: j.Template__r ? j.Template__r.Output_Format__c : '',
                    status: j.Status__c,
                    success: j.Success_Count__c || 0,
                    error: j.Error_Count__c || 0,
                    total: j.Total_Records__c || 0,
                    date: new Date(j.CreatedDate).toLocaleDateString(),
                    isPdf: j.Template__r && j.Template__r.Output_Format__c === 'PDF',
                    isCompleted: j.Status__c === 'Completed' || j.Status__c === 'Completed with Errors',
                    showMerge: j.Template__r && j.Template__r.Output_Format__c === 'PDF' &&
                        (j.Status__c === 'Completed' || j.Status__c === 'Completed with Errors') &&
                        (j.Success_Count__c || 0) > 0,
                    displayName: j.Label__c || (j.Template__r ? j.Template__r.Name : j.Name)
                }));
            })
            .catch(() => {});
    }

    get hasRecentJobs() {
        return this.filteredRecentJobs.length > 0;
    }

    get hasNoSearchResults() {
        return this.jobSearchTerm && this.filteredRecentJobs.length === 0;
    }

    handleJobLabelChange(event) {
        this.jobLabel = event.target.value;
    }

    handleJobSearchChange(event) {
        this.jobSearchTerm = event.target.value;
    }

    get filteredRecentJobs() {
        if (!this.jobSearchTerm) return this.recentJobs;
        const term = this.jobSearchTerm.toLowerCase();
        return this.recentJobs.filter(j =>
            j.displayName.toLowerCase().includes(term) ||
            j.templateName.toLowerCase().includes(term) ||
            j.status.toLowerCase().includes(term)
        );
    }

    async handleMergeJobPdfs(event) {
        const jobId = event.target.dataset.jobid;
        const job = this.recentJobs.find(j => j.id === jobId);
        if (!job) return;

        this.mergingJobId = jobId;
        try {
            this.showToast('Info', 'Loading generated PDFs...', 'info');
            const pdfs = await getJobGeneratedPdfs({ jobId });
            if (!pdfs || pdfs.length === 0) {
                this.showToast('Warning', 'No generated PDFs found for this job.', 'warning');
                return;
            }

            this.showToast('Info', `Merging ${pdfs.length} PDFs...`, 'info');
            const pdfBytesArray = [];
            for (const pdf of pdfs) {
                const b64 = await getContentVersionBase64({ contentVersionId: pdf.value });
                if (b64) {
                    pdfBytesArray.push(this._base64ToUint8Array(b64));
                }
            }

            if (pdfBytesArray.length === 0) {
                throw new Error('No PDFs could be loaded.');
            }

            let finalBytes;
            if (pdfBytesArray.length === 1) {
                finalBytes = pdfBytesArray[0];
            } else {
                finalBytes = mergePdfs(pdfBytesArray);
            }

            const fileName = (job.label || job.templateName || 'Bulk Merged') + '.pdf';
            const finalBase64 = this._uint8ArrayToBase64(finalBytes);
            this._downloadBase64(finalBase64, fileName, 'application/pdf');
            this.showToast('Success', `Merged ${pdfBytesArray.length} PDFs and downloaded.`, 'success');
        } catch (e) {
            const msg = e.body ? e.body.message : (e.message || 'Unknown error');
            this.showToast('Error', 'Merge failed: ' + msg, 'error');
        } finally {
            this.mergingJobId = null;
        }
    }

    handleTemplateChange(event) {
        this.selectedTemplateId = event.detail.value;
        const selected = this.templates.find(t => t.value === this.selectedTemplateId);
        if (selected) {
            this.baseObject = selected.baseObject;
            this.recordCount = null;
            this.loadSavedQueries();

            // Auto-load report filter WHERE clause from template config
            const tmplData = this._templateDataMap[this.selectedTemplateId];
            if (tmplData && tmplData.Query_Config__c) {
                try {
                    const config = JSON.parse(tmplData.Query_Config__c);

                    // Check for pre-built WHERE clause (saved from report import)
                    let autoFilter = null;
                    if (config.bulkWhereClause) {
                        autoFilter = config.bulkWhereClause;
                    }
                    // Fallback: convert reportFilters array to WHERE clause
                    else if (config.reportFilters && config.reportFilters.length > 0) {
                        const parts = config.reportFilters.map(f => {
                            if (f.operator === 'LIKE') return f.field + " LIKE '%" + f.value + "%'";
                            if (f.operator === 'IN' || f.operator === 'NOT IN') {
                                const vals = f.value.split(',').map(v => "'" + v.trim() + "'").join(', ');
                                return f.field + ' ' + f.operator + ' (' + vals + ')';
                            }
                            // Date literals, numbers, booleans, dates don't need quotes
                            const v = f.value.trim();
                            const dateLiterals = ['TODAY','YESTERDAY','TOMORROW','LAST_WEEK','THIS_WEEK','NEXT_WEEK','LAST_MONTH','THIS_MONTH','NEXT_MONTH','LAST_QUARTER','THIS_QUARTER','NEXT_QUARTER','LAST_YEAR','THIS_YEAR','NEXT_YEAR','LAST_90_DAYS','NEXT_90_DAYS'];
                            const upper = v.toUpperCase();
                            if (dateLiterals.includes(upper) || upper.startsWith('LAST_N_') || upper.startsWith('NEXT_N_') || /^\d+$/.test(v) || /^\d{4}-\d{2}-\d{2}/.test(v) || upper === 'TRUE' || upper === 'FALSE' || upper === 'NULL') {
                                return f.field + ' ' + f.operator + ' ' + v;
                            }
                            return f.field + " " + f.operator + " '" + f.value + "'";
                        });
                        autoFilter = parts.join(' AND ');
                    }

                    if (autoFilter) {
                        this.condition = autoFilter;
                        this.showToast('Filter Applied', 'Report filter loaded.', 'info');

                        // Auto-save as a saved query if not already saved
                        const existingMatch = this.savedQueries.find(q => q.Query_Condition__c === autoFilter);
                        if (!existingMatch) {
                            saveQuery({
                                templateId: this.selectedTemplateId,
                                label: 'From Report',
                                description: 'Auto-saved from report import',
                                condition: autoFilter
                            }).then(() => {
                                this.loadSavedQueries();
                            }).catch(() => {});
                        }
                    }
                } catch (e) {
                    // Not JSON or no filters — that's fine
                }
            }
        }
    }

    loadSavedQueries() {
        getSavedQueries({ templateId: this.selectedTemplateId })
            .then(data => {
                this.savedQueries = data;
            })
            .catch(_error => {
            });
    }

    handleLoadQuery(event) {
        const queryId = event.target.dataset.id;
        const query = this.savedQueries.find(q => q.Id === queryId);
        if (query) {
            this.condition = query.Query_Condition__c;
            this.recordCount = null;
        }
    }

    handleDeleteQuery(event) {
        const queryId = event.target.dataset.id;
        if (!confirm('Are you sure you want to delete this saved query?')) return;

        deleteQuery({ queryId })
            .then(() => {
                this.showToast('Success', 'Query deleted', 'success');
                this.loadSavedQueries();
            })
            .catch(_error => {
                this.showToast('Error', 'Failed to delete query', 'error');
            });
    }

    // --- Save Modal ---
    openSaveModal() {
        if (!this.condition) {
            this.showToast('Warning', 'Please enter a condition first.', 'warning');
            return;
        }
        this.newQueryName = '';
        this.newQueryDesc = '';
        this.isSaveModalOpen = true;
    }

    closeSaveModal() {
        this.isSaveModalOpen = false;
    }

    handleNewQueryNameChange(event) { this.newQueryName = event.target.value; }
    handleNewQueryDescChange(event) { this.newQueryDesc = event.target.value; }

    handleSaveQuery() {
        if (!this.newQueryName) {
            this.showToast('Error', 'Please enter a name.', 'error');
            return;
        }

        saveQuery({
            templateId: this.selectedTemplateId,
            label: this.newQueryName,
            description: this.newQueryDesc,
            condition: this.condition
        })
        .then(() => {
            this.showToast('Success', 'Query saved.', 'success');
            this.isSaveModalOpen = false;
            this.loadSavedQueries();
        })
        .catch(error => {
            this.showToast('Error', error.body.message, 'error');
        });
    }

    handleConditionChange(event) {
        this.condition = event.detail.value || event.target.value; // Support both
        this.recordCount = null;
    }

    async handleValidate() {
        if (!this.baseObject) return;
        this.isValidating = true;
        try {
            const count = await validateFilter({ objectName: this.baseObject, condition: this.condition });
            this.recordCount = count;
            this.showToast('Success', `Found ${count} records.`, 'success');
        } catch (error) {
            this.showToast('Validation Error', error.body.message, 'error');
            this.recordCount = null;
        } finally {
            this.isValidating = false;
        }
    }

    async handleRun() {
        if (!this.selectedTemplateId) {
            this.showToast('Error', 'Please select a template.', 'error');
            return;
        }

        this.isProcessing = true;
        this.jobStatus = 'Queued';
        this.jobProgress = { success: 0, error: 0, total: 0, percent: 0 };

        try {
            this.jobId = await submitJob({ templateId: this.selectedTemplateId, condition: this.condition, jobLabel: this.jobLabel });
            this.showToast('Success', 'Job started. Status will auto-refresh every 5 seconds.', 'success');
            this.startPolling();
        } catch (error) {
            this.showToast('Error', error.body.message, 'error');
            this.isProcessing = false;
        }
    }

    // --- Polling ---
    startPolling() {
        this.stopPolling();
        // Poll immediately, then every POLL_INTERVAL_MS
        this.pollJob();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollTimer = setInterval(() => {
            this.pollJob();
        }, POLL_INTERVAL_MS);
    }

    stopPolling() {
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        }
    }

    async pollJob() {
        if (!this.jobId) return;
        try {
            const job = await getJobStatus({ jobId: this.jobId });
            this.jobStatus = job.Status__c;
            const total = job.Total_Records__c || 0;
            const current = (job.Success_Count__c || 0) + (job.Error_Count__c || 0);
            this.jobProgress = {
                success: job.Success_Count__c || 0,
                error: job.Error_Count__c || 0,
                total: total,
                percent: total > 0 ? Math.floor((current / total) * 100) : 0
            };

            if (TERMINAL_STATUSES.includes(this.jobStatus)) {
                this.stopPolling();
                this.isProcessing = false;
                const variant = this.jobStatus === 'Completed' ? 'success' : (this.jobStatus === 'Failed' ? 'error' : 'warning');
                this.showToast('Job Finished', `Status: ${this.jobStatus} — ${this.jobProgress.success} succeeded, ${this.jobProgress.error} failed`, variant);
                this.loadRecentJobs();
            }
        } catch (_e) {
            this.stopPolling();
        }
    }

    // --- New Job ---
    handleNewJob() {
        this.stopPolling();
        // Archive completed job info
        if (this.jobId && this.jobStatus) {
            this.completedJobs = [{
                id: this.jobId,
                status: this.jobStatus,
                success: this.jobProgress.success || 0,
                error: this.jobProgress.error || 0,
                total: this.jobProgress.total || 0
            }, ...this.completedJobs].slice(0, 5); // Keep last 5
        }
        this.jobId = null;
        this.jobStatus = null;
        this.jobProgress = {};
        this.isProcessing = false;
    }

    get hasCompletedJobs() {
        return this.completedJobs.length > 0;
    }

    get isJobFinished() {
        return this.jobStatus && TERMINAL_STATUSES.includes(this.jobStatus);
    }

    get jobStatusVariant() {
        if (this.jobStatus === 'Completed') return 'success';
        if (this.jobStatus === 'Failed') return 'error';
        if (this.jobStatus === 'Completed with Errors') return 'warning';
        return 'inverse';
    }

    // --- Merge All Generated PDFs ---

    get showMergeAllButton() {
        if (!this.jobId || !this.jobStatus) return false;
        if (this.jobStatus === 'Failed') return false;
        // Only for PDF templates
        const tmpl = this._templateDataMap[this.selectedTemplateId];
        return tmpl && tmpl.Output_Format__c === 'PDF' &&
               (this.jobStatus === 'Completed' || this.jobStatus === 'Completed with Errors');
    }

    get mergeAllButtonLabel() {
        return this.isMerging ? 'Merging...' : 'Merge All PDFs';
    }

    async handleMergeAllJobPdfs() {
        this.isMerging = true;
        try {
            this.showToast('Info', 'Loading generated PDFs...', 'info');

            const pdfs = await getJobGeneratedPdfs({ jobId: this.jobId });
            if (!pdfs || pdfs.length === 0) {
                this.showToast('Warning', 'No generated PDFs found for this job.', 'warning');
                return;
            }

            this.showToast('Info', `Merging ${pdfs.length} PDFs...`, 'info');

            const pdfBytesArray = [];
            for (const pdf of pdfs) {
                const b64 = await getContentVersionBase64({ contentVersionId: pdf.value });
                if (b64) {
                    pdfBytesArray.push(this._base64ToUint8Array(b64));
                }
            }

            if (pdfBytesArray.length === 0) {
                throw new Error('No PDFs could be loaded.');
            }

            let finalBytes;
            if (pdfBytesArray.length === 1) {
                finalBytes = pdfBytesArray[0];
            } else {
                finalBytes = mergePdfs(pdfBytesArray);
            }

            const finalBase64 = this._uint8ArrayToBase64(finalBytes);
            this._downloadBase64(finalBase64, 'Bulk Merged.pdf', 'application/pdf');
            this.showToast('Success', `Merged ${pdfBytesArray.length} PDFs and downloaded.`, 'success');
        } catch (e) {
            const msg = e.body ? e.body.message : (e.message || 'Unknown error');
            this.showToast('Error', 'Merge failed: ' + msg, 'error');
        } finally {
            this.isMerging = false;
        }
    }

    _base64ToUint8Array(base64) {
        const binaryStr = atob(base64);
        const bytes = new Uint8Array(binaryStr.length);
        for (let i = 0; i < binaryStr.length; i++) {
            bytes[i] = binaryStr.charCodeAt(i);
        }
        return bytes;
    }

    _uint8ArrayToBase64(bytes) {
        let binary = '';
        for (let i = 0; i < bytes.length; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    }

    _downloadBase64(base64Data, fileName, mimeType) {
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

    get isRunDisabled() {
        return !this.selectedTemplateId || this.isProcessing;
    }
}
