//
//  CloudKitIncrementalStore.swift
//
//
//  Created by Nofel Mahmood on 26/03/2015.
//
//

import CoreData
import CloudKit
import ObjectiveC

let CKSIncrementalStoreCloudDatabaseCustomZoneName="CKSIncrementalStoreZone"
let CKSIncrementalStoreCloudDatabaseSyncSubcriptionName="CKSIncrementalStore_Sync_Subcription"

let CKSIncrementalStoreLocalStoreChangeTypeAttributeName="cks_LocalStore_Attribute_ChangeType"
let CKSIncrementalStoreLocalStoreRecordIDAttributeName="cks_LocalStore_Attribute_RecordID"
let CKSIncrementalStoreLocalStoreRecordEncodedValuesAttributeName = "cks_LocalStore_Attribute_EncodedValues"

let CKSIncrementalStoreDidStartSyncOperationNotification = "CKSIncrementalStoreDidStartSyncOperationNotification"
let CKSIncrementalStoreDidFinishSyncOperationNotification = "CKSIncrementalStoreDidFinishSyncOperationNotification"

let CKSIncrementalStoreSyncConflictPolicyOption = "CKSIncrementalStoreSyncConflictPolicyOption"

enum CKSLocalStoreRecordChangeType: Int16
{
    case RecordNoChange = 0
    case RecordUpdated  = 1
    case RecordDeleted  = 2
}


class CKSIncrementalStore: NSIncrementalStore {
    
    private var syncOperation:CKSIncrementalStoreSyncOperation?
    private var cloudStoreSetupOperation:CKSIncrementalStoreCloudStoreSetupOperation?
    private var cksStoresSyncConflictPolicy:CKSStoresSyncConflictPolicy = CKSStoresSyncConflictPolicy.GreaterModifiedDateWins
    private var database:CKDatabase?
    private var operationQueue:NSOperationQueue?
    private var backingPersistentStoreCoordinator:NSPersistentStoreCoordinator?
    private var backingPersistentStore:NSPersistentStore?
    private lazy var backingMOC:NSManagedObjectContext={
        
        var moc=NSManagedObjectContext(concurrencyType: NSManagedObjectContextConcurrencyType.PrivateQueueConcurrencyType)
        moc.persistentStoreCoordinator=self.backingPersistentStoreCoordinator
        moc.retainsRegisteredObjects=true
        return moc
        }()
    var recordConflictResolutionBlock:((clientRecord:CKRecord,serverRecord:CKRecord)->CKRecord)?
    
    override class func initialize()
    {
        NSPersistentStoreCoordinator.registerStoreClass(self, forStoreType: self.type)
    }
    
    override init(persistentStoreCoordinator root: NSPersistentStoreCoordinator, configurationName name: String?, URL url: NSURL, options: [NSObject : AnyObject]?) {
        
        self.database=CKContainer.defaultContainer().privateCloudDatabase
        if options != nil
        {
            if options![CKSIncrementalStoreSyncConflictPolicyOption] != nil
            {
                var syncConflictPolicy = options![CKSIncrementalStoreSyncConflictPolicyOption] as! NSNumber
                
                switch(syncConflictPolicy.shortValue)
                {
                case CKSStoresSyncConflictPolicy.ClientRecordWins.rawValue:
                    self.cksStoresSyncConflictPolicy = CKSStoresSyncConflictPolicy.ClientRecordWins
                case CKSStoresSyncConflictPolicy.ServerRecordWins.rawValue:
                    self.cksStoresSyncConflictPolicy = CKSStoresSyncConflictPolicy.ServerRecordWins
                case CKSStoresSyncConflictPolicy.ClientTellsWhichWins.rawValue:
                    self.cksStoresSyncConflictPolicy = CKSStoresSyncConflictPolicy.ClientTellsWhichWins
                case CKSStoresSyncConflictPolicy.GreaterModifiedDateWins.rawValue:
                    self.cksStoresSyncConflictPolicy = CKSStoresSyncConflictPolicy.GreaterModifiedDateWins
                case CKSStoresSyncConflictPolicy.KeepBoth.rawValue:
                    self.cksStoresSyncConflictPolicy = CKSStoresSyncConflictPolicy.KeepBoth
                default:
                    break
                }
                
            }
        }
        
        super.init(persistentStoreCoordinator: root, configurationName: name, URL: url, options: options)
        
    }
    
    class var type:String{
        return NSStringFromClass(self)
    }
    
    override func loadMetadata(error: NSErrorPointer) -> Bool {
        
        self.metadata=[
            NSStoreUUIDKey:NSProcessInfo().globallyUniqueString,
            NSStoreTypeKey:self.dynamicType.type
        ]
        var storeURL=self.URL
        var model:AnyObject=(self.persistentStoreCoordinator?.managedObjectModel.copy())!
        for e in model.entities
        {
            var entity=e as! NSEntityDescription
            
            if entity.superentity != nil
            {
                continue
            }
            
            var recordIDAttributeDescription = NSAttributeDescription()
            recordIDAttributeDescription.name=CKSIncrementalStoreLocalStoreRecordIDAttributeName
            recordIDAttributeDescription.attributeType=NSAttributeType.StringAttributeType
            recordIDAttributeDescription.indexed=true
            
            var recordEncodedValuesAttributeDescription = NSAttributeDescription()
            recordEncodedValuesAttributeDescription.name = CKSIncrementalStoreLocalStoreRecordEncodedValuesAttributeName
            recordEncodedValuesAttributeDescription.attributeType = NSAttributeType.BinaryDataAttributeType
            recordEncodedValuesAttributeDescription.indexed = true
            recordEncodedValuesAttributeDescription.optional = true
            
            var recordChangeTypeAttributeDescription = NSAttributeDescription()
            recordChangeTypeAttributeDescription.name = CKSIncrementalStoreLocalStoreChangeTypeAttributeName
            recordChangeTypeAttributeDescription.attributeType = NSAttributeType.Integer16AttributeType
            recordChangeTypeAttributeDescription.indexed = true
            recordChangeTypeAttributeDescription.defaultValue = NSNumber(short: CKSLocalStoreRecordChangeType.RecordNoChange.rawValue)
            
            entity.properties.append(recordIDAttributeDescription)
            entity.properties.append(recordEncodedValuesAttributeDescription)
            entity.properties.append(recordChangeTypeAttributeDescription)
            
        }
        
        
        self.backingPersistentStoreCoordinator=NSPersistentStoreCoordinator(managedObjectModel: model as! NSManagedObjectModel)
        
        var error: NSError? = nil
        self.backingPersistentStore = self.backingPersistentStoreCoordinator?.addPersistentStoreWithType(NSSQLiteStoreType, configuration: nil, URL: storeURL, options: nil, error: &error)
        
        if self.backingPersistentStore == nil
        {
            print("Backing Store Error \(error)")
            return false
        }
        
        self.operationQueue = NSOperationQueue()
        self.operationQueue?.maxConcurrentOperationCount = 1
        
        self.triggerSync()
        
        return true
        
    }
    
    internal func handlePush(#userInfo:[NSObject : AnyObject])
    {
        var ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo)
        
        if ckNotification.notificationType == CKNotificationType.RecordZone
        {
            var recordZoneNotification = CKRecordZoneNotification(fromRemoteNotificationDictionary: userInfo)
            if recordZoneNotification.recordZoneID.zoneName == CKSIncrementalStoreCloudDatabaseCustomZoneName
            {
                self.triggerSync()
            }
            
        }
    }
    
    internal func triggerSync()
    {
        if self.operationQueue != nil && self.operationQueue!.operationCount > 0
        {
            return
        }
        
        var syncOperationBlock = ({()->Void in
            
            self.syncOperation = CKSIncrementalStoreSyncOperation(persistentStoreCoordinator: self.backingPersistentStoreCoordinator, conflictPolicy: self.cksStoresSyncConflictPolicy)
            self.syncOperation?.syncConflictResolutionBlock = self.recordConflictResolutionBlock
            self.syncOperation?.syncCompletionBlock =  ({(error) -> Void in
                
                if error == nil
                {
                    print("Sync Performed Successfully")
                    NSOperationQueue.mainQueue().addOperationWithBlock({ () -> Void in
                        
                        NSNotificationCenter.defaultCenter().postNotificationName(CKSIncrementalStoreDidFinishSyncOperationNotification, object: self)
                        
                    })
                    
                }
                else
                {
                    print("Sync unSuccessful")
                    NSOperationQueue.mainQueue().addOperationWithBlock({ () -> Void in
                        
                        NSNotificationCenter.defaultCenter().postNotificationName(CKSIncrementalStoreDidFinishSyncOperationNotification, object: self, userInfo: error!.userInfo)
                    })
                }
                
            })
            self.operationQueue?.addOperation(self.syncOperation!)
        })
        
        
        if NSUserDefaults.standardUserDefaults().objectForKey(CKSIncrementalStoreCloudStoreCustomZoneKey) == nil || NSUserDefaults.standardUserDefaults().objectForKey(CKSIncrementalStoreCloudStoreZoneSubcriptionKey) == nil
        {
            self.cloudStoreSetupOperation = CKSIncrementalStoreCloudStoreSetupOperation(cloudDatabase: self.database)
            self.cloudStoreSetupOperation?.setupOperationCompletionBlock = ({(customZoneWasCreated,customZoneSubscriptionWasCreated,error)->Void in
                
                if error == nil
                {
                    syncOperationBlock()
                }
            })
            self.operationQueue?.addOperation(self.cloudStoreSetupOperation!)
        }
        else
        {
            syncOperationBlock()
        }
        
        
        NSNotificationCenter.defaultCenter().postNotificationName(CKSIncrementalStoreDidStartSyncOperationNotification, object: self)
        
        
    }
    
    override func executeRequest(request: NSPersistentStoreRequest, withContext context: NSManagedObjectContext, error: NSErrorPointer) -> AnyObject? {
        
        
        if request.requestType == NSPersistentStoreRequestType.FetchRequestType
        {
            var fetchRequest:NSFetchRequest = request as! NSFetchRequest
            return self.executeInResponseToFetchRequest(fetchRequest, context: context, error: error)
        }
            
        else if request.requestType==NSPersistentStoreRequestType.SaveRequestType
        {
            var saveChangesRequest:NSSaveChangesRequest = request as! NSSaveChangesRequest
            return self.executeInResponseToSaveChangesRequest(saveChangesRequest, context: context, error: error)
        }
        else
        {
            var exception=NSException(name: "Unknown Request Type", reason: "Unknown Request passed to NSManagedObjectContext", userInfo: nil)
            exception.raise()
        }
        
        return []
    }
    
    override func newValuesForObjectWithID(objectID: NSManagedObjectID, withContext context: NSManagedObjectContext, error: NSErrorPointer) -> NSIncrementalStoreNode? {
        
        var recordID:String = self.referenceObjectForObjectID(objectID) as! String
        var propertiesToFetch = objectID.entity.propertiesByName.values.array.filter({(object) -> Bool in
            
            if object is NSRelationshipDescription
            {
                var relationshipDescription: NSRelationshipDescription = object as! NSRelationshipDescription
                return relationshipDescription.toMany == false
            }
            return true
            
        }).map({(object) -> String in
            
            var propertyDescription: NSPropertyDescription = object as! NSPropertyDescription
            return propertyDescription.name
        })
        
        var predicate = NSPredicate(format: "%K == %@", CKSIncrementalStoreLocalStoreRecordIDAttributeName,recordID)
        var backingFetchRequest = self.backingFetchRequest(fromFetchRequest: NSFetchRequest(entityName: objectID.entity.name!), backingRequestPredicate: predicate, backingRequestResultType: NSFetchRequestResultType.DictionaryResultType, propertiesToFetch: propertiesToFetch, backingRequestFetchLimit: 1)
        
        var error: NSError?
        var results = self.backingMOC.executeFetchRequest(backingFetchRequest, error: &error)
        
        if error == nil && results?.count > 0
        {
            var backingObjectValues = results?.first as! Dictionary<String,NSObject>
            for (key,value) in backingObjectValues
            {
                if value is NSManagedObject
                {
                    var managedObject: NSManagedObject = value as! NSManagedObject
                    var recordID: String = managedObject.valueForKey(CKSIncrementalStoreLocalStoreRecordIDAttributeName) as! String
                    var entity: NSEntityDescription = self.persistentStoreCoordinator!.managedObjectModel.entitiesByName[managedObject.entity.name!] as! NSEntityDescription
                    
                    var objectID = self.newObjectIDForEntity(entity, referenceObject: recordID)
                    backingObjectValues[key] = objectID
                }
            }
            
            var incrementalStoreNode = NSIncrementalStoreNode(objectID: objectID, withValues: backingObjectValues, version: 1)
            return incrementalStoreNode
        }
        
        return nil
    }
    
    override func newValueForRelationship(relationship: NSRelationshipDescription, forObjectWithID objectID: NSManagedObjectID, withContext context: NSManagedObjectContext?, error: NSErrorPointer) -> AnyObject? {
        
        var recordID: String = self.referenceObjectForObjectID(objectID) as! String
        var fetchRequest: NSFetchRequest = NSFetchRequest(entityName: objectID.entity.name!)
        var predicate: NSPredicate = NSPredicate(format: "%K == %@", CKSIncrementalStoreLocalStoreRecordIDAttributeName,recordID)
        fetchRequest.predicate = predicate
        var results = self.backingMOC.executeFetchRequest(fetchRequest, error: error)
        var requestError: NSError?
        
        if error == nil && results?.count > 0
        {
            var managedObject: NSManagedObject = results?.first as! NSManagedObject
            var relationshipValues: Set<NSObject> = managedObject.valueForKey(relationship.name) as! Set<NSObject>
            return Array(relationshipValues).map({(object)->NSManagedObjectID in
                
                var value: NSManagedObject = object as! NSManagedObject
                var recordID: String = value.valueForKey(CKSIncrementalStoreLocalStoreRecordIDAttributeName) as! String
                var objectID: NSManagedObjectID = self.newObjectIDForEntity(value.entity, referenceObject: recordID)
                return objectID
            })
        }
        
        return []
    }
    
    override func obtainPermanentIDsForObjects(array: [AnyObject], error: NSErrorPointer) -> [AnyObject]? {
        
        return array.map({ (object)->NSManagedObjectID in
            
            var insertedObject:NSManagedObject = object as! NSManagedObject
            var newRecordID: String = NSUUID().UUIDString
            return self.newObjectIDForEntity(insertedObject.entity, referenceObject: newRecordID)
            
        })
    }
    
    // MARK : Fetch Request
    func backingFetchRequest(fromFetchRequest fetchRequest: NSFetchRequest, backingRequestPredicate: NSPredicate, backingRequestResultType: NSFetchRequestResultType, propertiesToFetch: [AnyObject]?, backingRequestFetchLimit: Int?) -> NSFetchRequest
    {
        var backingFetchRequestEntity: NSEntityDescription = self.backingMOC.persistentStoreCoordinator!.managedObjectModel.entitiesByName[fetchRequest.entityName!] as! NSEntityDescription
        var backingFetchRequest: NSFetchRequest = NSFetchRequest(entityName: backingFetchRequestEntity.name!)
        backingFetchRequest.predicate = self.predicateForBackingFetchRequest(currentPredicate: backingFetchRequest.predicate, backingPredicate: backingRequestPredicate )
        
        backingFetchRequest.predicate = self.predicateForBackingFetchRequest(currentPredicate: fetchRequest.predicate, backingPredicate: backingRequestPredicate)
        backingFetchRequest.sortDescriptors = fetchRequest.sortDescriptors
        backingFetchRequest.propertiesToGroupBy = fetchRequest.propertiesToGroupBy
        backingFetchRequest.resultType = backingRequestResultType
        backingFetchRequest.propertiesToFetch = propertiesToFetch
        
        if backingRequestFetchLimit != nil
        {
            backingFetchRequest.fetchLimit = backingRequestFetchLimit!
        }
        
        return backingFetchRequest
    }
    
    func predicateForBackingFetchRequest(currentPredicate predicate: NSPredicate?, backingPredicate: NSPredicate) -> NSPredicate
    {
        if predicate == nil
        {
            return backingPredicate
        }
        else
        {
            return NSCompoundPredicate.andPredicateWithSubpredicates([backingPredicate, predicate!])
        }
    }
    
    func executeInResponseToFetchRequest(fetchRequest:NSFetchRequest,context:NSManagedObjectContext,error:NSErrorPointer)->NSArray
    {
        var backingRequestPredicate: NSPredicate = NSPredicate(format: "%K != %@", CKSIncrementalStoreLocalStoreRecordIDAttributeName, NSNumber(short: CKSLocalStoreRecordChangeType.RecordDeleted.rawValue))
        
        var backingFetchRequest = self.backingFetchRequest(fromFetchRequest: fetchRequest, backingRequestPredicate: backingRequestPredicate, backingRequestResultType: NSFetchRequestResultType.DictionaryResultType, propertiesToFetch: [CKSIncrementalStoreLocalStoreRecordIDAttributeName], backingRequestFetchLimit: nil)
        
        var backingFetchError: NSError?
        var resultsFromLocalStore = self.backingMOC.executeFetchRequest(backingFetchRequest, error: &backingFetchError)
        
        if backingFetchError == nil && resultsFromLocalStore!.count > 0
        {
            resultsFromLocalStore = resultsFromLocalStore?.map({(result)->NSManagedObject in
                
                var resultDictionary: Dictionary<String,NSObject> = result as! Dictionary<String,NSObject>
                var recordID: String = resultDictionary[CKSIncrementalStoreLocalStoreRecordIDAttributeName] as! String
                var objectID = self.newObjectIDForEntity((fetchRequest.entity)!, referenceObject: recordID)
                var object = context.objectWithID(objectID)
                return object
                
            })
            
            return resultsFromLocalStore!
        }
        return []
    }
    
    // MARK : SaveChanges Request
    private func executeInResponseToSaveChangesRequest(saveRequest:NSSaveChangesRequest,context:NSManagedObjectContext,error:NSErrorPointer)->NSArray
    {
        self.insertObjectsInBackingStore(context.insertedObjects, mainContext: context)
        self.setObjectsInBackingStore(context.updatedObjects, toChangeType: CKSLocalStoreRecordChangeType.RecordUpdated)
        self.setObjectsInBackingStore(context.deletedObjects, toChangeType: CKSLocalStoreRecordChangeType.RecordDeleted)
        
        var error:NSErrorPointer = nil
        self.backingMOC.save(error)
        self.triggerSync()
        
        return NSArray()
    }
    
    func objectIDForBackingObjectForEntity(entityName: String, withReferenceObject referenceObject: String?) -> NSManagedObjectID?
    {
        if referenceObject == nil
        {
            return nil
        }
        
        var fetchRequest: NSFetchRequest = NSFetchRequest(entityName: entityName)
        fetchRequest.resultType = NSFetchRequestResultType.ManagedObjectIDResultType
        fetchRequest.fetchLimit = 1
        fetchRequest.predicate = NSPredicate(format: "%K == %@", CKSIncrementalStoreLocalStoreRecordIDAttributeName,referenceObject!)
        var error: NSError?
        var results = self.backingMOC.executeFetchRequest(fetchRequest, error: &error)
        
        if error == nil && results!.count > 0
        {
            return results!.last as? NSManagedObjectID
        }
        
        return nil
    }
    
    private func setRelationshipValuesForBackingObject(backingObject:NSManagedObject,sourceObject:NSManagedObject)
    {
        for relationship in sourceObject.entity.relationshipsByName.values.array as! [NSRelationshipDescription]
        {
            if sourceObject.hasFaultForRelationshipNamed(relationship.name) || sourceObject.valueForKey(relationship.name) == nil
            {
                continue
            }
            
            if relationship.toMany == true
            {
                var relationshipValue: Set<NSObject> = sourceObject.valueForKey(relationship.name) as! Set<NSObject>
                var backingRelationshipValue: Set<NSObject> = Set<NSObject>()
                
                for relationshipObject in relationshipValue
                {
                    var relationshipManagedObject: NSManagedObject = relationshipObject as! NSManagedObject
                    if relationshipManagedObject.objectID.temporaryID == false
                    {
                        var referenceObject: String = self.referenceObjectForObjectID(relationshipManagedObject.objectID) as! String
                        
                        var backingRelationshipObjectID = self.objectIDForBackingObjectForEntity(relationship.destinationEntity!.name!, withReferenceObject: referenceObject)
                        
                        if backingRelationshipObjectID != nil
                        {
                            var backingRelationshipObject = backingObject.managedObjectContext?.existingObjectWithID(backingRelationshipObjectID!, error: nil)
                            
                            if backingRelationshipObject != nil
                            {
                                backingRelationshipValue.insert(backingRelationshipObject!)
                            }
                        }
                    }
                }
                
                backingObject.setValue(backingRelationshipValue, forKey: relationship.name)
            }
            else
            {
                var relationshipValue: NSManagedObject = sourceObject.valueForKey(relationship.name) as! NSManagedObject
                if relationshipValue.objectID.temporaryID == false
                {
                    var referenceObject: String = self.referenceObjectForObjectID(relationshipValue.objectID) as! String
                    
                    var backingRelationshipObjectID = self.objectIDForBackingObjectForEntity(relationship.destinationEntity!.name!, withReferenceObject: referenceObject)
                    
                    if backingRelationshipObjectID != nil
                    {
                        var backingRelationshipObject = self.backingMOC.existingObjectWithID(backingRelationshipObjectID!, error: nil)
                        if backingRelationshipObject != nil
                        {
                            backingObject.setValue(backingRelationshipObject, forKey: relationship.name)
                        }
                    }
                }
            }
        }
    }
    
    func insertObjectsInBackingStore(objects:Set<NSObject>, mainContext: NSManagedObjectContext)
    {
        for object in objects
        {
            var sourceObject: NSManagedObject = object as! NSManagedObject
            var managedObject:NSManagedObject = NSEntityDescription.insertNewObjectForEntityForName((sourceObject.entity.name)!, inManagedObjectContext: self.backingMOC) as! NSManagedObject
            var keys = sourceObject.entity.attributesByName.keys.array
            var dictionary = sourceObject.dictionaryWithValuesForKeys(keys)
            managedObject.setValuesForKeysWithDictionary(dictionary)
            var referenceObject: String = self.referenceObjectForObjectID(sourceObject.objectID) as! String
            managedObject.setValue(referenceObject, forKey: CKSIncrementalStoreLocalStoreRecordIDAttributeName)
            managedObject.setValue(NSNumber(short: CKSLocalStoreRecordChangeType.RecordUpdated.rawValue), forKey: CKSIncrementalStoreLocalStoreChangeTypeAttributeName)
            self.setRelationshipValuesForBackingObject(managedObject, sourceObject: sourceObject)
            mainContext.willChangeValueForKey("objectID")
            mainContext.obtainPermanentIDsForObjects([(object as! NSManagedObject)], error: nil)
            mainContext.didChangeValueForKey("objectID")
            var saveError: NSError?
            self.backingMOC.save(&saveError)
        }
    }
    
    private func setObjectsInBackingStore(objects:Set<NSObject>,toChangeType changeType:CKSLocalStoreRecordChangeType)
    {
        let predicateObjectRecordIDKey = "objectRecordID"
        var predicate: NSPredicate = NSPredicate(format: "%K == $objectRecordID", CKSIncrementalStoreLocalStoreRecordIDAttributeName)
        
        for object in objects
        {
            var sourceObject: NSManagedObject = object as! NSManagedObject
            var fetchRequest: NSFetchRequest = NSFetchRequest(entityName: sourceObject.entity.name!)
            var recordID: String = self.referenceObjectForObjectID(sourceObject.objectID) as! String
            fetchRequest.predicate = predicate.predicateWithSubstitutionVariables([predicateObjectRecordIDKey:recordID])
            fetchRequest.fetchLimit = 1
            var requestError: NSError?
            var results = self.backingMOC.executeFetchRequest(fetchRequest, error: &requestError)
            if requestError == nil && results!.count > 0
            {
                var backingObject: NSManagedObject = results!.last as! NSManagedObject
                var keys = self.persistentStoreCoordinator!.managedObjectModel.entitiesByName[sourceObject.entity.name!]!.attributesByName.keys.array
                var sourceObjectValues = sourceObject.dictionaryWithValuesForKeys(keys)
                backingObject.setValuesForKeysWithDictionary(sourceObjectValues)
                backingObject.setValue(NSNumber(short: changeType.rawValue), forKey: CKSIncrementalStoreLocalStoreChangeTypeAttributeName)
                self.setRelationshipValuesForBackingObject(backingObject, sourceObject: sourceObject)
                self.backingMOC.save(nil)
            }
        }
    }
}
