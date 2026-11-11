#if os(macOS)
import Compression
import Foundation

/// Compression 프레임워크의 `COMPRESSION_ZLIB`(=raw DEFLATE, RFC 1951) 스트림 래퍼.
final class RawDeflateStream {
    enum Direction { case encode, decode }

    private var stream: compression_stream
    private let direction: Direction
    private let out: UnsafeMutablePointer<UInt8>
    private let outCapacity: Int
    private var finished = false

    init(_ direction: Direction, outputChunk: Int = 1 << 20) throws {
        self.direction = direction
        outCapacity = outputChunk
        out = .allocate(capacity: outputChunk)
        stream = compression_stream(
            dst_ptr: out, dst_size: 0,
            src_ptr: UnsafePointer(out), src_size: 0, state: nil
        )
        let op = direction == .encode ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE
        guard compression_stream_init(&stream, op, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            out.deallocate()
            throw ZipError.io("compression_stream_init 실패")
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        out.deallocate()
    }

    /// `input`을 먹이고 나온 출력을 `sink`로 넘긴다. 마지막 입력이면 `finalize`를 true로 준다.
    func process(_ input: UnsafeRawBufferPointer, finalize: Bool, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        if finished { return }
        let base = input.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(out)
        stream.src_ptr = base
        stream.src_size = input.count
        let flags: Int32 = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        while true {
            stream.dst_ptr = out
            stream.dst_size = outCapacity
            let status = compression_stream_process(&stream, flags)
            let produced = outCapacity - stream.dst_size
            if produced > 0 { try sink(UnsafeRawBufferPointer(start: out, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                finished = true
                if direction == .decode, stream.src_size != 0 {
                    // 스트림 뒤에 남는 바이트: 무시하지 않고 오류로 본다.
                    throw ZipError.corrupt("DEFLATE 스트림 뒤에 추가 데이터가 있습니다")
                }
                return
            case COMPRESSION_STATUS_OK:
                if finalize {
                    if produced == 0 && stream.src_size == 0 { throw ZipError.corrupt("DEFLATE 스트림이 중간에 끝났습니다") }
                    continue
                }
                if stream.src_size == 0 && stream.dst_size > 0 { return }
            default:
                throw ZipError.corrupt("DEFLATE 처리 오류")
            }
        }
    }

    var isFinished: Bool { finished }
}
#endif
