import SwiftUI

struct UsagePanelView: View {
    /// `false` renders the content without a scroll container, for `ImageRenderer`,
    /// which does not lay out a `ScrollView`.
    var scrolls = true

    @EnvironmentObject private var vm: UsageViewModel
    @EnvironmentObject private var updater: UpdaterController
    @AppStorage("section.limits") private var showLimits = true
    @AppStorage("section.tokens") private var showTokens = false
    @AppStorage("section.savings") private var showSavings = false

    private var now: Date { vm.now }
    private var week: Meter? { vm.gauge?.week }
    private var weekReset: PaceProjection? { week.flatMap { UsageMath.projection(for: $0, now: now) } }
    /// Only used for the sentences that extrapolate a rate.
    private var weekPace: PaceProjection? { (weekReset?.isMeaningful ?? false) ? weekReset : nil }

    /// The panel's natural height, measured through AppKit (see `remeasure`).
    @State private var contentHeight: CGFloat = 0

    /// The popover must fit under the menu bar, whatever sections are open.
    /// The popover may use the whole strip between the menu bar and the Dock. `visibleFrame`
    /// already excludes both, so only a small breathing margin comes off it. A fixed ceiling
    /// here is a bug: it clipped the default panel, which is 889pt tall once the gauge loads.
    private var maxHeight: CGFloat {
        let usable = NSScreen.main?.visibleFrame.height ?? 800
        return max(320, usable - 24)
    }

    /// A `ScrollView` has no intrinsic height: asked for its ideal size it answers
    /// almost nothing, and `maxHeight` only clamps, it never supplies one. Left that
    /// way the MenuBarExtra window collapses to a few points and the panel looks like
    /// it never opens. So the height is always concrete, and never zero.
    private var resolvedHeight: CGFloat {
        min(contentHeight > 0 ? contentHeight : Self.fallbackHeight, maxHeight)
    }
    private static let fallbackHeight: CGFloat = 560

    /// Re-measures the panel and stores its natural height.
    ///
    /// SwiftUI cannot measure this from the inside: the scroll view's height comes from the
    /// measurement, so during the sizing pass it proposes zero to its content and every
    /// reading comes back zero. Asking AppKit to size a non-scrolling copy has no such loop.
    private func remeasure() {
        contentHeight = PanelSizer.naturalHeight(of: UsagePanelView(scrolls: false).environmentObject(vm).environmentObject(updater))
    }

    /// Everything that changes how tall the panel wants to be. Text that merely gets longer
    /// is not tracked: it moves the height by a few points, and the scroll view absorbs that.
    private var layoutSignature: String {
        let gauge = vm.gauge
        return [
            showLimits.description, showTokens.description, showSavings.description,
            (gauge?.weeklyMeters.count ?? -1).description,
            (gauge?.session != nil).description,
            (vm.gaugeError != nil).description,
            vm.rtkInstalled.description, (vm.rtk != nil).description,
            vm.jevInstalled.description, (vm.stats.jevWeek.attempts > 0).description,
            (vm.stats.jevToday.compactions > 0).description,
        ].joined(separator: "|")
    }

    var body: some View {
        if scrolls {
            ScrollView(.vertical) { content }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: Theme.panelWidth, height: resolvedHeight)
                .onAppear {
                    remeasure()
                    // Opening the panel is a request to see current numbers; the gauge
                    // interval and the backoff still decide whether Anthropic is called.
                    Task { await vm.refresh() }
                }
                .onChange(of: layoutSignature) { _ in remeasure() }
        } else {
            content.frame(width: Theme.panelWidth)
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            hero
            if let error = vm.gaugeError { errorCard(error) }
            budgetCard
            limitsSection
            tokensSection
            if vm.rtkInstalled || vm.jevInstalled { savingsSection }
            settingsCard
        }
        .padding(10)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if let w = week {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(FR.num(w.utilization))
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.tone(used: w.utilization))
                        Text("%")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.tone(used: w.utilization))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.gaugeError == nil ? "Lecture…" : "Indisponible")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("Quota hebdomadaire")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if let reset = weekReset {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("RÉINITIALISATION")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text("dans " + FR.duration(reset.hoursLeft * 3600))
                        .font(.system(size: 16, weight: .bold))
                    Text(FR.dayTime(reset.resetsAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                }
            }
            if let w = week {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.tone(used: w.utilization))
                    Text("Quota hebdomadaire consommé")
                        .font(.system(size: 13, weight: .medium))
                }
                SegmentedBar(fraction: w.utilization / 100, color: Theme.tone(used: w.utilization))
            }
            if let p = weekPace ?? weekReset {
                Text(weekPace == nil ? "Semaine à peine entamée : le rythme n'est pas encore significatif."
                                     : paceSentence(p))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .card()
    }

    private func paceSentence(_ p: PaceProjection) -> String {
        if p.used >= 100 {
            return "Quota épuisé. Il se recharge à la réinitialisation."
        }
        if p.isOver {
            return "À ce rythme, le quota atteint \(FR.pct(p.landing)) : il sera épuisé avant la réinitialisation."
        }
        return "À ce rythme, le quota finira la semaine à \(FR.pct(p.landing)) : la marge est suffisante."
    }

    // MARK: - Cards

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compteurs Anthropic indisponibles")
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .card()
    }

    private var budgetCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BUDGET DU JOUR")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                if let p = weekReset {
                    Text(FR.pct(p.evenSharePerDay, decimals: 2))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                Text(budgetSentence)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .card()
    }

    private var budgetSentence: String {
        guard let p = weekReset else { return "En attente des compteurs Anthropic." }
        if p.remaining <= 0 { return "Plus rien à dépenser avant la réinitialisation." }
        return "Part quotidienne du quota restant (\(FR.pct(p.remaining))) répartie sur les \(FR.num(p.daysLeft, decimals: 1)) jours qui restent."
    }

    // MARK: - Sections

    private var limitsSection: some View {
        DisclosureCard(title: "Limites Anthropic par modèle",
                       icon: "gauge.with.dots.needle.33percent",
                       iconColor: .blue,
                       expanded: $showLimits) {
            if let gauge = vm.gauge {
                if let session = gauge.session { meterBlock(session, label: "Session en cours (5 h)") }
                ForEach(gauge.weeklyMeters) { meter in
                    Divider().opacity(0.4)
                    meterBlock(meter, label: meter.name == "all" ? "Tous modèles (7 jours)"
                                                                 : "Modèle \(Self.pretty(meter.name)) (7 jours)")
                }
            } else {
                InfoRow(label: "Lecture des compteurs", value: "en cours…")
            }
        }
    }

    /// `nimbus_quill` → `Nimbus Quill`
    static func pretty(_ name: String) -> String {
        name.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func meterBlock(_ meter: Meter, label: String) -> some View {
        let raw = UsageMath.projection(for: meter, now: now)
        let p = (raw?.isMeaningful ?? false) ? raw : nil
        let tone = Theme.tone(used: meter.utilization, landing: p?.landing)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(FR.pct(meter.utilization) + " utilisé")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone)
            }
            SegmentedBar(fraction: meter.utilization / 100, color: tone)
            if let raw {
                Text("Se réinitialise \(FR.dayTime(raw.resetsAt)), dans \(FR.duration(raw.hoursLeft * 3600)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let p {
                    Text("Rythme actuel \(FR.num(p.runningPerHour, decimals: 2)) %/h · rythme tenable \(FR.num(p.neededPerHour, decimals: 2)) %/h · fin de fenêtre prévue à \(FR.pct(p.landing))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Fenêtre trop récente pour projeter un rythme fiable.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Aucune date de réinitialisation communiquée pour ce compteur.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    private var tokensSection: some View {
        let s = vm.stats
        return DisclosureCard(title: "Tokens consommés",
                              icon: "text.alignleft",
                              iconColor: .purple,
                              expanded: $showTokens) {
            InfoRow(label: "Réponses de Claude aujourd'hui", value: FR.compact(s.messagesToday),
                    note: "\(FR.compact(s.messagesWeek)) sur les 7 derniers jours")
            Divider().opacity(0.4)
            InfoRow(label: "Tokens écrits par Claude aujourd'hui", value: FR.compact(s.outputToday),
                    note: "\(FR.compact(s.outputWeek)) sur la semaine")
            Divider().opacity(0.4)
            InfoRow(label: "Tokens de contexte lus aujourd'hui", value: FR.compact(s.readToday),
                    note: "entrée + cache lu + cache écrit · \(FR.compact(s.readWeek)) sur la semaine")
            Divider().opacity(0.4)
            InfoRow(label: "Sortie moyenne par réponse", value: FR.compact(s.avgOutputPerMessage) + " tokens")
            Divider().opacity(0.4)
            InfoRow(label: "Contexte moyen lu par réponse", value: FR.compact(s.avgReadPerMessage) + " tokens")
        }
    }

    private var savingsSection: some View {
        DisclosureCard(title: "Économies des outils",
                       icon: "scissors",
                       iconColor: .green,
                       expanded: $showSavings) {
            if vm.rtkInstalled { rtkRows }
            if vm.rtkInstalled && vm.jevInstalled { Divider().opacity(0.4) }
            if vm.jevInstalled { jevRows }
        }
    }

    @ViewBuilder private var rtkRows: some View {
        if let r = vm.rtk {
            InfoRow(label: "RTK · tokens évités aujourd'hui", value: FR.compact(r.today.savedTokens),
                    tint: .green,
                    note: "\(FR.pct(r.today.savingsPct, decimals: 1)) de \(FR.compact(r.today.inputTokens)) tokens, sur \(FR.compact(r.today.commands)) commandes filtrées")
            Divider().opacity(0.4)
            InfoRow(label: "RTK · tokens évités cette semaine", value: FR.compact(r.week.savedTokens),
                    note: "soit \(FR.pct(r.week.savingsPct, decimals: 1)) de moins qu'en sortie brute")
            Divider().opacity(0.4)
            InfoRow(label: "RTK · total depuis l'installation", value: FR.compact(r.allTime.savedTokens),
                    note: "\(FR.pct(r.allTime.savingsPct, decimals: 1)) économisés sur \(FR.compact(r.allTime.commands)) commandes")
        } else {
            InfoRow(label: "RTK · économies", value: "aucune donnée",
                    note: "rtk est installé mais « rtk gain » n'a encore rien à rapporter")
        }
    }

    @ViewBuilder private var jevRows: some View {
        let t = vm.stats.jevToday, w = vm.stats.jevWeek
        if w.attempts == 0 {
            InfoRow(label: "Jev · compactions", value: "aucune",
                    note: "aucune compaction n'est passée par fast-jev-compaction cette semaine")
        } else {
            let shown = t.compactions > 0 ? t : w
            InfoRow(label: "Jev · contexte élagué \(t.compactions > 0 ? "aujourd'hui" : "cette semaine")",
                    value: FR.pct(shown.avgReductionPct),
                    tint: .green,
                    note: "\(FR.compact(shown.messagesPruned)) messages retirés sur \(FR.compact(shown.messagesBefore)), le reste gardé mot pour mot")
            Divider().opacity(0.4)
            InfoRow(label: "Jev · compactions sans résumé", value: FR.compact(w.compactions),
                    note: w.fallbacks > 0
                        ? "\(FR.plural(w.fallbacks, "repli", "replis")) sur le résumé intégré cette semaine"
                        : "aucun repli sur le résumé intégré cette semaine")
        }
    }

    // MARK: - Settings

    private var settingsCard: some View {
        VStack(spacing: 0) {
            Button {
                Task { await vm.refresh(force: true) }
            } label: {
                ActionRow(icon: "arrow.clockwise", iconColor: .blue,
                          title: vm.isRefreshing ? "Actualisation en cours…" : "Actualiser maintenant",
                          subtitle: refreshSubtitle) {
                    if vm.isRefreshing { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.isRefreshing)
            Divider().opacity(0.4).padding(.leading, 46)
            Button { updater.checkForUpdates() } label: {
                ActionRow(icon: "arrow.down.circle", iconColor: .purple,
                          title: "Rechercher des mises à jour",
                          subtitle: "Version \(updater.currentVersion)")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!updater.canCheck)
            Divider().opacity(0.4).padding(.leading, 46)
            ActionRow(icon: "power", iconColor: .orange, title: "Lancer au démarrage") {
                Toggle("", isOn: $vm.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            Divider().opacity(0.4).padding(.leading, 46)
            Button { NSApplication.shared.terminate(nil) } label: {
                ActionRow(icon: "xmark.circle", iconColor: .red, title: "Quitter ClaudeMenu") {
                    Text(appVersion)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .card()
    }

    private var refreshSubtitle: String {
        if let next = vm.nextGaugeAttempt, vm.gaugeError != nil {
            let seen = vm.gauge.map { "Derniers compteurs \(FR.ago($0.fetchedAt, now: now))" } ?? "Compteurs jamais lus"
            return "\(seen) · nouvel essai dans \(FR.duration(next.timeIntervalSince(now)))"
        }
        guard let gauge = vm.gauge else { return "Les compteurs n'ont pas encore été lus" }
        return "Compteurs lus \(FR.ago(gauge.fetchedAt, now: now)) · tokens recomptés chaque minute"
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "v\(v)"
    }
}

/// Sizes a SwiftUI view the way a popover does: AppKit lays it out and reports the size it
/// asks for. Used to give the scroll view a concrete height without a measurement loop.
@MainActor
enum PanelSizer {
    /// The controller has to live in a window: outside one, `preferredContentSize` comes back
    /// larger than what the popover would use (640 instead of 559 on the default panel).
    private static let host: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        return window
    }()

    static func naturalHeight(of view: some View) -> CGFloat {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        host.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let height = controller.preferredContentSize.height
        host.contentViewController = nil
        return height
    }
}
