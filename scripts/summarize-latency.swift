#!/usr/bin/env swift

import Foundation

struct Sample {
  let interactionID: String
  let startedAt: String
  let terminalResult: String
  let cleanupResult: String
  let isControlledBenchmark: Bool
  let requestSucceeded: Bool?
  let correctnessPassed: Bool?
  let correctnessFailures: [String]
  let coldEligible: Bool?
  let configuredIdleSeconds: Double?
  let leadTimeSeconds: Double?
  let httpStatus: Int?
  let stopToOutputMS: Double?
  let cleanupMS: Double?
  let requestEncodingMS: Double?
  let networkRequestMS: Double?
  let responseDecodingMS: Double?
  let providerQueueMS: Double?
  let providerPromptMS: Double?
  let providerCompletionMS: Double?
  let providerTotalMS: Double?
  let cachedPromptTokens: Int?
  let connectionReused: Bool?
  let networkProtocolName: String?
  let dnsMS: Double?
  let connectMS: Double?
  let secureConnectionMS: Double?
  let requestUploadMS: Double?
  let timeToFirstByteMS: Double?
  let responseDownloadMS: Double?

  var clientNetworkOverheadMS: Double? {
    guard let networkRequestMS, let providerTotalMS else { return nil }
    return networkRequestMS - providerTotalMS
  }
}

func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

func number(_ value: Any?) -> Double? {
  guard let number = value as? NSNumber else { return nil }
  return number.doubleValue
}

func integer(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber else { return nil }
  return number.intValue
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
    "\(name): n=\(values.count), mean=\(format(mean)), p50=\(format(percentile(values, 0.50))), "
      + "p90=\(format(percentile(values, 0.90))), max=\(format(values.max()))")
}

let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appending(path: "AeriVoice/Benchmarks/interactions-v1.jsonl")
let inputURL = CommandLine.arguments.dropFirst().first.map {
  URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
} ?? defaultURL

guard let data = try? Data(contentsOf: inputURL) else {
  FileHandle.standardError.write(Data("No latency log found at \(inputURL.path)\n".utf8))
  exit(66)
}

var malformedLines = 0
let samples: [Sample] = data.split(separator: 0x0A).compactMap { line in
  guard
    let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
  else {
    malformedLines += 1
    return nil
  }
  let isLiveBenchmark = root["fixtureID"] != nil
  let cleanup = isLiveBenchmark ? root : dictionary(root["cleanup"])
  let requestedProviderTag = cleanup["requestedProviderTag"] as? String
  let selectedProvider = cleanup["selectedProvider"] as? String
  guard
    isLiveBenchmark || requestedProviderTag == "cerebras-direct"
      || selectedProvider == "Cerebras"
  else {
    return nil
  }
  let durations = dictionary(root["durationsMS"])
  let providerTiming = dictionary(cleanup["providerTiming"])
  let networkTiming = dictionary(cleanup["networkTiming"])
  let outcome = dictionary(root["outcome"])
  return Sample(
    interactionID: root["interactionID"] as? String ?? root["fixtureID"] as? String ?? "unknown",
    startedAt: root["startedAt"] as? String ?? "unknown",
    terminalResult: outcome["terminalResult"] as? String
      ?? ((root["requestSucceeded"] as? Bool) == true ? "succeeded" : "failed"),
    cleanupResult: cleanup["result"] as? String
      ?? ((root["requestSucceeded"] as? Bool) == true ? "applied" : "failed"),
    isControlledBenchmark: isLiveBenchmark,
    requestSucceeded: root["requestSucceeded"] as? Bool,
    correctnessPassed: root["correctnessPassed"] as? Bool,
    correctnessFailures: root["correctnessFailures"] as? [String] ?? [],
    coldEligible: root["coldEligible"] as? Bool,
    configuredIdleSeconds: number(root["configuredIdleSeconds"]),
    leadTimeSeconds: number(root["leadTimeSeconds"]),
    httpStatus: integer(cleanup["httpStatus"]),
    stopToOutputMS: number(durations["stopToOutputMS"]),
    cleanupMS: number(durations["cleanupMS"]),
    requestEncodingMS: number(cleanup["requestEncodingMS"]),
    networkRequestMS: number(cleanup["networkRequestMS"]),
    responseDecodingMS: number(cleanup["responseDecodingMS"]),
    providerQueueMS: number(providerTiming["queueMS"]),
    providerPromptMS: number(providerTiming["promptMS"]),
    providerCompletionMS: number(providerTiming["completionMS"]),
    providerTotalMS: number(providerTiming["totalMS"]),
    cachedPromptTokens: integer(cleanup["cachedPromptTokens"]),
    connectionReused: networkTiming["connectionReused"] as? Bool,
    networkProtocolName: networkTiming["networkProtocolName"] as? String,
    dnsMS: number(networkTiming["dnsMS"]),
    connectMS: number(networkTiming["connectMS"]),
    secureConnectionMS: number(networkTiming["secureConnectionMS"]),
    requestUploadMS: number(networkTiming["requestUploadMS"]),
    timeToFirstByteMS: number(networkTiming["timeToFirstByteMS"]),
    responseDownloadMS: number(networkTiming["responseDownloadMS"]))
}

guard !samples.isEmpty else {
  print("No Cerebras cleanup records found in \(inputURL.path)")
  exit(0)
}

print("Cerebras cleanup latency")
print("Source: \(inputURL.path)")
print("Records: \(samples.count) (malformed lines ignored: \(malformedLines))")
report("Stop to output", samples.compactMap(\.stopToOutputMS))
report("Cleanup boundary", samples.compactMap(\.cleanupMS))
report("Local request encoding", samples.compactMap(\.requestEncodingMS))
report("URLSession request", samples.compactMap(\.networkRequestMS))
report("Local response decoding", samples.compactMap(\.responseDecodingMS))
report("Provider queue", samples.compactMap(\.providerQueueMS))
report("Provider prompt", samples.compactMap(\.providerPromptMS))
report("Provider completion", samples.compactMap(\.providerCompletionMS))
report("Provider total", samples.compactMap(\.providerTotalMS))
report("Client/network overhead", samples.compactMap(\.clientNetworkOverheadMS))
report("DNS", samples.compactMap(\.dnsMS))
report("Connection", samples.compactMap(\.connectMS))
report("TLS", samples.compactMap(\.secureConnectionMS))
report("Request upload", samples.compactMap(\.requestUploadMS))
report("Time to first byte", samples.compactMap(\.timeToFirstByteMS))
report("Response download", samples.compactMap(\.responseDownloadMS))

let controlledSamples = samples.filter(\.isControlledBenchmark)
if !controlledSamples.isEmpty {
  let qualifying = controlledSamples.filter {
    $0.requestSucceeded == true && $0.correctnessPassed == true && $0.coldEligible == true
      && ($0.configuredIdleSeconds ?? 0) >= 90
  }
  let requestSuccesses = controlledSamples.filter { $0.requestSucceeded == true }.count
  let correctnessPasses = controlledSamples.filter { $0.correctnessPassed == true }.count
  let coldEligible = controlledSamples.filter { $0.coldEligible == true }.count
  let idleValues = Set(controlledSamples.compactMap(\.configuredIdleSeconds)).sorted()
  let leadValues = Set(controlledSamples.compactMap(\.leadTimeSeconds)).sorted()
  print(
    "Controlled gate: qualifying=\(qualifying.count)/\(controlledSamples.count), "
      + "request-success=\(requestSuccesses), correctness-pass=\(correctnessPasses), "
      + "cold-eligible=\(coldEligible)")
  print("Configured idle seconds: \(idleValues)")
  print("Lead-time seconds: \(leadValues)")
  let correctnessFailureCounts = Dictionary(
    grouping: controlledSamples.flatMap(\.correctnessFailures), by: { $0 }
  ).mapValues(\.count)
  print("Correctness failure categories: \(correctnessFailureCounts)")
}

let cacheObserved = samples.compactMap(\.cachedPromptTokens)
if !cacheObserved.isEmpty {
  let cacheHits = cacheObserved.filter { $0 > 0 }.count
  print(
    "Prompt cache: \(cacheHits)/\(cacheObserved.count) requests had cached tokens "
      + "(\(String(format: "%.1f", 100 * Double(cacheHits) / Double(cacheObserved.count)))%)")
} else {
  print("Prompt cache: n/a")
}

let reuseObserved = samples.compactMap(\.connectionReused)
if !reuseObserved.isEmpty {
  let reused = reuseObserved.filter { $0 }.count
  print(
    "Connection reuse: \(reused)/\(reuseObserved.count) requests "
      + "(\(String(format: "%.1f", 100 * Double(reused) / Double(reuseObserved.count)))%)")
} else {
  print("Connection reuse: n/a")
}

let outcomeCounts = Dictionary(grouping: samples, by: \.terminalResult).mapValues(\.count)
let cleanupCounts = Dictionary(grouping: samples, by: \.cleanupResult).mapValues(\.count)
let statusCounts = Dictionary(grouping: samples.compactMap(\.httpStatus), by: { $0 }).mapValues(\.count)
let protocols = Dictionary(grouping: samples.compactMap(\.networkProtocolName), by: { $0 })
  .mapValues(\.count)
print("Terminal outcomes: \(outcomeCounts)")
print("Cleanup outcomes: \(cleanupCounts)")
print("HTTP statuses: \(statusCounts)")
print("Network protocols: \(protocols)")

let slowest = samples.compactMap { sample -> (Sample, Double, String)? in
  if let cleanupMS = sample.cleanupMS { return (sample, cleanupMS, "cleanup") }
  if let networkRequestMS = sample.networkRequestMS {
    return (sample, networkRequestMS, "request")
  }
  return nil
}.sorted { $0.1 > $1.1 }.prefix(5)

print("Slowest cleanup/request records:")
for (sample, latencyMS, latencyLabel) in slowest {
  print(
    "- \(sample.startedAt) \(sample.interactionID): \(latencyLabel)=\(format(latencyMS)), "
      + "provider=\(format(sample.providerTotalMS)), queue=\(format(sample.providerQueueMS)), "
      + "network=\(format(sample.networkRequestMS)), reused=\(sample.connectionReused.map(String.init) ?? "n/a")")
}
