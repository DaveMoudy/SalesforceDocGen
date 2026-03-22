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

    handleRefreshTemplates() {
        refreshApex(this._wiredTemplateResult);
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    handleTemplateChange(event) {
        this.selectedTemplateId = event.detail.value;
        const selected = this.templates.find(t => t.value === this.selectedTemplateId);
        if (selected) {
            this.baseObject = selected.baseObject;
            this.recordCount = null;
            this.loadSavedQueries();

            // Auto-load report filter WHERE clause from template config if V3
            const tmplData = this._templateDataMap[this.selectedTemplateId];
            if (tmplData && tmplData.Query_Config__c) {
                try {
                    const config = JSON.parse(tmplData.Query_Config__c);
                    if (config.reportFilters && config.reportFilters.length > 0) {
                        // Convert report filters to WHERE clause
                        const parts = config.reportFilters.map(f => {
                            if (f.operator === 'LIKE') return f.field + " LIKE '%" + f.value + "%'";
                            return f.field + " " + f.operator + " '" + f.value + "'";
                        });
                        this.condition = parts.join(' AND ');
                        this.showToast('Filter Applied', 'Report filter loaded: ' + this.condition, 'info');
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
            this.jobId = await submitJob({ templateId: this.selectedTemplateId, condition: this.condition });
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

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    get isRunDisabled() {
        return !this.selectedTemplateId || this.isProcessing;
    }
}
