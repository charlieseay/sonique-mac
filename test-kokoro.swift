#!/usr/bin/env swift

import Foundation

// Add the Kokoro package path
import Kokoro

// Test Kokoro TTS synthesis
let configURL = URL(fileURLWithPath: "/Users/charlieseay/Projects/sonique-mac/Kokoro/MLX_GPU/config.json")
let weightsURL = URL(fileURLWithPath: "/Users/charlieseay/Projects/sonique-mac/Kokoro/MLX_GPU/kokoro-v1_0.safetensors")
let voicesDir = URL(fileURLWithPath: "/Users/charlieseay/Projects/sonique-mac/Kokoro/MLX_GPU/voices")

do {
    print("Loading Kokoro model...")
    let model = try KModel(configURL: configURL, weightsURL: weightsURL)
    let voices = VoiceLoader(baseDirectory: voicesDir, enableDownload: false)
    let pipeline = KPipeline(model: model, voices: voices)

    print("Synthesizing 'Hello world'...")
    let result = try pipeline.synthesize(text: "Hello world", voice: "af_jessica", speed: 1.0)

    print("✓ Generated \(result.audio.count) samples at \(result.sampleRate)Hz")

    // Convert to PCM and save
    var pcmData = Data(capacity: result.audio.count * 2)
    for sample in result.audio {
        let clamped = max(-1.0, min(1.0, sample))
        let int16Value = Int16(clamped * Float(Int16.max))
        withUnsafeBytes(of: int16Value.littleEndian) { pcmData.append(contentsOf: $0) }
    }

    let outputURL = URL(fileURLWithPath: "/tmp/kokoro-test.pcm")
    try pcmData.write(to: outputURL)

    print("✓ Saved \(pcmData.count) bytes PCM to \(outputURL.path)")
    print("✓ Kokoro TTS working!")

} catch {
    print("❌ Error: \(error)")
    exit(1)
}
