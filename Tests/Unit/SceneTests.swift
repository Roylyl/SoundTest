import XCTest
@testable import SoundTest

final class SceneTests: XCTestCase {
    private func scores(_ first: String, value: Double = 0.9) -> [RawScore] {
        SceneAnalysis.labels.enumerated().map { RawScore(index: $0.offset, label: $0.element, score: $0.element == first ? value : (1-value)/9) }
    }
    func testSmoothingWarmupTransitionAndUncertainty() {
        var smooth = SceneSmoother(); let options = SceneOptions()
        let a = scores("park"), b = scores("metro")
        for i in 0..<3 { XCTAssertNil(smooth.update(scores: a, start: Double(i), end: Double(i+1), padded: false, options: options).label) }
        XCTAssertEqual(smooth.update(scores:a,start:3,end:4,padded:false,options:options).label,"park")
        XCTAssertEqual(smooth.update(scores:b,start:4,end:5,padded:false,options:options).label,"park")
        XCTAssertNil(smooth.update(scores:b,start:5,end:6,padded:false,options:options).label)
        XCTAssertEqual(smooth.update(scores:b,start:6,end:7,padded:false,options:options).label,"metro")
        var uncertain = SceneSmoother()
        for i in 0..<4 {
            let p=uncertain.update(scores:scores("park",value:0.1),start:Double(i),end:Double(i+1),padded:false,options:options)
            XCTAssertNil(p.label)
            if i==3 { XCTAssertEqual(p.state,"不确定") }
        }
        let tail = smooth.update(scores:a,start:7,end:7.2,padded:true,options:options)
        XCTAssertNil(tail.label); XCTAssertEqual(tail.averagingCount,0)
    }
    func testActualBundledASCMatchesPythonReference() throws {
        let store = try SoundModelStore(), asset = try store.validate(.cpMobile)
        let engine = try CPMobileTagger(modelURL:store.folder(.cpMobile).appendingPathComponent(asset.modelFile), labelsURL:store.folder(.cpMobile).appendingPathComponent(asset.labelsFile))
        let bundle=Bundle(for: Self.self)
        let audio=try Data(contentsOf:XCTUnwrap(bundle.url(forResource:"asc-reference",withExtension:"f32")))
        let samples=audio.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
        let json=try Data(contentsOf:XCTUnwrap(bundle.url(forResource:"asc-reference",withExtension:"json")))
        let ref=try XCTUnwrap(JSONSerialization.jsonObject(with:json) as? [String:Any])
        let expected=try XCTUnwrap(ref["probabilities"] as? [Double])
        let result=try engine.classify(samples:samples,sampleRate:32000)
        XCTAssertEqual(result.map(\.label),SceneAnalysis.labels)
        for (actual,want) in zip(result,expected) { XCTAssertEqual(actual.score,want,accuracy:0.0001) }
        XCTAssertThrowsError(try engine.classify(samples:samples,sampleRate:16000))
        XCTAssertThrowsError(try engine.classify(samples:[.nan]+samples.dropFirst(),sampleRate:32000))
    }
    func testSceneRunnerAndLogRoundTripAt32k() throws {
        let runner=AnalysisRunner(), store=try SoundModelStore()
        let loaded=expectation(description:"loaded")
        runner.load(model:.cpMobile,store:store,threads:2) { result in
            if case .failure(let error)=result { XCTFail(error.localizedDescription) }
            loaded.fulfill()
        }
        wait(for:[loaded],timeout:30)
        var options=SoundOptions(); options.mode = .continuous; options.windowSeconds=1; options.stepSeconds=1; options.scene=SceneOptions()
        var record=SoundRecord(model:.cpMobile,asset:try store.asset(.cpMobile),options:options,device:"Simulator",actualInput:"file",actualInputUID:"file",material:MaterialInfo())
        record.taskType = .scenes; record.modelSampleRate=32000
        let finished=expectation(description:"finished")
        runner.onFinished = { result in
            XCTAssertEqual(result.audioSeconds,4.25,accuracy:0.0001)
            XCTAssertEqual(result.windows.count,5)
            XCTAssertTrue(result.events.isEmpty)
            XCTAssertTrue(result.windows.allSatisfy { $0.targets.isEmpty && $0.scene != nil })
            XCTAssertEqual(result.windows.last!.paddedSeconds,0.75,accuracy:0.0001)
            XCTAssertNil(result.windows.last!.scene!.label)
            do {
                try SoundSessionStore.save(result)
                let restored=try SoundSessionStore.load(result.id)
                XCTAssertEqual(restored.effectiveTask,.scenes)
                XCTAssertEqual(restored.windows.count,5)
                XCTAssertEqual(restored.modelSampleRate,32000)
                try SoundSessionStore.delete(restored)
            } catch { XCTFail(error.localizedDescription) }
            finished.fulfill()
        }
        runner.begin(record,isLive:false) { runner.analyzeFile([Float](repeating:0,count:136000)) }
        wait(for:[finished],timeout:30)
    }
    func testContinuousScenePCMAt32k() throws {
        let runner=AnalysisRunner(), store=try SoundModelStore()
        let loaded=expectation(description:"scene loaded")
        runner.load(model:.cpMobile,store:store,threads:2) { result in
            if case .failure(let error)=result { XCTFail(error.localizedDescription) }
            loaded.fulfill()
        }
        wait(for:[loaded],timeout:30)
        var options=SoundOptions(); options.mode = .continuous; options.windowSeconds=1; options.stepSeconds=0.5; options.scene=SceneOptions()
        options = try options.validated(for:.cpMobile)
        XCTAssertEqual(options.mappingVersion,"soundtest-asc-zh-v1")
        var record=SoundRecord(model:.cpMobile,asset:try store.asset(.cpMobile),options:options,device:"simulated PCM",actualInput:"generated PCM",actualInputUID:"test",material:MaterialInfo())
        record.taskType = .scenes; record.modelSampleRate=32000
        let finished=expectation(description:"scene live finished")
        finished.assertForOverFulfill = true
        runner.onFailure = { XCTFail($0) }
        runner.onWindow = { _, _ in Date() }
        runner.onFinished = { result in
            XCTAssertNil(result.error)
            XCTAssertEqual(result.audioSeconds,4,accuracy:0.0001)
            XCTAssertEqual(result.windows.count,7)
            XCTAssertEqual(result.windows.last!.start,3,accuracy:0.0001)
            XCTAssertEqual(result.windows.last!.end,4,accuracy:0.0001)
            XCTAssertTrue(result.windows.allSatisfy { $0.scene != nil && $0.scores.count == 10 && $0.queueDelayMS != nil })
            XCTAssertTrue(result.events.isEmpty)
            finished.fulfill()
        }
        runner.begin(record,isLive:true) {
            for _ in 0..<40 { runner.push([Float](repeating:0,count:3200),rate:32000) }
            runner.finish(stopTime:ProcessInfo.processInfo.systemUptime)
            runner.finish()
        }
        wait(for:[finished],timeout:30)
    }
    func testOldEventLogStillDecodesWithoutASCFields() throws {
        let store=try SoundModelStore()
        let record=SoundRecord(model:.yamnet,asset:try store.asset(.yamnet),options:SoundOptions(),device:"old",actualInput:"mic",actualInputUID:"mic",material:MaterialInfo())
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as? [String:Any])
        object["schemaVersion"]=1; object.removeValue(forKey:"taskType")
        let decoded=try JSONDecoder().decode(SoundRecord.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(decoded.effectiveTask,.events)
        try SoundSessionStore.save(decoded)
        XCTAssertEqual(try SoundSessionStore.load(decoded.id).schemaVersion,1)
        try SoundSessionStore.delete(decoded)
    }
    func testImport32kUsesOriginalFileAndPreservesDuration() throws {
        let bundle=Bundle(for:Self.self)
        let url=try XCTUnwrap(bundle.url(forResource:"1-34094-A-5",withExtension:"wav"))
        let audio=try AudioFileIO.load(url:url,sampleRate:32000)
        XCTAssertEqual(audio.sampleRate,32000); XCTAssertEqual(audio.samples.count,160000)
        XCTAssertEqual(audio.originalSampleRate,44100)
    }
}
