import CryptoKit
import Foundation

let key = P256.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())

var blob = Data()
func appendString(_ value: Data) {
    var length = UInt32(value.count).bigEndian
    blob.append(Data(bytes: &length, count: 4))
    blob.append(value)
}
appendString(Data("ecdsa-sha2-nistp256".utf8))
appendString(Data("nistp256".utf8))
appendString(key.publicKey.x963Representation)
print("ecdsa-sha2-nistp256 \(blob.base64EncodedString()) uitest")
