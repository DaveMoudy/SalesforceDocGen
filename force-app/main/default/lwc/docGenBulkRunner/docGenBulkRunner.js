import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { downloadBase64, extractWhereClause } from 'c/docGenUtils';
import getBulkTemplates from '@salesforce/apex/DocGenBulkController.getBulkTemplates';
import validateFilter from '@salesforce/apex/DocGenBulkController.validateFilter';
import submitJob from '@salesforce/apex/DocGenBulkController.submitJob';
import getJobStatus from '@salesforce/apex/DocGenBulkController.getJobStatus';
import getSavedQueries from '@salesforce/apex/DocGenBulkController.getSavedQueries';
import saveQuery from '@salesforce/apex/DocGenBulkController.saveQuery';
import deleteQuery from '@salesforce/apex/DocGenBulkController.deleteQuery';
import getRecentJobs from '@salesforce/apex/DocGenBulkController.getRecentJobs';
import analyzeJob from '@salesforce/apex/DocGenBulkController.analyzeJob';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import BASE_OBJ_FIELD from '@salesforce/schema/DocGen_Template__c.Base_Object_API__c';
import OUT_FMT_FIELD from '@salesforce/schema/DocGen_Template__c.Output_Format__c';
import QCONFIG_FIELD from '@salesforce/schema/DocGen_Template__c.Query_Config__c';
import JOB_LABEL_FIELD from '@salesforce/schema/DocGen_Job__c.Label__c';
import JOB_STATUS_FIELD from '@salesforce/schema/DocGen_Job__c.Status__c';
import JOB_SUCCESS_FIELD from '@salesforce/schema/DocGen_Job__c.Success_Count__c';
import JOB_ERROR_FIELD from '@salesforce/schema/DocGen_Job__c.Error_Count__c';
import JOB_TOTAL_FIELD from '@salesforce/schema/DocGen_Job__c.Total_Records__c';

const POLL_INTERVAL_MS = 5000;
const TERMINAL_STATUSES = ['Completed', 'Failed', 'Completed with Errors'];

export default class DocGenBulkRunner extends NavigationMixin(LightningElement) {
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
                    label: t.Name + ' (' + t[BASE_OBJ_FIELD.fieldApiName] + ' \u2022 ' + (t[OUT_FMT_FIELD.fieldApiName] || 'Document') + ')',
                    value: t.Id,
                    baseObject: t[BASE_OBJ_FIELD.fieldApiName]
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
    @track batchSize = 1;
    @track outputMode = 'combined'; // 'individual', 'combined', 'both'
    @track jobSearchTerm = '';

    // Job analysis state
    @track analysis = null;
    @track isAnalyzing = false;
    @track filterValidated = false;

    get analysisIcon() {
        if (!this.analysis) return 'utility:info';
        return this.analysis.canProceed ? 'utility:success' : 'utility:error';
    }

    get analysisVariant() {
        if (!this.analysis) return '';
        return this.analysis.canProceed ? 'success' : 'error';
    }

    get analysisItems() {
        if (!this.analysis || !this.analysis.items) return [];
        return this.analysis.items.map(item => ({
            ...item,
            iconName: item.status === 'ok' ? 'utility:success' : item.status === 'warning' ? 'utility:warning' : 'utility:error',
            iconVariant: item.status === 'ok' ? 'success' : item.status === 'warning' ? 'warning' : 'error'
        }));
    }

    async runAnalysis() {
        if (!this.selectedTemplateId || !this.recordCount) return;

        this.isAnalyzing = true;
        try {
            this.analysis = await analyzeJob({
                templateId: this.selectedTemplateId,
                recordCount: this.recordCount,
                batchSize: this.batchSize || 1,
                mergePdf: this.mergePdf || false
            });
        } catch (error) {
            console.error('Job analysis failed', error);
        } finally {
            this.isAnalyzing = false;
        }
    }

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
            this.analysis = null;
            this.filterValidated = false;
            this.loadSavedQueries();
            this.applyAutoFilter();
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
            downloadBase64(result.base64, 'Sample_' + (result.title || 'Document') + '.pdf', 'application/pdf');

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
                    label: j[JOB_LABEL_FIELD.fieldApiName] || '',
                    templateName: j.Template__r ? j.Template__r.Name : '',
                    outputFormat: j.Template__r ? j.Template__r[OUT_FMT_FIELD.fieldApiName] : '',
                    status: j[JOB_STATUS_FIELD.fieldApiName],
                    success: j[JOB_SUCCESS_FIELD.fieldApiName] || 0,
                    error: j[JOB_ERROR_FIELD.fieldApiName] || 0,
                    total: j[JOB_TOTAL_FIELD.fieldApiName] || 0,
                    date: new Date(j.CreatedDate).toLocaleDateString(),
                    isRunning: !['Completed', 'Failed', 'Completed with Errors'].includes(j[JOB_STATUS_FIELD.fieldApiName]),
                    displayName: j[JOB_LABEL_FIELD.fieldApiName] || (j.Template__r ? j.Template__r.Name : j.Name)
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

    handleBatchSizeChange(event) {
        const val = parseInt(event.target.value, 10);
        this.batchSize = (val >= 1 && val <= 200) ? val : 1;
        if (this.filterValidated) this.runAnalysis();
    }

    get outputModeOptions() {
        return [
            { label: 'Individual Files', value: 'individual' },
            { label: 'Print-Ready Packet', value: 'combined' },
            { label: 'Combined + Individual', value: 'both' }
        ];
    }

    handleOutputModeChange(event) {
        this.outputMode = event.detail.value;
        if (this.filterValidated) { this.runAnalysis(); }
    }

    get mergePdf() {
        return this.outputMode === 'combined' || this.outputMode === 'both';
    }

    get mergeOnly() {
        return this.outputMode === 'combined';
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

    handleViewJob(event) {
        const jobId = event.currentTarget.dataset.jobid;
        if (!jobId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: jobId,
                objectApiName: 'DocGen_Job__c',
                actionName: 'view'
            }
        });
    }

    handleTemplateChange(event) {
        this.selectedTemplateId = event.detail.value;
        const selected = this.templates.find(t => t.value === this.selectedTemplateId);
        if (selected) {
            this.baseObject = selected.baseObject;
            this.recordCount = null;
            this.analysis = null;
            this.filterValidated = false;
            this.loadSavedQueries();
            this.applyAutoFilter();
        }
    }

    loadSavedQueries() {
        getSavedQueries({ templateId: this.selectedTemplateId })
            .then(data => {
                this.savedQueries = data;
            })
            .catch(() => {
            });
    }

    /**
     * Extracts a WHERE clause from the selected template's Query_Config__c
     * and applies it as the current condition. Auto-saves as a saved query
     * if not already present.
     */
    applyAutoFilter() {
        const tmplData = this._templateDataMap[this.selectedTemplateId];
        if (!tmplData || !tmplData[QCONFIG_FIELD.fieldApiName]) return;

        const autoFilter = extractWhereClause(tmplData[QCONFIG_FIELD.fieldApiName]);
        if (!autoFilter) return;

        this.condition = autoFilter;
        this.showToast('Filter Applied', 'Report filter loaded.', 'info');

        const existingMatch = this.savedQueries.find(q => q.Query_Condition__c === autoFilter);
        if (!existingMatch) {
            saveQuery({
                templateId: this.selectedTemplateId,
                label: 'From Report',
                description: 'Auto-saved from report import',
                condition: autoFilter
            }).then(() => this.loadSavedQueries()).catch(() => {});
        }
    }

    handleLoadQuery(event) {
        const queryId = event.target.dataset.id;
        const query = this.savedQueries.find(q => q.Id === queryId);
        if (query) {
            this.condition = query.Query_Condition__c;
            this.recordCount = null;
            this.analysis = null;
            this.filterValidated = false;
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
            .catch(() => {
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
        this.analysis = null;
        this.filterValidated = false;
    }

    async handleValidate() {
        if (!this.baseObject) return;
        this.isValidating = true;
        this.analysis = null;
        try {
            const count = await validateFilter({ objectName: this.baseObject, condition: this.condition });
            this.recordCount = count;
            this.filterValidated = true;
            this.showToast('Success', `Found ${count} records.`, 'success');
            // Always run analysis after validation
            await this.runAnalysis();
        } catch (error) {
            this.showToast('Validation Error', error.body.message, 'error');
            this.recordCount = null;
            this.filterValidated = false;
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
            this.jobId = await submitJob({
                templateId: this.selectedTemplateId,
                condition: this.condition,
                jobLabel: this.jobLabel,
                mergePdf: this.mergePdf || false,
                batchSize: this.batchSize || 1,
                mergeOnly: this.mergeOnly || false
            });
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
            this.jobStatus = job[JOB_STATUS_FIELD.fieldApiName];
            const total = job[JOB_TOTAL_FIELD.fieldApiName] || 0;
            const current = (job[JOB_SUCCESS_FIELD.fieldApiName] || 0) + (job[JOB_ERROR_FIELD.fieldApiName] || 0);
            this.jobProgress = {
                success: job[JOB_SUCCESS_FIELD.fieldApiName] || 0,
                error: job[JOB_ERROR_FIELD.fieldApiName] || 0,
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
        } catch {
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

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    get isRunDisabled() {
        return !this.selectedTemplateId || this.isProcessing || !this.filterValidated || (this.analysis && !this.analysis.canProceed);
    }
}
