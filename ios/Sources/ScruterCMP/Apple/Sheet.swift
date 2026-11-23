#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// What the sheet's views share: the model, the step shown, the switches, and the way out.
final class CMPSheetState: ObservableObject {
    let model: SheetModel
    /// `nil`: the first layer; else the index of the purpose shown in the Personnaliser steps.
    @Published var step: Int?
    @Published var granted: Set<String>
    /// Drives the appearance and the leave (the sheet slides, or fades under Reduce Motion).
    @Published var shown = false
    @Published var copied = false
    /// The TCF layers (§6): what the visitor touched, a page over the steps or the preferences.
    @Published var tcfChoice = TcfChoice()
    @Published var tcfMoved = false
    @Published var page: CMPTcfPage?
    var touched = Set<String>()
    private var pages: [CMPTcfPage?] = []
    var decide: (SheetDecision) -> Void = { _ in }
    var close: () -> Void = {}
    var open: (URL) -> Void = { _ in }

    @_optimize(size) init(model: SheetModel, shown: Bool = false) {
        self.model = model
        granted = model.granted
        self.shown = shown
    }

    var source: CMPSource { model.kind == .banner ? .banner : .preferences }

    @_optimize(size) func acceptAll() { decide(SheetDecision(action: .acceptAll, granted: Set(model.purposes.map { $0.key }), source: source)) }
    @_optimize(size) func rejectAll() { decide(SheetDecision(action: .rejectAll, granted: [], source: source)) }
    @_optimize(size) func continueWithout() { decide(SheetDecision(action: .close, granted: [], source: .banner)) }
    @_optimize(size) func save() { decide(SheetDecision(action: nil, granted: granted, source: source, tcf: settledTcf())) }

    @_optimize(size) func toggle(_ key: String, _ on: Bool) {
        if on { granted.insert(key) } else { granted.remove(key) }
        // The IAB purposes and partners not touched follow the banner purposes from now on.
        if model.tcf != nil { tcfMoved = true }
    }

    @_optimize(size) func go(_ p: CMPTcfPage) {
        pages.append(page)
        animate { self.page = p }
    }

    @_optimize(size) func back() {
        let p = pages.popLast() ?? nil
        animate { self.page = p }
    }

    /// The first layer's links: « Voir nos n partenaires » opens the partners' step, « Intérêt légitime » the step of
    /// the objections.
    @_optimize(size) func openTcf(_ what: String) {
        guard let t = model.tcf else { return }
        let i = what == "li" ? t.liPlace.flatMap { k in model.purposes.firstIndex { $0.key == k } } : nil
        animate { self.step = i ?? self.model.purposes.count }
    }

    @_optimize(size) func animate(_ f: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled { f() } else { withAnimation(.easeInOut(duration: 0.25), f) }
    }
}

/// The sheet's controller: presented over the app (`overFullScreen`), never dismissed by a gesture (§2.2).
final class CMPSheetController: UIHostingController<CMPSheetRoot> {
    let state: CMPSheetState
    var onDecision: (SheetDecision) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onAppear: () -> Void = {}
    var openURL: (URL) -> Void = { _ in }
    private var leaving = false

    @_optimize(size) init(model: SheetModel) {
        state = CMPSheetState(model: model)
        super.init(rootView: CMPSheetRoot(state: state))
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
        state.decide = { [weak self] d in
            guard let self = self, !self.leaving else { return }
            self.onDecision(d)
        }
        state.close = { [weak self] in
            guard let self = self, !self.leaving else { return }
            self.onClose()
        }
        state.open = { [weak self] in self?.openURL($0) }
    }

    @available(*, unavailable)
    @_optimize(size) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @_optimize(size) override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
    }

    @_optimize(size) override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !state.shown else { return }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.9)) {
            state.shown = true
        }
        onAppear()
    }

    /// The sheet goes (after a decision, or the preferences' close button), then the controller.
    @_optimize(size) func leave(animated: Bool, completion: @escaping () -> Void) {
        guard !leaving else { return }
        leaving = true
        withAnimation(.easeIn(duration: animated ? 0.22 : 0)) { state.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.24 : 0)) {
            self.presentingViewController?.dismiss(animated: false, completion: completion) ?? completion()
        }
    }

    /// VoiceOver's escape gesture: « Continuer sans accepter » when the banner has it, the close button of the
    /// preferences; nothing else closes the first layer.
    @_optimize(size) override func accessibilityPerformEscape() -> Bool {
        if state.page != nil {
            state.back()
            return true
        }
        if state.model.kind == .preferences {
            state.close()
            return true
        }
        if state.step != nil {
            state.step = state.step == 0 ? nil : state.step! - 1
            return true
        }
        if state.model.closeLink {
            state.continueWithout()
            return true
        }
        return false
    }
}

/// The scrim and the sheet: a bottom sheet on phones, a 480 pt card in the centre from 600 pt (§2.2, board M3).
struct CMPSheetRoot: View {
    @ObservedObject var state: CMPSheetState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dark: Bool { state.model.theme == "dark" || (state.model.theme == "auto" && scheme == .dark) }

    @_optimize(size) var body: some View {
        // With the IAB TCF, the primary buttons' text at 5:1 (TCF Policies, Appendix B C(g)), as on the web.
        let palette = Palette.make(color: state.model.color, dark: dark, min: state.model.tcf != nil ? 5 : 0)
        GeometryReader { geo in
            let tablet = geo.size.width >= 600 && geo.size.height >= 600
            ZStack(alignment: tablet ? .center : .bottom) {
                Color(.sRGB, red: 23 / 255, green: 19 / 255, blue: 31 / 255, opacity: dark ? 0.6 : 0.4)
                    .opacity(state.shown ? 1 : 0)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                if state.shown {
                    CMPCard(state: state, palette: palette, tablet: tablet, size: geo.size, insets: geo.safeAreaInsets)
                        .transition(reduceMotion ? .opacity : tablet ? .opacity.combined(with: .scale(scale: 0.96)) : .move(edge: .bottom))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.bottom, alignment: tablet ? .center : .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.layoutDirection, state.model.rtl ? .rightToLeft : .leftToRight)
        .environment(\.locale, Locale(identifier: state.model.lang))
    }
}

/// One card: the band, the content (first layer, a step, or the preferences), the buttons.
struct CMPCard: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette
    let tablet: Bool
    let size: CGSize
    let insets: EdgeInsets
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    private var model: SheetModel { state.model }
    private var width: CGFloat { tablet ? 480 : min(size.width, 640) }
    private var maxHeight: CGFloat {
        tablet ? min(size.height * 0.9, size.height - 40) : size.height + insets.bottom - 8
    }

    /// The scrolling part's height: its content's, within what the band and the buttons leave (the tall preferences
    /// sheet on a phone takes all of it).
    private var scrollHeight: CGFloat {
        let room = max(0, maxHeight - chromeHeight)
        return model.kind == .preferences && !tablet ? room : min(contentHeight, room)
    }

    @_optimize(size) var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.kind == .preferences {
                    CMPPreferencesHeader(state: state, palette: palette)
                } else if model.closeLink {
                    CMPBand(state: state, palette: palette)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .cmpMeasureChrome()
            ScrollView {
                Group {
                    if let page = state.page {
                        CMPTcfPageView(state: state, palette: palette, page: page)
                    } else if model.kind == .preferences {
                        CMPPreferences(state: state, palette: palette)
                    } else if let i = state.step {
                        CMPStep(state: state, palette: palette, index: i)
                    } else {
                        CMPFirstLayer(state: state, palette: palette, tablet: tablet, width: width)
                    }
                }
                .cmpMeasureHeight()
            }
            .frame(height: scrollHeight)
            .onPreferenceChange(CMPHeightKey.self) { contentHeight = $0 }
            actions.fixedSize(horizontal: false, vertical: true).cmpMeasureChrome()
        }
        .onPreferenceChange(CMPChromeKey.self) { chromeHeight = $0 }
        .frame(width: width)
        .background(palette.surface.color)
        .clipShape(tablet ? CMPCorners(radius: 22, corners: .allCorners) : CMPCorners(radius: model.kind == .preferences ? 14 : 28, corners: [.topLeft, .topRight]))
        .shadow(color: Color.black.opacity(0.25), radius: 30, x: 0, y: tablet ? 20 : -10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier(model.kind == .banner ? "scruter-cmp-sheet" : "scruter-cmp-preferences")
    }

    @ViewBuilder private var actions: some View {
        let t = model.texts
        let items: [CMPButtonRow.Item] = {
            if model.kind == .preferences {
                return [
                    .init(title: t.reject_all, primary: false, id: "reject-all", action: state.rejectAll),
                    .init(title: t.save, primary: false, id: "save", action: state.save),
                    .init(title: t.accept_all, primary: true, id: "accept-all", action: state.acceptAll),
                ]
            }
            if let i = state.step {
                let last = i == model.stepCount - 1
                return [
                    .init(title: t.reject_all, primary: false, id: "reject-all", action: state.rejectAll),
                    last
                        ? .init(title: t.save, primary: false, id: "save", action: state.save)
                        : .init(title: model.words.next, primary: false, id: "next", action: { withStep(i + 1) }),
                    .init(title: t.accept_all, primary: true, id: "accept-all", action: state.acceptAll),
                ]
            }
            var row: [CMPButtonRow.Item] = []
            if !model.twoButtons { row.append(.init(title: t.reject_all, primary: false, id: "reject-all", action: state.rejectAll)) }
            if !model.purposes.isEmpty {
                row.append(.init(title: t.customize, primary: false, id: "customize", action: { withStep(0) }))
            }
            row.append(.init(title: t.accept_all, primary: true, id: "accept-all", action: state.acceptAll))
            return row
        }()
        VStack(spacing: 8) {
            CMPButtonRow(items: items, palette: palette, width: width - 32)
            if model.branding && !model.closeLink && model.kind == .banner {
                HStack(spacing: 5) {
                    CMPMark().stroke(palette.secondary.color, style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 12, height: 12)
                    Text(model.words.by + " Scruter").font(.caption2).foregroundColor(palette.secondary.color)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, tablet ? 16 : max(16, insets.bottom))
        .overlay(palette.line.color.frame(height: 1), alignment: .top)
        .layoutPriority(1)
        .accessibilitySortPriority(-1)
    }

    @_optimize(size) private func withStep(_ i: Int?) {
        if UIAccessibility.isReduceMotionEnabled {
            state.step = i
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { state.step = i }
        }
    }
}

/// The header band (docs/CMP.md §4.5): « Certifié par Scruter » on the left, « Continuer sans accepter » on the
/// right, in the brand colour.
struct CMPBand: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette
    @Environment(\.dynamicTypeSize) private var typeSize

    @_optimize(size) var body: some View {
        // At the largest text sizes its two elements stack, so both stay whole and reachable (board M3).
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    certified
                    pill.padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    certified
                    Spacer(minLength: 4)
                    pill
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .frame(minHeight: 40)
        .background(palette.brand.color)
        .layoutPriority(1)
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(-2)
    }

    @_optimize(size) private var certified: some View {
        let on = palette.onBrand.color
        return Button {
            if let u = URL(string: SheetModel.certifiedURL) { state.open(u) }
        } label: {
            HStack(spacing: 6) {
                CMPMark().stroke(on, style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 14, height: 14)
                Text(state.model.words.certified + " Scruter").font(.footnote).underline().foregroundColor(on)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(CMPPressStyle())
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("scruter-cmp-certified")
    }

    @_optimize(size) private var pill: some View {
        let on = palette.onBrand.color
        let label = palette.onBrand == .white ? RGB.ink.color : RGB.white.color
        return Button(action: state.continueWithout) {
            HStack(spacing: 4) {
                Text(state.model.texts.close).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.forward").font(.caption2.weight(.bold)).accessibilityHidden(true)
            }
            .foregroundColor(label)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(Capsule().fill(on))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(CMPPressStyle())
        .accessibilityIdentifier("scruter-cmp-close")
    }
}

/// The first layer (board M1, 1): the media, the app's icon astride it, the kicker, the title, the message, the
/// privacy policy link.
struct CMPFirstLayer: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette
    let tablet: Bool
    let width: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var titleFocused: Bool

    private var model: SheetModel { state.model }
    /// At the largest text sizes the media and the icon give their room to the text (board M3).
    private var large: Bool { typeSize.isAccessibilitySize }
    private var media: Bool { !large && !model.noPanel && !(model.hero?.phone == "hide" && !tablet) }

    @_optimize(size) var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if media {
                CMPHero(model: model, palette: palette, height: model.hero == nil ? 58 : tablet ? 120 : 92, width: width)
            }
            VStack(alignment: .leading, spacing: 0) {
                if media, let logo = model.logoURL {
                    CMPLogo(url: logo, icon: model.logoIsIcon, palette: palette)
                        .padding(.top, -40)
                        .padding(.bottom, 10)
                } else if !media {
                    Spacer().frame(height: 16)
                }
                HStack(alignment: .center, spacing: 12) {
                    if !media && !large, let logo = model.logoURL {
                        CMPLogo(url: logo, icon: model.logoIsIcon, palette: palette)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let k = model.texts.kicker, !k.isEmpty {
                            Text(k).font(.footnote.weight(.semibold)).foregroundColor(palette.accent.color)
                        }
                        Text(model.texts.title)
                            .font(.title2.weight(.bold))
                            .foregroundColor(palette.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($titleFocused)
                            .accessibilityIdentifier("scruter-cmp-title")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilitySortPriority(3)
                }
                if model.tcf != nil {
                    // The IAB text in the message's place, the policy among its links (docs/CMP.md §4.7, board M7).
                    CMPTcfFirst(state: state, palette: palette).accessibilitySortPriority(2)
                } else {
                    Text(model.texts.message)
                        .font(.subheadline)
                        .foregroundColor(palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .accessibilitySortPriority(2)
                }
                if model.tcf != nil {
                    EmptyView()
                } else if let p = model.policyURL, let url = URL(string: p) {
                    Button {
                        state.open(url)
                    } label: {
                        Text(model.words.privacy).font(.subheadline.weight(.semibold)).underline().foregroundColor(palette.text.color)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CMPPressStyle())
                    .accessibilityAddTraits(.isLink)
                    .accessibilityRemoveTraits(.isButton)
                    .accessibilitySortPriority(1)
                    .accessibilityIdentifier("scruter-cmp-policy")
                } else {
                    Spacer().frame(height: 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { titleFocused = true }
        }
    }
}

/// The media header: the photo, the video loop over its poster, or the tinted panel; its lower edge.
struct CMPHero: View {
    let model: SheetModel
    let palette: Palette
    let height: CGFloat
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var scale
    @State private var videoFile: URL?
    @State private var videoReady = false
    @State private var playing = true
    @State private var userStarted = false

    private var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    private var autoplay: Bool { !reduceMotion && !lowPower }

    @_optimize(size) var body: some View {
        ZStack(alignment: .bottomTrailing) {
            palette.tint.color
            if let hero = model.hero {
                let poster = CMPMedia.poster(hero, points: width, scale: scale)
                let focal = hero.focal ?? [50, 50]
                GeometryReader { g in
                    CMPRemoteImage(url: poster)
                        .frame(width: g.size.width, height: g.size.height, alignment: Alignment(
                            horizontal: focal[0] < 34 ? .leading : focal[0] > 66 ? .trailing : .center,
                            vertical: focal.count > 1 && focal[1] < 34 ? .top : focal.count > 1 && focal[1] > 66 ? .bottom : .center))
                        .clipped()
                    if let f = videoFile {
                        CMPLoop(file: f, playing: playing) { withAnimation(.easeOut(duration: 0.4)) { videoReady = true } }
                            .frame(width: g.size.width, height: g.size.height)
                            .opacity(videoReady ? 1 : 0)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(model.texts.hero_alt ?? "")
                .accessibilityHidden((model.texts.hero_alt ?? "").isEmpty)
                if hero.type == "video", CMPMedia.video(hero, points: width, scale: scale) != nil {
                    Button {
                        if videoFile == nil {
                            userStarted = true
                            loadVideo(hero)
                        } else {
                            playing.toggle()
                        }
                    } label: {
                        Image(systemName: videoFile != nil && playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CMPPressStyle())
                    .accessibilityLabel(videoFile != nil && playing ? model.words.pause : model.words.play)
                    .accessibilityIdentifier("scruter-cmp-video")
                    .padding(.trailing, 6)
                    .padding(.bottom, 14)
                    .onAppear {
                        // The video is requested only after the sheet's first frame, and never under Reduce Motion or
                        // Low Power Mode (§2.4).
                        if autoplay { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loadVideo(hero) } }
                    }
                }
            } else {
                CMPRings(color: palette.brand.color)
                    .offset(x: 30, y: -46)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(
            CMPEdge(kind: model.hero?.edge ?? "curve").fill(palette.surface.color).frame(height: 22).offset(y: 1),
            alignment: .bottom)
    }

    @_optimize(size) private func loadVideo(_ hero: HeroUi) {
        guard videoFile == nil, let u = CMPMedia.video(hero, points: width, scale: scale) else { return }
        CMPMedia.shared.fetch(u) { f in
            DispatchQueue.main.async {
                videoFile = f
                playing = true
            }
        }
    }
}

/// The app's icon on its plate (`logo_mode: auto`), or the uploaded logo on a wider plate; never a monogram.
struct CMPLogo: View {
    let url: String
    let icon: Bool
    let palette: Palette

    @_optimize(size) var body: some View {
        Group {
            if icon {
                CMPRemoteImage(url: url, contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.dark ? palette.soft.color : RGB.white.color))
            } else {
                CMPRemoteImage(url: url, contentMode: .fit)
                    .frame(maxWidth: 160, maxHeight: 24)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.dark ? palette.soft.color : RGB.white.color))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: icon ? 14 : 12, style: .continuous).strokeBorder(palette.line.color, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.18), radius: 9, x: 0, y: 6)
        .accessibilityHidden(true)
    }
}

/// One Personnaliser step (board M1, 2): « Étape n sur N », back, one purpose and its switch (off unless granted),
/// its description and providers.
struct CMPStep: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette
    let index: Int
    @AccessibilityFocusState private var focused: Bool

    @_optimize(size) var body: some View {
        let model = state.model
        let total = model.stepCount
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if UIAccessibility.isReduceMotionEnabled {
                        state.step = index == 0 ? nil : index - 1
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) { state.step = index == 0 ? nil : index - 1 }
                    }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(palette.text.color)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CMPPressStyle())
                .accessibilityLabel(model.words.back)
                .accessibilityIdentifier("scruter-cmp-back")
                Text(model.stepOf(index + 1, total))
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(palette.secondary.color)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ForEach(0..<total, id: \.self) { i in
                        Capsule().fill(i <= index ? palette.brand.color : palette.line.color).frame(width: 24, height: 6)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.leading, -10)
            .padding(.bottom, 10)
            if index < model.purposes.count {
                purpose(model.purposes[index])
            } else {
                CMPTcfPartners(state: state, palette: palette).accessibilityFocused($focused)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } }
        .id(index)
    }

    @ViewBuilder private func purpose(_ p: SheetModel.Purpose) -> some View {
        let model = state.model
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: CMPIcons.purpose(p.key))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(palette.accent.color)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.soft.color))
                    .accessibilityHidden(true)
                Toggle(isOn: Binding(get: { state.granted.contains(p.key) }, set: { state.toggle(p.key, $0) })) {
                    Text(p.name)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(palette.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(SwitchToggleStyle(tint: palette.brand.color))
                .accessibilityFocused($focused)
                .accessibilityIdentifier("scruter-cmp-switch-" + p.key)
            }
            if !p.description.isEmpty {
                Text(p.description)
                    .font(.subheadline)
                    .foregroundColor(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if !p.providers.isEmpty {
                Text(model.words.providers + " · " + String(p.providers.count))
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundColor(palette.secondary.color)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(p.providers, id: \.self) { name in
                        palette.line.color.frame(height: 1)
                        Text(name)
                            .font(.subheadline)
                            .foregroundColor(palette.text.color)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
            if model.tcf != nil {
                // The IAB purposes grouped under this purpose (board M15, 1).
                CMPTcfPurposes(state: state, palette: palette, key: p.key)
            }
    }
}

/// The preferences' header (board M4, 3): their title and the close button.
struct CMPPreferencesHeader: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette

    @_optimize(size) var body: some View {
        HStack(spacing: 12) {
            Text(state.model.texts.preferences_title)
                .font(.title3.weight(.bold))
                .foregroundColor(palette.text.color)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: state.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(palette.text.color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(palette.soft.color))
            }
            .buttonStyle(CMPPressStyle())
            .accessibilityLabel(state.model.words.close)
            .accessibilityIdentifier("scruter-cmp-preferences-close")
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .layoutPriority(1)
    }
}

/// The preferences (board M4, 3): every purpose and its state, the receipt; « Tout refuser » after a consent withdraws it.
struct CMPPreferences: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette

    @_optimize(size) var body: some View {
        let model = state.model
        VStack(alignment: .leading, spacing: 0) {
            if !model.texts.preferences_intro.isEmpty {
                Text(model.texts.preferences_intro)
                    .font(.subheadline)
                    .foregroundColor(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }
            ForEach(model.required, id: \.key) { p in
                row(p) {
                    Text(model.words.always).font(.footnote.weight(.semibold)).foregroundColor(palette.secondary.color)
                }
            }
            ForEach(model.purposes, id: \.key) { p in
                row(p) {
                    Toggle(isOn: Binding(get: { state.granted.contains(p.key) }, set: { state.toggle(p.key, $0) })) {
                        Text(p.name)
                    }
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: palette.brand.color))
                    .accessibilityLabel(p.name)
                    .accessibilityIdentifier("scruter-cmp-switch-" + p.key)
                }
            }
            if model.tcf != nil { CMPTcfPreferenceRows(state: state, palette: palette) }
            receipt.padding(.top, 12)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @_optimize(size) private func row<Trailing: View>(_ p: SheetModel.Purpose, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            palette.line.color.frame(height: 1)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.callout.weight(.semibold)).foregroundColor(palette.text.color)
                    if !p.providers.isEmpty {
                        Text(p.providers.joined(separator: ", ")).font(.footnote).foregroundColor(palette.secondary.color)
                    } else if !p.description.isEmpty {
                        Text(p.description).font(.footnote).foregroundColor(palette.secondary.color)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                trailing()
            }
            .padding(.vertical, 8)
            .frame(minHeight: 64)
        }
    }

    @ViewBuilder private var receipt: some View {
        let model = state.model
        VStack(alignment: .leading, spacing: 6) {
            if let id = model.consentId {
                Text(model.words.id + (model.words.colon.hasSuffix(" ") ? String(model.words.colon.dropLast()) : model.words.colon))
                    .font(.footnote)
                    .foregroundColor(palette.secondary.color)
                HStack(spacing: 8) {
                    Text(id)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(palette.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        UIPasteboard.general.string = id
                        state.copied = true
                        UIAccessibility.post(notification: .announcement, argument: model.words.copied)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state.copied = false }
                    } label: {
                        Text(state.copied ? model.words.copied : model.words.copy)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(palette.text.color)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CMPPressStyle())
                    .accessibilityIdentifier("scruter-cmp-copy")
                }
            } else {
                Text(model.words.noChoice).font(.footnote).foregroundColor(palette.secondary.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.soft.color))
    }
}

/// The confirmation after the choice (board M1, 3): 4 seconds, where to change it under it.
struct CMPToast: View {
    let model: SheetModel
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @_optimize(size) var body: some View {
        VStack {
            Spacer()
            if shown {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(.sRGB, red: 43 / 255, green: 196 / 255, blue: 138 / 255, opacity: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.words.saved).font(.subheadline.weight(.semibold)).foregroundColor(.white)
                        Text(model.words.savedHint).font(.footnote).foregroundColor(RGB(hex: "#D9D5E2")!.color)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 480)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(RGB.ink.color))
                .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                .padding(.horizontal, 16)
                .padding(.bottom, 100)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("scruter-cmp-saved")
            }
        }
        .environment(\.layoutDirection, model.rtl ? .rightToLeft : .leftToRight)
        .onAppear { withAnimation(.easeOut(duration: 0.3)) { shown = true } }
    }
}
#endif
