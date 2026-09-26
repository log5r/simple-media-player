import Foundation

// 再生中メディアの技術情報(LED領域の情報カラムに表示する値)をまとめて保持する。
// 表示項目を増やす場合は、(1) プロパティを1つ追加し、(2) ledRows に表示行を
// 1エントリ追加するだけでよい。値の供給側(AudioEngineService / VideoPlayerService)は
// この構造体を組み立てて onFormatLoaded で渡す
struct MediaFormatInfo: Equatable, Sendable {
    /// サンプリング周波数(Hz)。不明なら nil
    var sampleRateHz: Double?
    /// 音声ビットレート(kbps)。不明なら nil
    var bitrateKbps: Int?
    /// 動画フレームレート(fps)。音声のみ・不明なら nil
    var videoFrameRateFps: Double?
    /// コンテナ全体の総ビットレート(kbps)。不明なら nil
    var totalBitrateKbps: Int?

    static let empty = MediaFormatInfo()
}

// LED情報カラムの1行分(値+単位)。id は行の種類を表す固定文字列で、
// SwiftUI の ForEach がアニメーション時に行を同定するのに使う
struct LEDInfoRow: Identifiable, Equatable {
    let id: String
    let value: String
    let unit: String
}

extension MediaFormatInfo {
    // 表示順どおりの行リスト。値が無い(nil または 0 以下)項目は行ごと省く
    var ledRows: [LEDInfoRow] {
        var rows: [LEDInfoRow] = []
        if let bitrateKbps, bitrateKbps > 0 {
            rows.append(LEDInfoRow(id: "bitrate", value: String(bitrateKbps), unit: "kbps"))
        }
        if let sampleRateHz, sampleRateHz > 0 {
            rows.append(LEDInfoRow(id: "sampleRate", value: Self.compactText(sampleRateHz / 1000), unit: "kHz"))
        }
        if let videoFrameRateFps, videoFrameRateFps > 0 {
            rows.append(LEDInfoRow(id: "frameRate", value: Self.compactText(videoFrameRateFps), unit: "fps"))
        }
        if let totalBitrateKbps, totalBitrateKbps > 0 {
            rows.append(LEDInfoRow(id: "totalBitrate", value: String(totalBitrateKbps), unit: "kbps"))
        }
        return rows
    }

    // 44100Hz → "44.1"、48000Hz → "48" のように、整数なら小数点以下を省く
    private static func compactText(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
