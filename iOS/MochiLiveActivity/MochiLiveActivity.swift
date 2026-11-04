import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MochiWidgets: WidgetBundle {
    var body: some Widget {
        MochiLiveActivity()
        WaitingWidget()
    }
}

/// Mochi and the Claude mascot on the Lock Screen and in the Dynamic Island while Claude works
/// on the Mac. Started and updated by the Mac through Apple's push service.
struct MochiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MochiActivityAttributes.self) { context in
            MochiLockScreenView(attributes: context.attributes, state: context.state)
                .background(MochiLockScreenBackground())
                .activityBackgroundTint(MochiStyle.background)
                .activitySystemActionForegroundColor(MochiStyle.accent)
        } dynamicIsland: { context in
            let state = context.state
            let (symbol, tint) = MochiStyle.glyph(for: state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseArt(kind: .sprite, phase: state.art, frame: state.frame, height: 40)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if state.showsTimer {
                            ElapsedTimer(since: state.sinceDate)
                        } else {
                            Image(systemName: symbol)
                        }
                    }
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .frame(maxWidth: 76, alignment: .trailing)
                    .padding(.trailing, 6)
                    .padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(state.title)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        if let detail = state.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PhaseArt(kind: .scene, phase: state.art, frame: state.frame, height: 64)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 2)
                }
            } compactLeading: {
                PhaseArt(kind: .sprite, phase: state.art, frame: state.frame, height: 22)
                    .padding(.leading, 2)
            } compactTrailing: {
                Group {
                    if state.showsTimer {
                        ElapsedTimer(since: state.sinceDate).frame(maxWidth: 44)
                    } else {
                        Image(systemName: symbol)
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            } minimal: {
                PhaseArt(kind: .sprite, phase: state.art, frame: state.frame, height: 20)
            }
            .keylineTint(MochiStyle.accent)
        }
    }
}
