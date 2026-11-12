import Foundation

enum ClipboardHistoryPeriod:String,CaseIterable,Identifiable {
    case all="不限时间",today="今天",yesterday="昨天",week="最近 7 天",month="最近 30 天"
    var id:String {rawValue}
    func includes(_ date:Date,now:Date,calendar:Calendar)->Bool {
        guard self != .all else {return true}
        let today=calendar.startOfDay(for:now)
        guard let tomorrow=calendar.date(byAdding:.day,value:1,to:today) else {return false}
        let offset:Int
        switch self {
        case .today:offset=0
        case .yesterday:offset = -1
        case .week:offset = -6
        case .month:offset = -29
        case .all:return true
        }
        guard let start=calendar.date(byAdding:.day,value:offset,to:today) else {return false}
        let end=self == .yesterday ? today : tomorrow
        return date >= start && date < end
    }
}
