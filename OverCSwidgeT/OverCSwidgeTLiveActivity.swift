//
//  OverCSwidgeTLiveActivity.swift
//  OverCSwidgeT
//
//  Created by Lukas on 29/10/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct OverCSwidgeTAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct OverCSwidgeTLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OverCSwidgeTAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension OverCSwidgeTAttributes {
    fileprivate static var preview: OverCSwidgeTAttributes {
        OverCSwidgeTAttributes(name: "World")
    }
}

extension OverCSwidgeTAttributes.ContentState {
    fileprivate static var smiley: OverCSwidgeTAttributes.ContentState {
        OverCSwidgeTAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: OverCSwidgeTAttributes.ContentState {
         OverCSwidgeTAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: OverCSwidgeTAttributes.preview) {
   OverCSwidgeTLiveActivity()
} contentStates: {
    OverCSwidgeTAttributes.ContentState.smiley
    OverCSwidgeTAttributes.ContentState.starEyes
}
