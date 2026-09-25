// Renders frames of scene.metal on the GPU and writes them to stdout as raw
// 16-bit RGBA, ready to pipe into ffmpeg.
//
// usage: render <scene.metal> <width> <height> <fps> <seconds> <all | frame,frame,...>

import Foundation
import Metal
import MetalPerformanceShaders

let args = CommandLine.arguments
guard args.count == 7 else {
    fputs("usage: render <scene.metal> <width> <height> <fps> <seconds> <all | frame,frame,...>\n", stderr)
    exit(1)
}

let source = try String(contentsOfFile: args[1], encoding: .utf8)
let width = Int(args[2])!, height = Int(args[3])!
let fps = Double(args[4])!, seconds = Double(args[5])!
let total = Int((fps * seconds).rounded())
let frames = args[6] == "all" ? Array(0..<total) : args[6].split(separator: ",").map { Int($0)! }

let device = MTLCreateSystemDefaultDevice()!
let library: MTLLibrary
do {
    library = try device.makeLibrary(source: source, options: nil)
} catch {
    fputs("shader compile failed:\n\(error)\n", stderr)
    exit(1)
}

func pipeline(_ name: String) -> MTLComputePipelineState {
    try! device.makeComputePipelineState(function: library.makeFunction(name: name)!)
}

func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat, shared: Bool = false) -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = shared ? .shared : .private
    return device.makeTexture(descriptor: desc)!
}

func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
    enc.setComputePipelineState(pso)
    enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
}

let scenePSO = pipeline("scene")
let downPSO = pipeline("downsample")
let compositePSO = pipeline("composite")
let queue = device.makeCommandQueue()!

let hdr = texture(width, height, .rgba16Float)
let small = texture(width / 4, height / 4, .rgba16Float)
let bloomA = texture(width / 4, height / 4, .rgba16Float)
let bloomB = texture(width / 4, height / 4, .rgba16Float)
let output = texture(width, height, .rgba16Unorm, shared: true)
let blurA = MPSImageGaussianBlur(device: device, sigma: 3.0)
let blurB = MPSImageGaussianBlur(device: device, sigma: 14.0)

var pixels = [UInt8](repeating: 0, count: width * height * 8)
let started = Date()

for (index, frame) in frames.enumerated() {
    var params: [SIMD4<Float>] = [
        SIMD4(Float(width), Float(height), Float(Double(frame) / fps), Float(seconds)),
        SIMD4(0, 0, 0, 0),
    ]
    let cb = queue.makeCommandBuffer()!

    var enc = cb.makeComputeCommandEncoder()!
    enc.setBytes(&params, length: 32, index: 0)
    enc.setTexture(hdr, index: 0)
    dispatch(enc, scenePSO, width, height)
    enc.setTexture(small, index: 1)
    dispatch(enc, downPSO, width / 4, height / 4)
    enc.endEncoding()

    blurA.encode(commandBuffer: cb, sourceTexture: small, destinationTexture: bloomA)
    blurB.encode(commandBuffer: cb, sourceTexture: small, destinationTexture: bloomB)

    enc = cb.makeComputeCommandEncoder()!
    enc.setBytes(&params, length: 32, index: 0)
    enc.setTexture(hdr, index: 0)
    enc.setTexture(bloomA, index: 1)
    enc.setTexture(bloomB, index: 2)
    enc.setTexture(output, index: 3)
    dispatch(enc, compositePSO, width, height)
    enc.endEncoding()

    cb.commit()
    cb.waitUntilCompleted()
    if let error = cb.error {
        fputs("GPU error on frame \(frame): \(error)\n", stderr)
        exit(1)
    }

    output.getBytes(&pixels, bytesPerRow: width * 8,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    fwrite(pixels, 1, pixels.count, stdout)

    let done = index + 1
    let elapsed = Date().timeIntervalSince(started)
    fputs(String(format: "\rframe %d/%d  (%.2fs per frame)", done, frames.count, elapsed / Double(done)), stderr)
}
fflush(stdout)
fputs("\n", stderr)
