public with sharing class DocGenDataRetriever {
    
    /**
     * Executes a dynamic SOQL query based on the fields configuration and record ID.
     * @param recordId The ID of the root record.
     * @param baseObject The API name of the base object.
     * @param fieldsConfig The comma-separated list of fields and subqueries (SELECT part).
     * @return Map<String, Object> The queried data.
     */
    public static Map<String, Object> getRecordData(Id recordId, String baseObject, String fieldsConfig) {
        if (String.isBlank(baseObject) || String.isBlank(fieldsConfig) || recordId == null) {
            throw new AuraHandledException('Invalid parameters for data retrieval.');
        }

        // Basic sanity check to prevent obvious injection if not using binding (though we use binding for ID)
        // In a real robust system, we would parse fieldsConfig more strictly.
        // For now, we assume the admin configuring this knows SOQL.
        
        // Parse and validate fields
        Set<String> validFields = new Set<String>();
        SObjectType objType = Schema.getGlobalDescribe().get(baseObject);
        if (objType == null) {
             throw new AuraHandledException('Invalid object: ' + baseObject);
        }
        Map<String, SObjectField> fieldMap = objType.getDescribe().fields.getMap();
        
        // Simple regex to split top-level fields vs subqueries is hard.
        // But the input `fieldsConfig` comes from our builder: "Field1, Field2, (SELECT ...)"
        // We can try to split by comma, but subqueries contain commas.
        // A safer approach: Catch the exception or use a smarter split.
        // Given complexity of parsing subqueries, we will wrap the query in a Try/Catch with Field Validation logic *if* straightforward query fails?
        // No, user wants us to skip invalid fields.
        
        // Strategy:
        // 1. Split by comma (ignoring parens).
        // 2. For each part:
        //    a. If subquery: Keep as is (or validate subquery object/fields if ambitious).
        //    b. If field: Check existance. Check for custom field suffix.
        
        List<String> queryParts = new List<String>();
        String currentPart = '';
        Integer parenLevel = 0;
        
        for (Integer i = 0; i < fieldsConfig.length(); i++) {
            String charAt = fieldsConfig.substring(i, i+1);
            if (charAt == '(') parenLevel++;
            if (charAt == ')') parenLevel--;
            
            if (charAt == ',' && parenLevel == 0) {
                queryParts.add(currentPart.trim());
                currentPart = '';
            } else {
                currentPart += charAt;
            }
        }
        queryParts.add(currentPart.trim()); // Last part
        
        String cleanSelect = '';
        for (String part : queryParts) {
            String cleanPart = part;
            
            // Check if it is a subquery
            // Allow for "(SELECT" or "( SELECT" etc.
            String upperPart = part.toUpperCase();
            if (part.startsWith('(') && upperPart.contains('SELECT') && upperPart.contains('FROM')) {
                // Keep subqueries as is for now (too complex to validate fully without full parser)
            } else {
                 // Is it a relationship field? e.g. Account.Name
                 String fieldName = part.trim();
                 if (String.isBlank(fieldName)) continue;
                 
                 // Handle "Tier" vs "Tier__c"
                 // Check if field exists on base object
                 if (!fieldMap.containsKey(fieldName)) {
                     // Try appending __c if missing
                     if (!fieldName.endsWithIgnoreCase('__c') && fieldMap.containsKey(fieldName + '__c')) {
                         cleanPart = fieldName + '__c';
                     } else if (fieldName.contains('.')) {
                         // Relationship field: e.g. Account.Name or custom__r.Field__c
                         List<String> relParts = fieldName.split('\\.');
                         if (relParts.size() == 2) {
                             String relName = relParts[0];
                             Boolean relFound = false;
                             for (Schema.SObjectField sof : fieldMap.values()) {
                                 Schema.DescribeFieldResult dfr = sof.getDescribe();
                                 if (dfr.getRelationshipName() == relName) {
                                     relFound = true;
                                     break;
                                 }
                             }
                             if (!relFound) {
                                 System.debug(LoggingLevel.WARN, 'DocGen: Relationship not found, skipping: ' + fieldName);
                                 continue;
                             }
                         }
                     } else {
                         // Field does not exist. SKIP it to prevent crash.
                         System.debug(LoggingLevel.WARN, 'DocGen: Field not found, skipping: ' + fieldName);
                         continue; 
                     }
                 }
            }
            
            if (String.isNotBlank(cleanSelect)) cleanSelect += ', ';
            cleanSelect += cleanPart;
        }
        
        if (String.isBlank(cleanSelect)) cleanSelect = 'Id'; // Fallback
        
        String query = 'SELECT ' + cleanSelect + ' FROM ' + String.escapeSingleQuotes(baseObject) + ' WHERE Id = :recordId LIMIT 1';
        
        System.debug(LoggingLevel.INFO, 'DocGen Query: ' + query);

        try {
            List<SObject> results = Database.query(query, AccessLevel.USER_MODE);
            if (results.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'DocGen: Query returned no results for ID: ' + recordId);
                return null;
            }
            // Optimization: Use manual mapping to avoid JSON.serialize Heap Spike
            return mapSObject(results[0]);
        } catch (Exception e) {
             // Fallback: If stripping failed (e.g. subquery error), return clear error
            System.debug(LoggingLevel.ERROR, 'DocGen: Query Execution Error: ' + e.getMessage());
            throw new AuraHandledException('Error executing query. Please verify your template configuration.');
        }
    }

    private static Map<String, Object> mapSObject(SObject record) {
        Map<String, Object> data = new Map<String, Object>();
        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
        
        for (String key : populatedFields.keySet()) {
            try {
                Object value = populatedFields.get(key);
                
                if (value instanceof List<SObject>) {
                    List<Map<String, Object>> childList = new List<Map<String, Object>>();
                    for (SObject child : (List<SObject>) value) {
                        childList.add(mapSObject(child));
                    }
                    data.put(key, new Map<String, Object>{ 'totalSize' => childList.size(), 'records' => childList });
                } else if (value instanceof SObject) {
                    Map<String, Object> parentMap = mapSObject((SObject) value);
                    // Ensure parent record Id is always available for image resolution
                    if (!parentMap.containsKey('Id')) {
                        try {
                            parentMap.put('Id', ((SObject) value).Id);
                        } catch (Exception ignored) {
                            // Id may not be accessible in all contexts
                        }
                    }
                    data.put(key, parentMap);
                } else if (value instanceof Address) {
                     Address addr = (Address) value;
                     data.put(key, new Map<String, Object>{
                         'street' => addr.getStreet(),
                         'city' => addr.getCity(), 
                         'state' => addr.getState(),
                         'postalCode' => addr.getPostalCode(),
                         'country' => addr.getCountry()
                     });
                } else if (value instanceof Location) {
                     Location loc = (Location) value;
                     data.put(key, new Map<String, Object>{
                         'latitude' => loc.getLatitude(),
                         'longitude' => loc.getLongitude()
                     });
                } else {
                    data.put(key, value);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DocGen: Error mapping field ' + key + ': ' + e.getMessage());
                // Skip this field but allow others
            }
        }
        return data;
    }
}