import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplateShares from '@salesforce/apex/DocGenController.getTemplateShares';
import shareTemplate from '@salesforce/apex/DocGenController.shareTemplate';
import removeShare from '@salesforce/apex/DocGenController.removeShare';
import searchUsersAndGroups from '@salesforce/apex/DocGenController.searchUsersAndGroups';

const COLUMNS = [
    { label: 'Name', fieldName: 'UserOrGroupName' },
    { label: 'Type', fieldName: 'RowCause' }, // Usually 'Manual' for shares we create
    { label: 'Access Level', fieldName: 'AccessLevel' },
    { type: 'button-icon', typeAttributes: {
        iconName: 'utility:delete',
        name: 'delete',
        title: 'Remove Access',
        variant: 'bare',
        disabled: { fieldName: 'isOwner' } // Cannot delete Owner share
    }, initialWidth: 50 }
];

export default class DocGenSharing extends LightningElement {
    @api recordId; // Template ID
    
    @track shares = [];
    @track searchResults = [];
    @track selectedRecord = null;
    
    searchTerm = '';
    selectedAccess = 'Read';
    isSearching = false;
    
    columns = COLUMNS;

    get accessOptions() {
        return [
            { label: 'Read Only', value: 'Read' },
            { label: 'Read/Write', value: 'Edit' }
        ];
    }
    
    get hasSearchResults() {
        return this.searchResults && this.searchResults.length > 0;
    }
    
    get isShareDisabled() {
        return !this.selectedRecord;
    }

    connectedCallback() {
        this.loadShares();
    }

    loadShares() {
        if (!this.recordId) return;
        getTemplateShares({ templateId: this.recordId })
            .then(data => {
                this.shares = data.map(row => ({
                    ...row,
                    isOwner: row.RowCause === 'Owner'
                }));
            })
            .catch(error => {
                this.showToast('Error', 'Error loading shares: ' + error.body?.message, 'error');
            });
    }

    // --- Search Logic ---
    handleSearchChange(event) {
        this.searchTerm = event.detail.value;
        if (this.searchTerm.length < 2) {
            this.searchResults = [];
            return;
        }
        
        this.isSearching = true;
        searchUsersAndGroups({ searchTerm: this.searchTerm })
            .then(results => {
                this.searchResults = (results || []).map(r => ({
                    ...r,
                    Icon: (r.Icon && String(r.Icon).trim()) ? r.Icon : 'standard:user'
                }));
            })
            .catch(error => {
                console.error(error);
            })
            .finally(() => {
                this.isSearching = false;
            });
    }

    handleSelectResult(event) {
        const id = event.currentTarget.dataset.id;
        this.selectedRecord = this.searchResults.find(r => r.Id === id);
        this.searchResults = []; 
        this.searchTerm = ''; // Clear search input visually? Or keep it? keeping it clear
    }
    
    handleClearSelection() {
        this.selectedRecord = null;
    }

    handleAccessChange(event) {
        this.selectedAccess = event.detail.value;
    }

    // --- Actions ---
    handleShare() {
        if (!this.selectedRecord) return;
        
        shareTemplate({ 
            templateId: this.recordId, 
            userOrGroupId: this.selectedRecord.Id, 
            accessLevel: this.selectedAccess 
        })
        .then(() => {
            this.showToast('Success', 'Template shared successfully.', 'success');
            this.handleClearSelection();
            this.loadShares();
        })
        .catch(error => {
            this.showToast('Error', 'Share failed: ' + (error.body?.message || error.message), 'error');
        });
    }

    handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;
        
        if (actionName === 'delete') {
            removeShare({ shareId: row.Id })
                .then(() => {
                    this.showToast('Success', 'Access removed.', 'success');
                    this.loadShares();
                })
                .catch(error => {
                    this.showToast('Error', 'Remove failed: ' + (error.body?.message || error.message), 'error');
                });
        }
    }
    
    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}