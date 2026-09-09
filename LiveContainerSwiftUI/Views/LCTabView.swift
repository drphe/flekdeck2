//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import ObjectiveC

struct LCTabView: View {
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""
    @State private var isiOSBeta = false

    @AppStorage("LCBetaBannerOverride", store: LCUtils.appGroupUserDefault) private var betaBannerOverride: Int = 0
    
    @State var previousSelectedTab : LCTabIdentifier = .apps
    @State private var isBlocked = false
    @State private var hasCheckedBlockedStatus = false
    @State private var didFailBlockedStatusCheck = false
    @State private var didRunPostGateStartup = false
    @State private var isVerifyingAccess = false
    @State private var accessVerificationFailureMessage = "Please check your internet connection and try again."
    @State private var blockedReason = "Unavailable"
    @State private var blockedMessage = "Your access has been limited by the service."
    @AppStorage("FSEncryptedUDID") private var encryptedUDID: String = ""
    
    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    
    @StateObject var searchContextAppList = SearchContext()
    @StateObject var searchContextSource = SearchContext()
    
    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    
    var body: some View {
        Group {
            if !hasCheckedBlockedStatus {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                }
            } else if didFailBlockedStatusCheck {  
                AccessVerificationFailedView(message: accessVerificationFailureMessage, udid: $encryptedUDID) {
                    Task {
                        await verifyAccess(forceNetworkCheck: true)
                    }
                }
            } else if isBlocked {
                AccessBlockedView(reason: blockedReason, message: blockedMessage)
            } else {
                LCAppListView(searchContext: searchContextAppList)
            }
        }
        .modifier(DeferBottomHomeGestureModifier())
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc) {}
            Button("lc.common.copy".loc) { copyError() }
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $crashReportShow) {
            NavigationView {
                ScrollView {
                    Text(errorInfo)
                        .font(.system(size: 12).monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("lc.common.copy".loc, action: {
                            copyError()
                        })
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error".loc)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            setupInitialRepositoriesIfNeeded()
            Task { await MultiRepoSearchModel.prefetchAllRepos() }
            await verifyAccess()
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onChange(of: sharedModel.selectedTab) { newValue in
            if newValue != LCTabIdentifier.search {
                previousSelectedTab = newValue
            }
        }
        .onChange(of: betaBannerOverride) { _ in
            updateBetaOverlay()
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(to: newPhase)
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
        .onChange(of: sharedModel.pendingOpenURL) { _ in
            processPendingURLIfNeeded()
        }
    }
    
    private func handleScenePhaseChange(to newPhase: ScenePhase) {
        guard newPhase == .active else { return }
        Task {
            await verifyAccess()
        }
    }
    
    func dispatchURL(url: URL) {
        if isBlocked || didFailBlockedStatusCheck || !hasCheckedBlockedStatus {
            sharedModel.pendingOpenURL = url
            return
        }
        repeat {
            if url.isFileURL {
                sharedModel.selectedTab = .apps
                break
            }
            if url.scheme?.lowercased() == "sidestore" {
                sharedModel.selectedTab = .apps
                break
            }
            
            guard let host = url.host?.lowercased() else {
                return
            }
            
            switch host {
            case "livecontainer-launch", "install", "open-web-page", "open-url":
                sharedModel.selectedTab = .apps
            case "certificate":
                sharedModel.selectedTab = .settings
            case "source":
                sharedModel.selectedTab = .sources
            default:
                return
            }
            
        } while(false)
        
        sharedModel.deepLink = url
    }

    func processPendingURLIfNeeded() {
        guard hasCheckedBlockedStatus, !isBlocked, !didFailBlockedStatusCheck,
              let url = sharedModel.pendingOpenURL else {
            return
        }
        sharedModel.pendingOpenURL = nil
        dispatchURL(url: url)
    }
    
    // MARK: - Existing helper functions
    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }
    
    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")
        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }
        guard let errorStr else { return }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }
    
    func copyError() { UIPasteboard.general.string = errorInfo }
    
    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }
            
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }
        
        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }
        
        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }
    
    func checkAndSaveBundleId() {
        if DataManager.shared.model.multiLCStatus == 2 {
            let scheme = UserDefaults.lcAppUrlScheme() ?? ""
            LCUtils.appGroupUserDefault.set(Bundle.main.bundleIdentifier, forKey: "LCBundleID.\(scheme)")
        }
        
        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }
        
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil), let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "Unable to determine application-identifier"
            errorShow = true
            return
        }
        
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }
        
        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }
        
        if(bundleId != correctBundleId) {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }
    
    func checkGetTaskAllow() {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil), (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }
    
    private func setupInitialRepositoriesIfNeeded() {
        let didSetupKey = "DidSetupDefaultRepositories"
        
        guard !UserDefaults.standard.bool(forKey: didSetupKey) else {
            return
        }
        
        let defaultApps: [AppRepository] = [
            AppRepository(
                name: "FlekSt0re Lib",
                iconUrl: "https://flekstore.com/pro_app/icons/apple-touch-icon.png",
                sourceURL: "Default app catalog",
                isSelected: true
            ),
            AppRepository(
                name: "Nabzclan - App Store",
                iconUrl: "https://cdn.nabzclan.vip/popupv3/imgs/logo-tras.png",
                sourceURL: "https://appstore.nabzclan.vip/repos/altstore.php",
                isSelected: false
            ),
            AppRepository(
                name: "AppTesters IPA Repo",
                iconUrl: "https://apptesters.org/apptesters-512x512.png",
                sourceURL: "https://repository.apptesters.org/",
                isSelected: false
            ),
            AppRepository(
                name: "Quantum Source",
                iconUrl: "https://quarksources.github.io/assets/ElementQ-Circled.png",
                sourceURL: "https://quarksources.github.io/dist/quantumsource.min.json",
                isSelected: false
            )
        ]
        
        if let data = try? JSONEncoder().encode(defaultApps) {
            UserDefaults.standard.set(data, forKey: "savedRepositories")
        }
        UserDefaults.standard.set(true, forKey: didSetupKey)
    }

    @MainActor
    private func verifyAccess(forceNetworkCheck: Bool = false) async {
        guard !isVerifyingAccess else {
            return
        }
        isVerifyingAccess = true
        await refreshBlockedStatus(forceNetworkCheck: forceNetworkCheck)
        runPostGateStartupIfNeeded()
        isVerifyingAccess = false
    }

    private func refreshBlockedStatus(forceNetworkCheck: Bool = false) async {
        #if targetEnvironment(simulator)
        await MainActor.run {
            isBlocked = false
            didFailBlockedStatusCheck = false
            hasCheckedBlockedStatus = true
        }
        return
        #endif

        guard let resolvedEncryptedUDID = resolveEncryptedUDID() else {
            await MainActor.run {
                accessVerificationFailureMessage = "User UDID is empty. Please contact FlekSt0re tech support."
                didFailBlockedStatusCheck = true
                hasCheckedBlockedStatus = true
            }
            return
        }

        let cached = AccessVerdictStore.load(for: resolvedEncryptedUDID)

        if let cached, cached.isBanned {
            await MainActor.run {
                applyBan(reason: cached.banReason, message: cached.banMessage)
            }
            refreshVerdictInBackground(for: resolvedEncryptedUDID)
            return
        }

        if let cached, !forceNetworkCheck, cached.isWithinGraceWindow() {
            await MainActor.run {
                applyAccessGranted()
            }
            if !cached.isFresh() {
                refreshVerdictInBackground(for: resolvedEncryptedUDID)
            }
            return
        }

        switch await AccessVerificationService.fetchStatus(encryptedUDID: resolvedEncryptedUDID) {
        case .answered(let response):
            AccessVerdictStore.save(response, for: resolvedEncryptedUDID)
            await MainActor.run {
                if response.isBanned {
                    applyBan(reason: response.banReason, message: response.message)
                } else {
                    applyAccessGranted()
                }
            }
        case .unreachable:
            await MainActor.run {
                applyVerificationFailure("Please check your internet connection and try again.")
            }
        case .serviceError:
            await MainActor.run {
                applyVerificationFailure("FlekSt0re is temporarily unavailable. Please try again in a few minutes.")
            }
        }
    }

    private func refreshVerdictInBackground(for encryptedUDID: String) {
        Task {
            guard case .answered(let response) = await AccessVerificationService.fetchStatus(
                encryptedUDID: encryptedUDID
            ) else {
                return
            }
            AccessVerdictStore.save(response, for: encryptedUDID)

            await MainActor.run {
                if response.isBanned {
                    applyBan(reason: response.banReason, message: response.message)
                } else {
                    applyAccessGranted()
                    runPostGateStartupIfNeeded()
                }
            }
        }
    }

    @MainActor
    private func applyBan(reason: String?, message: String?) {
        isBlocked = true
        blockedReason = formatBanReason(reason)
        blockedMessage = formatBanMessage(message)
        didFailBlockedStatusCheck = false
        hasCheckedBlockedStatus = true
    }

    @MainActor
    private func applyAccessGranted() {
        isBlocked = false
        didFailBlockedStatusCheck = false
        accessVerificationFailureMessage = "Please check your internet connection and try again."
        hasCheckedBlockedStatus = true
    }

    @MainActor
    private func applyVerificationFailure(_ message: String) {
        accessVerificationFailureMessage = message
        didFailBlockedStatusCheck = true
        hasCheckedBlockedStatus = true
    }

    @MainActor
    private func runPostGateStartupIfNeeded() {
        guard hasCheckedBlockedStatus, !isBlocked, !didFailBlockedStatusCheck, !didRunPostGateStartup else {
            return
        }
        didRunPostGateStartup = true

        sharedModel.selectedTab = .apps
        closeDuplicatedWindow()
        checkLastLaunchError()
        checkTeamId()
        checkAndSaveBundleId()
        checkGetTaskAllow()
        checkPrivateContainerBookmark()
        checkiOSBeta()
        processPendingURLIfNeeded()
    }

    private func resolveEncryptedUDID() -> String? {
        let stored = encryptedUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            return stored
        }

        if let bundleValue = Bundle.main.infoDictionary?["encryptedUdid"] as? String {
            let trimmed = bundleValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                encryptedUDID = trimmed
                return trimmed
            }
        }

        return nil
    }

    private func formatBanReason(_ rawReason: String?) -> String {
        let trimmed = rawReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Unavailable" }

        return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func formatBanMessage(_ rawMessage: String?) -> String {
        let trimmed = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Your access has been limited by the service." }

        return trimmed
    }

    func checkiOSBeta() {
        if let buildVersion = UIDevice.current.buildVersion,
           let lastChar = buildVersion.last,
           lastChar.isLowercase {
            isiOSBeta = true
        }
        updateBetaOverlay()
    }

    private func updateBetaOverlay() {
        let shouldShow: Bool
        switch betaBannerOverride {
        case 1: shouldShow = true
        case 2: shouldShow = false
        default: shouldShow = isiOSBeta
        }

        if let scene = sceneDelegate.window?.windowScene {
            if shouldShow {
                BetaOverlayManager.shared.show(on: scene)
            } else {
                BetaOverlayManager.shared.hide()
            }
        }
    }

    func checkPrivateContainerBookmark() {
        if sharedModel.multiLCStatus == 2 {
            return
        }
        if LCUtils.appGroupUserDefault.object(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil {
            return
        }
        
        guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else {
            errorInfo = "Failed to create bookmark for Documents folder?"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}

private struct AccessVerificationFailedView: View {
    let message: String
    @Binding var udid: String
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.yellow)

                Text("Unable to verify access")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .multilineTextAlignment(.center)
  
                TextField("Enter UDID", text: $udid)  
                    .textFieldStyle(.roundedBorder)  
                    .autocorrectionDisabled()  
                    .padding(.top, 8)  
  
                Button(action: onRetry) {
                    Text("Retry & Save")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            )
            .padding(.horizontal, 24)
        }
    }
}

private struct DeferBottomHomeGestureModifier: ViewModifier {
    func body(content: Content) -> AnyView {
        if #available(iOS 16.0, *) {
            return AnyView(
                content
                    .defersSystemGestures(on: .bottom)
                    .background(BottomEdgeGestureDeferralInstaller())
            )
        }
        return AnyView(content)
    }
}

private struct BottomEdgeGestureDeferralInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let root = window?.rootViewController else { return }
            ScreenEdgeGestureDeferrer.install(fromRoot: root)
        }
    }
}

private enum ScreenEdgeGestureDeferrer {
    private static var swizzledClasses = Set<ObjectIdentifier>()

    static func install(fromRoot root: UIViewController) {
        let base = hostingControllerBaseClass(of: root) ?? object_getClass(root)
        swizzle(hostingBase: base)
        refresh(from: root)
    }

    private static func hostingControllerBaseClass(of vc: UIViewController) -> AnyClass? {
        var result: AnyClass? = nil
        var cls: AnyClass? = object_getClass(vc)
        while let c = cls {
            if String(cString: class_getName(c)).contains("UIHostingController") {
                result = c
            }
            cls = class_getSuperclass(c)
        }
        return result
    }

    private static func swizzle(hostingBase cls: AnyClass?) {
        guard let cls else { return }
        let id = ObjectIdentifier(cls)
        guard !swizzledClasses.contains(id) else { return }
        swizzledClasses.insert(id)

        let preferredSel = #selector(getter: UIViewController.preferredScreenEdgesDeferringSystemGestures)
        if let method = class_getInstanceMethod(cls, preferredSel) {
            let previousIMP = method_getImplementation(method)
            let typeEnc = method_getTypeEncoding(method)
            let block: @convention(block) (UIViewController) -> UIRectEdge = { obj in
                typealias Getter = @convention(c) (UIViewController, Selector) -> UIRectEdge
                let previous = unsafeBitCast(previousIMP, to: Getter.self)(obj, preferredSel)
                return previous.union(.bottom)
            }
            class_replaceMethod(cls, preferredSel, imp_implementationWithBlock(block), typeEnc)
        }

        let childSel = #selector(getter: UIViewController.childForScreenEdgesDeferringSystemGestures)
        if let method = class_getInstanceMethod(cls, childSel) {
            let typeEnc = method_getTypeEncoding(method)
            let block: @convention(block) (UIViewController) -> UIViewController? = { _ in nil }
            class_replaceMethod(cls, childSel, imp_implementationWithBlock(block), typeEnc)
        }
    }

    private static func refresh(from root: UIViewController) {
        var vc: UIViewController? = root
        while let current = vc {
            current.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            vc = current.presentedViewController
        }
    }
}
