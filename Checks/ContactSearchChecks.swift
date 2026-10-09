import Foundation

@main
struct ContactSearchChecks {
    static func main() {
        let mobile = DevicePhoneNumber(id: "mobile", label: "Mobil", value: "+43 (664) 123-45-67")
        let office = DevicePhoneNumber(id: "office", label: "Arbeit", value: "+43 1 555 500")
        let person = DeviceContact(id: "test", name: "Anna Müller", numbers: [mobile, office])
        precondition(person.containsPhoneNumber("00436641234567"))
        precondition(person.containsPhoneNumber("+43 1 555500"))
        precondition(!person.containsPhoneNumber("500"))
        precondition(!person.containsPhoneNumber(""))
        precondition(!person.containsPhoneNumber("+436641234568"))
        precondition(DeviceContact.resolvedContact(in: [person], number: "00436641234567")?.name == person.name)
        let duplicate = DeviceContact(id: "other", name: "Anderer Kontakt", numbers: [mobile])
        precondition(DeviceContact.resolvedContact(in: [person, duplicate], number: mobile.value) == nil)
        precondition(DeviceContact.resolvedContact(in: [person], number: "500") == nil)
        precondition(person.matches("MULLER"))
        precondition(person.matches("  Anna  "))
        precondition(person.matches("66412345"))
        precondition(person.matches("+43 (664)"))
        precondition(person.matches("555-500"))
        precondition(person.matches(""))
        precondition(!person.matches("Anna 5"))
        precondition(!person.matches("+"))
        precondition(!person.matches("Berger"))
        precondition(person.callContact(for: office).number == office.value)
        precondition(person.callContact(for: mobile).id != person.callContact(for: office).id)
        print("PASS: case/diacritic search, formatted numbers, multiple numbers and selection identity")
    }
}
