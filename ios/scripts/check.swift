import Foundation
import AVFoundation

@main struct ContractChecks {
    static func main() throws {
        func check(_ condition: Bool, _ label: String) throws {
            if !condition { throw APIError(message: "检查失败：" + label) }
        }
        try check(try API.normalizedNumber("13800000000") == "+8613800000000", "国内号码补国家码")
        try check(try API.normalizedNumber("+12025550123") == "+12025550123", "国际号码保留")
        try check(try API.normalizedSMSReplyNumber("10086") == "10086", "客服短号短信回复")
        try check(try API.normalizedSMSReplyNumber("13800000000") == "+8613800000000", "手机号短信回复")
        do { _ = try API.normalizedSMSReplyNumber("10;AT"); throw APIError(message: "短信回复误收非法号码") }
        catch let e as APIError { try check(e.message != "短信回复误收非法号码", "短信回复拒绝非法号码") }
        for short in ["110", "10086", "95347", "123456"] {
            try check(try API.normalizedDialNumber(short) == short, "短号拨号")
        }
        for number in ["01012345678", "057112345678", "23456789", "4001234567", "8001234567"] {
            try check(try API.normalizedDialNumber(number) == number, "座机或服务电话拨号")
        }
        try check(try API.normalizedDialNumber("13800000000") == "+8613800000000", "拨号手机号补国家码")
        try check(try API.numberFromSystemCallURL(URL(string: "tel:%2B86-138%200000%200000")!) == "+8613800000000", "系统号码交接")
        for invalid in ["tel:10086;AT", "tel://10086", "https://example.invalid/10086"] {
            do { _ = try API.numberFromSystemCallURL(URL(string: invalid)!); throw APIError(message: "接受了错误系统号码") }
            catch let e as APIError { try check(e.message != "接受了错误系统号码", "拒绝错误系统号码") }
        }
        for invalid in ["12", "1234567890123", "10086;ATH", "4001234567\nAT+CFUN=0", "１３８００００００００"] {
            do { _ = try API.normalizedDialNumber(invalid); throw APIError(message: "接受了错误拨号") }
            catch let e as APIError { try check(e.message != "接受了错误拨号", "拒绝错误拨号") }
        }
        do { _ = try API.normalizedNumber("10086"); throw APIError(message: "短信误收短号") }
        catch let e as APIError { try check(e.message != "短信误收短号", "短信规则未扩大") }
        for invalid in ["13800000000;AT", "123", "+012345678", "１３８００００００００"] {
            do { _ = try API.normalizedNumber(invalid); throw APIError(message: "接受了错误号码") }
            catch let e as APIError { try check(e.message != "接受了错误号码", "拒绝错误号码") }
        }
        for invalid in ["http://example.invalid", "https://user:secret@example.invalid", "https://example.invalid/api", "https://example.invalid?token=secret"] {
            do { _ = try API.baseURL(invalid); throw APIError(message: "接受了错误地址") }
            catch let e as APIError { try check(e.message != "接受了错误地址", "拒绝不安全地址") }
        }
        let sampleKey = "hdk_" + String(repeating: "a", count: 64)
        try check(try API.normalizedKey("Bearer " + sampleKey) == sampleKey, "App Key 格式")
        for invalid in ["web-password", "Bearer old-login-token", sampleKey + "\r\nInjected: value"] {
            do { _ = try API.normalizedKey(invalid); throw APIError(message: "接受了错误 Key") }
            catch let e as APIError { try check(e.message != "接受了错误 Key", "拒绝错误 Key") }
        }
        let url = try API.baseURL("https://example.invalid:40443/")
        try check(url.appendingPathComponent("api/auth/login").path == "/api/auth/login", "根路径拼接")
        let status = try JSONDecoder().decode(CallStatus.self, from: Data(#"{"state":"active","available":false,"recording":true}"#.utf8))
        try check(status.title == "设备暂不可用", "设备离线优先于旧通话状态")
        let contact = try JSONDecoder().decode(SMSContact.self, from: Data(#"{"peer":"demo","imsi":"sample","last_content":"示例","last_timestamp":"2026-09-22","unread_count":0}"#.utf8))
        try check(contact.id == "sample|demo", "旧短信字段兼容")
        let selectorContact = SMSContact(peer: "demo", iccid: "sample-card", imsi: "sample-imsi", device_id: "sample-device", last_content: "", last_timestamp: "", unread_count: 0)
        let selectors = API.threadQuery(selectorContact).map(\.name)
        try check(selectors.contains("iccid") && !selectors.contains("imsi") && !selectors.contains("device_id"), "短信会话 SIM 标识互斥")
        let encoded = API.requestURL(url, path: "voice-test/app/sms/thread", query: [.init(name: "peer", value: "+8613800000000")])
        let rawQuery = URLComponents(url: encoded, resolvingAgainstBaseURL: false)!.percentEncodedQuery!
        let formDecoded = rawQuery.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        try check(formDecoded == "peer=+8613800000000", "国际号码加号经过服务端表单查询解码保持原样")
        let frames = PCMFrames()
        let sample = Data(repeating: 7, count: 320)
        frames.append(sample)
        try check(frames.next().allSatisfy { $0 == 0 }, "未通话时不保留麦克风内容")
        frames.enable(true); frames.append(sample.prefix(100))
        try check(frames.next().count == 320, "不足一帧时填充静音")
        frames.append(sample.prefix(220))
        try check(frames.next() == sample, "采集分块合并为 20ms 帧")
        frames.append(Data(repeating: 9, count: 6400))
        for _ in 0..<10 { try check(frames.next() == Data(repeating: 9, count: 320), "弱网缓存最多 200ms") }
        try check(frames.next().allSatisfy { $0 == 0 }, "缓存不会无限增长")
        frames.append(sample); frames.enable(false); frames.enable(true)
        try check(frames.next().allSatisfy { $0 == 0 }, "静音/挂断立即清理残留语音")
        var signed = Data(repeating: 0, count: 320)
        signed[0] = 0; signed[1] = 128; signed[2] = 255; signed[3] = 127
        let decoded = PCMFrames.floatSamples(signed)!
        try check(decoded[0] == -1 && decoded[1] > 0.999, "S16_LE 正负满幅解码")
        try check(PCMFrames.floatSamples(Data(repeating: 0, count: 319)) == nil, "拒绝错误音频帧")
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 960)!
        input.frameLength = 960
        for i in 0..<960 { input.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 1000 / 48000)) * 0.5 }
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 320)!
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        converter.primeMethod = .none
        var provided = false
        var failure: NSError?
        let conversionStatus = converter.convert(to: output, error: &failure) { _, state in
            if provided { state.pointee = .noDataNow; return nil }
            provided = true; state.pointee = .haveData; return input
        }
        try check(failure == nil && conversionStatus != .error && output.frameLength == 160, "48kHz 采样转换为 8kHz 20ms")
        let converted = Data(bytes: output.int16ChannelData![0], count: 320)
        try check(PCMFrames.floatSamples(converted)!.contains { abs($0) > 0.2 }, "重采样保留有效声音")
        print("通过：号码、HTTPS/Key、短信互斥标识、20ms 音频分帧、缓存上限、静音清理、PCM 解码及 48k→8k 重采样。未联网、未启用麦克风。")
    }
}
