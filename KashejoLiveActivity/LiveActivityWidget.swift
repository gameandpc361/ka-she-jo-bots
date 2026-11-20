import ActivityKit
import WidgetKit
import SwiftUI

struct KashejoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KashejoQueueAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack { Label("Kashejo 投稿キュー", systemImage: "paperplane.fill"); Spacer(); Text("\(context.state.completed)/\(context.state.total)").monospacedDigit() }
                ProgressView(value: Double(context.state.completed), total: Double(max(1, context.state.total)))
                Text(context.state.status).font(.caption).foregroundStyle(.secondary)
                if let next = context.state.nextAt { Text("次の処理予定: \(next, style: .time)").font(.caption2) }
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "paperplane.fill") }
                DynamicIslandExpandedRegion(.trailing) { Text("\(context.state.completed)/\(context.state.total)").monospacedDigit() }
                DynamicIslandExpandedRegion(.bottom) { VStack(alignment: .leading) { ProgressView(value: Double(context.state.completed), total: Double(max(1, context.state.total))); Text(context.state.status).font(.caption) } }
            } compactLeading: { Image(systemName: "paperplane.fill") }
              compactTrailing: { Text("\(context.state.completed)/\(context.state.total)").font(.caption2) }
              minimal: { Image(systemName: "paperplane.fill") }
        }
    }
}
