import Swift
import SwiftShims

public struct MyStruct {
  public var x: Int
  public var y: Double
  public var z: Bool?
  public var w: Int16
  
  // Not iterated over
  public var myComputed: Int32 {
    get { 9 }
    set { x = Int(newValue) }
  }
}

/// Internal checks.
///
/// Internal checks are to be used for checking correctness conditions in the
/// standard library. They are only enable when the standard library is built
/// with the build configuration INTERNAL_CHECKS_ENABLED enabled. Otherwise, the
/// call to this function is a noop.
@usableFromInline @_transparent
internal func _internalInvariant(
  _ condition: @autoclosure () -> Bool, _ message: String = "",
  file: StaticString = #file, line: UInt = #line
) {
#if INTERNAL_CHECKS_ENABLED
  if !_fastPath(condition()) {
    fatalError(String(message), file: file, line: line)
  }
#endif
}

@usableFromInline @_transparent
internal func _internalInvariantFailure(
  _ message: String = "",
  file: StaticString = #file, line: UInt = #line
) -> Never {
  _internalInvariant(false, message, file: file, line: line)
  Builtin.conditionallyUnreachable()
}

public struct _EachFieldOptions: OptionSet {
  public var rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  /// Require the top-level type to be a class.
  ///
  /// If this is not set, the top-level type is required to be a struct or
  /// tuple.
  public static var classType = _EachFieldOptions(rawValue: 1 << 0)

  /// Ignore fields that can't be introspected.
  ///
  /// If not set, the presence of things that can't be introspected causes
  /// the function to immediately return `false`.
  public static var ignoreUnknown = _EachFieldOptions(rawValue: 1 << 1)
}

@_silgen_name("swift_isClassType")
internal func _isClassType(_: Any.Type) -> Bool

@_silgen_name("swift_getMetadataKind")
internal func _metadataKind(_: Any.Type) -> UInt

@_silgen_name("swift_reflectionMirror_recursiveCount")
internal func _getRecursiveChildCount(_: Any.Type) -> Int

@_silgen_name("swift_reflectionMirror_recursiveChildMetadata")
internal func _getChildMetadata(
  _: Any.Type,
  index: Int,
  fieldMetadata: UnsafeMutablePointer<_FieldReflectionMetadata>
) -> Any.Type

@_silgen_name("swift_reflectionMirror_recursiveChildOffset")
internal func _getChildOffset(
  _: Any.Type,
  index: Int
) -> Int

public enum _MetadataKind: UInt {
  // With "flags":
  // runtimePrivate = 0x100
  // nonHeap = 0x200
  // nonType = 0x400
  
  case `class` = 0
  case `struct` = 0x200     // 0 | nonHeap
  case `enum` = 0x201       // 1 | nonHeap
  case optional = 0x202     // 2 | nonHeap
  case foreignClass = 0x203 // 3 | nonHeap
  case opaque = 0x300       // 0 | runtimePrivate | nonHeap
  case tuple = 0x301        // 1 | runtimePrivate | nonHeap
  case function = 0x302     // 2 | runtimePrivate | nonHeap
  case existential = 0x303  // 3 | runtimePrivate | nonHeap
  case metatype = 0x304     // 4 | runtimePrivate | nonHeap
  case objcClassWrapper = 0x305     // 5 | runtimePrivate | nonHeap
  case existentialMetatype = 0x306  // 6 | runtimePrivate | nonHeap
  case heapLocalVariable = 0x400    // 0 | nonType
  case heapGenericLocalVariable = 0x500 // 0 | nonType | runtimePrivate
  case errorObject = 0x501  // 1 | nonType | runtimePrivate
  case unknown = 0xffff
  
  init(_ type: Any.Type) {
    let v = _metadataKind(type)
    if let result = _MetadataKind(rawValue: v) {
      self = result
    } else {
      self = .unknown
    }
  }
}

extension AnyKeyPath {
  internal static func _create(
    capacityInBytes bytes: Int,
    initializedBy body: (UnsafeMutableRawBufferPointer) -> Void
  ) -> Self {
    _internalInvariant(bytes > 0 && bytes % 4 == 0,
                 "capacity must be multiple of 4 bytes")
    let result = Builtin.allocWithTailElems_1(self, (bytes/4)._builtinWordValue,
                                              Int32.self)
    
    // Program will crash if I retain/release the pointer, so just leave it
    // un-retained.
    let unmanaged = Unmanaged.passUnretained(result)
    
    // Workaround for the fact that `_kvcKeyPathStringPtr` is API-internal.
    // Emulates the code: `result._kvcKeyPathStringPtr = nil`
    let opaque = unmanaged.toOpaque()
    let bound = opaque.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    let opaque2 = bound.pointee
    let bound2 = opaque2.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    bound2.pointee = nil
    
    let base = UnsafeMutableRawPointer(Builtin.projectTailElems(result,
                                                                Int32.self))
    body(UnsafeMutableRawBufferPointer(start: base, count: bytes))
    return result
  }
}

// MARK: Implementation details
internal enum KeyPathComponentKind {
  /// The keypath references an externally-defined property or subscript whose
  /// component describes how to interact with the key path.
  case external
  /// The keypath projects within the storage of the outer value, like a
  /// stored property in a struct.
  case `struct`
  /// The keypath projects from the referenced pointer, like a
  /// stored property in a class.
  case `class`
  /// The keypath projects using a getter/setter pair.
  case computed
  /// The keypath optional-chains, returning nil immediately if the input is
  /// nil, or else proceeding by projecting the value inside.
  case optionalChain
  /// The keypath optional-forces, trapping if the input is
  /// nil, or else proceeding by projecting the value inside.
  case optionalForce
  /// The keypath wraps a value in an optional.
  case optionalWrap
}

internal struct RawKeyPathComponent {
  internal var header: Header
  internal var body: UnsafeRawBufferPointer

  internal init(header: Header, body: UnsafeRawBufferPointer) {
    self.header = header
    self.body = body
  }
  
  internal struct Header {
    internal var _value: UInt32
    
    init(discriminator: UInt32, payload: UInt32) {
      _value = 0
      self.discriminator = discriminator
      self.payload = payload
    }
    
    internal var discriminator: UInt32 {
      get {
        return (_value & Header.discriminatorMask) >> Header.discriminatorShift
      }
      set {
        let shifted = newValue << Header.discriminatorShift
        _internalInvariant(shifted & Header.discriminatorMask == shifted,
                     "discriminator doesn't fit")
        _value = _value & ~Header.discriminatorMask | shifted
      }
    }
    internal var storedOffsetPayload: UInt32 {
      get {
        _internalInvariant(kind == .struct || kind == .class,
                     "not a stored component")
        return _value & Header.storedOffsetPayloadMask
      }
      set {
        _internalInvariant(kind == .struct || kind == .class,
                     "not a stored component")
        _internalInvariant(newValue & Header.storedOffsetPayloadMask == newValue,
                     "payload too big")
        _value = _value & ~Header.storedOffsetPayloadMask | newValue
      }
    }
    internal var payload: UInt32 {
      get {
        return _value & Header.payloadMask
      }
      set {
        _internalInvariant(newValue & Header.payloadMask == newValue,
                     "payload too big")
        _value = _value & ~Header.payloadMask | newValue
      }
    }
    internal var endOfReferencePrefix: Bool {
      get {
        return _value & Header.endOfReferencePrefixFlag != 0
      }
      set {
        if newValue {
          _value |= Header.endOfReferencePrefixFlag
        } else {
          _value &= ~Header.endOfReferencePrefixFlag
        }
      }
    }
    
    internal var kind: KeyPathComponentKind {
      switch (discriminator, payload) {
      case (Header.externalTag, _):
        return .external
      case (Header.structTag, _):
        return .struct
      case (Header.classTag, _):
        return .class
      case (Header.computedTag, _):
        return .computed
      case (Header.optionalTag, Header.optionalChainPayload):
        return .optionalChain
      case (Header.optionalTag, Header.optionalWrapPayload):
        return .optionalWrap
      case (Header.optionalTag, Header.optionalForcePayload):
        return .optionalForce
      default:
        _internalInvariantFailure("invalid header")
      }
    }
    
    internal static var payloadMask: UInt32 {
      return _SwiftKeyPathComponentHeader_PayloadMask
    }
    internal static var discriminatorMask: UInt32 {
      return _SwiftKeyPathComponentHeader_DiscriminatorMask
    }
    internal static var discriminatorShift: UInt32 {
      return _SwiftKeyPathComponentHeader_DiscriminatorShift
    }
    internal static var externalTag: UInt32 {
      return _SwiftKeyPathComponentHeader_ExternalTag
    }
    internal static var structTag: UInt32 {
      return _SwiftKeyPathComponentHeader_StructTag
    }
    internal static var computedTag: UInt32 {
      return _SwiftKeyPathComponentHeader_ComputedTag
    }
    internal static var classTag: UInt32 {
      return _SwiftKeyPathComponentHeader_ClassTag
    }
    internal static var optionalTag: UInt32 {
      return _SwiftKeyPathComponentHeader_OptionalTag
    }
    internal static var optionalChainPayload: UInt32 {
      return _SwiftKeyPathComponentHeader_OptionalChainPayload
    }
    internal static var optionalWrapPayload: UInt32 {
      return _SwiftKeyPathComponentHeader_OptionalWrapPayload
    }
    internal static var optionalForcePayload: UInt32 {
      return _SwiftKeyPathComponentHeader_OptionalForcePayload
    }
    
    internal static var endOfReferencePrefixFlag: UInt32 {
      return _SwiftKeyPathComponentHeader_EndOfReferencePrefixFlag
    }
    internal static var storedMutableFlag: UInt32 {
      return _SwiftKeyPathComponentHeader_StoredMutableFlag
    }
    internal static var storedOffsetPayloadMask: UInt32 {
      return _SwiftKeyPathComponentHeader_StoredOffsetPayloadMask
    }
    internal static var outOfLineOffsetPayload: UInt32 {
      return _SwiftKeyPathComponentHeader_OutOfLineOffsetPayload
    }
    internal static var unresolvedFieldOffsetPayload: UInt32 {
      return _SwiftKeyPathComponentHeader_UnresolvedFieldOffsetPayload
    }
    internal static var unresolvedIndirectOffsetPayload: UInt32 {
      return _SwiftKeyPathComponentHeader_UnresolvedIndirectOffsetPayload
    }
    internal static var maximumOffsetPayload: UInt32 {
      return _SwiftKeyPathComponentHeader_MaximumOffsetPayload
    }
    
    // The component header is 4 bytes, but may be followed by an aligned
    // pointer field for some kinds of component, forcing padding.
    internal static var pointerAlignmentSkew: Int {
      return MemoryLayout<Int>.size - MemoryLayout<Int32>.size
    }
    
    init(stored kind: KeyPathStructOrClass,
         mutable: Bool,
         inlineOffset: UInt32) {
      let discriminator: UInt32
      switch kind {
      case .struct: discriminator = Header.structTag
      case .class: discriminator = Header.classTag
      }

      _internalInvariant(inlineOffset <= Header.maximumOffsetPayload)
      let payload = inlineOffset
        | (mutable ? Header.storedMutableFlag : 0)
      self.init(discriminator: discriminator,
                payload: payload)
    }
  }
  
  internal func clone(into buffer: inout UnsafeMutableRawBufferPointer,
             endOfReferencePrefix: Bool) {
    var newHeader = header
    newHeader.endOfReferencePrefix = endOfReferencePrefix
    
    var componentSize = MemoryLayout<Header>.size
    buffer.storeBytes(of: newHeader, as: Header.self)
    switch header.kind {
    case .struct,
         .class:
      if header.storedOffsetPayload == Header.outOfLineOffsetPayload {
        let overflowOffset = body.load(as: UInt32.self)
        buffer.storeBytes(of: overflowOffset, toByteOffset: 4,
                          as: UInt32.self)
        componentSize += 4
      }
      break
    case .optionalChain,
         .optionalForce,
         .optionalWrap:
      break
    case .computed:
      // Metadata does not have enough information to construct computed
      // properties. In the Swift stdlib, this case would execute other code.
      // That code is left out because it is not necessary for this use case.
      fatalError("Implement support for key paths to computed properties.")
      break
    case .external:
      _internalInvariantFailure("should have been instantiated away")
    }
    buffer = UnsafeMutableRawBufferPointer(
      start: buffer.baseAddress.unsafelyUnwrapped + componentSize,
      count: buffer.count - componentSize)
  }
}

internal struct KeyPathBuffer {
  internal struct Builder {
    internal var buffer: UnsafeMutableRawBufferPointer
    internal init(_ buffer: UnsafeMutableRawBufferPointer) {
      self.buffer = buffer
    }
    internal mutating func pushRaw(
      size: Int, alignment: Int
    ) -> UnsafeMutableRawBufferPointer {
      var baseAddress = buffer.baseAddress.unsafelyUnwrapped
      var misalign = Int(bitPattern: baseAddress) & (alignment - 1)
      if misalign != 0 {
        misalign = alignment - misalign
        baseAddress = baseAddress.advanced(by: misalign)
      }
      let result = UnsafeMutableRawBufferPointer(
        start: baseAddress,
        count: size)
      buffer = UnsafeMutableRawBufferPointer(
        start: baseAddress + size,
        count: buffer.count - size - misalign)
      return result
    }
    internal mutating func push<T>(_ value: T) {
      let buf = pushRaw(size: MemoryLayout<T>.size,
                        alignment: MemoryLayout<T>.alignment)
      buf.storeBytes(of: value, as: T.self)
    }
    internal mutating func pushHeader(_ header: Header) {
      push(header)
      // Start the components at pointer alignment
      _ = pushRaw(size: RawKeyPathComponent.Header.pointerAlignmentSkew,
             alignment: 4)
    }
  }
  
  internal struct Header {
    internal var _value: UInt32
    internal init(size: Int, trivial: Bool, hasReferencePrefix: Bool) {
      _internalInvariant(size <= Int(Header.sizeMask),
                   "key path too big")
      _value = UInt32(size)
        | (trivial ? Header.trivialFlag : 0)
        | (hasReferencePrefix ? Header.hasReferencePrefixFlag : 0)
    }
    
    internal static var sizeMask: UInt32 {
      return _SwiftKeyPathBufferHeader_SizeMask
    }
    internal static var reservedMask: UInt32 {
      return _SwiftKeyPathBufferHeader_ReservedMask
    }
    internal static var trivialFlag: UInt32 {
      return _SwiftKeyPathBufferHeader_TrivialFlag
    }
    internal static var hasReferencePrefixFlag: UInt32 {
      return _SwiftKeyPathBufferHeader_HasReferencePrefixFlag
    }
  }
}

internal enum KeyPathStructOrClass {
  case `struct`, `class`
}

@discardableResult
public func _forEachField(
  of type: Any.Type,
  options: _EachFieldOptions = [],
  body: (UnsafePointer<CChar>, Int, Any.Type, _MetadataKind) -> Bool
) -> Bool {
  // Require class type iff `.classType` is included as an option
  if _isClassType(type) != options.contains(.classType) {
    return false
  }

  let childCount = _getRecursiveChildCount(type)
  for i in 0..<childCount {
    let offset = _getChildOffset(type, index: i)

    var field = _FieldReflectionMetadata()
    let childType = _getChildMetadata(type, index: i, fieldMetadata: &field)
    defer { field.freeFunc?(field.name) }
    let kind = _MetadataKind(childType)

    if !body(field.name!, offset, childType, kind) {
      return false
    }
  }

  return true
}

@discardableResult
public func _forEachFieldWithKeyPath<Root>(
  of type: Root.Type,
  options: _EachFieldOptions = [],
  body: (UnsafePointer<CChar>, PartialKeyPath<Root>) -> Bool
) -> Bool {
  // Class types not supported because the metadata does not have
  // enough information to construct computed properties.
  if _isClassType(type) != options.contains(.classType) {
    return false
  }
  let ignoreUnknown = options.contains(.ignoreUnknown)
  
  let childCount = _getRecursiveChildCount(type)
  for i in 0..<childCount {
    let offset = _getChildOffset(type, index: i)

    var field = _FieldReflectionMetadata()
    let childType = _getChildMetadata(type, index: i, fieldMetadata: &field)
    defer { field.freeFunc?(field.name) }
    let kind = _MetadataKind(childType)
    let supportedType: Bool
    switch kind {
      case .struct, .class, .optional, .existential,
          .existentialMetatype, .tuple, .enum:
        supportedType = true
      default:
        supportedType = false
    }
    if !supportedType || !field.isStrong {
      if !ignoreUnknown { return false }
      continue;
    }
    
    func keyPathType<Leaf>(for: Leaf.Type) -> PartialKeyPath<Root>.Type {
      if field.isVar { return WritableKeyPath<Root, Leaf>.self }
      return KeyPath<Root, Leaf>.self
    }
    
    let resultSize = MemoryLayout<Int32>.size + MemoryLayout<Int>.size
    let partialKeyPath = _openExistential(childType, do: keyPathType)
       ._create(capacityInBytes: resultSize) {
      var destBuilder = KeyPathBuffer.Builder($0)
      destBuilder.pushHeader(KeyPathBuffer.Header(
        size: resultSize - MemoryLayout<Int>.size,
        trivial: true,
        hasReferencePrefix: false
      ))
      let component = RawKeyPathComponent(
           header: RawKeyPathComponent.Header(stored: .struct,
                                              mutable: field.isVar,
                                              inlineOffset: UInt32(offset)),
           body: UnsafeRawBufferPointer(start: nil, count: 0))
      component.clone(
        into: &destBuilder.buffer,
        endOfReferencePrefix: false)
    }
    
    if !body(field.name!, partialKeyPath) {
      return false
    }
  }
  return true
}

_forEachFieldWithKeyPath(of: MyStruct.self) { name, kp in
  print("A string:", String(cString: name))
  print("A kp:", kp)
  return true
}
