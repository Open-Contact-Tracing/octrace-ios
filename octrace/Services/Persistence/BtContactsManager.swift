import Foundation
import CoreLocation

class BtContactsManager {
    
    private static let path = DataManager.docsDir.appendingPathComponent("bt-contacts").path
    
    private init() {
    }
    
    static var contacts: [String:BtContactHealth] {
        get {
            guard let data = NSKeyedUnarchiver.unarchiveObject(withFile: path) as? Data else { return [:] }
            do {
                return try PropertyListDecoder().decode([String:BtContactHealth].self, from: data)
            } catch {
                print("Retrieve Failed")
                
                return [:]
            }
        }
        
        set {
            do {
                let data = try PropertyListEncoder().encode(newValue)
                NSKeyedArchiver.archiveRootObject(data, toFile: path)
            } catch {
                print("Save Failed")
            }
        }
    }
    
    static func removeOldContacts() {
        let expirationTimestamp = DataManager.expirationTimestamp()
        
        let newContacts = contacts.filter { (_, health) in
            health.contact.encounters.first!.tst > expirationTimestamp
        }
        
        contacts = newContacts
    }
    
    static func matchContacts(_ keysData: KeysData) -> BtContact? {
        let newContacts = contacts
        
        var lastInfectedContact: BtContact? = nil
        
        newContacts.forEach { (id, health) in
            let contactTst = health.contact.encounters.first!.tst
            let contactDay = SecurityUtil.getDayNumber(from: contactTst)
            if keysData.keys.contains(where: { $0.day == contactDay &&
                SecurityUtil.match(id, contactTst, $0) }) {
                health.infected = true
                lastInfectedContact = health.contact
            }
        }
        
        contacts = newContacts
        
        return lastInfectedContact
    }

    static func addContact(_ id: String, _ encounter: BtEncounter) {
        var newContacts = contacts
        
        if let health = newContacts[id] {
            health.contact.encounters.append(encounter)
        } else {
            newContacts[id] = BtContactHealth(BtContact(id, [encounter]))
        }
        
        contacts = newContacts
    }
    
}

class BtContactHealth : Codable {
    let contact: BtContact
    var infected: Bool = false
    
    init(_ contact: BtContact) {
        self.contact = contact
    }
}

class BtContact : Codable {
    let id: String
    var encounters: [BtEncounter]
    
    init(_ id: String, _ encounters: [BtEncounter]) {
        self.id = id
        self.encounters = encounters
    }
}

struct BtEncounter : Codable {
    let rssi: Int
    let lat: Double
    let lng: Double
    let accuracy: Int
    let tst: Int64
}