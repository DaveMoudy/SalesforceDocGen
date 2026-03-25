/**
 * Interface for custom Apex data providers in DocGen.
 *
 * Implement this interface to supply custom data to DocGen templates
 * from any source — external APIs, computed fields, cross-object aggregations,
 * Apex wrappers, or anything SOQL can't reach.
 *
 * The returned Map must follow the same structure that DocGen's merge engine expects:
 *
 *   Simple fields:
 *     'Name' => 'Acme Corp'
 *     'Amount' => 50000
 *     'CloseDate' => Date.today()
 *
 *   Parent lookups (nested map):
 *     'Account' => new Map<String, Object>{ 'Name' => 'Acme', 'Industry' => 'Tech' }
 *
 *   Child loops (map with 'records' key):
 *     'Contacts' => new Map<String, Object>{
 *         'records' => new List<Object>{
 *             new Map<String, Object>{ 'FirstName' => 'Alice', 'LastName' => 'Smith' },
 *             new Map<String, Object>{ 'FirstName' => 'Bob', 'LastName' => 'Jones' }
 *         }
 *     }
 *
 * Example implementation:
 *
 *   public class InvoiceDataProvider implements DocGenDataProvider {
 *       public Map<String, Object> getData(Id recordId) {
 *           Opportunity opp = [SELECT Name, Amount, Account.Name FROM Opportunity WHERE Id = :recordId];
 *           Map<String, Object> data = new Map<String, Object>();
 *           data.put('Name', opp.Name);
 *           data.put('Amount', opp.Amount);
 *           data.put('Account', new Map<String, Object>{ 'Name' => opp.Account.Name });
 *           data.put('TaxRate', 0.0825); // Computed field — no SOQL equivalent
 *           data.put('TaxAmount', opp.Amount * 0.0825);
 *           data.put('Total', opp.Amount * 1.0825);
 *           return data;
 *       }
 *   }
 *
 * To use: set the template's Query_Config__c to:
 *   {"v":4,"provider":"InvoiceDataProvider"}
 *
 * DocGen will instantiate the class, call getData(), and merge the result
 * into your template using the same {FieldName} tags as SOQL-based templates.
 */
public interface DocGenDataProvider {
    /**
     * Returns a map of field names to values for the given record.
     * @param recordId The source record ID (may be null for standalone data)
     * @return Map<String, Object> with field names as keys
     */
    Map<String, Object> getData(Id recordId);

    /**
     * Returns the list of merge tag names this provider supplies.
     * Used by the query builder UI to display available tags.
     * Use dot notation for parent lookups (e.g., 'Account.Name')
     * and prefix child loops with '#' (e.g., '#LineItems', 'LineItems.Product', '/LineItems').
     * @return List of field/tag names
     */
    List<String> getFieldNames();
}
