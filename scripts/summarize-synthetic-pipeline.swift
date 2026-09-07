#!/usr/bin/env swift

import Foundation

struct Sample {
  let index: Int
  let startedAt: String
  let warmingEnabled: Bool?
  let comparisonPair: Int?
  let providerQueueMS: Double?
  let pipelineSucceeded: Bool
  let transcriptionCorrectnessPassed: Bool
  let cleanupCorrectnessPassed: Bool
  let correctnessFailures: [String]
  let failureStage: String?
  let failureCategory: String?
  let sonioxConnectMS: Double?
  let audioStreamingMS: Double?
  let sonioxFinalizeMS: Double?
  let cleanupMS: Double?
  let endOfAudioToCleanedMS: Double?
  let providerTotalMS: Double?
  let networkRequestMS: Double?
  let timeToFirstByteMS: Double?
  let connectionReused: Bool?
  let finalAudioProcessedMS: Double?
  let audioDurationMS: Double?

  var clientNetworkOverheadMS: Double? {
    guard let networkRequestMS, let providerTotalMS else { return nil }
    return networkRequestMS - providerTotalMS
  }

  var finalAudioCoverageMS: Double? {
    guard let finalAudioProcessedMS, let audioDurationMS else { return nil }
    return finalAudioProcessedMS - audioDurationMS
  }
}

func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

func number(_ value: Any?) -> Double? {
  guard let value = value as? NSNumber else { return nil }
  return value.doubleValue
}

func percentile(_ values: [Double], _ fraction: Double) -> Double? {
  guard !values.isEmpty else { return nil }
  let sorted = values.sorted()
  let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
  return sorted[min(rank - 1, sorted.count - 1)]
}

func format(_ value: Double?) -> String {
  value.map { String(format: "%.1f ms", $0) } ?? "n/a"
}

func report(_ name: String, _ values: [Double]) {
  guard !values.isEmpty else {
    print("\(name): n/a")
    return
  }
  let mean = values.reduce(0, +) / Double(values.count)
  print(
    "\(name): n=\(values.count), mean=\(format(mean)), "
      + "p50=\(format(percentile(values, 0.50))), p90=\(format(percentile(values, 0.90))), "
      + "max=\(format(values.max()))")
}

guard let path = CommandLine.arguments.dropFirst().first else {
  FileHandle.standardError.write(
    Data("Usage: summarize-synthetic-pipeline.swift <benchmark.jsonl>\n".utf8))
  exit(64)
}
let inputURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
guard let data = try? Data(contentsOf: inputURL) else {
  FileHandle.standardError.write(Data("No benchmark log found at \(inputURL.path)\n".utf8))
  exit(66)
}

var malformedLines = 0
let samples: [Sample] = data.split(separator: 0x0A).compactMap { line in
  guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
    root["benchmarkKind"] as? String == "synthetic-soniox-cerebras"
  else {
    malformedLines += 1
    return nil
  }
  let durations = dictionary(root["durationsMS"])
  let stt = dictionary(root["stt"])
  let cleanup = dictionary(root["cleanup"])
  let providerTiming = dictionary(cleanup["providerTiming"])
  let networkTiming = dictionary(cleanup["networkTiming"])
  let outcome = dictionary(root["outcome"])
  return Sample(
    index: (root["sampleIndex"] as? NSNumber)?.intValue ?? 0,
    startedAt: root["startedAt"] as? String ?? "unknown",
    warmingEnabled: root["warmingEnabled"] as? Bool,
    comparisonPair: (root["comparisonPair"] as? NSNumber)?.intValue,
    providerQueueMS: number(providerTiming["queueMS"]),
    pipelineSucceeded: outcome["pipelineSucceeded"] as? Bool ?? false,
    transcriptionCorrectnessPassed: outcome["transcriptionCorrectnessPassed"] as? Bool ?? false,
    cleanupCorrectnessPassed: outcome["cleanupCorrectnessPassed"] as? Bool ?? false,
    correctnessFailures: outcome["correctnessFailures"] as? [String] ?? [],
    failureStage: outcome["failureStage"] as? String,
    failureCategory: outcome["failureCategory"] as? String,
    sonioxConnectMS: number(durations["sonioxConnectMS"]),
    audioStreamingMS: number(durations["audioStreamingMS"]),
    sonioxFinalizeMS: number(durations["sonioxFinalizeMS"]),
    cleanupMS: number(durations["cerebrasCleanupMS"]),
    endOfAudioToCleanedMS: number(durations["endOfAudioToCleanedMS"]),
    providerTotalMS: number(providerTiming["totalMS"]),
    networkRequestMS: number(cleanup["networkRequestMS"]),
    timeToFirstByteMS: number(networkTiming["timeToFirstByteMS"]),
    connectionReused: networkTiming["connectionReused"] as? Bool,
    finalAudioProcessedMS: number(stt["finalAudioProcessedMS"]),
    audioDurationMS: number(stt["audioDurationMS"]))
}

guard !samples.isEmpty else {
  print("No synthetic Soniox + Cerebras records found in \(inputURL.path)")
  exit(0)
}

print("Synthetic Soniox + Cerebras benchmark")
print("Source: \(inputURL.path)")
print("Records: \(samples.count) (malformed lines ignored: \(malformedLines))")
if samples.contains(where: { $0.comparisonPair != nil }) {
  for enabled in [false, true] {
    let group = samples.filter { $0.warmingEnabled == enabled }
    print("\nWarming \(enabled ? "ON" : "OFF"): \(group.count) samples")
    summarize(group)
  }
} else {
  summarize(samples)
}

func summarize(_ samples: [Sample]) {
  report("End of audio to cleaned text", samples.compactMap(\.endOfAudioToCleanedMS))
  report("Soniox finalization", samples.compactMap(\.sonioxFinalizeMS))
  report("Cerebras cleanup", samples.compactMap(\.cleanupMS))
  report("Cerebras provider queue", samples.compactMap(\.providerQueueMS))
  report("Cerebras provider total", samples.compactMap(\.providerTotalMS))
  report("Cerebras client/network overhead", samples.compactMap(\.clientNetworkOverheadMS))
  report("Cerebras time to first byte", samples.compactMap(\.timeToFirstByteMS))
  report("Soniox connection", samples.compactMap(\.sonioxConnectMS))
  report("Synthetic audio streaming", samples.compactMap(\.audioStreamingMS))
  report("Final-audio coverage difference", samples.compactMap(\.finalAudioCoverageMS))

  let pipelineSuccesses = samples.filter(\.pipelineSucceeded).count
  let transcriptionPasses = samples.filter(\.transcriptionCorrectnessPassed).count
  let cleanupPasses = samples.filter(\.cleanupCorrectnessPassed).count
  let reused = samples.compactMap(\.connectionReused)
  let reuseCount = reused.filter { $0 }.count
  print(
    "Gates: pipeline-success=\(pipelineSuccesses)/\(samples.count), "
      + "transcription-correctness=\(transcriptionPasses)/\(samples.count), "
      + "cleanup-correctness=\(cleanupPasses)/\(samples.count)")
  print("Cerebras connection reuse: \(reuseCount)/\(reused.count)")

  let failureCounts = Dictionary(
    grouping: samples.compactMap { sample -> String? in
      if let stage = sample.failureStage, let category = sample.failureCategory {
        return "\(stage):\(category)"
      }
      return nil
    }, by: { $0 }
  ).mapValues(\.count)
  let correctnessCounts = Dictionary(
    grouping: samples.flatMap(\.correctnessFailures), by: { $0 }
  ).mapValues(\.count)
  print("Pipeline failure categories: \(failureCounts)")
  print("Correctness failure categories: \(correctnessCounts)")

  print("Slowest post-audio samples:")
  for sample in samples.sorted(by: {
    ($0.endOfAudioToCleanedMS ?? -.infinity) > ($1.endOfAudioToCleanedMS ?? -.infinity)
  }).prefix(5) {
    print(
      "- sample \(sample.index) at \(sample.startedAt): "
        + "post-audio=\(format(sample.endOfAudioToCleanedMS)), "
        + "soniox=\(format(sample.sonioxFinalizeMS)), cleanup=\(format(sample.cleanupMS)), "
        + "provider=\(format(sample.providerTotalMS)), "
        + "reused=\(sample.connectionReused.map(String.init) ?? "n/a")")
  }
}
