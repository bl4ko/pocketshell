import Crypto
import Foundation

public enum OpenSSHPublicKey {
    public static func line(for publicKey: P256.Signing.PublicKey, comment: String) -> String {
        var blob = Data()
        appendString(Data("ecdsa-sha2-nistp256".utf8), to: &blob)
        appendString(Data("nistp256".utf8), to: &blob)
        appendString(publicKey.x963Representation, to: &blob)
        return "ecdsa-sha2-nistp256 \(blob.base64EncodedString()) \(comment)"
    }

    private static func appendString(_ value: Data, to blob: inout Data) {
        var length = UInt32(value.count).bigEndian
        blob.append(Data(bytes: &length, count: 4))
        blob.append(value)
    }
}
