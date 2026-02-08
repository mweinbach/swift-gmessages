import Foundation
import GMProto
@preconcurrency import SwiftProtobuf

/// PBLite is the JSON-array encoding used by Google Messages for Web.
///
/// It encodes a protobuf message as a JSON array, where index = fieldNumber-1.
/// Nested messages are nested arrays.
enum PBLite {
    enum Error: Swift.Error, LocalizedError {
        case expectedJSONArray(Any)
        case expectedString(Any)
        case expectedArray(Any)
        case invalidBase64(String)
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .expectedJSONArray(let got):
                return "Expected JSON array, got \(type(of: got))"
            case .expectedString(let got):
                return "Expected string, got \(type(of: got))"
            case .expectedArray(let got):
                return "Expected array, got \(type(of: got))"
            case .invalidBase64:
                return "Invalid base64"
            case .invalidUTF8:
                return "Invalid UTF-8"
            }
        }
    }

    /// Marshal a protobuf message into PBLite JSON bytes.
    static func marshal(_ message: any SwiftProtobuf.Message) throws -> Data {
        let slice = try serializeToSlice(message)
        return try JSONSerialization.data(withJSONObject: slice, options: [])
    }

    /// Unmarshal PBLite JSON bytes into a protobuf message.
    static func unmarshal<T: SwiftProtobuf.Message>(_ data: Data, as type: T.Type) throws -> T {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        return try unmarshal(obj, as: type)
    }

    /// Unmarshal an already-parsed JSON object into a protobuf message.
    static func unmarshal<T: SwiftProtobuf.Message>(_ obj: Any, as type: T.Type) throws -> T {
        guard let arr = obj as? [Any] else {
            throw Error.expectedJSONArray(obj)
        }
        var decoder = PBLiteDecoder(values: arr, messageType: type)
        var msg = T()
        try msg.decodeMessage(decoder: &decoder)
        return msg
    }

    // MARK: - Binary Field Mapping (pblite.pblite_binary)

    private static func isBinaryField(messageType: any SwiftProtobuf.Message.Type, fieldNumber: Int) -> Bool {
        PBLiteBinaryFields.fieldsByMessageName[messageType.protoMessageName]?.contains(fieldNumber) ?? false
    }

    private enum PBLiteBinaryFields {
        // Keep in sync with `Protos/*` fields annotated with `(pblite.pblite_binary) = true`.
        static let fieldsByMessageName: [String: Set<Int>] = [
            // authentication.proto
            Authentication_SignInGaiaRequest.Inner.protoMessageName: [36],
            Authentication_SignInGaiaResponse.protoMessageName: [2],
            Authentication_RPCGaiaData.UnknownContainer.Item2.Item1.protoMessageName: [1],
            Authentication_RPCGaiaData.UnknownContainer.Item4.protoMessageName: [1, 8],

            // rpc.proto
            Rpc_OutgoingRPCMessage.protoMessageName: [9],
        ]
    }

    // MARK: - Serialization

    private static func serializeToSlice(_ message: any SwiftProtobuf.Message) throws -> [Any] {
        var visitor = PBLiteEncodingVisitor(messageType: type(of: message))
        try message.traverse(visitor: &visitor)
        visitor.trimTrailingNulls()
        return visitor.result
    }

    private struct PBLiteEncodingVisitor: SwiftProtobuf.Visitor {
        let messageType: any SwiftProtobuf.Message.Type
        var result: [Any] = []

        // MARK: - Visitor Basics

        mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {
            setValue(NSNumber(value: value), fieldNumber: fieldNumber)
        }

        mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {
            setValue(NSNumber(value: value), fieldNumber: fieldNumber)
        }

        mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {
            setValue(NSNumber(value: value), fieldNumber: fieldNumber)
        }

        mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {
            setValue(value, fieldNumber: fieldNumber)
        }

        mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {
            if PBLite.isBinaryField(messageType: messageType, fieldNumber: fieldNumber) {
                let data = Data(value.utf8)
                setValue(data.base64EncodedString(), fieldNumber: fieldNumber)
            } else {
                setValue(value, fieldNumber: fieldNumber)
            }
        }

        mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {
            setValue(value.base64EncodedString(), fieldNumber: fieldNumber)
        }

        mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws {
            setValue(value.rawValue, fieldNumber: fieldNumber)
        }

        mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
            if PBLite.isBinaryField(messageType: messageType, fieldNumber: fieldNumber) {
                let data = try value.serializedData()
                setValue(data.base64EncodedString(), fieldNumber: fieldNumber)
            } else {
                let nested = try PBLite.serializeToSlice(value)
                setValue(nested, fieldNumber: fieldNumber)
            }
        }

        mutating func visitSingularGroupField<G: SwiftProtobuf.Message>(value: G, fieldNumber: Int) throws {
            try visitSingularMessageField(value: value, fieldNumber: fieldNumber)
        }

        // MARK: - Repeated / Packed

        mutating func visitRepeatedFloatField(value: [Float], fieldNumber: Int) throws {
            setValue(value.map { NSNumber(value: Double($0)) }, fieldNumber: fieldNumber)
        }

        mutating func visitRepeatedDoubleField(value: [Double], fieldNumber: Int) throws {
            setValue(value.map { NSNumber(value: $0) }, fieldNumber: fieldNumber)
        }

        mutating func visitRepeatedInt32Field(value: [Int32], fieldNumber: Int) throws {
            setValue(value.map { NSNumber(value: Int64($0)) }, fieldNumber: fieldNumber)
        }

        mutating func visitRepeatedInt64Field(value: [Int64], fieldNumber: Int) throws {
            setValue(value.map { NSNumber(value: $0) }, fieldNumber: fieldNumber)
        }

        mutating func visitRepeatedUInt32Field(value: [UInt32], fieldNumber: Int) throws {
            setValue(value.map { NSNumber(value: UInt64($0)) }, fieldNumber: fieldNumber)
        }

        mutating func visitRepeatedUInt64Field(value: [UInt64], fieldNumber: Int) throws {
            setValue(value.map { NSNumber(value: $0) }, fieldNumber: fieldNumber)
        }

        mutating func visitRepeatedSInt32Field(value: [Int32], fieldNumber: Int) throws { try visitRepeatedInt32Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitRepeatedSInt64Field(value: [Int64], fieldNumber: Int) throws { try visitRepeatedInt64Field(value: value, fieldNumber: fieldNumber) }

        mutating func visitRepeatedFixed32Field(value: [UInt32], fieldNumber: Int) throws { try visitRepeatedUInt32Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitRepeatedFixed64Field(value: [UInt64], fieldNumber: Int) throws { try visitRepeatedUInt64Field(value: value, fieldNumber: fieldNumber) }

        mutating func visitRepeatedSFixed32Field(value: [Int32], fieldNumber: Int) throws { try visitRepeatedInt32Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitRepeatedSFixed64Field(value: [Int64], fieldNumber: Int) throws { try visitRepeatedInt64Field(value: value, fieldNumber: fieldNumber) }

        mutating func visitRepeatedBoolField(value: [Bool], fieldNumber: Int) throws {
            setValue(value, fieldNumber: fieldNumber)
        }

        mutating func visitRepeatedStringField(value: [String], fieldNumber: Int) throws {
            if PBLite.isBinaryField(messageType: messageType, fieldNumber: fieldNumber) {
                let encoded = value.map { Data($0.utf8).base64EncodedString() }
                setValue(encoded, fieldNumber: fieldNumber)
            } else {
                setValue(value, fieldNumber: fieldNumber)
            }
        }

        mutating func visitRepeatedBytesField(value: [Data], fieldNumber: Int) throws {
            setValue(value.map { $0.base64EncodedString() }, fieldNumber: fieldNumber)
        }

        mutating func visitRepeatedEnumField<E: SwiftProtobuf.Enum>(value: [E], fieldNumber: Int) throws {
            setValue(value.map { $0.rawValue }, fieldNumber: fieldNumber)
        }

        mutating func visitRepeatedMessageField<M: SwiftProtobuf.Message>(value: [M], fieldNumber: Int) throws {
            if PBLite.isBinaryField(messageType: messageType, fieldNumber: fieldNumber) {
                let encoded = try value.map { try $0.serializedData().base64EncodedString() }
                setValue(encoded, fieldNumber: fieldNumber)
            } else {
                let nested = try value.map { try PBLite.serializeToSlice($0) }
                setValue(nested, fieldNumber: fieldNumber)
            }
        }

        mutating func visitRepeatedGroupField<G: SwiftProtobuf.Message>(value: [G], fieldNumber: Int) throws {
            try visitRepeatedMessageField(value: value, fieldNumber: fieldNumber)
        }

        mutating func visitPackedFloatField(value: [Float], fieldNumber: Int) throws { try visitRepeatedFloatField(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedDoubleField(value: [Double], fieldNumber: Int) throws { try visitRepeatedDoubleField(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedInt32Field(value: [Int32], fieldNumber: Int) throws { try visitRepeatedInt32Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedInt64Field(value: [Int64], fieldNumber: Int) throws { try visitRepeatedInt64Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedUInt32Field(value: [UInt32], fieldNumber: Int) throws { try visitRepeatedUInt32Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedUInt64Field(value: [UInt64], fieldNumber: Int) throws { try visitRepeatedUInt64Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedSInt32Field(value: [Int32], fieldNumber: Int) throws { try visitRepeatedSInt32Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedSInt64Field(value: [Int64], fieldNumber: Int) throws { try visitRepeatedSInt64Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedFixed32Field(value: [UInt32], fieldNumber: Int) throws { try visitRepeatedFixed32Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedFixed64Field(value: [UInt64], fieldNumber: Int) throws { try visitRepeatedFixed64Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedSFixed32Field(value: [Int32], fieldNumber: Int) throws { try visitRepeatedSFixed32Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedSFixed64Field(value: [Int64], fieldNumber: Int) throws { try visitRepeatedSFixed64Field(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedBoolField(value: [Bool], fieldNumber: Int) throws { try visitRepeatedBoolField(value: value, fieldNumber: fieldNumber) }
        mutating func visitPackedEnumField<E: SwiftProtobuf.Enum>(value: [E], fieldNumber: Int) throws { try visitRepeatedEnumField(value: value, fieldNumber: fieldNumber) }

        // MARK: - Maps / Extensions / Unknowns

        mutating func visitMapField<KeyType, ValueType: SwiftProtobuf.MapValueType>(
            fieldType: SwiftProtobuf._ProtobufMap<KeyType, ValueType>.Type,
            value: SwiftProtobuf._ProtobufMap<KeyType, ValueType>.BaseType,
            fieldNumber: Int
        ) throws {
            throw PBLite.Error.expectedJSONArray(value)
        }

        mutating func visitMapField<KeyType, ValueType>(
            fieldType: SwiftProtobuf._ProtobufEnumMap<KeyType, ValueType>.Type,
            value: SwiftProtobuf._ProtobufEnumMap<KeyType, ValueType>.BaseType,
            fieldNumber: Int
        ) throws where ValueType.RawValue == Int {
            throw PBLite.Error.expectedJSONArray(value)
        }

        mutating func visitMapField<KeyType, ValueType>(
            fieldType: SwiftProtobuf._ProtobufMessageMap<KeyType, ValueType>.Type,
            value: SwiftProtobuf._ProtobufMessageMap<KeyType, ValueType>.BaseType,
            fieldNumber: Int
        ) throws {
            throw PBLite.Error.expectedJSONArray(value)
        }

        mutating func visitExtensionFields(fields: SwiftProtobuf.ExtensionFieldValueSet, start: Int, end: Int) throws {}
        mutating func visitExtensionFieldsAsMessageSet(fields: SwiftProtobuf.ExtensionFieldValueSet, start: Int, end: Int) throws {}
        mutating func visitUnknown(bytes: Data) throws {}

        // MARK: - Helpers

        mutating func trimTrailingNulls() {
            while let last = result.last, last is NSNull {
                result.removeLast()
            }
        }

        private mutating func setValue(_ value: Any, fieldNumber: Int) {
            precondition(fieldNumber >= 1)
            if result.count < fieldNumber {
                result.append(contentsOf: Array(repeating: NSNull(), count: fieldNumber - result.count))
            }
            result[fieldNumber - 1] = value
        }
    }

    // MARK: - Deserialization

    private struct PBLiteDecoder: SwiftProtobuf.Decoder {
        private let values: [Any]
        private let messageType: any SwiftProtobuf.Message.Type
        private let fieldNumbers: [Int]
        private var fieldIndex = 0

        private var currentFieldNumber: Int = 0
        private var currentValue: Any = NSNull()

        init(values: [Any], messageType: any SwiftProtobuf.Message.Type) {
            self.values = values
            self.messageType = messageType
            var nums: [Int] = []
            nums.reserveCapacity(values.count)
            for (idx, v) in values.enumerated() where !(v is NSNull) {
                nums.append(idx + 1)
            }
            self.fieldNumbers = nums
        }

        // MARK: - Decoder plumbing

        mutating func handleConflictingOneOf() throws {
            throw SwiftProtobuf.JSONDecodingError.conflictingOneOf
        }

        mutating func nextFieldNumber() throws -> Int? {
            guard fieldIndex < fieldNumbers.count else { return nil }
            let num = fieldNumbers[fieldIndex]
            fieldIndex += 1
            currentFieldNumber = num
            currentValue = values[num - 1]
            return num
        }

        // MARK: - Scalars

        mutating func decodeSingularFloatField(value: inout Float) throws { value = Float(try decodeDouble()) }
        mutating func decodeSingularFloatField(value: inout Float?) throws {
            guard let d = try decodeDoubleAllowNull() else {
                value = nil
                return
            }
            value = Float(d)
        }
        mutating func decodeRepeatedFloatField(value: inout [Float]) throws { value.append(contentsOf: try decodeDoubleArray().map(Float.init)) }

        mutating func decodeSingularDoubleField(value: inout Double) throws { value = try decodeDouble() }
        mutating func decodeSingularDoubleField(value: inout Double?) throws { value = try decodeDoubleAllowNull() }
        mutating func decodeRepeatedDoubleField(value: inout [Double]) throws { value.append(contentsOf: try decodeDoubleArray()) }

        mutating func decodeSingularInt32Field(value: inout Int32) throws { value = Int32(try decodeInt64()) }
        mutating func decodeSingularInt32Field(value: inout Int32?) throws { value = currentValue is NSNull ? nil : Int32(try decodeInt64()) }
        mutating func decodeRepeatedInt32Field(value: inout [Int32]) throws { value.append(contentsOf: try decodeInt64Array().map(Int32.init)) }

        mutating func decodeSingularInt64Field(value: inout Int64) throws { value = try decodeInt64() }
        mutating func decodeSingularInt64Field(value: inout Int64?) throws { value = currentValue is NSNull ? nil : try decodeInt64() }
        mutating func decodeRepeatedInt64Field(value: inout [Int64]) throws { value.append(contentsOf: try decodeInt64Array()) }

        mutating func decodeSingularUInt32Field(value: inout UInt32) throws { value = UInt32(try decodeUInt64()) }
        mutating func decodeSingularUInt32Field(value: inout UInt32?) throws { value = currentValue is NSNull ? nil : UInt32(try decodeUInt64()) }
        mutating func decodeRepeatedUInt32Field(value: inout [UInt32]) throws { value.append(contentsOf: try decodeUInt64Array().map(UInt32.init)) }

        mutating func decodeSingularUInt64Field(value: inout UInt64) throws { value = try decodeUInt64() }
        mutating func decodeSingularUInt64Field(value: inout UInt64?) throws { value = currentValue is NSNull ? nil : try decodeUInt64() }
        mutating func decodeRepeatedUInt64Field(value: inout [UInt64]) throws { value.append(contentsOf: try decodeUInt64Array()) }

        mutating func decodeSingularSInt32Field(value: inout Int32) throws { try decodeSingularInt32Field(value: &value) }
        mutating func decodeSingularSInt32Field(value: inout Int32?) throws { try decodeSingularInt32Field(value: &value) }
        mutating func decodeRepeatedSInt32Field(value: inout [Int32]) throws { try decodeRepeatedInt32Field(value: &value) }

        mutating func decodeSingularSInt64Field(value: inout Int64) throws { try decodeSingularInt64Field(value: &value) }
        mutating func decodeSingularSInt64Field(value: inout Int64?) throws { try decodeSingularInt64Field(value: &value) }
        mutating func decodeRepeatedSInt64Field(value: inout [Int64]) throws { try decodeRepeatedInt64Field(value: &value) }

        mutating func decodeSingularFixed32Field(value: inout UInt32) throws { try decodeSingularUInt32Field(value: &value) }
        mutating func decodeSingularFixed32Field(value: inout UInt32?) throws { try decodeSingularUInt32Field(value: &value) }
        mutating func decodeRepeatedFixed32Field(value: inout [UInt32]) throws { try decodeRepeatedUInt32Field(value: &value) }

        mutating func decodeSingularFixed64Field(value: inout UInt64) throws { try decodeSingularUInt64Field(value: &value) }
        mutating func decodeSingularFixed64Field(value: inout UInt64?) throws { try decodeSingularUInt64Field(value: &value) }
        mutating func decodeRepeatedFixed64Field(value: inout [UInt64]) throws { try decodeRepeatedUInt64Field(value: &value) }

        mutating func decodeSingularSFixed32Field(value: inout Int32) throws { try decodeSingularInt32Field(value: &value) }
        mutating func decodeSingularSFixed32Field(value: inout Int32?) throws { try decodeSingularInt32Field(value: &value) }
        mutating func decodeRepeatedSFixed32Field(value: inout [Int32]) throws { try decodeRepeatedInt32Field(value: &value) }

        mutating func decodeSingularSFixed64Field(value: inout Int64) throws { try decodeSingularInt64Field(value: &value) }
        mutating func decodeSingularSFixed64Field(value: inout Int64?) throws { try decodeSingularInt64Field(value: &value) }
        mutating func decodeRepeatedSFixed64Field(value: inout [Int64]) throws { try decodeRepeatedInt64Field(value: &value) }

        mutating func decodeSingularBoolField(value: inout Bool) throws { value = try decodeBool() }
        mutating func decodeSingularBoolField(value: inout Bool?) throws { value = currentValue is NSNull ? nil : try decodeBool() }
        mutating func decodeRepeatedBoolField(value: inout [Bool]) throws { value.append(contentsOf: try decodeBoolArray()) }

        mutating func decodeSingularStringField(value: inout String) throws { value = try decodeString() }
        mutating func decodeSingularStringField(value: inout String?) throws { value = currentValue is NSNull ? nil : try decodeString() }
        mutating func decodeRepeatedStringField(value: inout [String]) throws { value.append(contentsOf: try decodeStringArray()) }

        mutating func decodeSingularBytesField(value: inout Data) throws { value = try decodeBytes() }
        mutating func decodeSingularBytesField(value: inout Data?) throws { value = currentValue is NSNull ? nil : try decodeBytes() }
        mutating func decodeRepeatedBytesField(value: inout [Data]) throws { value.append(contentsOf: try decodeBytesArray()) }

        // MARK: - Enum

        mutating func decodeSingularEnumField<E: SwiftProtobuf.Enum>(value: inout E) throws where E.RawValue == Int {
            let raw = Int(try decodeInt64())
            value = E(rawValue: raw) ?? E()
        }

        mutating func decodeSingularEnumField<E: SwiftProtobuf.Enum>(value: inout E?) throws where E.RawValue == Int {
            if currentValue is NSNull {
                value = nil
                return
            }
            let raw = Int(try decodeInt64())
            value = E(rawValue: raw) ?? E()
        }

        mutating func decodeRepeatedEnumField<E: SwiftProtobuf.Enum>(value: inout [E]) throws where E.RawValue == Int {
            let raws = try decodeInt64Array().map { Int($0) }
            value.append(contentsOf: raws.map { E(rawValue: $0) ?? E() })
        }

        // MARK: - Message / Group

        mutating func decodeSingularMessageField<M: SwiftProtobuf.Message>(value: inout M?) throws {
            if currentValue is NSNull {
                value = nil
                return
            }
            if PBLite.isBinaryField(messageType: messageType, fieldNumber: currentFieldNumber) {
                let data = try decodeBytesFromBase64String(currentValue)
                value = try M(serializedData: data)
                return
            }
            guard let arr = currentValue as? [Any] else {
                throw PBLite.Error.expectedArray(currentValue)
            }
            var nestedDecoder = PBLiteDecoder(values: arr, messageType: M.self)
            var msg = M()
            try msg.decodeMessage(decoder: &nestedDecoder)
            value = msg
        }

        mutating func decodeRepeatedMessageField<M: SwiftProtobuf.Message>(value: inout [M]) throws {
            guard let arr = currentValue as? [Any] else {
                throw PBLite.Error.expectedArray(currentValue)
            }
            if PBLite.isBinaryField(messageType: messageType, fieldNumber: currentFieldNumber) {
                for item in arr {
                    let data = try decodeBytesFromBase64String(item)
                    value.append(try M(serializedData: data))
                }
                return
            }
            for item in arr {
                guard let nested = item as? [Any] else {
                    throw PBLite.Error.expectedArray(item)
                }
                var nestedDecoder = PBLiteDecoder(values: nested, messageType: M.self)
                var msg = M()
                try msg.decodeMessage(decoder: &nestedDecoder)
                value.append(msg)
            }
        }

        mutating func decodeSingularGroupField<G: SwiftProtobuf.Message>(value: inout G?) throws { try decodeSingularMessageField(value: &value) }
        mutating func decodeRepeatedGroupField<G: SwiftProtobuf.Message>(value: inout [G]) throws { try decodeRepeatedMessageField(value: &value) }

        // MARK: - Map / Extensions

        mutating func decodeMapField<KeyType, ValueType: SwiftProtobuf.MapValueType>(
            fieldType: SwiftProtobuf._ProtobufMap<KeyType, ValueType>.Type,
            value: inout SwiftProtobuf._ProtobufMap<KeyType, ValueType>.BaseType
        ) throws {
            throw SwiftProtobuf.JSONDecodingError.failure
        }

        mutating func decodeMapField<KeyType, ValueType>(
            fieldType: SwiftProtobuf._ProtobufEnumMap<KeyType, ValueType>.Type,
            value: inout SwiftProtobuf._ProtobufEnumMap<KeyType, ValueType>.BaseType
        ) throws where ValueType.RawValue == Int {
            throw SwiftProtobuf.JSONDecodingError.failure
        }

        mutating func decodeMapField<KeyType, ValueType>(
            fieldType: SwiftProtobuf._ProtobufMessageMap<KeyType, ValueType>.Type,
            value: inout SwiftProtobuf._ProtobufMessageMap<KeyType, ValueType>.BaseType
        ) throws {
            throw SwiftProtobuf.JSONDecodingError.failure
        }

        mutating func decodeExtensionField(
            values: inout SwiftProtobuf.ExtensionFieldValueSet,
            messageType: any SwiftProtobuf.Message.Type,
            fieldNumber: Int
        ) throws {
            // No extensions in this schema.
        }

        // MARK: - Primitive parsing helpers

        private func decodeDouble() throws -> Double {
            if let n = currentValue as? NSNumber {
                return n.doubleValue
            }
            if let s = currentValue as? String, let d = Double(s) {
                return d
            }
            throw SwiftProtobuf.JSONDecodingError.failure
        }

        private func decodeDoubleAllowNull() throws -> Double? {
            if currentValue is NSNull { return nil }
            return try decodeDouble()
        }

        private func decodeDoubleArray() throws -> [Double] {
            guard let arr = currentValue as? [Any] else { throw PBLite.Error.expectedArray(currentValue) }
            return try arr.map { item in
                if let n = item as? NSNumber { return n.doubleValue }
                if let s = item as? String, let d = Double(s) { return d }
                throw SwiftProtobuf.JSONDecodingError.failure
            }
        }

        private func decodeInt64() throws -> Int64 {
            if let n = currentValue as? NSNumber {
                return n.int64Value
            }
            if let s = currentValue as? String, let i = Int64(s) {
                return i
            }
            throw SwiftProtobuf.JSONDecodingError.failure
        }

        private func decodeInt64Array() throws -> [Int64] {
            guard let arr = currentValue as? [Any] else { throw PBLite.Error.expectedArray(currentValue) }
            return try arr.map { item in
                if let n = item as? NSNumber { return n.int64Value }
                if let s = item as? String, let i = Int64(s) { return i }
                throw SwiftProtobuf.JSONDecodingError.failure
            }
        }

        private func decodeUInt64() throws -> UInt64 {
            if let n = currentValue as? NSNumber {
                return n.uint64Value
            }
            if let s = currentValue as? String, let i = UInt64(s) {
                return i
            }
            throw SwiftProtobuf.JSONDecodingError.failure
        }

        private func decodeUInt64Array() throws -> [UInt64] {
            guard let arr = currentValue as? [Any] else { throw PBLite.Error.expectedArray(currentValue) }
            return try arr.map { item in
                if let n = item as? NSNumber { return n.uint64Value }
                if let s = item as? String, let i = UInt64(s) { return i }
                throw SwiftProtobuf.JSONDecodingError.failure
            }
        }

        private func decodeBool() throws -> Bool {
            if let b = currentValue as? Bool {
                return b
            }
            if let n = currentValue as? NSNumber {
                return n.intValue != 0
            }
            throw SwiftProtobuf.JSONDecodingError.failure
        }

        private func decodeBoolArray() throws -> [Bool] {
            guard let arr = currentValue as? [Any] else { throw PBLite.Error.expectedArray(currentValue) }
            return try arr.map { item in
                if let b = item as? Bool { return b }
                if let n = item as? NSNumber { return n.intValue != 0 }
                throw SwiftProtobuf.JSONDecodingError.failure
            }
        }

        private func decodeString() throws -> String {
            guard let s = currentValue as? String else { throw PBLite.Error.expectedString(currentValue) }
            if PBLite.isBinaryField(messageType: messageType, fieldNumber: currentFieldNumber) {
                let data = try decodeBytesFromBase64String(s)
                guard let str = String(data: data, encoding: .utf8) else {
                    throw PBLite.Error.invalidUTF8
                }
                return str
            }
            return s
        }

        private func decodeStringArray() throws -> [String] {
            guard let arr = currentValue as? [Any] else { throw PBLite.Error.expectedArray(currentValue) }
            return try arr.map { item in
                guard let s = item as? String else { throw PBLite.Error.expectedString(item) }
                if PBLite.isBinaryField(messageType: messageType, fieldNumber: currentFieldNumber) {
                    let data = try decodeBytesFromBase64String(s)
                    guard let str = String(data: data, encoding: .utf8) else { throw PBLite.Error.invalidUTF8 }
                    return str
                }
                return s
            }
        }

        private func decodeBytes() throws -> Data {
            return try decodeBytesFromBase64String(currentValue)
        }

        private func decodeBytesArray() throws -> [Data] {
            guard let arr = currentValue as? [Any] else { throw PBLite.Error.expectedArray(currentValue) }
            return try arr.map { try decodeBytesFromBase64String($0) }
        }

        private func decodeBytesFromBase64String(_ value: Any) throws -> Data {
            guard let s = value as? String else { throw PBLite.Error.expectedString(value) }
            guard let data = Data(base64Encoded: s) else { throw PBLite.Error.invalidBase64(s) }
            return data
        }
    }
}
