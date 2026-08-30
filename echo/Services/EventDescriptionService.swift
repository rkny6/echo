import Foundation

/// 统一的事件消息生成服务，提供一致的事件描述文本
struct EventMessageService {
    /// 获取事件的描述文本（外部使用）
    public static func describe(_ event: CompanionEvent) -> String {
        switch event.type {
        case .outing:
            return "用户外出了。这可能是散步、出门活动或外出工作。"
            
        case .sleep:
            let severity = event.metadata["severity"] ?? "extreme"
            let reason = event.metadata["reason"]
            if let durationStr = event.metadata["duration"], let duration = Int(durationStr) {
                let hours = duration / 60
                let minutes = duration % 60
                if severity == "soft" {
                    switch reason {
                    case "oversleep":
                        return "用户昨晚睡得偏久（约\(hours)小时\(minutes)分钟），可以在上午自然关心一下她醒后的状态，语气轻、不要像告警。"
                    case "low_quality", "low_deep":
                        return "用户昨晚睡眠质量一般（约\(hours)小时\(minutes)分钟），可以在上午轻声关心一下她今天精不精神，不要夸张。"
                    default:
                        return "用户昨晚睡得不算理想（约\(hours)小时\(minutes)分钟），可以在上午自然关心一下，语气温柔、不要天天念叨。"
                    }
                }
                if reason == "oversleep" {
                    return "用户昨晚睡得过久，约\(hours)小时\(minutes)分钟，可以关心一下她是否休息得太沉或状态发懵。"
                }
                return "用户昨晚睡眠质量不佳，只睡了约\(hours)小时\(minutes)分钟。"
            }
            if severity == "soft" {
                return "用户昨晚睡眠不算理想，可以在上午轻声关心一下她的状态。"
            }
            return "用户最近睡眠不足，睡眠质量不佳。"
            
        case .lowSteps:
            if let stepsStr = event.metadata["steps"], let steps = Int(stepsStr) {
                return "用户今天步数较少，只走了\(steps)步。看起来比较久坐。"
            }
            return "用户今天活动量较少。"
            
        case .highSteps:
            if let stepsStr = event.metadata["steps"], let steps = Int(stepsStr) {
                return "用户今天步数很多，走了\(steps)步。看起来比较活跃。"
            }
            return "用户今天活动量很大。"

        case .lowHRV:
            return "用户最近的心率变异性（HRV）明显低于自己平时的水平，这通常提示压力较大、疲劳或恢复不足，可以关心一下用户最近的状态。"

        case .goodSteps:
            return "用户最近这几天的步数一直很稳定、活动量不错，可以夸夸用户最近的生活状态挺规律的。"

        case .goodHRV:
            return "用户最近的心率变异性（HRV）一直保持在自己平时的正常水平甚至更好，说明身体恢复状态不错，可以顺带提一句用户最近气色/状态看起来不错。"
            
        case .menstrualCycle:
            if let daysStr = event.metadata["daysUntilStart"], let days = Int(daysStr) {
                if days == 0 {
                    return "根据可靠的周期预测，她的月经期可能即将开始或已经开始。请温柔、自然地关心身体状态，不要像医疗提醒，也不要夸张或说教。"
                } else {
                    return "根据可靠的周期预测，她的月经期大约在\(days)天后开始。可以提前轻轻关心身体与安排，语气体贴、点到为止，本周期只提一次即可。"
                }
            }
            return "她的月经周期信息提示需要特别关注，请以体贴、自然的方式关心她，不要像医疗提醒。"
            
        case .birthday:
            return "今天是用户的生日，应该好好庆祝一下！"
            
        case .holiday:
            if let label = event.metadata["label"] as? String {
                return "今天是特殊的日子：\(label)，应该享受节日氛围。"
            }
            return "今天是法定节假日，用户应该好好放松休息。"
            
        case .weekend:
            if let label = event.metadata["label"] as? String {
                return "今天是：\(label)，用户可以好好放松休息了。"
            }
            return "今天是周末，用户应该好好放松休息。"
            
        case .onlineGreeting:
            return silenceCareDescription(for: event, evening: false)

        case .eveningCheckIn:
            return silenceCareDescription(for: event, evening: true)
        }
    }

    /// Prefer sleep-aware careTone; fall back to wall-clock hours for legacy metadata.
    private static func silenceCareDescription(for event: CompanionEvent, evening: Bool) -> String {
        let toneRaw = event.metadata["careTone"] as? String
        let tone = toneRaw.flatMap { ContactSilenceMetrics.CareTone(rawValue: $0) }
        let allowsMultiDay = (event.metadata["allowsMultiDayLanguage"] as? String) == "1"
            || ((event.metadata["calendarDaysApart"] as? String).flatMap(Int.init) ?? 0) >= 2
        let wallHours = (event.metadata["hoursSinceContact"] as? String).flatMap(Double.init)
        let awakeHours = (event.metadata["awakeHoursSinceContact"] as? String).flatMap(Double.init)

        let resolved = tone ?? {
            let h = wallHours ?? 0
            if h >= 48 { return ContactSilenceMetrics.CareTone.multiDay }
            if h >= 20 { return .sameDayLong }
            return .light
        }()

        switch resolved {
        case .multiDay where allowsMultiDay || (wallHours ?? 0) >= 48:
            if evening {
                return "已经跨过至少两天没有收到用户的消息；现在是晚上，可以轻声关心一下她是否还好，不要催促或质问，也不要夸张成更久。"
            }
            return "已经跨过至少两天没有收到用户的消息了，用户似乎很忙；可以真诚惦记，但不要指责。"
        case .overnight:
            if evening {
                return "中间主要是正常睡眠/夜间空档，不是被冷落；现在是晚上，随口关心一下即可，禁止说「几天」「很久」。"
            }
            return "间隔主要是正常睡眠/夜间空档，不是被冷落；像睡醒后自然打个招呼，禁止说「几天」「很久没见」。"
        case .sameDayLong:
            let awakeNote = awakeHours.map { "（清醒时段约\(Int($0))小时）" } ?? ""
            if evening {
                return "同一天里有好一阵子没有收到用户的消息\(awakeNote)；现在是晚上，轻声关心，点到为止，不要说「几天」。"
            }
            return "同一天里有好一阵子没和用户联系\(awakeNote)；可稍微关心，但不要说「几天」或「很久」。"
        case .light, .multiDay:
            if evening {
                return "有一段时间没和用户联系了；现在是晚上，可以轻声关心一下她的状态，不要夸张时间。"
            }
            return "有一段时间没和用户联系了；轻松打招呼即可，不要说「几天」或「很久」。"
        }
    }
}